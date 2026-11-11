import LeanFM.SessionTools
open Lean LeanFM.Session LeanFM.SessionTools

def main : IO Unit := do
  let source ← IO.FS.readFile "examples/sessions/DepositSettlement.leanfm"
  let p ← IO.ofExcept (Text.parse source)
  let layer ← IO.ofExcept (Generative.resolve p.body)
  let paths ← IO.ofExcept (Generative.compile layer p.roles)
  let result := Json.mkObj [
    ("prompt", "Show a diagram of the settlement example with probability"),
    ("question", "Which interactions and deadlines result from each declared branch and delay sample?"),
    ("source", "examples/sessions/DepositSettlement.leanfm"),
    ("reducer", "Text.parse; Generative.resolve; Generative.compile; Generative.reports"),
    ("unit", "exact conditional probability; fixed 24-hour days"),
    ("boundary", "One finite sequential settlement; illustrative declared assumptions, no measured frequencies"),
    ("metadata", layer.metadata),
    ("paths", toJson (paths.map fun (path, run) => Json.mkObj [
      ("probability", path.probability.text),
      ("events", Json.arr (run.events.map eventJson)),
      ("obligations", toJson (Generative.reports run run.now))]))]
  IO.FS.writeFile "exports/settlement-probability/model.json" result.pretty
