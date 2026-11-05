import LeanFM.Session
import LeanFM.Session.Attack
import LeanFM.Logic
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

/-- The secrecy requirement again, without a flag: never is Bob committed to Alice while Ivo knows
Bob's nonce. -/
def secrecyByKnows : Json :=
  Json.mkObj [("never", Json.mkObj [("and", Json.arr #[
    Json.mkObj [("claimed", "commit(B, A)")],
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

/-! ## Two sessions: reflection

A challenge–response with one shared key, `kAB`. Alice challenges with `na`; Bob answers with
`{na}kAB` and his own challenge `nb`; Alice answers `{nb}kAB`. With one session of Bob it is safe.
With two, Ivo needs no key: he hands Bob's own challenge to Bob's second session, which encrypts it
for him. -/

def kAB : Pat := .lit (.key "kAB")

--@begin Reflection
/-- With `named`, each answer carries the name of the party who made it. -/
def answer (named : Bool) (x : String) (who : String) : Pat :=
  .enc kAB (if named then .pair (.var x) (name who) else .var x)

def challenger (named : Bool := false) : Role := { name := "Alice", steps :=
  [ .fresh "na"
  , .claim "running" [name "A", name "B"]
  , .send (name "B") (.var "na")
  , .recv (.pair (answer named "na" "B") (.var "m"))
  , .send (name "B") (answer named "m" "A")
  , .claim "finished" [name "A", name "B"] ] }

def responder (named : Bool := false) : Role := { name := "Bob", steps :=
  [ .recv (.var "c")
  , .fresh "nb"
  , .send (name "A") (.pair (answer named "c" "B") (.var "nb"))
  , .recv (answer named "nb" "A")
  , .claim "commit" [name "B", name "A"] ] }

def reflection (bobSessions : Nat) (named : Bool := false) : Protocol :=
  let roles := (challenger named).sessions 1 ++ (responder named).sessions bobSessions
  { attacker := "Ivo"
  , attackerKnows := [.atom "A", .atom "B", ni]
  , domain := coverFresh roles [na, nb, ni]
  , roles
  , flags := [] }
--@end Reflection

/-- Bob commits to Alice though Alice never started a run with him. -/
def impersonation : Json := Json.mkObj [("never", Json.mkObj [("and", Json.arr #[
  Json.mkObj [("claimed", "commit(B, A)")],
  Json.mkObj [("not", Json.mkObj [("claimed", "running(A, B)")])]])])]

def reflectionCompletes : Json := Json.mkObj [("EF", Json.mkObj [("and", Json.arr #[
  Json.mkObj [("claimed", "commit(B, A)")], Json.mkObj [("claimed", "finished(A, B)")]])])]

def oneBob := (reflection 1).explore
def twoBobs := (reflection 2).explore
def askReflection (n : Nat) (f : Json) : Json :=
  (reflection n).check (if n == 1 then oneBob else twoBobs) s!"reflection{n}" f

#guard verdict (askReflection 1 impersonation) == "proved"
#guard verdict (askReflection 2 impersonation) == "disproved"
#guard verdict (askReflection 2 reflectionCompletes) == "proved"

-- The fix: each answer names who made it, so Bob's own answer is not the one he waits for.
def twoBobsNamed := (reflection 2 true).explore
def askNamed (f : Json) : Json := (reflection 2 true).check twoBobsNamed "reflection-named" f
#guard verdict (askNamed impersonation) == "proved"
#guard verdict (askNamed reflectionCompletes) == "proved"

def reportReflection : IO Unit := do
  for n in [1, 2] do
    let m := if n == 1 then oneBob else twoBobs
    IO.println s!"Reflection with {n} session(s) of Bob: {m.states.size} states"
    for (key, f) in [("impersonation", impersonation), ("canComplete", reflectionCompletes)] do
      let r := askReflection n f
      IO.println s!"  {key}: {verdict r}"
      for step in walk r do IO.println s!"      {step}"

/-! ## A defender on the wire

Bob accepts whatever reaches him. A defender, Guard, stands in front of him and drops `bad`. What
it can stop depends on what it can see: a plaintext `bad`, yes; `bad` sealed for Bob, only when it
holds Bob's key, as an intercepting gateway does. Declared as the JSON `check_protocol` takes. -/

--@begin Defender
def guarded (bobReceives : Json) (defender : Option Json) (formula : Json) : Json :=
  let base := json% {
    roles: [{name: "Bob", steps: [
      {recv: $(bobReceives)},
      {claim: {name: "accept", args: [{atom: "B"}, {var: "x"}]}}]}],
    attacker: {name: "Ivo", knows: [{atom: "B"}, {atom: "good"}, {atom: "bad"}, {pk: "B"}]},
    domain: [{atom: "good"}, {atom: "bad"}],
    formula: $(formula) }
  match defender with
  | some d => base.setObjVal! "defender" d
  | none => base

def plain := json% {var: "x"}
def sealedForBob := json% {enc: {key: {pk: "B"}, body: {var: "x"}}}
def filter := json% {name: "Guard", protects: ["Bob"], drop: [{atom: "bad"}]}
def intercepting := json% {name: "Guard", protects: ["Bob"], knows: [{sk: "B"}], drop: [{atom: "bad"}]}
--@end Defender

def neverBad := json% {never: {claimed: "accept(B, bad)"}}
def goodArrives := json% {EF: {claimed: "accept(B, good)"}}

def tool (name : String) (args : Json) : Json :=
  match LeanFM.Logic.run name args with
  | some (.ok j) => j
  | some (.error e) => Json.mkObj [("verdict", "rejected"), ("reason", Json.str e)]
  | none => Json.mkObj [("verdict", "no tool")]

def defenderCases : List (String × Json × Option Json) :=
  [ ("no defender, plaintext", plain, none)
  , ("filter, plaintext", plain, some filter)
  , ("filter, sealed for Bob", sealedForBob, some filter)
  , ("intercepting filter (holds sk(B)), sealed for Bob", sealedForBob, some intercepting) ]

#guard defenderCases.map (fun (_, r, d) => verdict (tool "check_protocol" (guarded r d neverBad))) ==
  ["disproved", "proved", "disproved", "proved"]
#guard defenderCases.all (fun (_, r, d) => verdict (tool "check_protocol" (guarded r d goodArrives)) == "proved")

/-! ## Reassembly

The defender scans the stream Bob reads for the signature EVIL, but the attacker cuts the stream
into segments, and when two segments overlap, the defender and the host may keep different bytes. -/

def reassemblyCases : List (String × String) :=
  [("first", "last"), ("last", "first"), ("first", "first"), ("last", "last")]

def reassembly (box host : String) : Json :=
  tool "check_reassembly" (Json.mkObj [("box", Json.str box), ("host", Json.str host)])

/-! ## For the book -/

def tex (t : String) : String := ((t.replace "{" "\\{").replace "}" "\\}").replace "#" "\\#"

/-- The wire along a returned walk, through Ivo, marking where he first can derive `watch`. -/
def diagram (p : Protocol) (watch : Msg) (path : List String) : List LeanFM.MDPDiagram.InteractionMessage := Id.run do
  let mut w : World := { threads := p.roles.map (fun _ => {}), attacker := canon (analz p.attackerKnows) }
  let mut out : List LeanFM.MDPDiagram.InteractionMessage := []
  let mut known := false
  for label in path do
    match (p.moves w).find? (·.label == label) with
    | some mv =>
      if let some { src, dst, term := m, .. } := mv.wire then
        let note := if !known && mv.next.knows watch then s!"; now Ivo knows {watch}" else ""
        if note != "" then known := true
        out := out ++ [{ src := tex src, dst := tex dst, label := tex (toString m ++ note) }]
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
    (LeanFM.MDPDiagram.renderInteractionTeX ["Alice", "Ivo", "Bob"] (diagram (declared .original) nb attack))
  IO.FS.writeFile (out ++ "ns-reflection-roles.tex") (listing (block src "Reflection"))
  IO.FS.writeFile (out ++ "ns-defender.tex") (listing (block src "Defender"))
  let tt := fun (t : String) => "\\texttt{" ++ tex t ++ "}"
  IO.FS.writeFile (out ++ "ns-defender-verdicts.tex") <|
    "\\begin{tabular}{p{0.46\\textwidth}ll}\n\\toprule\n" ++
    "Bob receives, through & Bob never accepts bad & good still arrives \\\\\n\\midrule\n" ++
    "\n".intercalate (defenderCases.map fun (n, r, d) =>
      s!"{n} & {verdict (tool "check_protocol" (guarded r d neverBad))} & {verdict (tool "check_protocol" (guarded r d goodArrives))} \\\\") ++
    "\n\\bottomrule\n\\end{tabular}\n"
  let segText := fun (j : Json) => match j.getObjValD "segments" with
    | .arr ss => if ss.isEmpty then "---" else ", then ".intercalate (ss.toList.map fun (sg : Json) =>
        s!"{tt ((sg.getObjValD "data").getStr?.toOption.getD "?")} at {(sg.getObjValD "offset").getStr?.toOption.getD "?"}")
    | _ => "---"
  let rows ← reassemblyCases.mapM fun (b, h) => do
    let r := reassembly b h
    IO.println s!"reassembly {b}/{h}: {verdict r}"
    pure s!"{b} & {h} & {verdict r} & {segText r} \\\\"
  IO.FS.writeFile (out ++ "ns-reassembly.tex") <|
    "\\begin{tabular}{llll}\n\\toprule\n" ++
    "defender keeps & host keeps & never delivered & evasion \\\\\n\\midrule\n" ++
    "\n".intercalate rows ++ "\n\\bottomrule\n\\end{tabular}\n"
  let reflected := walk (askReflection 2 impersonation)
  IO.FS.writeFile (out ++ "ns-reflection.tex")
    (listing ("\n".intercalate (reflected.zipIdx.map fun (l, i) => s!"{i + 1}. {l}")))
  IO.FS.writeFile (out ++ "ns-reflection-diagram.tex")
    (LeanFM.MDPDiagram.renderInteractionTeX (["Bob", "Ivo", "Bob#2"].map tex)
      (diagram (reflection 2) (.enc (.key "kAB") nb) reflected))
  IO.FS.writeFile (out ++ "ns-reflection-verdicts.tex") <|
    "\\begin{tabular}{p{0.40\\textwidth}lll}\n\\toprule\n" ++
    s!"LeanFM \\texttt\{check\\_ctl} & one Bob ({oneBob.states.size}) & two Bobs ({twoBobs.states.size}) & two Bobs, names inside ({twoBobsNamed.states.size}) \\\\\n\\midrule\n" ++
    "\n".intercalate ([("Bob never commits to Alice unless Alice ran with Bob", impersonation),
      ("Alice and Bob can complete an honest run", reflectionCompletes)].map fun (r, f) =>
        s!"{r} & {verdict (askReflection 1 f)} & {verdict (askReflection 2 f)} & {verdict (askNamed f)} \\\\") ++
    "\n\\bottomrule\n\\end{tabular}\n"
  let row := fun (reading : String) (f : Json) =>
    s!"{reading} & {verdict (ask .original f)} & {verdict (ask .lowe f)} \\\\"
  IO.FS.writeFile (out ++ "ns-verdicts.tex") <|
    "\\begin{tabular}{p{0.52\\textwidth}ll}\n\\toprule\n" ++
    s!"LeanFM \\texttt\{check\\_ctl} & 1978 ({original.states.size} states) & Lowe ({lowe.states.size} states) \\\\\n\\midrule\n" ++
    "\n".intercalate ((formulas.map fun (_, r, f) => row r f) ++
      [row "the same secrecy, as \\texttt{never (claimed commit(B, A) and knows(Ivo, nb))}" secrecyByKnows]) ++
    "\n\\bottomrule\n\\end{tabular}\n"

end NeedhamSchroeder

def main : IO Unit := do
  NeedhamSchroeder.report
  NeedhamSchroeder.reportReflection
  NeedhamSchroeder.writeBook
