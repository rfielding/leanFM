import LeanFM.Artifacts

/-!
# Global session types

The core of the session-typing library, and the only module a protocol has to pay for.

A global type is a grammar whose terminals are messages between roles. Roles are values of any
type the user chooses; message labels are the names of ordinary Lean structures (the protocol's
vocabulary), so a guard such as `p.amount = q.price` is type-checked Lean, not a string.

Nothing here knows about queues, networks or HTTP. Those live in `Physics`, `Topology` and `Http`,
and a protocol that never imports them never pays for them.
-/

namespace LeanFM.Session

/-! ## Payloads and typed guards -/

/-- Decoded payloads of the messages seen so far on one run, by message id. -/
abbrev Env := List (String × Dynamic)

def Env.find (env : Env) (id : String) (α : Type) [TypeName α] : Option α :=
  (env.lookup id).bind (·.get? α)

/-- A `where` clause. The protocol syntax elaborates the clause as a Lean `Bool` over the typed
payloads it names, so it is checked when the protocol is written; `text` is kept for display. -/
structure Guard where
  text : String
  eval : Env → Option Bool

instance : Repr Guard := ⟨fun g _ => repr g.text⟩

/-! ## Interactions and global types -/

structure Interaction (R : Type) where
  id    : Option String := none
  label : String
  src   : R
  dst   : R
  cause : Option String := none
  guard : Option Guard := none
  deriving Repr

inductive Global (R : Type) where
  /-- One message from `i.src` to `i.dst`, then `k`. -/
  | msg    (i : Interaction R) (k : Global R)
  /-- An event at one role only, such as a timer firing; nobody else observes it. -/
  | act    (role : R) (label : String) (k : Global R)
  /-- Exactly one branch happens. Nobody names the role that decides: it is the one role that
  starts every branch, by sending its first message or by an event of its own (`decider`). -/
  | choice (branches : List (Global R))
  /-- All branches, interleaved, then `k`. -/
  | par    (branches : List (Global R)) (k : Global R)
  /-- Any `need` of the branches, then `k`; the rest are not cancelled unless a message says so. -/
  | join   (need : Nat) (branches : List (Global R)) (k : Global R)
  | loop   (name : String) (body : Global R)
  | var    (name : String)
  /-- Any number of instances of `body`, concurrently, then `k`. Each instance is a session of
  its own, as each HTTP request is: a thread is forked for it when its first message arrives, and
  it shares nothing with the other instances but the state behind them. -/
  | sessions (body : Global R) (k : Global R)
  /-- A named box around `body` (what `include` writes), then `k`. It changes nothing about the
  protocol: every check sees `body` followed by `k`. It is there for people, so that a diagram can
  draw the included protocol as a box to open and close. -/
  | box (name : String) (body : Global R) (k : Global R)
  | done
  deriving Repr, Inhabited

/-- One step of a linear run. -/
inductive Step (R : Type) where
  | msg (i : Interaction R)
  | act (role : R) (label : String)
  deriving Inhabited


/-! ## Projection to local types -/

inductive Local (R : Type) where
  | send   (to : R) (label : String) (k : Local R)
  | recv   (fromRole : R) (label : String) (k : Local R)
  | act    (label : String) (k : Local R)
  /-- This role chooses. -/
  | select (branches : List (Local R))
  /-- Another role chose; this role learns which branch from what arrives. -/
  | offer  (branches : List (Local R))
  | par    (branches : List (Local R)) (k : Local R)
  | loop   (name : String) (body : Local R)
  | var    (name : String)
  /-- Serve (or start) any number of instances of `body`, each on its own thread, then `k`. -/
  | sessions (body : Local R) (k : Local R)
  | done
  deriving Repr, BEq, Inhabited


namespace Local

