import LeanFM.Session
import LeanFM.Session.Attack
import LeanFM.MDPDiagram

/-!
# Needham–Schroeder, and Lowe's attack

The public-key Needham–Schroeder protocol (1978), declared and run against an attacker who is the
network. Alice runs once, with a peer she chooses: Bob, or Ivo. Bob answers once, whoever claims to
be calling. Ivo is a legitimate user with his own key pair, so Alice may well choose to talk to him;
he also sees every message on the wire and may send anything he can derive.

Nothing here builds the state space. The roles are declared as scripts over message patterns, and
`LeanFM.Session.Attack` generates the model: every honest message goes to Ivo, and an honest role
accepts any message of the shape it expects that Ivo can build. Requirements are flags over that
world: `SecrecyBreach` when Bob has committed to a run with Alice and Ivo can derive Bob's nonce,
`Impersonation` when Bob has committed to Alice although Alice never ran with Bob. LeanFM's
`check_ctl` decides `never` of each. For the 1978 protocol both fail, and the counterexample is
Lowe's attack (1995). With Lowe's fix, Bob names himself in his reply, and both hold on every
reachable state. The secrecy requirement is also asked directly with a `knows` atom, without a
flag, and must agree.

Run: `lake env lean --run NeedhamSchroeder.lean`
-/

namespace NeedhamSchroeder
open LeanFM.Session LeanFM.Session.Knowledge LeanFM.Session.Attack Lean

/-! ## The protocol, as a session type -/

structure Msg1 where na : Nat deriving TypeName
structure Msg2 where na : Nat deriving TypeName
structure Msg3 where nb : Nat deriving TypeName

/-- `{na, A}pk(B)`, then `{na, nb}pk(A)`, then `{nb}pk(B)`. Afterwards each believes the other is
the one who decrypted its nonce. -/
--@begin NS
protocol NS (A, B) {
  m1: Msg1 from A to B;
  m2: Msg2 from B to A cause m1 where m2.na = m1.na;
  m3: Msg3 from A to B cause m2;
}
--@end NS

#guard (NS "A" "B").issues ["A", "B"] == []

/-! ## The protocol, as roles over terms -/

inductive Variant where
  /-- Needham and Schroeder, 1978: `{na, nb}pk(A)` -/
  | original
  /-- Lowe, 1995: `{na, nb, B}pk(A)`; Alice accepts only her chosen peer's name -/
  | lowe
  deriving DecidableEq, Repr

def name (n : String) : Pat := .lit (.atom n)
def na := Msg.atom "na"
def nb := Msg.atom "nb"
def ni := Msg.atom "ni"

--@begin Roles
def alice (v : Variant) : Role := { name := "Alice", steps :=
  [ .choose "peer" [.atom "B", .atom "I"]
  , .claim "running" [name "A", .var "peer"]
  , .send (.var "peer") (.enc (.pk (.var "peer")) (.tuple [.lit na, name "A"]))
  , .recv (.enc (.pk (name "A")) (match v with
      | .original => .tuple [.lit na, .var "n"]
      | .lowe => .tuple [.lit na, .var "n", .var "peer"]))
  , .send (.var "peer") (.enc (.pk (.var "peer")) (.var "n"))
  , .claim "finished" [name "A", .var "peer"] ] }

def bob (v : Variant) : Role := { name := "Bob", steps :=
  [ .recv (.enc (.pk (name "B")) (.tuple [.var "m", .var "x"]))
  , .send (.var "x") (.enc (.pk (.var "x")) (match v with
      | .original => .tuple [.var "m", .lit nb]
      | .lowe => .tuple [.var "m", .lit nb, name "B"]))
  , .recv (.enc (.pk (name "B")) (.lit nb))
  , .claim "commit" [name "B", .var "x"] ] }

def declared (v : Variant) : Protocol :=
  { attacker := "Ivo"
  , attackerKnows := [.atom "A", .atom "B", .atom "I", .pk "A", .pk "B", .pk "I", .sk "I", ni]
  , domain := [na, nb, ni]
  , domains := [("x", [.atom "A", .atom "B", .atom "I"])]
  , roles := [alice v, bob v]
  , flags :=
    [ ⟨"SecrecyBreach", fun w => w.claimed "commit" [.atom "B", .atom "A"] && w.knows nb⟩
    , ⟨"Impersonation", fun w => w.claimed "commit" [.atom "B", .atom "A"] && !w.claimed "running" [.atom "A", .atom "B"]⟩
    , ⟨"HonestRun", fun w => w.claimed "commit" [.atom "B", .atom "A"] && w.claimed "finished" [.atom "A", .atom "B"]⟩ ] }
--@end Roles

/-! ## The requirements -/

def formulas : List (String × String × Json) :=
  [ ("secrecy", "Ivo never learns the nonce Bob shares with Alice",
      Json.mkObj [("never", Json.mkObj [("after", "SecrecyBreach")])])
  , ("authentication", "Bob never commits to Alice unless Alice ran with Bob",
      Json.mkObj [("never", Json.mkObj [("after", "Impersonation")])])
  , ("canComplete", "Alice and Bob can complete an honest run",
      Json.mkObj [("EF", Json.mkObj [("after", "HonestRun")])]) ]

