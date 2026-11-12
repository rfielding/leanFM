import LeanFM

/-!
# GoServer's message types, from its .proto

`spec/Requirements.proto` is the source of truth for GoServer's messages. This writes the
`--@begin Types` region of `spec/Session.lean` from it: one Lean structure per message the session
type uses (and every message those contain), each field named by its protobuf JSON name, as the Go
server sends it (`request_id` is `requestId`), and an empty structure for each local event the
proto does not declare. The `where` conditions in `Session.lean` are then typed against the whole
messages, by Lean when the file is elaborated and by LeanFM's parser in the session-type panel. It
also writes `spec/generated/Payload.lean`, the session as a Lean module: the payload types, the
event envelope, and the states of each role whose projection is sequential.

Run from the LeanFM root after changing `spec/Requirements.proto`:
`lake env lean --run projects/GoServer/spec/SessionTypes.lean`, then
`lake env lean projects/GoServer/spec/Session.lean` and
`lake env lean --run projects/GoServer/spec/SessionPanel.lean`.
-/

open Lean LeanFM LeanFM.Session

namespace Project.SessionTypes

def root := "projects/GoServer/spec"

/-- The session-type regions (`--@begin Rooms` and after), without the Types region. -/
partial def protocolRegions (lines : List String) (acc : Array String := #[]) (inside : Bool := false) : Array String :=
  match lines with
  | [] => acc
  | l :: rest =>
    if l.startsWith "--@begin Types" then protocolRegions ((rest.dropWhile (!·.startsWith "--@end Types")).drop 1) acc false
    else if l.startsWith "--@begin " then protocolRegions rest acc true
    else if l.startsWith "--@end " then protocolRegions rest acc false
    else if inside then protocolRegions rest (acc.push l) true
    else protocolRegions rest acc false

def leanStructure (m : Types.Message) : String :=
  let doc := if m.doc.isEmpty then [] else [s!"/-- {m.doc} -/"]
  "\n".intercalate (doc ++ (if m.fields.isEmpty then [s!"structure {m.name} where deriving TypeName"] else
    [s!"structure {m.name} where"] ++ m.fields.map (fun f => s!"  {f.name} : {f.ty.render}") ++ ["  deriving TypeName"]))

def main : IO UInt32 := do
  let src ← IO.FS.readFile s!"{root}/Session.lean"
  let proto ← IO.FS.readFile s!"{root}/Requirements.proto"
  let env ← IO.ofExcept (Proto.ofProto proto)
  let text := "\n".intercalate (protocolRegions (src.splitOn "\n")).toList
  -- the protocol read with the proto's types: every condition is typed against whole messages
  let parsed ← IO.ofExcept (Text.parse text (some env))
  -- every protocol of the file, not only the main one: each label needs its type for Lean
  let labels := parsed.allLabels
  let ms ← IO.ofExcept (Types.complete env labels (onlyUsed := true))
  let region := "\n\n".intercalate (ms.map leanStructure)
  let lines := src.splitOn "\n"
  let before := lines.takeWhile (!·.startsWith "--@begin Types")
  let after := (lines.dropWhile (!·.startsWith "--@end Types"))
  if after.isEmpty then IO.eprintln "Session.lean has no --@begin Types / --@end Types region"; return 1
  let header := ["--@begin Types",
    "-- Generated from spec/Requirements.proto by spec/SessionTypes.lean; regenerate it rather than editing.",
    "-- Fields carry their protobuf JSON names, as the Go server sends them."]
  IO.FS.writeFile s!"{root}/Session.lean" ("\n".intercalate (before ++ header ++ [region] ++ after))
  IO.println s!"wrote the Types region of {root}/Session.lean: {ms.length} message types from Requirements.proto"
  -- the session as a Lean module: payload types, the event envelope, and the states of each
  -- sequential role (selfhost.session.lean); roles that run branches in parallel are named with the reason
  let (lean, notes) ← IO.ofExcept (parsed.global.leanModule parsed.name parsed.roles env)
  IO.FS.createDirAll s!"{root}/generated"
  IO.FS.writeFile s!"{root}/generated/Payload.lean" lean
  IO.println s!"wrote {root}/generated/Payload.lean{if notes.isEmpty then "" else s!" ({notes.length} roles without states)"}"
  return 0

end Project.SessionTypes

def main : IO UInt32 := Project.SessionTypes.main
