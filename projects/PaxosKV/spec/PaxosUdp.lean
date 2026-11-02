import Lean.Data.Json

/-!
# One Paxos slot over UDP, across two islands

The product of three replicas and the UDP channels between them, small enough for the LeanFM MCP
server's `check_ctl` (at most 4096 model nodes and 64 KiB of arguments).

* `kv0` and `kv1` are in island `us`, `kv2` in island `eu`.
* `kv0` is the stable leader: every replica has already promised its ballot 1, so it goes straight
  to phase 2 with value `A` (Multi-Paxos).
* `kv2` has lost touch with the leader and takes over with ballot 2: phase 1, then the value the
  promises report, or its own value `B` if they report none.
* A replica's own acceptance is a local fsync, synchronous with its send; every other message
  crosses a UDP channel.
* UDP physics: a sent message stays available and may be delivered to each replica in any order,
  late, or never. Duplicate delivery to the same replica is left out (it is a no-op for these
  messages except for re-sent promises), which keeps the model under the server's bounds.
* A learner reports `ChosenA` or `ChosenB` when two replicas have accepted the same ballot and
  value.

Variants:

* `correct`: `kv2` adopts the highest accepted value reported by its quorum of promises.
* `broken`: `kv2` ignores what the promises report and proposes `B`.
* `partitioned`: `correct`, but nothing crosses between `us` and `eu`.
* `lossy`: the leader alone, with every message free to be lost (`Lost`).

Loss and safety. Every prefix of a run that loses messages is also a prefix of a run that merely
delays them, and this model delays any message arbitrarily. So the safety verdicts (agreement,
conflict) hold for lossy UDP as they stand. Liveness does not transfer: in the first three variants
every message is eventually delivered, which is the `fairDelivery` assumption of the session
spec. The `lossy` variant drops that assumption, on a slice small enough to fit the server's
bounds with explicit `Lost` steps.

Run from the LeanFM root: `lake env lean --run projects/PaxosKV/spec/PaxosUdp.lean`; writes the
draft tasks to `projects/PaxosKV/reports/mcp/`.
-/

namespace Project.PaxosUdp
open Lean

inductive Variant | correct | broken | partitioned | lossy
  deriving BEq, Repr

def Variant.name : Variant → String
  | .correct => "correct" | .broken => "broken" | .partitioned => "partitioned" | .lossy => "lossy"

def island (a : Nat) : String := if a == 2 then "eu" else "us"

/-- A message on the wire. `prepare` is ballot 2's; `accept b v`; `promise a r` reports what
acceptor `a` had accepted when it promised. -/
inductive Msg where
  | prepare
  | accept (b : Nat) (v : String)
  | promise (a : Nat) (reported : Option (Nat × String))
  deriving BEq, Repr

def Msg.key : Msg → String
  | .prepare => "P"
  | .accept b v => s!"A{b}{v}"
  | .promise a none => s!"R{a}-"
  | .promise a (some (b, v)) => s!"R{a}{b}{v}"

def Msg.sender : Msg → Nat
  | .prepare => 2
  | .accept b _ => if b == 1 then 0 else 2
  | .promise a _ => a

inductive Phase where
  | idle | preparing | sent (v : String)
  deriving BEq, Repr, Inhabited

structure State where
  promised : List Nat                       -- per acceptor
  accepted : List (Option (Nat × String))   -- per acceptor
  leaderSent : Bool
  challenger : Phase
  msgs : List Msg                           -- sent, kept sorted by key
  delivered : List (String × Nat)           -- (message key, acceptor), sorted
  chosen : List String                      -- sorted
  deriving BEq, Repr, Inhabited

def State.key (s : State) : String :=
  let acc := s.accepted.map (fun x => match x with | none => "-" | some (b, v) => s!"{b}{v}")
  let ph := match s.challenger with | .idle => "i" | .preparing => "p" | .sent v => v
  s!"{s.promised}|{acc}|{s.leaderSent}|{ph}|{s.msgs.map Msg.key}|{s.delivered}|{s.chosen}"