/-- The secrecy requirement again, without a flag: once Bob has committed to Alice, Ivo never
knows Bob's nonce. -/
def secrecyByKnows : Json :=
  Json.mkObj [("never", Json.mkObj [("and", Json.arr #[
    Json.mkObj [("after", "Bob claims commit(B, A)")],
    Json.mkObj [("knows", Json.mkObj [("actor", "Ivo"), ("term", termJson nb)])]])])]

def original := (declared .original).explore
def lowe := (declared .lowe).explore
def ask (v : Variant) (f : Json) : Json :=
  (declared v).check (if v == .original then original else lowe) (if v == .original then "ns" else "nsl") f

-- The 1978 protocol: the attack exists. Lowe's fix: it does not. Both can still be run honestly.
#guard verdict (ask .original (formulas[0]!).2.2) == "disproved"
#guard verdict (ask .original (formulas[1]!).2.2) == "disproved"
#guard verdict (ask .original (formulas[2]!).2.2) == "proved"
#guard verdict (ask .lowe (formulas[0]!).2.2) == "proved"
#guard verdict (ask .lowe (formulas[1]!).2.2) == "proved"
#guard verdict (ask .lowe (formulas[2]!).2.2) == "proved"
-- Asked with a knows atom instead of a flag, secrecy gets the same verdicts.
#guard verdict (ask .original secrecyByKnows) == "disproved"
#guard verdict (ask .lowe secrecyByKnows) == "proved"

def report : IO Unit := do
  let runs : List (String × Variant × Model) :=
    [("Needham–Schroeder (1978)", .original, original), ("with Lowe's fix (1995)", .lowe, lowe)]
  for (title, v, m) in runs do
    IO.println s!"{title}: {m.states.size} states, {m.edges.length} transitions"
    for (key, reading, f) in formulas ++ [("secrecy, as a knows atom", "the same, without a flag", secrecyByKnows)] do
      let r := ask v f
      IO.println s!"  {key}: {verdict r}  ({reading})"
      for step in walk r do IO.println s!"      {step}"

/-! ## For the book -/

def tex (t : String) : String := (t.replace "{" "\\{").replace "}" "\\}"

/-- The wire along a returned walk, through Ivo, marking where he first can derive Bob's nonce. -/
def diagram (path : List String) : List LeanFM.MDPDiagram.InteractionMessage := Id.run do
  let p := declared .original
  let mut w : World := { threads := p.roles.map (fun _ => {}), attacker := canon (analz p.attackerKnows) }
  let mut out : List LeanFM.MDPDiagram.InteractionMessage := []
  let mut known := false
  for label in path do
    match (p.moves w).find? (·.label == label) with
    | some mv =>
      if let some (src, dst, m) := mv.wire then
        let note := if !known && mv.next.knows nb then "; now Ivo knows nb" else ""
        if note != "" then known := true
        out := out ++ [{ src, dst, label := tex (toString m) ++ note }]
      w := mv.next
    | none => pure ()
  return out

def block (src name : String) : String :=
  match (src.splitOn s!"--@begin {name}\n")[1]? with
  | some rest => ((rest.splitOn s!"--@end {name}").headD "").trimAsciiEnd.toString
  | none => panic! s!"no block {name}"

def ascii (t : String) : String :=
  (((t.replace "→" "->").replace "⇐" "<-").replace "⇒" "=>").replace "–" "-"

def listing (body : String) : String :=
  "\\begin{lstlisting}[language={}]\n" ++ ascii body ++ "\n\\end{lstlisting}\n"

def writeBook : IO Unit := do
  let src ← IO.FS.readFile "NeedhamSchroeder.lean"
  let out := "book/generated/"
  IO.FS.writeFile (out ++ "ns-protocol.tex") (listing (block src "NS"))
  IO.FS.writeFile (out ++ "ns-roles.tex") (listing (block src "Roles"))
  let attack := walk (ask .original (formulas[0]!).2.2)
  let numbered := (attack.zipIdx.map fun (l, i) => s!"{i + 1}. {l}")
  IO.FS.writeFile (out ++ "ns-attack.tex") (listing ("\n".intercalate numbered))
  IO.FS.writeFile (out ++ "ns-attack-diagram.tex")
    (LeanFM.MDPDiagram.renderInteractionTeX ["Alice", "Ivo", "Bob"] (diagram attack))
  let row := fun (reading : String) (f : Json) =>
    s!"{reading} & {verdict (ask .original f)} & {verdict (ask .lowe f)} \\\\"
  IO.FS.writeFile (out ++ "ns-verdicts.tex") <|
    "\\begin{tabular}{p{0.52\\textwidth}ll}\n\\toprule\n" ++
    s!"LeanFM \\texttt\{check\\_ctl} & 1978 ({original.states.size} states) & Lowe ({lowe.states.size} states) \\\\\n\\midrule\n" ++
    "\n".intercalate ((formulas.map fun (_, r, f) => row r f) ++
      [row "the same secrecy, as \\texttt{never (after commit(B, A) and knows(Ivo, nb))}" secrecyByKnows]) ++
    "\n\\bottomrule\n\\end{tabular}\n"

end NeedhamSchroeder

def main : IO Unit := do
  NeedhamSchroeder.report
  NeedhamSchroeder.writeBook
