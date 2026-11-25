import LeanFM.Session.SpecCheck
import LeanFM.Session.Calls

/-!
# Properties suggested from the protocol itself (clause selfhost.session.properties)

`session_ctl` without a formula answers questions built from the protocol shown, not generic ones:
whether a session can always still end, must end or can run forever, how it starts, whether each
call is answered (A-until, and non-vacuously with strongly-implies) and never answered before it is
asked (E-until under a negation), and, when the protocol declares secret fields, where secrets go.
Each suggestion is decided, so a suggestion is a question the protocol answers, with its path.
-/

namespace LeanFM.Session
open Lean

namespace Suggest

/-- At most this many suggestions. -/
def maxSuggestions : Nat := 12

def after (l : String) : Json := Json.mkObj [("on", Json.str l)]
def one (k : String) (f : Json) : Json := Json.mkObj [(k, f)]
def two (k : String) (a b : Json) : Json := Json.mkObj [(k, Json.arr #[a, b])]
def anyOf (ls : List String) : Json :=
  match ls with
  | [l] => after l
  | _ => Json.mkObj [("or", Json.arr (ls.map after).toArray)]
def notTerminal : Json := one "not" (Json.str "stop")
def secret (fields : List (String × String)) : Json := Json.mkObj [("secret", Json.mkObj (fields.map fun (k, v) => (k, Json.str v)))]

/-- A call with its nested calls, flattened. -/
partial def flatten (c : Call String) : List (Call String) := c :: c.nested.flatMap flatten

end Suggest

open Suggest in
/-- The suggested properties of one session of the protocol, named, at most `maxSuggestions`. -/
def Global.suggest (g : Global String) (roles : List String) (secretsOf : String → List String := fun _ => [])
    (maxStates : Nat := Conform.graphMaxStates) : Except String (List (String × Json)) := do
  let graph ← g.stateGraph maxStates
  let firsts := ((graph.edges.filter (·.1 == "s0")).map (·.2.2.label)).eraseDups
  let base : List (String × Json) :=
    [ ("Every session can still end from every state it reaches (no trap)", one "AG" (one "EF" (Json.str "stop")))
    , ("Every session ends (no path runs forever)", one "AF" (Json.str "stop"))
    , ("Some session can run forever", one "EG" notTerminal) ] ++
    (if firsts.isEmpty then [] else
      [(s!"Every session starts with {" or ".intercalate firsts}", one "AX" (anyOf firsts))])
  -- secrets: only when the protocol declares secret fields on some message it sends
  let carrying := (graph.edges.filter fun (_, _, n) => !n.isAct && !(secretsOf n.label).isEmpty).map (·.2.2)
  let secretOnes : List (String × Json) :=
    if carrying.isEmpty then [] else
      let receivers := (carrying.map (·.dst)).eraseDups
      ("No secret is ever sent", one "AG" (one "not" (secret []))) ::
        ((roles.filter (!receivers.contains ·)).map fun r =>
          (s!"No secret ever reaches {r}", one "AG" (one "not" (secret [("to", r)]))))
  -- calls: one set per request label, its responses being every label that answers it
  let calls := (g.calls.flatMap flatten).filter (!·.responses.isEmpty)
  let byRequest : List (String × List String) := calls.foldl (fun acc c =>
    let rs := c.responses.map (·.label)
    match acc.find? (·.1 == c.request.label) with
    | some _ => acc.map fun (q, old) => if q == c.request.label then (q, (old ++ rs).eraseDups) else (q, old)
    | none => acc ++ [(c.request.label, rs.eraseDups)]) []
  let callOnes : List (String × Json) := byRequest.flatMap fun (q, rs) =>
    let answered := anyOf rs
    [ (s!"Every {q} is answered ({" or ".intercalate rs}) before the session ends",
        one "AG" (two "implies" (after q) (two "AU" notTerminal answered)))
    , (s!"{q} can happen, and every {q} is eventually answered",
        two "stronglyImplies" (after q) (one "AF" answered))
    , (s!"No {" or ".intercalate rs} before a {q}",
        one "not" (two "EU" (one "not" (after q)) answered)) ]
  return (base ++ secretOnes ++ callOnes).take maxSuggestions

/-- Every suggestion decided over one built graph: name, formula and the checker's answer (its
verdict, reading, notation and path), or the error that formula gave. -/
def Global.suggestions (g : Global String) (name : String) (roles : List String)
    (secretsOf : String → List String := fun _ => []) (b : LeanFM.Logic.Bounds := sessionBounds) :
    Except String (List (String × Json × Except String Json)) := do
  let ps ← g.suggest roles secretsOf b.maxDraftStates
  let answers ← g.checkFormulas name (ps.map (·.2)) secretsOf b
  return (ps.zip answers).map fun ((n, f), a) => (n, f, a)

end LeanFM.Session
