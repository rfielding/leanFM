import LeanFM.Session.Global

/-!
# Calls and typestate, derived from a global type (clause selfhost.session.calls)

`cause` packages interactions into calls. A message whose cause chain reaches a request from its
receiver to its sender is a response to that request (the rule `Global.httpCuts` and
`Global.diagram` use too); anything else is a request. A request, the responses that answer it,
and the detail between them make one call: an HTTP operation with its status codes, or a function
from its parameters to its result. The detail of a call is every message its request causes,
directly or through others, except its responses and what they cause; requests in the detail are
calls nested inside it.

`Global.calls` lists a protocol's calls as that tree. `Local.typestate` reads one role's projection
as a typestate API: every state of the role is a type, every send, event or receive a method that
consumes the state and returns the next one, a select several methods on one state, an offer one
receive whose result is a sum. `prev` order (concurrency) is not here: it belongs to recorded runs.

Negative requirements: a response is never listed as a call of its own; a message is never placed
in the detail of a call whose response caused it; protocol text is shown, never interpreted.
-/

namespace LeanFM.Session

variable {R : Type}

/-- Every message once, in the order written; an included protocol's messages in place. A choice
copies its continuation into every branch, so a message is kept at its first appearance. -/
def Global.messages [ToString R] (g : Global R) : List (Interaction R) :=
  let key (i : Interaction R) :=
    s!"{i.id.getD ""}|{i.label}|{i.src}|{i.dst}|{i.cause.getD ""}"
  let rec go : Global R → List (Interaction R)
    | .msg i k => i :: go k
    | .act _ _ k => go k
    | .choice bs => bs.attach.flatMap fun ⟨b, _⟩ => go b
    | .par bs k | .join _ bs k => (bs.attach.flatMap fun ⟨b, _⟩ => go b) ++ go k
    | .loop _ b => go b
    | .sessions b k | .box _ b k => go b ++ go k
    | .var _ | .done => []
  (go g).foldl (fun acc i => if acc.any (key · == key i) then acc else acc ++ [i]) []

/-- A message with the request it answers, if it is a response. -/
structure Classified (R : Type) where
  msg : Interaction R
  answers : Option String

def Global.classify [DecidableEq R] [ToString R] (g : Global R) : List (Classified R) :=
  g.messages.foldl (fun acc m =>
    let rec walk : Option String → Nat → Option String
      | _, 0 | none, _ => none
      | some c, fuel + 1 => match acc.find? (·.msg.id == some c) with
        | some a =>
          if a.answers.isNone && a.msg.src == m.dst && a.msg.dst == m.src then some c
          else walk a.msg.cause fuel
        | none => none
    acc ++ [{ msg := m, answers := walk m.cause 64 }]) []

structure Call (R : Type) where
  request   : Interaction R
  responses : List (Interaction R)
  nested    : List (Call R)

namespace Calls

/-- The ids up `m`'s cause chain, nearest first. -/
def ancestors (ms : List (Classified R)) (m : Interaction R) : List String :=
  let rec go : Option String → Nat → List String
    | _, 0 | none, _ => []
    | some c, fuel + 1 => c :: go ((ms.find? (·.msg.id == some c)).bind (·.msg.cause)) fuel
  go m.cause 64

def responsesOf (ms : List (Classified R)) (r : String) : List (Interaction R) :=
  (ms.filter (·.answers == some r)).map (·.msg)

/-- Whether `m` is in the detail of request `r`: its cause chain reaches `r` before any of `r`'s
responses. -/
def inDetail (ms : List (Classified R)) (r : String) (m : Interaction R) : Bool :=
  let resp := (responsesOf ms r).filterMap (·.id)
  let rec go : List String → Bool
    | [] => false
    | a :: rest => if resp.contains a then false else if a == r then true else go rest
  go (ancestors ms m)

/-- The call `m` is nested in: the nearest request up its cause chain whose detail holds it. -/
def parent (ms : List (Classified R)) (m : Interaction R) : Option String :=
  (ancestors ms m).find? fun a =>
    (ms.any fun c => c.msg.id == some a && c.answers.isNone) && inDetail ms a m

end Calls

def Global.calls [DecidableEq R] [ToString R] (g : Global R) : List (Call R) :=
  let ms := g.classify
  let requests := (ms.filter (·.answers.isNone)).map (·.msg)
  let rec build (fuel : Nat) (under : Option String) : List (Call R) :=
    match fuel with
    | 0 => []
    | fuel + 1 =>
      (requests.filter (Calls.parent ms · == under)).map fun r =>
        { request := r
          responses := match r.id with | some id => Calls.responsesOf ms id | none => []
          nested := match r.id with | some id => build fuel (some id) | none => [] }
  build 16 none

def Interaction.withStatus (i : Interaction R) : String :=
  i.label ++ (match i.status with | some s => s!" {s}" | none => "")

