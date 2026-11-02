import Lean.Data.Json

/-!
# Two models for the LeanFM MCP server

Both are small products of shards and their channels, written as draft tasks for `check_ctl`.

## Replication

Shard `a` (island `us`) writes up to two records (`a1 < a2` in `dt`) and shard `b` (island `eu`)
one, `b1`. A write is two steps at its origin: `Begin` takes the timestamp, `Commit`
makes the record readable. A partition can start and heal at any time; a pull across it times
out. Writes never wait for the other island.

* `ordered`: each shard pulls by a per-origin `dt` mark (everything of that origin with `dt`
  above the mark, then the mark moves to the highest `dt` received), and an origin commits in
  `dt` order.
* `unordered`: the same `dt` marks, but an origin may commit `a2` before `a1` (two concurrent
  writers).
* `cursor`: commits as in `unordered`, but each shard keeps a cursor into the peer's feed, in
  the order the peer made records readable (its `visible_dt`, assigned at commit), and pulls
  everything past it. This is the design.

`Synced` is an observer step: both shards hold the same records and nothing is uncommitted.

## Lanes

Shard `a` writes `a1 < a2 < a3` in its feed. Shard `b` pulls them into an import queue, and lanes
finish the imports in any order; each import's label names `b`'s cursor after it commits. A lane can lose its work when the shard restarts (an in-memory queue)
and the record must then be pulled again, from `b`'s cursor into `a`'s feed.

* `laneMax`: the cursor moves to the highest feed position imported.
* `laneContiguous`: the cursor moves only over a contiguous run of imported records.

## Lane reservation

Two lanes (scaled down from 128), three large imports and one small one. The scheduler starts an
import whenever a lane may take it.

* `shared`: any import may take any lane.
* `reserved`: large imports may take at most one of the two lanes.

## Failing imports

Two lanes, two imports that fail on every attempt (`F1`, `F2`) and one that would succeed (`X`).

* `hold`: a failed attempt retries in the lane it holds.
* `yield`: a failed attempt gives up its lane and waits out a backoff before it is queued again.

## Feed

One shard holds two local writes (`a1 < a2`) and imports `b1`, whose `dt` lies between them. A
browser pages through the shard's records by a cursor. `Missed` is an observer step: a record is
readable at or below the browser's cursor and the browser never received it.

* `byDt`: the browser's cursor is the highest `dt` it has seen.
* `visibleAtBegin`: the cursor is `visible_dt`, assigned when a write begins.
* `visibleAtCommit`: the cursor is `visible_dt`, assigned when a write commits (one writer).

## Policy

`plans.pdf.rego` starts at `v0`, which lets a reader in. During a partition island `us` tightens it
(`v1`, based on `v0`, denies the reader) and island `eu` edits it too (`v2`, based on `v0`, a later
`dt`, still allows). Later anyone holding both may write `v3`, based on `v1` and `v2`, which keeps
the tightening. A read on a shard is decided from the versions that shard holds.

* `latestWins`: the version with the greatest `dt` decides.
* `allHeads`: every head (a held version no other held version is based on) must allow.

`LeakA`/`LeakB` is a read allowed while the shard holds a head that denies it.

Run from the LeanFM root: `lake env lean --run projects/IslandUploads/spec/Islands.lean`.
-/

namespace Project.Islands
open Lean

def base36 (n : Nat) : String :=
  let digit (d : Nat) : Char := if d < 10 then Char.ofNat (48 + d) else Char.ofNat (87 + d)
  if n < 36 then (digit n).toString else base36 (n / 36) ++ (digit (n % 36)).toString
termination_by n
decreasing_by omega

def sid (n : Nat) : String := "s" ++ base36 n

