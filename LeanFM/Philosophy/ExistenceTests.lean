import LeanFM.Philosophy.Existence

/-! Tests for the philosophy calculator. Built with the library, so `lake build` runs them. -/

namespace LeanFM.Philosophy.ExistenceTests
open LeanFM.Philosophy

def eval (id : String) (w : World) : Bool := ((sentence? id).map (·.eval w)).getD false

-- the closed form agrees with iterating the successor
#guard (worlds 12).all fun w => (List.range (3 * w.size)).all fun k => w.reach k == w.iterate k

-- each top policy gives up exactly one of total, injective, zero-first
def peano (w : World) : List Bool := [eval "succ-total" w, eval "succ-injective" w, eval "zero-first" w]
#guard (worlds 12).all fun w => match w.top with
  | .undefined => peano w == [false, true, true]
  | .wrap      => peano w == [true, true, false]
  | .saturate  => peano w == [true, false, true]
-- so no catalogued world has all three, as no_finite_dedekind says of every finite world
#guard (worlds 12).all fun w => peano w != [true, true, true]

-- the wraparound world keeps "a successor is larger" but loses transitivity: order is local
#guard (worlds 12).all fun w => w.top != .wrap || (eval "succ-above" w && !eval "order-transitive" w)
-- the ladder's verdicts for ℕ, each proved by a theorem in Existence.lean
#guard ladder.map (·.inNat) == [true, true, true, true, true, false, true]

-- frame conditions agree with their axioms on every catalogued frame
#guard (frames ++ [linear 1, linear 2, single 1]).all fun f => f.convergent == f.axiom2
#guard (frames ++ [linear 1, linear 2, single 1]).all fun f => f.connected == f.axiom3
-- the Barcan formula fails exactly on the frames that grow
#guard frames.all fun f => f.barcan == !f.grows
-- the modal logics separate the frames
#guard frames.map (fun f => (f.grows, f.axiom2, f.axiom3, f.barcan)) ==
  [(true, true, true, false), (true, true, false, false), (true, false, false, false), (false, true, true, true)]

def report (name : String) : Report :=
  match positions.find? (·.name == name) with
  | some p => classify p.answers
  | none => classify []

-- Zeilberger's position lives in finite worlds with an undefined top
#guard (report "Largest number, successor undefined").finiteWorlds.length == 10
#guard (report "Largest number, successor undefined").finiteWorlds.all (·.startsWith "undefined top")
#guard !(report "Largest number, successor undefined").nat
-- potentialists and the actualist agree on every ladder sentence (all need an infinite world) ...
#guard ["Linear potentialism", "Convergent potentialism", "Actualism"].all fun n =>
  (report n).finiteWorlds.isEmpty && (report n).nat && (report n).infinite.isSome
-- ... and are told apart only by the frames
#guard (report "Linear potentialism").frames == ["linear, 5 stages"]
#guard (report "Convergent potentialism").frames == ["convergent (two extensions meet)"]
#guard (report "Actualism").frames == ["one completed stage of 5 numbers"]

-- a theorem-backed conflict is called impossible
#guard ((classify [("largest", true), ("succ-total", true), ("succ-above", true)]).conflict.bind (·.2)).isSome
#guard ((classify [("exp-total", true), ("succ-total", false)]).conflict.bind (·.2)).isSome
-- a gap in the catalogue is reported as a gap, never as impossible: a world that wraps but keeps
-- the plain order would satisfy these, it is just not catalogued
#guard match (classify [("largest", true), ("zero-first", false)]).conflict with
  | some (_, none) => true | _ => false
-- unknown sentences are reported, not silently ignored
#guard (classify [("succ-total", true), ("choice", true)]).unknown == ["choice"]

end LeanFM.Philosophy.ExistenceTests