partial def Call.lines [ToString R] (ind : String) (c : Call R) : List String :=
  let r := c.request
  let name := (match r.id with | some x => s!"{x}: " | none => "") ++ r.label
  let ret := if c.responses.isEmpty then "no reply"
    else " | ".intercalate (c.responses.map Interaction.withStatus)
  let route := match r.route with | some x => s!"  {x}" | none => ""
  s!"{ind}{name}  {r.src} → {r.dst}{route}" :: s!"{ind}  returns {ret}" ::
    c.nested.flatMap (Call.lines (ind ++ "    "))

/-- The calls of a protocol, two lines each (the request, then what it returns), nested calls
indented under the call they serve. -/
def Global.callsText [DecidableEq R] [ToString R] (g : Global R) : String :=
  "\n".intercalate (g.calls.flatMap (Call.lines ""))

/-! ## Typestate -/

namespace Typestate

structure St where
  n : Nat := 0
  lines : List (Nat × String) := []

abbrev M := StateM St

def fresh : M Nat := modifyGet fun s => (s.n, { s with n := s.n + 1 })
def line (i : Nat) (t : String) : M Unit := modify fun s => { s with lines := s.lines ++ [(i, t)] }
def nm (i : Nat) : String := s!"S{i}"

/-- `a` then `b`: `b` replaces every place `a` ends. -/
partial def append : Local R → Local R → Local R
  | .send t l k, b => .send t l (append k b)
  | .recv f l k, b => .recv f l (append k b)
  | .act l k, b => .act l (append k b)
  | .select bs, b => .select (bs.map (append · b))
  | .offer bs, b => .offer (bs.map (append · b))
  | .par bs k, b => .par bs (append k b)
  | .loop n body, b => .loop n (append body b)
  | .sessions body k, b => .sessions body (append k b)
  | .var n, _ => .var n
  | .done, b => b

/-- A `par` the role takes part in on one side only is no concurrency for that role: it is that
side, then what follows. -/
partial def norm : Local R → Local R
  | .par bs k =>
    match bs.filter (fun b => match b with | .done => false | _ => true) with
    | [] => norm k
    | [b] => norm (append b k)
    | live => .par live k
  | l => l

variable [ToString R]

mutual
/-- The state a local type starts in. -/
partial def ts (env : List (String × String)) (l : Local R) : M String :=
  match norm l with
  | .done => pure "End"
  | .var n => pure ((env.lookup n).getD s!"?{n}")
  | .loop n b => do
      let i ← fresh
      edges ((n, nm i) :: env) i b
      pure (nm i)
  | l' => do
      let i ← fresh
      edges env i l'
      pure (nm i)

/-- The methods of state `i` that `l` gives it. -/
partial def edges (env : List (String × String)) (i : Nat) (l : Local R) : M Unit :=
  match norm l with
  | .send to l k => do
      let k' ← ts env k
      line i s!"{nm i}.send{l}(m : {l}) : {k'}    -- to {to}"
  | .recv fr l k => do
      let k' ← ts env k
      line i s!"{nm i}.receive() : {l} × {k'}    -- from {fr}"
  | .act l k => do
      let k' ← ts env k
      line i s!"{nm i}.{l}() : {k'}"
  | .select bs => do
      for b in bs do edges env i b
  | .offer bs => do
      let alts ← bs.mapM fun b => match norm b with
        | .recv fr l k => do return s!"{l} × {← ts env k} (from {fr})"
        | .done => pure "nothing × End"
        | b => do return s!"_ × {← ts env b}"
      line i s!"{nm i}.receive() : {" | ".intercalate alts}"
  | .par bs k => do
      let subs ← bs.mapM (ts env)
      let k' ← ts env k
      line i s!"{nm i}.fork() : ({" ∥ ".intercalate subs}) then {k'}"
  | .loop n b => edges ((n, nm i) :: env) i b
  | .sessions b k => do
      let b' ← ts env b
      let k' ← ts env k
      line i s!"{nm i}.serve() : many {b'} then {k'}"
  | .var n => line i s!"{nm i}.continue() : {(env.lookup n).getD s!"?{n}"}"
  | .done => line i s!"{nm i}.stop() : End"
end

end Typestate

/-- One role's projection as a typestate API: the role starts in `S0`, each method consumes its
state and returns the next, and `End` has no methods. -/
def Local.typestate [ToString R] (l : Local R) : String :=
  let (start, st) := (Typestate.ts [] l).run {}
  let sorted := st.lines.mergeSort (fun a b => a.1 ≤ b.1)
  "\n".intercalate (s!"start : {start}" :: sorted.map (·.2))

/-- Every listed role's typestate API, or why its projection failed. -/
def Global.typestates [DecidableEq R] [ToString R] (g : Global R) (roles : List R) :
    List (R × Except String String) :=
  roles.map fun r => (r, (g.project r).map Local.typestate)

end LeanFM.Session
