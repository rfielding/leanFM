import LeanFM.SessionTools

/-! Writes the files a session type generates (clause selfhost.session.files). For a directory
holding `SessionType.leanfm` (the global session type with its message structures), it writes
under `generated/`: `Payload.proto`, `Payload.lean` (payload types, the event envelope and each
role's states) and `actors/<role>-openapi.yaml` for each role that serves HTTP. Nothing is written
outside `<dir>/generated/`. `Implementation.lean` beside the session type is written by hand: it
holds what is not a requirement (the transport binding, deployment and libraries).

Run from the LeanFM root: `lake env lean --run SessionFiles.lean examples/oauth`. -/

open Lean LeanFM.SessionTools

def main (args : List String) : IO UInt32 := do
  let some dir := args.head? | IO.eprintln "usage: lake env lean --run SessionFiles.lean <dir with SessionType.leanfm>"; return 2
  let text ← IO.FS.readFile s!"{dir}/SessionType.leanfm"
  match sessionFiles (Json.mkObj [("lean", Json.str text)]) with
  | .error e => IO.eprintln s!"{dir}/SessionType.leanfm: {e}"; return 1
  | .ok files =>
    for (path, body) in files do
      let out := s!"{dir}/generated/{path}"
      if let some parent := (System.FilePath.mk out).parent then IO.FS.createDirAll parent
      IO.FS.writeFile out body
      IO.println s!"wrote {out}"
    return 0
