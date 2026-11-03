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
  /-- `role` decides which branch happens, from what it has sent and what has arrived. -/
  | choice (role : R) (branches : List (Global R))
  /-- All branches, interleaved, then `k`. -/
  | par    (branches : List (Global R)) (k : Global R)
  /-- Any `need` of the branches, then `k`; the rest are not cancelled unless a message says so. -/
  | join   (need : Nat) (branches : List (Global R)) (k : Global R)
  | loop   (name : String) (body : Global R)
  | var    (name : String)
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
  | done
  deriving Repr, BEq, Inhabited


namespace Local

/-- A local type as indented lines, in the protocol syntax's words: `send`, `receive`, `select`
(this role chooses) and `offer` (another role chose, and what arrives says which). -/
partial def lines {R : Type} [ToString R] (ind : String := "") : Local R → List String
  | .send to l k => s!"{ind}send {l} to {to};" :: lines ind k
  | .recv fr l k => s!"{ind}receive {l} from {fr};" :: lines ind k
  | .act l k => s!"{ind}{l};" :: lines ind k
  | .select bs => block ind "select" bs
  | .offer bs => block ind "offer" bs
  | .par bs k => block ind "par" bs ++ lines ind k
  | .loop n b => (s!"{ind}rec {n} " ++ "{") :: lines (ind ++ "  ") b ++ [ind ++ "}"]
  | .var n => [s!"{ind}continue {n};"]
  | .done => []
where
  block (ind word : String) (bs : List (Local R)) : List String :=
    match bs.map (lines (ind ++ "  ")) with
    | [] => []
    | b :: rest =>
      ((s!"{ind}{word} " ++ "{") :: b) ++ rest.flatMap (fun r => (ind ++ "} or {") :: r) ++ [ind ++ "}"]

def render {R : Type} [ToString R] (l : Local R) : String := "\n".intercalate (lines "" l)

end Local

namespace Global

variable {R : Type}

/-- Sequential composition: `g` runs wherever `f` reaches `done`. This is how productions stack:
each one is written as if it were the whole protocol. -/
partial def andThen : Global R → Global R → Global R
  | .msg i k, g => .msg i (andThen k g)
  | .act r l k, g => .act r l (andThen k g)
  | .choice r bs, g => .choice r (bs.map (andThen · g))
  | .par bs k, g => .par bs (andThen k g)
  | .join n bs k, g => .join n bs (andThen k g)
  | .loop n b, g => .loop n (andThen b g)
  | .var n, _ => .var n
  | .done, g => g

partial def labels : Global R → List String
  | .msg i k => i.label :: labels k
  | .act _ l k => l :: labels k
  | .choice _ bs => bs.flatMap labels
  | .par bs k | .join _ bs k => bs.flatMap labels ++ labels k
  | .loop _ b => labels b
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
  | .choice _ bs => bs.flatMap runs
  | .par bs k | .join _ bs k =>
    let front := bs.foldl (fun acc b => acc.flatMap (fun p => (runs b).map (p ++ ·))) [[]]
    front.flatMap (fun p => (runs k).map (p ++ ·))
  | .loop _ b => runs b
  | .var _ | .done => [[]]

def _root_.LeanFM.Session.Step.involves [DecidableEq R] (r : R) : Step R → Bool
  | .msg i => i.src == r || i.dst == r
  | .act a _ => a == r

def _root_.LeanFM.Session.Step.label : Step R → String
  | .msg i => i.label
  | .act _ l => l

/-- The first step of a branch, if it has one before looping or finishing. -/
def first (g : Global R) : List (Step R) :=
  (runs g).filterMap (·.head?)

/-! ## Well-formedness -/

/-- LeanFM's choice rule: every choice is internal to one role. Each branch must begin with a
message that role sends, or with an event at that role alone (its timer, its own decision), and
the branches must begin differently. Whether every other role can tell which branch was taken is
checked by projection. -/
partial def choiceIssues [DecidableEq R] [ToString R] : Global R → List String
  | .msg _ k | .act _ _ k => choiceIssues k
  | .choice c bs =>
    let firsts := bs.flatMap first
    let bad := firsts.filter (fun s => match s with
      | .msg i => !(i.src == c) | .act a _ => !(a == c))
    -- a branch may begin with a nested choice; count each branch's distinct first events once
    let ls := bs.flatMap (fun b => ((first b).map Step.label).eraseDups)
    (bad.map (fun s => s!"choice at {c}: a branch starts with {s.label}, which {c} does not decide")) ++
    (if ls.eraseDups.length < ls.length then [s!"choice at {c}: two branches start with the same event"] else []) ++
    bs.flatMap choiceIssues
  | .par bs k | .join _ bs k => bs.flatMap choiceIssues ++ choiceIssues k
  | .loop _ b => choiceIssues b
  | .var _ | .done => []