/-- Breadth-first exploration of any labelled successor function, keyed by a state string. -/
def explore {S : Type} [Inhabited S] (init : S) (key : S → String) (next : S → List (String × S)) :
    Array String × List (Nat × Nat × String) := Id.run do
  let mut ids : Std.HashMap String Nat := {}
  let mut states : Array S := #[init]
  ids := ids.insert (key init) 0
  let mut trans : Array (Nat × Nat × String) := #[]
  let mut seen : Std.HashSet String := {}
  let mut i := 0
  while i < states.size do
    let s := states[i]!
    for (label, t) in next s do
      let k := key t
      let j ← match ids.get? k with
        | some j => pure j
        | none =>
          let j := states.size
          states := states.push t
          ids := ids.insert k j
          pure j
      let e := s!"{i}>{j}>{label}"
      if !seen.contains e then
        seen := seen.insert e
        trans := trans.push (i, j, label)
    i := i + 1
  return (states.map key, trans.toList)

def draftJson (id : String) (alphabet : List String) (states : Array String) (trans : List (Nat × Nat × String)) : Json :=
  let missing := alphabet.filter (fun l => !trans.any (·.2.2 == l))
  let extra := if missing.isEmpty then [] else ["alphabet"]
  Json.mkObj
    [ ("id", id)
    , ("states", Lean.toJson ((List.range states.size).map sid ++ extra))
    , ("initial", sid 0)
    , ("terminals", Lean.toJson ([] : List String))
    , ("transitions", Json.arr ((trans.map (fun (a, b, l) =>
        Json.mkObj [("src", Json.str (sid a)), ("dst", Json.str (sid b)), ("message", Json.str l)])) ++
        missing.map (fun l => Json.mkObj [("src", "alphabet"), ("dst", "alphabet"), ("message", Json.str l)])).toArray) ]

def write (name : String) (draft : Json) (states : Array String) : IO Unit := do
  let dir := "projects/IslandUploads/reports/mcp"
  IO.FS.createDirAll dir
  IO.FS.writeFile s!"{dir}/{name}.task.json" (draft.compress ++ "\n")
  let keys := Json.mkObj ((List.range states.size).map (fun i => (sid i, Json.str (states[i]!))))
  IO.FS.writeFile s!"{dir}/{name}.states.json" (keys.compress ++ "\n")

/-! ## Replication -/

/-- A record by origin and position: `("a", 1)` is `a1`. Its `dt` order within an origin is its
position. -/
abbrev Rec := String × Nat

def recName (r : Rec) : String := s!"{r.1.toUpper}{r.2}"

structure Repl where
  begun     : List Rec          -- timestamps taken, not yet readable
  committed : List Rec          -- readable at the origin
  holdsA    : List Rec          -- records held by shard a (its own committed ones and imports)
  holdsB    : List Rec
  markAonB  : Nat               -- b's mark for origin a, or b's cursor into a's feed
  markBonA  : Nat
  partitioned : Bool
  deriving Inhabited, BEq

/-- How a shard remembers how far it has replicated from its peer. -/
inductive ReplMode | ordered | unordered | cursor
  deriving BEq

/-- `holdsA` and `holdsB` are kept in the order each shard made records readable, so in `cursor`
mode the list is the shard's feed and its order is part of the state. -/
def Repl.key (feedOrder : Bool) (s : Repl) : String :=
  let srt (xs : List Rec) := (xs.map recName).mergeSort (· ≤ ·)
  let held (xs : List Rec) := if feedOrder then xs.map recName else srt xs
  s!"{srt s.begun}|{srt s.committed}|{held s.holdsA}|{held s.holdsB}|{s.markAonB}|{s.markBonA}|{s.partitioned}"

