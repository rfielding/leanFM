import LeanFM.Session.Text
import LeanFM.Session.Diagram

open LeanFM.Session

def main : IO Unit := do
  let source ← IO.FS.readFile "book/generated/legal-session-inference/DepositHistories.leanfm"
  let p ← match Text.parse source with
    | .ok p => pure p
    | .error e => throw (IO.userError e)
  let model := p.global.diagramModel p.roles p.name
  for shape in model.shapes do
    match shape with
    | .rect "activation" _ y _ h _ _ _ =>
      if y < 48 || y + h > model.height - 40 then
        throw (IO.userError s!"activation outside lifelines: {y}, {h}")
    | _ => pure ()
  IO.FS.writeFile "exports/legal-render-conversation/global-type-light.svg" (model.svg .light)
  IO.FS.writeFile "book/generated/legal-session-inference/global-type.svg" (model.svg .light)
  IO.println "ok: legal diagram regenerated; all activations stay within lifelines"