/-- A local type as indented lines, in the protocol syntax's words: `send`, `receive`, `select`
(this role chooses) and `offer` (another role chose, and what arrives says which). -/
partial def lines {R : Type} [ToString R] [BEq R] (ind : String := "") : Local R → List String
  | .send to l k => s!"{ind}send {l} to {to};" :: lines ind k
  | .recv fr l k => s!"{ind}receive {l} from {fr};" :: lines ind k
  | .act l k => s!"{ind}{l};" :: lines ind k
  | .select bs => block ind "select" "or" bs
  | .offer bs => block ind "offer" "or" bs
  | .par bs k => block ind "par" "and" (bs.filter (· != .done)) ++ lines ind k
  | .loop n b => (s!"{ind}rec {n} " ++ "{") :: lines (ind ++ "  ") b ++ [ind ++ "}"]
  | .var n => [s!"{ind}continue {n};"]
  | .sessions b k => (s!"{ind}sessions " ++ "{") :: lines (ind ++ "  ") b ++ [ind ++ "}"] ++ lines ind k
  | .done => []
where
  block (ind word sep : String) (bs : List (Local R)) : List String :=
    match bs.map (lines (ind ++ "  ")) with
    | [] => []
    | [b] => if word == "par" then lines ind (bs.headD .done) else ((s!"{ind}{word} " ++ "{") :: b) ++ [ind ++ "}"]
    | b :: rest =>
      ((s!"{ind}{word} " ++ "{") :: b) ++ rest.flatMap (fun r => (ind ++ "} " ++ sep ++ " {") :: r) ++ [ind ++ "}"]

def render {R : Type} [ToString R] [BEq R] (l : Local R) : String := "\n".intercalate (lines "" l)

end Local

namespace Global

variable {R : Type}

/-- Sequential composition: `g` runs wherever `f` reaches `done`. This is how productions stack:
each one is written as if it were the whole protocol. -/
partial def andThen : Global R → Global R → Global R
  | .msg i k, g => .msg i (andThen k g)
  | .act r l k, g => .act r l (andThen k g)
  | .choice bs, g => .choice (bs.map (andThen · g))
  | .par bs k, g => .par bs (andThen k g)
  | .join n bs k, g => .join n bs (andThen k g)
  | .loop n b, g => .loop n (andThen b g)
  | .var n, _ => .var n
  | .sessions b k, g => .sessions b (andThen k g)
  | .box n b k, g => .box n b (andThen k g)
  | .done, g => g

partial def labels : Global R → List String
  | .msg i k => i.label :: labels k
  | .act _ l k => l :: labels k
  | .choice bs => bs.flatMap labels
  | .par bs k | .join _ bs k => bs.flatMap labels ++ labels k
  | .loop _ b => labels b
  | .sessions b k => labels b ++ labels k
  | .box _ b k => labels (andThen b k)
  | .var _ | .done => []

/-- Linear runs: every branch of every choice, each loop body once, parallel branches in order.