/-- The classic multiparty rule, for comparison: the chooser must *send* the first message of
every branch; there are no events at one role alone. -/
partial def classicChoiceIssues [DecidableEq R] [ToString R] : Global R → List String
  | .msg _ k | .act _ _ k => classicChoiceIssues k
  | .choice c bs =>
    let bad := (bs.flatMap first).filter (fun s => match s with
      | .msg i => !(i.src == c) | .act a _ => !(a == c))
    (bad.map (fun s => s!"choice at {c}: {s.label} is not sent by {c}")) ++ bs.flatMap classicChoiceIssues
  | .par bs k | .join _ bs k => bs.flatMap classicChoiceIssues ++ classicChoiceIssues k
  | .loop _ b => classicChoiceIssues b
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

/-- Merge what one role sees of the branches of a choice it does not make.

* Branches that look the same to the role need no merging.
* Branches that begin with different messages the role receives become an `offer`: the role
  learns the branch from what arrives. Two that begin with the same message must continue alike.
* A role that has not yet taken part in this session may be absent from some branches: its part
  of the session starts with the first message it receives, as a thread forked for that session,
  so a branch that never contacts it asks nothing of it. -/
def mergeBranches [DecidableEq R] [ToString R] (r c : R) (started : Bool) (ps : List (Local R)) :
    Except String (Local R) := do
  let alts := ps.flatMap Local.alternatives
  match alts with
  | [] => pure .done
  | p :: rest =>
    if rest.all (· == p) then return p
    let absent := alts.filter (· == .done)
    let receiving := alts.filter (fun l => l.firstReceived.isSome)
    if absent.length + receiving.length < alts.length || (!absent.isEmpty && started) then
      throw s!"{r} cannot tell which branch {c} chose"
    let labels := (receiving.filterMap Local.firstReceived).eraseDups
    let merged ← labels.mapM (fun lbl => do
      let same := receiving.filter (·.firstReceived == some lbl)
      match same with
      | q :: qs => if qs.all (· == q) then pure q else throw s!"{r} cannot tell which branch {c} chose after {lbl}"
      | [] => throw s!"{r} cannot tell which branch {c} chose")
    return .offer (merged ++ (if absent.isEmpty then [] else [.done]))

/-- Project the global type onto one role. `started` says whether the role has already taken
part in this session on the current path. Fails where the role would have to know a choice it is
never told about: the knowledge-of-choice condition. -/
partial def projectFrom [DecidableEq R] [ToString R] (r : R) (started : Bool) : Global R → Except String (Local R)
  | .msg i k => do
    let involved := i.src == r || i.dst == r
    let k' ← projectFrom r (started || involved) k
    if i.src == r then pure (.send i.dst i.label k')
    else if i.dst == r then pure (.recv i.src i.label k')
    else pure k'
  | .act a l k => do
    let k' ← projectFrom r (started || a == r) k
    pure (if a == r then .act l k' else k')
  | .choice c bs => do
    let ps ← bs.mapM (projectFrom r (started || c == r))
    if c == r then pure (.select ps) else mergeBranches r c started ps
  | .par bs k => do pure (.par (← bs.mapM (projectFrom r started)) (← projectFrom r started k))
  | .join _ bs k => do pure (.par (← bs.mapM (projectFrom r started)) (← projectFrom r started k))
  | .loop n b => do pure (.loop n (← projectFrom r started b))
  | .var n => pure (.var n)
  | .done => pure .done

def project [DecidableEq R] [ToString R] (r : R) (g : Global R) : Except String (Local R) :=
  projectFrom r false g

/-- Every issue of the core rules, for the given roles. -/
def issues [DecidableEq R] [ToString R] (g : Global R) (roles : List R) : List String :=
  choiceIssues g ++ causeIssues g ++
    roles.filterMap (fun r => match (project r g : Except String (Local R)) with | .error e => some e | .ok _ => none)

/-! ## Bridge to the durable artifact format -/

instance : Inhabited GrammarExpr := ⟨.empty⟩

/-- Translate to the `GrammarExpr` that LeanFM's existing artifacts and checks consume. -/
partial def toGrammarExpr [ToString R] (task : String) : Global R → GrammarExpr
  | .msg i k => .seq (.event ⟨task, toString i.src, toString i.dst, i.label⟩) (toGrammarExpr task k)
  | .act r l k => .seq (.event ⟨task, toString r, toString r, l⟩) (toGrammarExpr task k)
  | .choice _ bs => .choice (bs.map (toGrammarExpr task))
  | .par bs k => .seq (bs.foldl (fun acc b => .parallel acc (toGrammarExpr task b)) .empty) (toGrammarExpr task k)
  | .join n bs k => .seq (.thresholdJoin n (bs.map (toGrammarExpr task))) (toGrammarExpr task k)
  | .loop n b => .seq (.repeat (toGrammarExpr task b)) (.ref n)
  | .var _ => .empty
  | .done => .empty

end Global
end LeanFM.Session