def insertSorted (key : α → String) (x : α) (xs : List α) : List α :=
  if xs.any (fun y => key y == key x) then xs
  else (x :: xs).mergeSort (fun a b => key a ≤ key b)

def State.send (s : State) (m : Msg) : State := { s with msgs := insertSorted Msg.key m s.msgs }
def State.mark (s : State) (m : Msg) (a : Nat) : State :=
  { s with delivered := insertSorted (fun (k, a) => s!"{k}{a}") (m.key, a) s.delivered }

def set (xs : List α) (i : Nat) (x : α) : List α := xs.set i x

/-- Acceptor `a` receives `accept b v`. -/
def acceptAt (s : State) (a b : Nat) (v : String) : Option State :=
  if b ≥ s.promised.getD a 0 then
    some { s with promised := set s.promised a b, accepted := set s.accepted a (some (b, v)) }
  else none

def initial : State :=
  { promised := [1, 1, 1], accepted := [none, none, none], leaderSent := false, challenger := .idle
    msgs := [], delivered := [], chosen := [] }

/-- Successors, each with the message that labels the step. -/
def next (variant : Variant) (s : State) : List (String × State) :=
  let ok (x y : Nat) := !(variant == .partitioned && island x != island y)
  let leader : List (String × State) :=
    if s.leaderSent then [] else
      let m := Msg.accept 1 "A"
      let s' := ({ s with leaderSent := true }.send m).mark m 0
      [("Accept1A", (acceptAt s' 0 1 "A").getD s')]
  let challenger : List (String × State) :=
    if variant == .lossy then [] else
    match s.challenger with
    | .idle =>
      -- kv2 promises its own ballot locally, reporting what it has accepted
      let s' := ({ s with challenger := .preparing, promised := set s.promised 2 2 }.send .prepare).mark .prepare 2
      [("Prepare2", s'.send (.promise 2 (s.accepted.getD 2 none)))]
    | .preparing =>
      let promises := s.msgs.filterMap (fun m => match m with
        | .promise a r => if ok a 2 then some (a, r) else none | _ => none)
      let pairs := promises.flatMap (fun (a1, r1) => promises.filterMap (fun (a2, r2) =>
        if a1 < a2 then some (r1, r2) else none))
      pairs.map (fun (r1, r2) =>
        let reported := [r1, r2].filterMap id
        let highest := reported.foldl (fun acc (b, v) => match acc with
          | some (b', _) => if b > b' then some (b, v) else acc
          | none => some (b, v)) none
        let v := match variant, highest with
          | .broken, _ => "B"
          | _, some (_, v) => v
          | _, none => "B"
        let m := Msg.accept 2 v
        let s' := ({ s with challenger := .sent v }.send m).mark m 2
        (s!"Accept2{v}", (acceptAt s' 2 2 v).getD s'))
    | .sent _ => []
  let deliveries : List (String × State) := s.msgs.flatMap (fun m =>
    match m with
    | .promise _ _ => []
    | _ => [0, 1, 2].filterMap (fun a =>
      if !ok m.sender a || s.delivered.contains (m.key, a) then none else
      let s1 := s.mark m a
      if variant == .lossy && a != m.sender then
        match m with
        | .accept b v => some (s!"Accepted{a}", (acceptAt s1 a b v).getD s1)
        | _ => none
      else
      match m with
      | .prepare =>
        if 2 ≥ s.promised.getD a 0 then
          some (s!"Promise{a}", ({ s1 with promised := set s.promised a 2 }).send (.promise a (s.accepted.getD a none)))
        else some ("Rejected", s1)
      | .accept b v =>
        match acceptAt s1 a b v with
        | some s2 => some (s!"Accepted{a}", s2)
        | none => some ("Rejected", s1)
      | _ => none))
  let learner : List (String × State) := ["A", "B"].flatMap (fun v =>
    if s.chosen.contains v then [] else
    [1, 2].filterMap (fun b =>
      if (s.accepted.filter (· == some (b, v))).length ≥ 2
      then some (s!"Chosen{v}", { s with chosen := (v :: s.chosen).mergeSort (· ≤ ·) }) else none))
  let losses : List (String × State) :=
    if variant != .lossy then [] else
    s.msgs.flatMap (fun m => [0, 1, 2].filterMap (fun a =>
      if a == m.sender || s.delivered.contains (m.key, a) then none else some ("Lost", s.mark m a)))
  leader ++ challenger ++ deliveries ++ losses ++ learner

structure Model where
  states : Array String
  transitions : List (Nat × Nat × String)

def explore (variant : Variant) : Model := Id.run do
  let mut ids : Std.HashMap String Nat := {}
  let mut states : Array State := #[initial]
  ids := ids.insert initial.key 0
  let mut trans : Array (Nat × Nat × String) := #[]
  let mut seen : Std.HashSet String := {}
  let mut i := 0
  while i < states.size do
    let s := states[i]!
    for (label, t) in next variant s do
      let k := t.key
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
  return { states := states.map State.key, transitions := trans.toList }

def base36 (n : Nat) : String :=
  let digit (d : Nat) : Char := if d < 10 then Char.ofNat (48 + d) else Char.ofNat (87 + d)
  if n < 36 then (digit n).toString else base36 (n / 36) ++ (digit (n % 36)).toString
termination_by n
decreasing_by omega

def sid (n : Nat) : String := "s" ++ base36 n

/-- Every label any variant can produce. -/
def alphabet : List String :=
  ["Accept1A", "Prepare2", "Promise0", "Promise1", "Promise2", "Accept2A", "Accept2B",
   "Accepted0", "Accepted1", "Accepted2", "Rejected", "Lost", "ChosenA", "ChosenB"]

/-- A draft task declares its messages only through its transitions, so a message that a variant
can never produce (`ChosenB` when `eu` is cut off) would be an unknown atom. Labels missing from
the reachable model are declared on one unreachable state, `alphabet`, which no path visits. -/
def Model.toJson (m : Model) (id : String) : Json :=
  let missing := alphabet.filter (fun l => !m.transitions.any (·.2.2 == l))
  let extra := if missing.isEmpty then [] else ["alphabet"]
  Json.mkObj
    [ ("id", id)
    , ("states", Lean.toJson ((List.range m.states.size).map sid ++ extra))
    , ("initial", sid 0)
    , ("terminals", Lean.toJson ([] : List String))
    , ("transitions", Json.arr ((m.transitions.map (fun (a, b, l) =>
        Json.mkObj [("src", Json.str (sid a)), ("dst", Json.str (sid b)), ("message", Json.str l)])) ++
        missing.map (fun l => Json.mkObj [("src", "alphabet"), ("dst", "alphabet"), ("message", Json.str l)])).toArray) ]

def main : IO Unit := do
  IO.FS.createDirAll "projects/PaxosKV/reports/mcp"
  for v in [Variant.correct, .broken, .partitioned, .lossy] do
    let m := explore v
    let json := (m.toJson s!"paxos_udp_{v.name}").compress
    IO.FS.writeFile s!"projects/PaxosKV/reports/mcp/paxos-udp-{v.name}.task.json" (json ++ "\n")
    -- state contents by id, for turning paths into event traces; not sent to the server
    let keys := Json.mkObj ((List.range m.states.size).map (fun i => (sid i, Json.str (m.states[i]!))))
    IO.FS.writeFile s!"projects/PaxosKV/reports/mcp/paxos-udp-{v.name}.states.json" (keys.compress ++ "\n")
    IO.println s!"{v.name}: {m.states.size} states, {m.transitions.length} transitions, {json.length} bytes"

end Project.PaxosUdp

def main : IO Unit := Project.PaxosUdp.main
