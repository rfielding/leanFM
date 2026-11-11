import LeanFM.SessionTools
open Lean LeanFM.SessionTools

-- Reproducible evidence for selfhost.session.generative{,.execution,.monitor}.
def main : IO Unit := do
  let source ← IO.FS.readFile "examples/sessions/DepositSettlement.leanfm"
  let overlay ← IO.ofExcept (Json.parse (← IO.FS.readFile "examples/sessions/DepositSettlement.overlay.json"))
  let base := [("lean", Json.str source), ("instances", toJson (10 : Nat)), ("seed", toJson (11 : Nat))]
  let checked ← IO.ofExcept (check (Json.mkObj base))
  let inlineRun ← IO.ofExcept (simulate (Json.mkObj base))
  let layeredRun ← IO.ofExcept (simulate (Json.mkObj (base ++ [("overlay", overlay)])))
  let monitored ← IO.ofExcept (conform (Json.mkObj [
    ("lean", source), ("overlay", overlay), ("events", layeredRun.getObjValD "events")]))
  let evidence := Json.mkObj [
    ("prompt", "Implement inline deadlines and probabilities while retaining external probability layers."),
    ("question", "Does the accepted settlement example check, generate and round-trip with both forms of annotation?"),
    ("source", "examples/sessions/DepositSettlement.leanfm and DepositSettlement.overlay.json"),
    ("reducer", "session_check; seeded session_simulate; session_conform on generated events"),
    ("unit", "session-relative milliseconds and exact conditional probability"),
    ("boundary", "ten finite sequential settlement sessions, seed 11; illustrative declared assumptions"),
    ("check", checked), ("inline", inlineRun), ("external", layeredRun), ("conform", monitored)]
  IO.FS.writeFile "exports/legal-render-conversation/generative-check.json" evidence.pretty
