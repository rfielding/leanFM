import LeanFM.RunCheck

/-! Tests for selfhost.requirements.standing (decision requirement-standing): a run proves what one
path can, the strong and weak implications behave as features and guarantees, a counterexample is
the shortest refuting prefix, and the arrays agree with a direct recursive reference. -/
namespace LeanFM.RunCheckTests
open LeanFM.Logic LeanFM.RunCheck

def run (ls : List String) (complete := false) : Run := { labels := ls.toArray, complete }
def f (s : String) : Formula := match parseSexpr s with | .ok x => x | .error _ => .ff
def valueOf (s : String) (rs : List Run) : Option V := (judge (f s) rs).toOption.map (·.value)

def feature := "(stronglyImplies (on Call) (inevitably (on Answer)))"
-- the lazy server: no Call ever, so the feature is not shown (presumably false), never tested
#guard valueOf feature [run ["Hello"] true] == some .presumablyFalse
-- a Call answered: tested (presumably true; a run cannot prove always)
#guard valueOf feature [run ["Call", "Answer"] true] == some .presumablyTrue
-- a complete run with a Call and no Answer refutes it; the counterexample is the first event
#guard valueOf feature [run ["Call", "Bye"] true] == some .false_
#guard ((judge (f feature) [run ["Hello", "Call", "Bye"] true]).toOption.bind (·.counterexample)) == some (0, 3)
-- still running: the Answer may yet come
#guard valueOf feature [run ["Call"]] == some .presumablyFalse
-- the welded door: no OpenDoor, so the guarantee holds, and the judgement says it was never triggered
def guard := "(weaklyImplies (on OpenDoor) (on Password))"
#guard valueOf guard [run ["Knock"] true] == some .presumablyTrue
#guard ((judge (f guard) [run ["Knock"] true]).toOption.map (·.untriggered.length)) == some 1
#guard ((judge (f guard) [run ["Password", "OpenDoor"] true]).toOption.map (·.untriggered.length)) == some 0
#guard valueOf "(always (implies (on OpenDoor) (on Password)))" [run ["OpenDoor"] true] == some .false_
-- never: a run with the bad event refutes it, at that event
#guard valueOf "(never (on Pay))" [run ["Quote", "Pay"]] == some .false_
#guard ((judge (f "(never (on Pay))") [run ["Quote", "Pay", "Receipt"]]).toOption.bind (·.counterexample)) == some (0, 2)
-- possibly: one run shows it; a run without it never refutes it
#guard valueOf "(possibly (on Pay))" [run ["Pay"]] == some .true_
#guard valueOf "(possibly (on Pay))" [run ["Quote"] true] == some .presumablyFalse
#guard valueOf "(always (possibly stop))" [run ["A", "B"] true] != some .false_
#guard valueOf "(always (possibly stop))" [run ["A", "B"]] != some .false_
-- across sessions: one session shows the trigger, another is a quiet session
#guard valueOf feature [run ["Hello"] true, run ["Call", "Answer"] true] == some .presumablyTrue
#guard valueOf feature [run ["Call", "Answer"] true, run ["Call"] true] == some .false_
-- stop holds only at the end of a complete session
#guard valueOf "(inevitably stop)" [run ["A"] true] == some .presumablyTrue
#guard valueOf "(inevitably stop)" [run ["A"]] == some .presumablyFalse
-- an atom a run does not show is refused, naming it
#guard match judge (f "(always (at s1))") [run ["A"]] with
  | .error e => (e.splitOn "a run shows only on M").length > 1 | .ok _ => false
#guard (judge (f feature) []).toOption.isNone

/-! A reference: each value computed directly from its definition at each state. -/
partial def ref (r : Run) (g : Formula) (i : Nat) : V :=
  let n := r.labels.size
  let endS := strongEnd r
  let endW := weakEnd r
  let rec untilAt (a b : Formula) (j : Nat) (endV : V) : V :=
    if j > n then endV else (ref r b j).or ((ref r a j).and (if j == n then endV else untilAt a b (j + 1) endV))
  match g with
  | .tt => .true_ | .ff => .false_
  | .after m => if i > 0 && r.labels[i - 1]! == m then .true_ else .false_
  | .terminal => if i < n then .false_ else if r.complete then .true_ else .presumablyFalse
  | .not h => (ref r h i).not
  | .and hs => hs.foldl (fun v h => v.and (ref r h i)) .true_
  | .or hs => hs.foldl (fun v h => v.or (ref r h i)) .false_
  | .implies a b => (ref r a i).not.or (ref r b i)
  | .ex h => (if i < n then ref r h (i + 1) else endS).some_
  | .ax h => (if i < n then ref r h (i + 1) else endW).all_
  | .ef h => (untilAt .tt h i endS).some_
  | .af h => (untilAt .tt h i endS).all_
  | .eg h => (untilAt h .ff i endW).some_
  | .ag h => (untilAt h .ff i endW).all_
  | .eu a b => (untilAt a b i endS).some_
  | .au a b => (untilAt a b i endS).all_
  | .ew a b => (untilAt a b i endW).some_
  | .aw a b => (untilAt a b i endW).all_
  | _ => .presumablyFalse

def nextR (s : Nat) : Nat := (s * 1103515245 + 12345) % 2147483648
def pick (s k : Nat) : Nat × Nat := let s' := nextR s; (s' / 65536 % k, s')

partial def genF (s : Nat) (d : Nat) : Formula × Nat :=
  let (k, s) := pick s (if d == 0 then 3 else 13)
  let atom (s : Nat) : Formula × Nat := let (j, s) := pick s 3
    (match j with | 0 => .after "A" | 1 => .after "B" | _ => .terminal, s)
  match k with
  | 0 | 1 | 2 => atom s
  | 3 => let (a, s) := genF s (d - 1); (.not a, s)
  | 4 => let (a, s) := genF s (d - 1); let (b, s) := genF s (d - 1); (.and [a, b], s)
  | 5 => let (a, s) := genF s (d - 1); let (b, s) := genF s (d - 1); (.implies a b, s)
  | 6 => let (a, s) := genF s (d - 1); (.ex a, s)
  | 7 => let (a, s) := genF s (d - 1); (.ax a, s)
  | 8 => let (a, s) := genF s (d - 1); (.ef a, s)
  | 9 => let (a, s) := genF s (d - 1); (.ag a, s)
  | 10 => let (a, s) := genF s (d - 1); (.af a, s)
  | 11 => let (a, s) := genF s (d - 1); let (b, s) := genF s (d - 1); (.au a b, s)
  | _ => let (a, s) := genF s (d - 1); let (b, s) := genF s (d - 1); (.ew a b, s)

def genRun (s : Nat) : Run × Nat := Id.run do
  let (len, s0) := pick s 7
  let mut s := s0
  let mut ls : Array String := #[]
  for _ in [0:len] do
    let (j, s') := pick s 3
    s := s'
    ls := ls.push (match j with | 0 => "A" | 1 => "B" | _ => "C")
  let (c, s1) := pick s 2
  return ({ labels := ls, complete := c == 1 }, s1)

def disagreements (trials : Nat) : Nat := Id.run do
  let mut s := 42
  let mut bad := 0
  for _ in [0:trials] do
    let (g, s1) := genF s 4
    let (r, s2) := genRun s1
    s := s2
    let fast := eval r g
    for i in [0:r.labels.size + 1] do
      if fast[i]! != ref r g i then bad := bad + 1
  return bad

#guard disagreements 2000 == 0

end LeanFM.RunCheckTests