For the structural checks below (choice, cause, projection) this is exact, not an approximation,
when each parallel branch is its own session: a thread per session that ingests only the messages
its session expects and sends only the ones it owes cannot be affected by how another session's
messages interleave with its own. Interleavings matter only where sessions share state (two
Paxos ballots meeting in an acceptor's promise); the model checker explores those. -/
partial def runs : Global R → List (List (Step R))
  | .msg i k => (runs k).map (.msg i :: ·)
  | .act r l k => (runs k).map (.act r l :: ·)
  | .choice bs => bs.flatMap runs
  | .par bs k | .join _ bs k =>
    let front := bs.foldl (fun acc b => acc.flatMap (fun p => (runs b).map (p ++ ·))) [[]]
    front.flatMap (fun p => (runs k).map (p ++ ·))
  | .loop _ b => runs b
  -- no instance, or one: instances are independent sessions, so one stands for all of them
  | .sessions b k => runs k ++ (runs b).flatMap (fun p => (runs k).map (p ++ ·))
  | .box _ b k => runs (andThen b k)
  | .var _ | .done => [[]]

def _root_.LeanFM.Session.Step.involves [DecidableEq R] (r : R) : Step R → Bool
  | .msg i => i.src == r || i.dst == r
  | .act a _ => a == r

def _root_.LeanFM.Session.Step.label : Step R → String
  | .msg i => i.label
  | .act _ l => l

/-- The role that takes a step: the sender of a message, or the role an event happens at. -/
def _root_.LeanFM.Session.Step.actor : Step R → R
  | .msg i => i.src
  | .act a _ => a

/-- The first step of a branch, if it has one before looping or finishing. -/
def first (g : Global R) : List (Step R) :=
  (runs g).filterMap (·.head?)

/-! ## Well-formedness -/

/-- The role that decides a choice: the one role that starts every branch, by sending its first
message or by an event of its own. An empty branch (`or { }`) is that role choosing to do nothing;
whether the others can tell is projection's question. Branches started by different roles leave no
role to decide: that is a race (a non-local choice), since each could start its branch at once. -/
def decider [DecidableEq R] [ToString R] (bs : List (Global R)) : Except String R :=
  let firsts := (bs.map first).filter (!·.isEmpty)
  if firsts.isEmpty then
    .error "a choice none of whose branches does anything, so no role decides it"
  else
    match (firsts.flatten.map Step.actor).eraseDups with
    | [r] => .ok r
    | rs =>
      let who := rs.map (fun r =>
        let ls := ((firsts.flatten.filter (·.actor == r)).map Step.label).eraseDups
        s!"{r} starts {" or ".intercalate ls}")
      .error s!"no single role decides a choice, so it is a race: {"; ".intercalate who}"

/-- LeanFM's choice rule: every choice is internal to one role, the one that starts every
branch (`decider`), and the branches must begin differently. Whether every other role can tell
which branch was taken is checked by projection. -/
partial def choiceIssues [DecidableEq R] [ToString R] : Global R → List String
  | .msg _ k | .act _ _ k => choiceIssues k
  | .choice bs =>
    -- a branch may begin with a nested choice; count each branch's distinct first events once
    let ls := bs.flatMap (fun b => ((first b).map Step.label).eraseDups)
    (match decider bs with
      | .error e => [e]
      | .ok c => if ls.eraseDups.length < ls.length then [s!"{c}'s choice: two branches start with the same event"] else []) ++
    bs.flatMap choiceIssues
  | .par bs k | .join _ bs k => bs.flatMap choiceIssues ++ choiceIssues k
  | .loop _ b => choiceIssues b
  | .sessions b k => choiceIssues b ++ choiceIssues k
  | .box _ b k => choiceIssues (andThen b k)
  | .var _ | .done => []

/-- The classic multiparty rule, for comparison: the chooser must *send* the first message of
every branch; there are no events at one role alone. -/
partial def classicChoiceIssues [DecidableEq R] [ToString R] : Global R → List String
  | .msg _ k | .act _ _ k => classicChoiceIssues k
  | .choice bs =>
    let bad := (bs.flatMap first).filter (fun s => match s with | .msg _ => false | .act _ _ => true)
    (match decider bs with | .error e => [e] | .ok _ => []) ++
    (bad.map (fun s => s!"a choice starts with {s.label}, which is not a message")) ++ bs.flatMap classicChoiceIssues
  | .par bs k | .join _ bs k => bs.flatMap classicChoiceIssues ++ classicChoiceIssues k
  | .loop _ b => classicChoiceIssues b
  | .sessions b k => classicChoiceIssues b ++ classicChoiceIssues k
  | .box _ b k => classicChoiceIssues (andThen b k)
  | .var _ | .done => []

/-- A role may cause-point only to messages it sent or received: it decides from its own history. -/
def causeIssues [DecidableEq R] [ToString R] (g : Global R) : List String :=
  (runs g).flatMap (fun run =>
    let (_, issues) := run.foldl (fun (acc : List (R × String) × List String) s =>
      let (known, issues) := acc
      match s with
      | .act _ _ => acc
      | .msg i =>
        let issues := match i.cause with
          | some c => if known.contains (i.src, c) then issues
                      else issues ++ [s!"{i.label}: {i.src} never saw {c}"]
          | none => issues
        let known := match i.id with
          | some id => known ++ [(i.src, id), (i.dst, id)]
          | none => known
        (known, issues)) ([], [])
    issues) |>.eraseDups

/-- The branches a role may find itself in, with nested offers flattened. -/
def _root_.LeanFM.Session.Local.alternatives {R : Type} : Local R → List (Local R)
  | .offer qs => qs
  | l => [l]

def _root_.LeanFM.Session.Local.firstReceived {R : Type} : Local R → Option String
  | .recv _ l _ => some l
  | _ => none

/-- The messages a role may receive before it does anything else, however deep they are; `none`
when on some path it would send or act first. -/
partial def _root_.LeanFM.Session.Local.firstReceives {R : Type} [BEq R] : Local R → Option (List String)
  | .recv _ l _ => some [l]
  | .send .. | .act .. => none
  | .select bs | .offer bs => bs.foldlM (fun acc b => do pure (acc ++ (← b.firstReceives))) []
  | .par bs k =>
    let live := bs.filter (· != .done)
    if live.isEmpty then k.firstReceives
    else live.foldlM (fun acc b => do pure (acc ++ (← b.firstReceives))) []
  | .loop _ b => b.firstReceives
  | .sessions b k => do pure ((← b.firstReceives) ++ (← k.firstReceives))
  | .var _ | .done => some []

/-- Merge what one role sees of the branches of a choice it does not make.

* Branches that look the same to the role need no merging.
* Branches that begin with different messages the role receives become an `offer`: the role
  learns the branch from what arrives. Two that begin with the same message must continue alike.
* A role that has not yet taken part in this session may be absent from some branches: its part
  of the session starts with the first message it receives, as a thread forked for that session,
  so a branch that never contacts it asks nothing of it. In a loop, a branch that only goes round
  again without contacting it is absent in the same way: the next round is a new session for it. -/
def mergeBranches [DecidableEq R] [ToString R] (r c : R) (started : Bool) (ps : List (Local R)) :
    Except String (Local R) := do
  let alts := ps.flatMap Local.alternatives
  match alts with
  | [] => pure .done
  | p :: rest =>
    if rest.all (· == p) then return p
    let isAbsent : Local R → Bool := fun l => match l with
      | .done => true
      | .var _ => !started
      | _ => false
    let absent := alts.filter isAbsent
    -- A role that has not started does nothing until something reaches it. It needs no message
    -- now, only that whatever reaches it first tells the branches apart.
    if !started then
      let live := (alts.filter (!isAbsent ·)).eraseDups
      let firsts := live.map Local.firstReceives
      if firsts.all (fun f => match f with | some (_ :: _) => true | _ => false) then
        let ls := firsts.filterMap id
        if (ls.flatten.eraseDups.length == ls.flatten.length) then
          return .offer (live ++ absent.eraseDups)
    let receiving := alts.filter (fun l => l.firstReceived.isSome)
    if absent.length + receiving.length < alts.length || (!absent.isEmpty && started) then
      throw s!"{r} cannot tell which branch {c} chose"
    let labels := (receiving.filterMap Local.firstReceived).eraseDups
    let merged ← labels.mapM (fun lbl => do
      let same := receiving.filter (·.firstReceived == some lbl)
      match same with
      | q :: qs => if qs.all (· == q) then pure q else throw s!"{r} cannot tell which branch {c} chose after {lbl}"
      | [] => throw s!"{r} cannot tell which branch {c} chose")
    return .offer (merged ++ absent.eraseDups)

/-- Whether a role takes part in a global type: sends, receives, acts or decides. A `continue`
to a loop outside the term counts, since it leads back into that loop; a whole loop the role never
appears in does not. -/
partial def involvesIn [DecidableEq R] (bound : List String) (r : R) : Global R → Bool
  | .msg i k => i.src == r || i.dst == r || involvesIn bound r k
  | .act a _ k => a == r || involvesIn bound r k
  -- the role that decides starts a branch, so it is involved in that branch
  | .choice bs => bs.any (involvesIn bound r)
  | .par bs k | .join _ bs k => bs.any (involvesIn bound r) || involvesIn bound r k
  | .loop n b => involvesIn (n :: bound) r b
  | .sessions b k => involvesIn bound r b || involvesIn bound r k
  | .box _ b k => involvesIn bound r (andThen b k)
  | .var n => !bound.contains n
  | .done => false

def involves [DecidableEq R] (r : R) (g : Global R) : Bool := involvesIn [] r g

/-- Project the global type onto one role. `started` says whether the role has already taken
part in this session on the current path. Fails where the role would have to know a choice it is
never told about: the knowledge-of-choice condition. -/
partial def projectFrom [DecidableEq R] [ToString R] (r : R) (started : Bool) (g : Global R) :
    Except String (Local R) :=
  -- a role that takes no part in what follows has nothing left to do in it
  if !involves r g then pure .done else
  match g with
  | .msg i k => do
    let involved := i.src == r || i.dst == r
    let k' ← projectFrom r (started || involved) k
    if i.src == r then pure (.send i.dst i.label k')
    else if i.dst == r then pure (.recv i.src i.label k')
    else pure k'
  | .act a l k => do
    let k' ← projectFrom r (started || a == r) k
    pure (if a == r then .act l k' else k')
  | .choice bs => do
    let c ← decider bs
    let ps ← bs.mapM (projectFrom r (started || c == r))
    if c == r then pure (.select ps) else mergeBranches r c started ps
  | .par bs k => do pure (.par (← bs.mapM (projectFrom r started)) (← projectFrom r started k))
  | .join _ bs k => do pure (.par (← bs.mapM (projectFrom r started)) (← projectFrom r started k))
  | .loop n b => do pure (.loop n (← projectFrom r started b))
  | .var n => pure (.var n)
  -- every instance is a fresh session: nobody has taken part in it yet
  | .box _ b k => projectFrom r started (andThen b k)
  | .sessions b k => do
    let k' ← projectFrom r started k
    if involves r b then pure (.sessions (← projectFrom r false b) k') else pure k'
  | .done => pure .done

def project [DecidableEq R] [ToString R] (r : R) (g : Global R) : Except String (Local R) :=
  projectFrom r false g

/-- Every issue of the core rules, for the given roles. -/
def issues [DecidableEq R] [ToString R] (g : Global R) (roles : List R) : List String :=
  (choiceIssues g ++ causeIssues g ++
    roles.filterMap (fun r => match (project r g : Except String (Local R)) with | .error e => some e | .ok _ => none)).eraseDups

/-! ## Bridge to the durable artifact format -/

instance : Inhabited GrammarExpr := ⟨.empty⟩

/-- Translate to the `GrammarExpr` that LeanFM's existing artifacts and checks consume. -/
partial def toGrammarExpr [ToString R] (task : String) : Global R → GrammarExpr
  | .msg i k => .seq (.event ⟨task, toString i.src, toString i.dst, i.label⟩) (toGrammarExpr task k)
  | .act r l k => .seq (.event ⟨task, toString r, toString r, l⟩) (toGrammarExpr task k)
  | .choice bs => .choice (bs.map (toGrammarExpr task))
  | .par bs k => .seq (bs.foldl (fun acc b => .parallel acc (toGrammarExpr task b)) .empty) (toGrammarExpr task k)
  | .join n bs k => .seq (.thresholdJoin n (bs.map (toGrammarExpr task))) (toGrammarExpr task k)
  | .loop n b => .seq (.repeat (toGrammarExpr task b)) (.ref n)
  | .sessions b k => .seq (.repeat (toGrammarExpr task b)) (toGrammarExpr task k)
  | .box _ b k => toGrammarExpr task (andThen b k)
  | .var _ => .empty
  | .done => .empty

end Global
end LeanFM.Session
