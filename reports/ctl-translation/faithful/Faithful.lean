import LeanFM.SessionTools
open Lean LeanFM

/-- dump <file.leanfm> <out.json>: the protocol's state graph as the checker's inline task.
    check <file.leanfm> <formulas.json> <out.json>: decide each formula on that graph. -/
def main (args : List String) : IO UInt32 := do
  match args with
  | ["dump", file, out] =>
    let text ← IO.FS.readFile file
    match (do let p ← LeanFM.SessionTools.parseProtocol (Json.mkObj [("lean", Json.str text)]); let (d, _) ← p.global.draft p.name; pure (p.name, d)) with
    | .ok (n, d) => IO.FS.writeFile out (Json.mkObj [("name", Json.str n), ("draft", d)]).compress; pure 0
    | .error e => IO.eprintln e; pure 1
  | ["check", file, fs, out] =>
    let text ← IO.FS.readFile file
    let some (.arr forms) := (Json.parse (← IO.FS.readFile fs)).toOption | IO.eprintln "bad formulas"; pure 1
    match (do let p ← LeanFM.SessionTools.parseProtocol (Json.mkObj [("lean", Json.str text)]); let (d, _) ← p.global.draft p.name; pure (p.name, d)) with
    | .error e => IO.eprintln e; pure 1
    | .ok (n, d) =>
      let t0 ← IO.monoMsNow
      let mut rows := #[]
      for f in forms do
        let s ← IO.monoMsNow
        let v := match LeanFM.Session.checkDraft n d f with
          | .ok a => (a.getObjValAs? String "verdict").toOption.getD "?" ++ (match (a.getObjValAs? String "report").toOption with | some r => if r.isEmpty then "" else " | " ++ r | none => "")
          | .error e => "error: " ++ e
        let e ← IO.monoMsNow
        rows := rows.push (Json.mkObj [("verdict", Json.str v), ("ms", toJson (e - s))])
      let t1 ← IO.monoMsNow
      IO.FS.writeFile out (Json.mkObj [("ms", toJson (t1 - t0)), ("rows", Json.arr rows)]).compress
      pure 0
  | ["checkdraft", dfile, fs, out] =>
    let some dj := (Json.parse (← IO.FS.readFile dfile)).toOption | IO.eprintln "bad draft"; pure 1
    let d := (dj.getObjVal? "draft").toOption.getD dj
    let some (.arr forms) := (Json.parse (← IO.FS.readFile fs)).toOption | IO.eprintln "bad formulas"; pure 1
    let big : LeanFM.Logic.Bounds := { LeanFM.Session.sessionBounds with maxFormulaNodes := 100000000, maxDepth := 100000, maxArgumentBytes := 1000000000 }
    let t0 ← IO.monoMsNow
    let .ok t := LeanFM.Logic.resolveTask d big | IO.eprintln "bad task"; pure 1
    let some m := LeanFM.Logic.buildModel t big | IO.eprintln "model too big"; pure 1
    let t1 ← IO.monoMsNow
    let mut rows := #[]
    for fj in forms do
      let s ← IO.monoMsNow
      let v := match LeanFM.Logic.parseFormula fj with
        | .ok f => if (LeanFM.Logic.Model.sat m f)[0]! then "proved" else "disproved"
        | .error e => "error: " ++ e
      let e ← IO.monoMsNow
      rows := rows.push (Json.mkObj [("verdict", Json.str v), ("ms", toJson (e - s))])
    let t2 ← IO.monoMsNow
    IO.FS.writeFile out (Json.mkObj [("modelMs", toJson (t1 - t0)), ("ms", toJson (t2 - t1)), ("nodes", toJson m.size), ("rows", Json.arr rows)]).compress
    pure 0
  | ["mutants", mfile, fs, out] =>
    let some (.arr ds) := (Json.parse (← IO.FS.readFile mfile)).toOption | IO.eprintln "bad mutants"; pure 1
    let some (.arr forms) := (Json.parse (← IO.FS.readFile fs)).toOption | IO.eprintln "bad formulas"; pure 1
    let big : LeanFM.Logic.Bounds := { LeanFM.Session.sessionBounds with maxFormulaNodes := 100000000, maxDepth := 100000, maxArgumentBytes := 1000000000 }
    let fsP := forms.toList.filterMap fun fj => (LeanFM.Logic.parseFormula fj).toOption
    let mut rows := #[]
    for d in ds do
      let r : Json := match LeanFM.Logic.resolveTask d big with
        | .error e => Json.str ("error: " ++ e)
        | .ok t => match LeanFM.Logic.buildModel t big with
          | none => Json.str "too big"
          | some m => match (fsP.zip (List.range fsP.length)).find? (fun (f, _) => !(LeanFM.Logic.Model.sat m f)[0]!) with
            | some (_, i) => toJson i
            | none => Json.null
      rows := rows.push r
    IO.FS.writeFile out (Json.arr rows).compress
    pure 0
  | _ => IO.eprintln "usage"; pure 2
