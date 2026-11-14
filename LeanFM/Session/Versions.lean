import LeanFM.Session.Evolution
import LeanFM.Session.Text

/-!
# Versions and clean upgrade paths (clause selfhost.session.versions)

A file keeps the versions of a protocol still deployed, oldest first. Version N may follow version
M only if there is a clean upgrade path from M to N: an order in which the roles of both versions
upgrade one at a time such that every mixed deployment along the way runs without getting stuck.

A mixed deployment is the old protocol's roles, each running its old local type, except the roles
already upgraded, which run their new local type. It is explored with `Evolution.explore`, the same
composed-system search `session_compat` uses: a message is taken when the sender may send it and
the receiver may receive it there, and a state where nothing can happen and some role cannot stop is
stuck. The start (nobody upgraded) is the old protocol and the end (everybody upgraded) is the new
one, both checked as protocols already. Roles only in the new version join with the last upgrade;
roles only in the old one leave with it.

The search is over sets of upgraded roles, breadth first, so the order found is a shortest one and
every set is explored once. Negative requirements: no path is reported with the first steps that get
stuck and their paths, never as a pass; more than `maxShared` shared roles, or a mixed deployment
the search cannot finish, is refused rather than answered.
-/

namespace LeanFM.Session
namespace Versions

/-- At most this many roles shared by two versions are searched (2^8 mixed deployments). -/
def maxShared : Nat := 8

/-- Why a mixed deployment fails: the roles upgraded, and where it gets stuck. -/
structure Stuck where
  upgraded : List String
  failure : Evolution.Failure
  deriving Inhabited

def Stuck.text (s : Stuck) : String :=
  let path := if s.failure.path.isEmpty then "at the start" else s!"after {"; ".intercalate s.failure.path}"
  s!"with {", ".intercalate s.upgraded} upgraded, the deployment gets stuck {path}: {s.failure.reason}"

/-- The answer: an order to upgrade the roles in, or why there is none. -/
inductive Path where
  | clean (order : List String)
  | none (why : List Stuck)
  deriving Inhabited

/-- Search for a clean upgrade path from `old` to `new`. -/
def search (old new : Global String) (oldRoles newRoles : List String) : Except String Path := do
  let body (g : Global String) := match g with | .sessions b _ => b | other => other
  let lo <- oldRoles.mapM fun r => ((body old).project r).mapError (fun e => s!"the old {r}: " ++ e)
  let ln <- newRoles.mapM fun r => ((body new).project r).mapError (fun e => s!"the new {r}: " ++ e)
  let shared := oldRoles.filter newRoles.contains
  if shared.isEmpty then
    return .none [{ upgraded := [], failure := { path := [], reason := "the versions share no role, so no role can upgrade on its own; keep the old protocol's roles, or give the new one another name" } }]
  if shared.length > maxShared then
    throw s!"{shared.length} roles are shared by the two versions; at most {maxShared} are searched for an upgrade order"
  -- the mixed deployment with the roles of `up` upgraded
  let mixed (up : List String) : List (Local String) :=
    (oldRoles.zip lo).map fun (r, l) =>
      if up.contains r then (ln[newRoles.idxOf r]?).getD l else l
  let full := shared.length
  -- breadth first over sets of upgraded roles, kept in the order they upgraded
  let mut frontier : List (List String) := [[]]
  let mut seen : List (List String) := [[]]
  let mut stuck : List Stuck := []
  for _ in [0:full] do
    let mut next : List (List String) := []
    for order in frontier do
      for r in shared do
        if order.contains r then continue
        let order' := order ++ [r]
        if order'.length == full then return .clean order'
        let key := shared.filter order'.contains
        if seen.contains key then continue
        seen := key :: seen
        match Evolution.explore oldRoles (mixed order') with
        | .ok none => next := next ++ [order']
        | .ok (some f) => stuck := stuck ++ [{ upgraded := order', failure := f }]
        | .error e => throw s!"with {", ".intercalate order'} upgraded: {e}"
    if next.isEmpty then
      -- no set of this size runs: the deepest failures are the answer
      let deepest := (stuck.map fun s => s.upgraded.length).foldl max 0
      return .none (stuck.filter fun s => s.upgraded.length == deepest)
    frontier := next
  return .none stuck

/-- The main protocol's message labels across its versions, in order of first appearance: each
label's place is its payload field number, in every version. -/
def labelHistory (p : Text.Parsed) : List String :=
  let gs : List (Global String) := match p.versioned.lookup p.name with
    | some vs => vs.map fun (v : Prod Nat (Prod (List String) (Global String))) => v.2.2
    | none => [p.global]
  (gs.flatMap fun (g : Global String) => g.messages.map fun m => m.label).eraseDups

/-- Each consecutive pair of versions of every versioned protocol, with the order found. -/
structure Upgrade where
  protocolName : String
  fromVersion : Nat
  toVersion : Nat
  order : List String
  deriving Inhabited, Repr

/-- Why a version has no clean upgrade path from the one before, in one message. -/
def refusal (n : String) (a b : Nat) (why : List Stuck) : String :=
  s!"{n} version {b} has no clean upgrade path from version {a}: " ++ "; ".intercalate (why.map fun w => w.text)

/-- Check every version against the one before it: the upgrades, or the first refusal. -/
def check (p : Text.Parsed) : Except String (List Upgrade) :=
  p.versioned.flatMapM fun (n, vs) =>
    (vs.zip (vs.drop 1)).mapM fun ((a, ra, ga), (b, rb, gb)) => do
      match <- search ga gb ra rb with
      | .clean order => pure { protocolName := n, fromVersion := a, toVersion := b, order }
      | .none why => throw (refusal n a b why)

/-- The versions a build of version `v` accepts from a peer: its own, and the one before it while the
upgrade runs (`declared` lists the versions the file keeps). -/
def accepted (declared : List Nat) (v : Nat) : List Nat :=
  let before := (declared.filter fun d => d < v).foldl max 0
  (if before == 0 then [] else [before]) ++ [v]

/-- The highest version both peers accept, and none rather than a guess. -/
def negotiate (mine theirs : List Nat) : Option Nat :=
  (mine.filter theirs.contains).foldl (fun acc v => some (match acc with | some a => max a v | none => v)) none

end Versions
end LeanFM.Session
