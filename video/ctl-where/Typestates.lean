import LeanFM.SessionTools
import LeanFM.Session.Faithful

/-! The checker model, the refinement rounds and the typestate graph of each protocol the video
draws, as LeanFM's own `Faithful.typestates` computes them (the book's `typestatesOf`). The video
colours nodes by these classes; nothing about them is drawn by hand.
Usage: lake env lean --run video/ctl-where/Typestates.lean <out.json> <name>=<file.leanfm> ... -/

open Lean LeanFM.Session LeanFM.Session.Faithful LeanFM.SessionTools

def modelOf (text : String) : IO Typestates := do
  let p ← IO.ofExcept (parseProtocol (Json.mkObj [("lean", Json.str text)]))
  let (d, _) ← IO.ofExcept (p.global.draft p.name)
  let g ← IO.ofExcept (modelOfDraft d)
  return typestates g

def toJ (t : Typestates) : Json :=
  let g := t.graph
  Json.mkObj
    [ ("nodes", Json.arr (g.label.map fun (m, e) => Json.mkObj [("message", match m with | some x => Json.str x | none => Json.null), ("ends", Json.bool e)]))
    , ("succ", Json.arr (g.succ.map fun s => Json.arr (s.map toJson)))
    , ("rounds", Json.arr (t.rounds.map fun r => Json.arr (r.map toJson)))
    , ("rep", Json.arr (t.rep.map toJson))
    , ("next", Json.arr (t.next.map fun s => Json.arr (s.map toJson)))
    , ("lookahead", toJson t.lookahead)
    , ("typestates", toJson t.count) ]

def main (args : List String) : IO Unit := do
  let out :: specs := args | throw (IO.userError "usage: Typestates.lean <out.json> <name>=<file> ...")
  let mut res : List (String × Json) := []
  for s in specs do
    let [name, file] := s.splitOn "=" | throw (IO.userError s!"expected name=file, got {s}")
    res := res ++ [(name, toJ (← modelOf (← IO.FS.readFile file)))]
  IO.FS.writeFile out (Json.mkObj res).pretty
  IO.println s!"wrote {out}"