def replNext (mode : ReplMode) (s : Repl) : List (String × Repl) :=
  let ordered := mode == .ordered
  let origins := ["a", "b"]
  -- `a` writes two records, enough to commit out of order; `b` writes one
  let begins := origins.flatMap (fun o => (if o == "a" then [1, 2] else [1]).filterMap (fun n =>
    let r := (o, n)
    -- timestamps are taken in order at each origin
    if s.begun.contains r || s.committed.contains r then none
    else if n == 2 && !(s.begun.contains (o, 1) || s.committed.contains (o, 1)) then none
    else some (s!"Begin{recName r}", { s with begun := s.begun ++ [r] })))
  let commits := s.begun.filterMap (fun r =>
    let earlierPending := s.begun.any (fun x => x.1 == r.1 && x.2 < r.2)
    if ordered && earlierPending then none else
    let s' := { s with begun := s.begun.erase r, committed := s.committed ++ [r] }
    let s' := if r.1 == "a" then { s' with holdsA := s'.holdsA ++ [r] } else { s' with holdsB := s'.holdsB ++ [r] }
    some (s!"Commit{recName r}", s'))
  -- b pulls origin a from a; a pulls origin b from b
  let pullAtoB : String × Repl :=
    if s.partitioned then ("PeerTimedOut", s) else
    if mode == .cursor then
      -- everything in a's feed past b's cursor; the cursor moves to the end of what was served
      let fresh := (s.holdsA.drop s.markAonB).filter (fun r => !s.holdsB.contains r)
      ("PullAtoB", { s with holdsB := s.holdsB ++ fresh, markAonB := s.holdsA.length })
    else
    let fresh := s.committed.filter (fun r => r.1 == "a" && r.2 > s.markAonB && !s.holdsB.contains r)
    let mark := fresh.foldl (fun m r => max m r.2) s.markAonB
    ("PullAtoB", { s with holdsB := s.holdsB ++ fresh, markAonB := mark })
  let pullBtoA : String × Repl :=
    if s.partitioned then ("PeerTimedOut", s) else
    if mode == .cursor then
      let fresh := (s.holdsB.drop s.markBonA).filter (fun r => !s.holdsA.contains r)
      ("PullBtoA", { s with holdsA := s.holdsA ++ fresh, markBonA := s.holdsB.length })
    else
    let fresh := s.committed.filter (fun r => r.1 == "b" && r.2 > s.markBonA && !s.holdsA.contains r)
    let mark := fresh.foldl (fun m r => max m r.2) s.markBonA
    ("PullBtoA", { s with holdsA := s.holdsA ++ fresh, markBonA := mark })
  let net := if s.partitioned then [("Heal", { s with partitioned := false })] else [("Partition", { s with partitioned := true })]
  let same (x y : List Rec) := x.all y.contains && y.all x.contains
  let synced := if s.begun.isEmpty && same s.holdsA s.holdsB && same s.holdsA s.committed then [("Synced", s)] else []
  begins ++ commits ++ [pullAtoB, pullBtoA] ++ net ++ synced

def replAlphabet : List String :=
  ["BeginA1", "BeginA2", "BeginB1", "CommitA1", "CommitA2", "CommitB1",
   "PullAtoB", "PullBtoA", "PeerTimedOut", "Partition", "Heal", "Synced"]

/-! ## Lanes -/

structure Lanes where
  committed : Nat          -- a's records readable at a: a1..a{committed}
  queued    : List Nat     -- pulled by b, waiting in a lane
  imported  : List Nat     -- visible at b
  mark      : Nat
  deriving Inhabited, BEq

def Lanes.key (s : Lanes) : String :=
  s!"{s.committed}|{s.queued.mergeSort (· ≤ ·)}|{s.imported.mergeSort (· ≤ ·)}|{s.mark}"

def contiguous (imported : List Nat) : Nat :=
  let rec go (fuel n : Nat) : Nat :=
    match fuel with
    | 0 => n
    | fuel + 1 => if imported.contains (n + 1) then go fuel (n + 1) else n
  go 8 0

def lanesNext (contig : Bool) (s : Lanes) : List (String × Lanes) :=
  let writes := if s.committed < 3 then [(s!"CommitA{s.committed + 1}", { s with committed := s.committed + 1 })] else []
  let fresh := (List.range s.committed).map (· + 1) |>.filter (fun r => r > s.mark && !s.queued.contains r && !s.imported.contains r)
  let pull := if fresh.isEmpty then [] else [("PullAtoB", { s with queued := s.queued ++ fresh })]
  let imports := s.queued.map (fun r =>
    let imported := s.imported ++ [r]
    let mark := if contig then contiguous imported else max s.mark r
    (s!"ImportA{r}to{mark}", { s with queued := s.queued.erase r, imported, mark }))
  let restart := if s.queued.isEmpty then [] else [("RestartB", { s with queued := [] })]
  let synced := if s.committed == 3 && s.imported.length == 3 then [("Synced", s)] else []
  writes ++ pull ++ imports ++ restart ++ synced

/-- An import's label names the cursor after its commit: `ImportA2to0` finished `a2` and left the
cursor at 0; `ImportA1to3` finished `a1` and moved it to 3. -/
def lanesAlphabet : List String :=
  ["CommitA1", "CommitA2", "CommitA3", "PullAtoB", "RestartB", "Synced"] ++
  ([1, 2, 3].flatMap (fun r => [0, 1, 2, 3].map (fun c => s!"ImportA{r}to{c}")))

/-! ## Lane reservation -/

structure Sched where
  queued  : List String
  running : List String
  done    : List String
  deriving Inhabited, BEq

def Sched.key (s : Sched) : String := s!"{s.queued}|{s.running.mergeSort (· ≤ ·)}|{s.done.mergeSort (· ≤ ·)}"

def isLarge (x : String) : Bool := x.startsWith "B"

def schedNext (reserved : Bool) (s : Sched) : List (String × Sched) :=
  let lanes := 2
  let largeCap := if reserved then 1 else 2
  let mayStart (x : String) :=
    s.running.length < lanes && (!isLarge x || (s.running.filter isLarge).length < largeCap)
  let starts := s.queued.filter mayStart |>.map (fun x =>
    (s!"Start{x}", { s with queued := s.queued.erase x, running := s.running ++ [x] }))
  let dones := s.running.map (fun x =>
    (s!"Done{x}", { s with running := s.running.erase x, done := s.done ++ [x] }))
  -- an eager scheduler: when an import can start, it starts before anything else happens
  if starts.isEmpty then dones else starts

def schedAlphabet : List String :=
  ["StartB1", "StartB2", "StartB3", "StartS", "DoneB1", "DoneB2", "DoneB3", "DoneS"]

/-! ## Failing imports -/

structure Retry where
  queued  : List String
  running : List String
  cooling : List String
  done    : List String
  deriving Inhabited, BEq

def Retry.key (s : Retry) : String :=
  let srt (xs : List String) := xs.mergeSort (· ≤ ·)
  s!"{srt s.queued}|{srt s.running}|{srt s.cooling}|{srt s.done}"

def retryNext (yieldLane : Bool) (s : Retry) : List (String × Retry) :=
  let starts := if s.running.length < 2 then s.queued.map (fun x =>
    (s!"Start{x}", { s with queued := s.queued.erase x, running := s.running ++ [x] })) else []
  let finishes := s.running.map (fun x =>
    if x.startsWith "F" then
      if yieldLane then (s!"Fail{x}", { s with running := s.running.erase x, cooling := s.cooling ++ [x] })
      else (s!"Retry{x}", s)
    else (s!"Done{x}", { s with running := s.running.erase x, done := s.done ++ [x] }))
  let backoffs := s.cooling.map (fun x =>
    (s!"Backoff{x}", { s with cooling := s.cooling.erase x, queued := s.queued ++ [x] }))
  -- eager: a free lane is filled before anything else happens; a backoff ends only when nothing can start
  if !starts.isEmpty then starts
  else if !finishes.isEmpty then finishes ++ backoffs
  else backoffs

def retryAlphabet : List String :=
  ["StartF1", "StartF2", "StartX", "FailF1", "FailF2", "RetryF1", "RetryF2", "BackoffF1", "BackoffF2", "DoneX"]

/-! ## Feed -/

inductive Cursor | byDt | visibleAtBegin | visibleAtCommit
  deriving BEq, Inhabited

def Cursor.name : Cursor → String
  | .byDt => "byDt" | .visibleAtBegin => "visibleAtBegin" | .visibleAtCommit => "visibleAtCommit"

/-- `dt` of each record; `B1` was written on the other island between `A1` and `A2`. -/
def dtOf : String → Nat
  | "A1" => 1 | "B1" => 2 | "A2" => 3 | _ => 0

structure Feed where
  pending   : List (String × Nat)   -- writes in progress, with visible_dt if already assigned (0: none)
  readable  : List (String × Nat)   -- committed, with the key the browser's cursor compares
  arrived   : List String           -- writes started (local) or imports received
  clock     : Nat                   -- the shard's visible_dt clock
  cursor    : Nat
  seen      : List String
  missed    : Bool
  deriving Inhabited, BEq

def Feed.key (s : Feed) : String :=
  s!"{s.pending}|{s.readable}|{s.arrived}|{s.clock}|{s.cursor}|{s.seen.mergeSort (· ≤ ·)}|{s.missed}"

def feedNext (c : Cursor) (s : Feed) : List (String × Feed) :=
  -- local writes take their dt in order; the import arrives whenever replication delivers it
  let starts := ["A1", "A2", "B1"].filterMap (fun r =>
    if s.arrived.contains r then none
    else if r == "A2" && !s.arrived.contains "A1" then none
    else
      let label := if r == "B1" then "ImportB1" else s!"Begin{r}"
      match c with
      | .visibleAtBegin => some (label, { s with arrived := s.arrived ++ [r], pending := s.pending ++ [(r, s.clock + 1)], clock := s.clock + 1 })
      | _ => some (label, { s with arrived := s.arrived ++ [r], pending := s.pending ++ [(r, 0)] }))
  let commits := s.pending.map (fun (r, v) =>
    let (k, clock) := match c with
      | .byDt => (dtOf r, s.clock)
      | .visibleAtBegin => (v, s.clock)
      | .visibleAtCommit => (s.clock + 1, s.clock + 1)
    (s!"Commit{r}", { s with pending := s.pending.erase (r, v), readable := s.readable ++ [(r, k)], clock }))
  -- `visibleAtCommit` has one writer: only the oldest pending write may commit
  let commits := if c == .visibleAtCommit then commits.take 1 else commits
  let page := s.readable.filter (fun (_, k) => k > s.cursor)
  let poll : List (String × Feed) :=
    if page.isEmpty then [] else
    [("FeedPage", { s with cursor := page.foldl (fun m (_, k) => max m k) s.cursor,
                           seen := s.seen ++ (page.map (·.1)).filter (!s.seen.contains ·) })]
  let missed := if !s.missed && s.readable.any (fun (r, k) => k ≤ s.cursor && !s.seen.contains r)
    then [("Missed", { s with missed := true })] else []
  starts ++ commits ++ poll ++ missed

def feedAlphabet : List String :=
  ["BeginA1", "BeginA2", "ImportB1", "CommitA1", "CommitA2", "CommitB1", "FeedPage", "Missed"]

/-! ## Policy -/

/-- Policy versions in `dt` order, with what each is based on and whether it lets the reader in. -/
def prevs : Nat → List Nat
  | 1 => [0] | 2 => [0] | 3 => [1, 2] | _ => []
def allows : Nat → Bool
  | 0 => true | 1 => false | 2 => true | _ => false

partial def ancestors (v : Nat) : List Nat := (prevs v).flatMap (fun p => p :: ancestors p)

structure Pol where
  holdsA : List Nat
  holdsB : List Nat
  partitioned : Bool
  deriving Inhabited, BEq

def Pol.key (s : Pol) : String :=
  s!"{s.holdsA.mergeSort (· ≤ ·)}|{s.holdsB.mergeSort (· ≤ ·)}|{s.partitioned}"

def heads (held : List Nat) : List Nat :=
  held.filter (fun v => !held.any (fun w => (ancestors w).contains v))

def decide (latestWins : Bool) (held : List Nat) : Bool :=
  if latestWins then allows (held.foldl max 0) else (heads held).all allows

def polNext (latestWins : Bool) (s : Pol) : List (String × Pol) :=
  let union (x y : List Nat) := x ++ y.filter (!x.contains ·)
  let writes :=
    (if s.holdsA.contains 1 || s.holdsB.contains 1 then [] else [("TightenOnA", { s with holdsA := s.holdsA ++ [1] })]) ++
    (if s.holdsA.contains 2 || s.holdsB.contains 2 then [] else [("EditOnB", { s with holdsB := s.holdsB ++ [2] })]) ++
    (if s.holdsA.contains 3 || s.holdsB.contains 3 then [] else
      (if s.holdsA.contains 1 && s.holdsA.contains 2 then [("MergeOnA", { s with holdsA := s.holdsA ++ [3] })] else []) ++
      (if s.holdsB.contains 1 && s.holdsB.contains 2 then [("MergeOnB", { s with holdsB := s.holdsB ++ [3] })] else []))
  let pulls :=
    if s.partitioned then [("PeerTimedOut", s)]
    else [("PullAtoB", { s with holdsB := union s.holdsB s.holdsA }), ("PullBtoA", { s with holdsA := union s.holdsA s.holdsB })]
  let net := if s.partitioned then [("Heal", { s with partitioned := false })] else [("Partition", { s with partitioned := true })]
  let read (shard : String) (held : List Nat) : String × Pol :=
    if decide latestWins held then
      (if (heads held).all allows then s!"Read{shard}" else s!"Leak{shard}", s)
    else (s!"Denied{shard}", s)
  writes ++ pulls ++ net ++ [read "A" s.holdsA, read "B" s.holdsB]

def polAlphabet : List String :=
  ["TightenOnA", "EditOnB", "MergeOnA", "MergeOnB", "PullAtoB", "PullBtoA", "PeerTimedOut", "Partition", "Heal",
   "ReadA", "ReadB", "DeniedA", "DeniedB", "LeakA", "LeakB"]

def main : IO Unit := do
  for (name, mode) in [("repl-ordered", ReplMode.ordered), ("repl-unordered", .unordered), ("repl-cursor", .cursor)] do
    let init : Repl := { begun := [], committed := [], holdsA := [], holdsB := [], markAonB := 0, markBonA := 0, partitioned := false }
    let (states, trans) := explore init (Repl.key (mode == .cursor)) (replNext mode)
    let draft := draftJson name replAlphabet states trans
    write name draft states
    IO.println s!"{name}: {states.size} states, {trans.length} transitions, {draft.compress.length} bytes"
  for (name, contig) in [("lanes-max", false), ("lanes-contiguous", true)] do
    let init : Lanes := { committed := 0, queued := [], imported := [], mark := 0 }
    let (states, trans) := explore init Lanes.key (lanesNext contig)
    let draft := draftJson name lanesAlphabet states trans
    write name draft states
    IO.println s!"{name}: {states.size} states, {trans.length} transitions, {draft.compress.length} bytes"
  for (name, y) in [("retry-hold", false), ("retry-yield", true)] do
    let init : Retry := { queued := ["F1", "F2", "X"], running := [], cooling := [], done := [] }
    let (states, trans) := explore init Retry.key (retryNext y)
    let draft := draftJson name retryAlphabet states trans
    write name draft states
    IO.println s!"{name}: {states.size} states, {trans.length} transitions, {draft.compress.length} bytes"
  for (name, reserved) in [("sched-shared", false), ("sched-reserved", true)] do
    let init : Sched := { queued := ["B1", "B2", "B3", "S"], running := [], done := [] }
    let (states, trans) := explore init Sched.key (schedNext reserved)
    let draft := draftJson name schedAlphabet states trans
    write name draft states
    IO.println s!"{name}: {states.size} states, {trans.length} transitions, {draft.compress.length} bytes"
  for c in [Cursor.byDt, .visibleAtBegin, .visibleAtCommit] do
    let init : Feed := { pending := [], readable := [], arrived := [], clock := 0, cursor := 0, seen := [], missed := false }
    let (states, trans) := explore init Feed.key (feedNext c)
    let name := s!"feed-{c.name}"
    let draft := draftJson name feedAlphabet states trans
    write name draft states
    IO.println s!"{name}: {states.size} states, {trans.length} transitions, {draft.compress.length} bytes"
  for (name, lww) in [("policy-latestWins", true), ("policy-allHeads", false)] do
    let init : Pol := { holdsA := [0], holdsB := [0], partitioned := false }
    let (states, trans) := explore init Pol.key (polNext lww)
    let draft := draftJson name polAlphabet states trans
    write name draft states
    IO.println s!"{name}: {states.size} states, {trans.length} transitions, {draft.compress.length} bytes"

end Project.Islands

def main : IO Unit := Project.Islands.main
