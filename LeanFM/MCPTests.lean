import LeanFM.MCP
import LeanFM.MCPHost

open Lean
open LeanFM.MCP
open LeanFM.MCPHost

def assertContains (label haystack needle : String) : IO Unit :=
  if haystack.contains needle then IO.println s!"ok: {label}"
  else throw <| IO.userError s!"{label}: expected {needle}"

/-- The navigator's stages for the view's smoke test (clause selfhost.mcp.session.navigator),
answered as project_view would, with the switch still off. -/
def projectViewResults : IO Json := do
  let pv (args : List (String × Json)) : IO Json := do
    match ← LeanFM.ProjectView.answer (Json.mkObj args) with
    | .ok (text, body) => pure (Json.mkObj [("content", Json.arr #[Json.mkObj [("type", "text"), ("text", text)]]), ("structuredContent", body)])
    | .error e => throw <| IO.userError s!"project_view {Json.mkObj args |>.compress}: {e}"
  let protocols ← pv [("stage", "requirements"), ("section", "protocols")]
  let firstProtocol := (((((protocols.getObjValD "structuredContent").getObjValD "page").getObjValD "items").getArr?).toOption.getD #[])[0]?.getD (Json.str "")
  -- every page of the code listing, as the view asks for them in turn
  let mut codePages : Array Json := #[]
  let mut offset : Option Nat := some 0
  while offset.isSome && codePages.size < 30 do
    let pg ← pv [("stage", "code"), ("offset", toJson offset.get!)]
    codePages := codePages.push pg
    offset := (((pg.getObjValD "structuredContent").getObjValD "page").getObjValAs? Nat "next").toOption
  return Json.mkObj [
    ("list", ← pv []), ("chat", ← pv [("stage", "chat")]), ("book", ← pv [("stage", "book"), ("page", (2 : Nat))]),
    ("requirements", ← pv [("stage", "requirements")]),
    ("sections", Json.mkObj [("tasks", ← pv [("stage", "requirements"), ("section", "tasks")]), ("protocols", protocols),
      ("clauses", ← pv [("stage", "requirements"), ("section", "clauses")]),
      ("requirements", ← pv [("stage", "requirements"), ("section", "requirements")]),
      ("implementations", ← pv [("stage", "requirements"), ("section", "implementations")]),
      ("properties", ← pv [("stage", "requirements"), ("section", "properties"), ("task", "selfhost_workflow")]),
      ("transitions", ← pv [("stage", "requirements"), ("section", "transitions"), ("task", "selfhost_workflow")])]),
    ("protocol", ← pv [("stage", "requirements"), ("file", firstProtocol)]),
    ("specFile", ← pv [("stage", "requirements"), ("file", "LeanFM/LLMGenerated/SelfHosting.lean")]),
    ("impl", ← pv [("stage", "impl")]),
    ("code", Json.arr codePages), ("codeFile", ← pv [("stage", "code"), ("file", "LeanFM/ProjectView.lean")]),
    ("maqam", Json.mkObj [("zig", ← pv [("project", "Maqam"), ("stage", "code")]),
      ("rust", ← pv [("project", "Maqam"), ("stage", "code"), ("impl", "rust")])])]

/-- project_view is unlisted and refused while the switch is off, as server_logs is. -/
def projectViewOffTests (offList : String) : IO Unit := do
  let expect (label : String) (ok : Bool) : IO Unit :=
    if ok then IO.println s!"ok: {label}" else throw <| IO.userError s!"failed: {label}"
  expect "MCP does not list project_view on a host that has not enabled it" (!offList.contains "\"project_view\"")
  let pvOff ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":77,\"method\":\"tools/call\",\"params\":{\"name\":\"project_view\",\"arguments\":{\"stage\":\"chat\"}}}"
  expect "MCP refuses project_view where it is off" (pvOff.body.contains "project_view is off on this host")

/-- server_info (clause selfhost.mcp.server-info, LeanFM/ServerInfo.lean): off, unlisted and refused, and
serverInfo.version without a commit, until the executable turns the switch on. -/
def serverInfoOffTests (offList : String) : IO Unit := do
  let expect (label : String) (ok : Bool) : IO Unit :=
    if ok then IO.println s!"ok: {label}" else throw <| IO.userError s!"failed: {label}"
  expect "MCP does not list server_info on a host that has not enabled it" (!offList.contains "\"server_info\"")
  let off ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":78,\"method\":\"tools/call\",\"params\":{\"name\":\"server_info\",\"arguments\":{}}}"
  expect "MCP refuses server_info where it is off" (off.body.contains "server_info is off on this host" && !off.body.contains "\"commit\"")
  LeanFM.ServerInfo.capture
  let init ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":79,\"method\":\"initialize\",\"params\":{}}"
  expect "MCP serverInfo.version names no commit where server_info is off" (init.body.contains "\"version\":\"0.1.0\"")

/-- server_info once enabled and captured in the checkout: its commit is git's HEAD. -/
def serverInfoTests : IO Unit := do
  let expect (label : String) (ok : Bool) : IO Unit :=
    if ok then IO.println s!"ok: {label}" else throw <| IO.userError s!"failed: {label}"
  let list ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":80,\"method\":\"tools/list\"}"
  expect "MCP lists server_info once enabled" (list.body.contains "\"name\":\"server_info\"")
  let r ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":81,\"method\":\"tools/call\",\"params\":{\"name\":\"server_info\",\"arguments\":{}}}"
  let sc := ((Json.parse r.body).toOption.getD Json.null).getObjValD "result" |>.getObjValD "structuredContent"
  let head := ((← IO.Process.output { cmd := "git", args := #["rev-parse", "HEAD"] }).stdout.splitOn "\n").headD ""
  let commit := (sc.getObjValAs? String "commit").toOption.getD ""
  expect "server_info's commit is git rev-parse HEAD" (LeanFM.ServerInfo.isCommit head && commit == head)
  expect "server_info counts changed files and is not stale" ((sc.getObjValAs? Nat "changedFiles").isOk && (sc.getObjValAs? Bool "stale").toOption == some false)
  let init ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":82,\"method\":\"initialize\",\"params\":{}}"
  expect "MCP serverInfo.version names the short commit where server_info is on" (init.body.contains s!"\"version\":\"0.1.0+{(head.take 12).toString}")
  let arg ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":83,\"method\":\"tools/call\",\"params\":{\"name\":\"server_info\",\"arguments\":{\"cmd\":\"ls\"}}}"
  expect "server_info refuses an argument" (arg.body.contains "server_info takes no arguments" && !arg.body.contains "\"commit\"")
  expect "isCommit accepts 40 and 64 lowercase hex digits only"
    (LeanFM.ServerInfo.isCommit (String.ofList (List.replicate 40 'a')) && LeanFM.ServerInfo.isCommit (String.ofList (List.replicate 64 '0')) &&
     !LeanFM.ServerInfo.isCommit (String.ofList (List.replicate 39 'a')) && !LeanFM.ServerInfo.isCommit (String.ofList (List.replicate 40 'A')) &&
     !LeanFM.ServerInfo.isCommit "main" && !LeanFM.ServerInfo.isCommit "fatal: not a git repository: /home/x/.git")
  expect "server_info is stale only when the executable is newer than at start"
    (LeanFM.ServerInfo.isStale 100 101 && !LeanFM.ServerInfo.isStale 100 100)

/-- Session tools load a project's protocol a file at a time (clause selfhost.mcp.session.project-files).
LeanFM and GoServer are committed, so every protocol file either lists must load through
`{project, file}` and check cleanly (session_check answers, not rejected); LeanFM's own protocol has
no review findings. Refusals: a file not listed, a path out of the root, a project not listed,
file together with lean, and project and file while project_view is off. -/
def projectFilesOffTests : IO Unit := do
  let r ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":90,\"method\":\"tools/call\",\"params\":{\"name\":\"session_check\",\"arguments\":{\"project\":\"LeanFM\",\"file\":\"LeanFM/LLMGenerated/LeanFM.leanfm\"}}}"
  if r.body.contains "is off on this host" && r.body.contains "\"isError\":true" then IO.println "ok: a session tool reads no project file while project_view is off"
  else throw <| IO.userError s!"failed: project file read while off: {r.body.take 300}"

def projectFilesTests : IO Unit := do
  let expect (label : String) (ok : Bool) : IO Unit :=
    if ok then IO.println s!"ok: {label}" else throw <| IO.userError s!"failed: {label}"
  let call (tool : String) (args : Json) : IO Json := do
    let req := Json.mkObj [("jsonrpc", "2.0"), ("id", (91 : Nat)), ("method", "tools/call"),
      ("params", Json.mkObj [("name", Json.str tool), ("arguments", args)])]
    let r ← dispatch req.compress
    match Json.parse r.body with
    | .ok j => pure (j.getObjValD "result")
    | .error e => throw <| IO.userError s!"{tool}: unparsable answer {e}"
  let rejected (j : Json) : Bool := (j.getObjValAs? Bool "isError").toOption.getD false
  let reason (j : Json) : String := ((j.getObjValD "structuredContent").getObjValAs? String "reason").toOption.getD ""
  for project in ["LeanFM", "GoServer"] do
    let mut files : Array String := #[]
    let mut offset : Option Nat := some 0
    while offset.isSome && files.size < 2000 do
      let .ok (_, body) ← LeanFM.ProjectView.answer (Json.mkObj [("project", Json.str project), ("stage", "requirements"),
        ("section", "protocols"), ("offset", toJson offset.get!)]) | throw <| IO.userError s!"{project}: protocols not listed"
      let pg := body.getObjValD "page"
      files := files ++ (((pg.getObjValD "items").getArr?).toOption.getD #[]).filterMap (·.getStr?.toOption)
      offset := (pg.getObjValAs? Nat "next").toOption
    expect s!"{project} lists protocol files" (!files.isEmpty)
    for f in files do
      let r ← call "session_check" (Json.mkObj [("project", Json.str project), ("file", Json.str f)])
      -- a file of a mistakes/ directory is an example written to fail (video/lean-tutorial/mistakes)
      if (f.splitOn "/").contains "mistakes" then
        if !rejected r then throw <| IO.userError s!"failed: {project} {f} was written to fail and loaded"
      -- a file holding only implementation blocks has no protocol to load, and says so
      else if rejected r && !(reason r).contains "holds only implementation blocks" then
        throw <| IO.userError s!"failed: {project} {f} does not load cleanly: {reason r}"
    IO.println s!"ok: every one of the {files.size} {project} protocol files loads through project and file and checks"
  let ps ← LeanFM.ProjectView.projects
  let some lean := ps[0]? | throw <| IO.userError "no LeanFM project"
  let files ← LeanFM.ProjectView.protocolFiles lean
  expect "LeanFM lists its own protocol first" (files.1[0]? == some "LeanFM/LLMGenerated/LeanFM.leanfm")
  let own ← call "session_review" (Json.mkObj [("project", "LeanFM"), ("file", "LeanFM/LLMGenerated/LeanFM.leanfm")])
  expect "LeanFM's own protocol reviews with no findings"
    (!rejected own && (((own.getObjValD "structuredContent").getObjValAs? String "reading").toOption.getD "").contains "no findings")
  let ex ← call "session_explore" (Json.mkObj [("project", "LeanFM"), ("file", "LeanFM/LLMGenerated/LeanFM.leanfm")])
  expect "session_explore opens LeanFM's own protocol by project and file" (!rejected ex && ex.compress.contains "LeanFMMcp")
  -- where a client starts (selfhost.mcp.introduction)
  let intro ← call "introduction" (Json.mkObj [])
  let ib := intro.getObjValD "structuredContent"
  expect "introduction answers the rule, LeanFM's requirement files, standings and next calls"
    (!rejected intro && ((ib.getObjValAs? String "rule").toOption.getD "").contains "strong implication" &&
     ib.compress.contains "LeanFM/LLMGenerated/LeanFM.leanfm" && (ib.getObjValD "standing").getObjValD "proved" != Json.null &&
     ((ib.getObjValD "next").getArr?.toOption.getD #[]).any fun c => (c.getObjValAs? String "tool").toOption == some "session_explore")
  let badIntro ← call "introduction" (Json.mkObj [("project", "NoSuchProject")])
  expect "introduction refuses an unknown project, naming the projects" (rejected badIntro && (reason badIntro).contains "LeanFM")
  expect "the instructions begin by telling the client to call introduction" (LeanFM.MCP.instructions.startsWith "Call introduction first")
  -- the tree carries the file's requirements with their standings (selfhost.requirements.tree)
  let treeOf (r : Json) : Array Json := ((r.getObjValD "structuredContent").getObjValD "tree").getArr?.toOption.getD #[]
  let label (n : Json) : String := (n.getObjValAs? String "label").toOption.getD ""
  let kind (n : Json) : String := (n.getObjValAs? String "kind").toOption.getD ""
  let t := treeOf ex
  expect "session_explore by file has a requirements node"
    (t.any fun n => kind n == "requirements" && (label n).startsWith "requirements: ")
  expect "the McpCall requirement stands proved, with its conform evidence under it"
    (t.any (fun n => kind n == "requirement" && label n == "proved · selfhost.session.event_log: Every MCP request a server takes is answered") &&
     t.any (fun n => kind n == "evidence" && (label n).contains "conform LeanFM/LLMGenerated/runs/mcp-call.jsonl"))
  let forged ← call "session_explore" (Json.mkObj [("project", "LeanFM"), ("file", "LeanFM/LLMGenerated/LeanFM.leanfm"),
    ("_requirements", Json.arr #[Json.mkObj [("id", "forged"), ("standing", "proved")]])])
  let parentOf (n : Json) : Option Nat := (n.getObjValAs? Nat "parent").toOption
  let ids := t.filterMap fun n => (n.getObjValAs? Nat "id").toOption
  let roots := t.filter fun n => match parentOf n with | some q => !ids.contains q | none => true
  expect "the tree is the list: one root, the requirements node"
    (roots.size == 1 && roots.all fun n => kind n == "requirements")
  expect "the implicit requirements of every LeanFM app are rows"
    (t.any (fun n => label n == "proved · protocol: LeanFMMcp checks with no issues") && t.any (fun n => label n == "proved · LeanFMMcp can always end"))
  expect "the first requirement row is the root protocol, labelled protocol:"
    ((t.filter (kind · == "requirement"))[0]?.map label == some "proved · protocol: selfhost.session.real_events: The MCP conversation follows LeanFMMcp")
  expect "the protocol's structure sits under a requirement row"
    (t.any fun n => kind n == "protocol" && (parentOf n).any fun q => t.any fun m => (m.getObjValAs? Nat "id").toOption == some q && kind m == "requirement")
  expect "every protocol of the file has its interaction diagram under a requirement row"
    (["LeanFMMcp", "McpCall", "ServerStart"].all fun q => t.any fun n => kind n == "definition" && label n == s!"interaction diagram of {q}" &&
      (parentOf n).any fun r => t.any fun m => (m.getObjValAs? Nat "id").toOption == some r && kind m == "requirement")
  expect "the root's first child is all CTL, holding every formula"
    (match t.toList with
     | _ :: first :: _ => kind first == "ctl" && (label first).startsWith "all CTL: " &&
         t.any (fun n => kind n == "formula" && label n == "(stronglyImplies (on Call) (inevitably (on Answer)))" && parentOf n == (first.getObjValAs? Nat "id").toOption)
     | _ => false)
  expect "a caller's _requirements is ignored" (!((treeOf forged).any fun n => (label n).contains "forged"))
  let plain ← call "session_explore" (Json.mkObj [("lean", "protocol P (A, B) { M from A to B; }"),
    ("_requirements", Json.arr #[Json.mkObj [("id", "forged"), ("standing", "proved")]])])
  expect "session_explore of lean text has no requirements node" (!((treeOf plain).any fun n => kind n == "requirements"))
  for (label, args, needle) in [
      ("a file that is not a listed protocol", Json.mkObj [("file", "LeanFM.lean")], "protocol files listed"),
      ("a path out of the root", Json.mkObj [("project", "GoServer"), ("file", "../../LeanFM/LLMGenerated/LeanFM.leanfm")], "protocol files listed"),
      ("an absolute path", Json.mkObj [("file", "/etc/passwd")], "protocol files listed"),
      ("a project not listed", Json.mkObj [("project", "projects/GoServer"), ("file", "x.leanfm")], "project must be one of"),
      ("file together with lean", Json.mkObj [("file", "LeanFM/LLMGenerated/LeanFM.leanfm"), ("lean", "protocol P (A, B) { M from A to B; }")], "not both"),
      ("project without file", Json.mkObj [("project", "GoServer")], "file must be")] do
    let r ← call "session_check" args
    expect s!"a session tool refuses {label}" (rejected r && (reason r).contains needle)

/-- project_view (LeanFM/ProjectView.lean, clause selfhost.mcp.session.navigator): the navigator's
stages, read-only, inside each project root. Runs with the switch on. -/
def projectViewTests : IO Unit := do
  let expect (label : String) (ok : Bool) : IO Unit :=
    if ok then IO.println s!"ok: {label}" else throw <| IO.userError s!"failed: {label}"
  let pvList ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":78,\"method\":\"tools/list\"}"
  expect "MCP lists project_view once enabled, drawn by the session view"
    (pvList.body.contains "\"name\":\"project_view\"" && LeanFM.MCP.projectViewTool.compress.contains "ui://leanfm/session-view")
  let pvCall (args : String) : IO String := do
    let r ← dispatch ("{\"jsonrpc\":\"2.0\",\"id\":79,\"method\":\"tools/call\",\"params\":{\"name\":\"project_view\",\"arguments\":" ++ args ++ "}}")
    pure r.body
  let names ← pvCall "{}"
  expect "project_view lists LeanFM first and the projects with a manifest"
    (names.contains "\"projects\":[\"LeanFM\",\"GoServer\"" && names.contains "PaxosKV")
  for bad in ["projects/GoServer", "../GoServer", "/etc", "GoServer/.."] do
    let r ← pvCall ("{\"project\":\"" ++ bad ++ "\",\"stage\":\"chat\"}")
    expect s!"project_view refuses the project {bad}" (r.contains "project must be one of LeanFM")
  let extra ← pvCall "{\"stage\":\"chat\",\"message\":\"hello\"}"
  expect "project_view takes no message argument" (extra.contains "message is not one of them")
  let lchat ← pvCall "{\"stage\":\"chat\"}"
  expect "project_view chat for LeanFM says where the conversation happens" (lchat.contains "happens in the agent" && lchat.contains "\"found\":false")
  -- decoding a saved log needs no conversation on disk: a fixture line, its key redacted, a bad line dropped
  let fixture := LeanFM.ProjectView.chatMessages #["m1|user|bGV0J3MgYnVpbGQgYSBnbyBzZXJ2ZXIuIG15IGtleSBpcyBzay1hYmNkZWZnaGlqa2xtbm9wcXJzdHV2d3g=|0|0|0|0|0|1700000000000|model-x", "not a log line"]
  expect "project_view decodes a saved conversation line and redacts its key"
    (fixture.size == 1 && (fixture[0]!.getObjValAs? String "role").toOption == some "user" &&
     ((fixture[0]!.getObjValAs? String "text").toOption.getD "").startsWith "let's build a go server" &&
     !((fixture[0]!.getObjValAs? String "text").toOption.getD "").contains "sk-abcdefghijklmnopqrstuvwx")
  -- conversations are never committed: GoServer's chat decodes its log when this checkout has one,
  -- and otherwise says where the conversation lives (a fresh checkout, such as CI's, has none)
  let gchat ← pvCall "{\"project\":\"GoServer\",\"stage\":\"chat\"}"
  let saved ← System.FilePath.pathExists "projects/GoServer/conversations/main.log"
  expect "project_view chat for GoServer decodes its saved log, or says where it lives without one"
    (if saved then gchat.contains "\"role\":\"user\"" && gchat.contains "\"found\":true"
     else gchat.contains "\"found\":false" && gchat.contains "conversations/main.log")
  expect "project_view decodes base64 both ways" (String.fromUTF8! (LeanFM.ProjectView.base64Decode (LeanFM.ProjectView.base64Encode "key=sk-ABC é".toUTF8)) == "key=sk-ABC é")
  let lbook ← pvCall "{\"stage\":\"book\",\"page\":3}"
  expect "project_view book returns a page image of at most 48000 bytes and the page count"
    ((lbook.contains "\"mimeType\":\"image/png\"" || lbook.contains "\"mimeType\":\"image/jpeg\"") && lbook.contains "\"data\":\"" &&
      lbook.contains "\"page\":3" && lbook.contains "\"pages\":" && lbook.length < LeanFM.ProjectView.maxAnswerChars)
  let lbook2 ← pvCall "{\"stage\":\"book\",\"page\":3}"
  expect "project_view book answers a page again from its cache, without a render" (lbook2.contains "\"cached\":true")
  let slow ← LeanFM.ProjectView.runBounded "sleep" #["5"] 300
  expect "a render that outlives its limit is killed and refused" (match slow with | .error e => e.contains "ran longer" | .ok _ => false)
  -- every stage and section answers under the bound, for LeanFM and for GoServer
  for proj in ["LeanFM", "GoServer"] do
    for args in ["\"stage\":\"chat\"", "\"stage\":\"requirements\"", "\"stage\":\"code\"", "\"stage\":\"book\"",
        "\"stage\":\"requirements\",\"section\":\"tasks\"", "\"stage\":\"requirements\",\"section\":\"clauses\"",
        "\"stage\":\"requirements\",\"section\":\"protocols\""] do
      let r ← pvCall ("{\"project\":\"" ++ proj ++ "\"," ++ args ++ "}")
      expect s!"project_view {proj} \{{args}} answers under {LeanFM.ProjectView.maxAnswerChars} characters"
        (r.length < LeanFM.ProjectView.maxAnswerChars + 200 && !r.contains "\"error\"")
  let big := Json.mkObj [("text", Json.str ("".pushn 'x' 80000))]
  expect "an answer built over the bound is refused, naming it"
    (match LeanFM.ProjectView.bounded "t" "" big with | .error e => e.contains "70000-character bound" | .ok _ => false)
  expect "an item over 8000 characters is cut and marked"
    (let c := LeanFM.ProjectView.fitItem big; c.compress.length < 8100 && c.getObjValD "cut" == Json.bool true)
  let lreq ← pvCall "{\"stage\":\"requirements\"}"
  expect "project_view requirements for LeanFM lists its sections with counts"
    (lreq.contains "\"sections\"" && lreq.contains "\"name\":\"tasks\"" && lreq.contains "\"name\":\"clauses\"" && lreq.contains "\"name\":\"protocols\"" && !lreq.contains "selfhost_workflow")
  let ltasks ← pvCall "{\"stage\":\"requirements\",\"section\":\"tasks\"}"
  expect "project_view's tasks page carries the workflow task" (ltasks.contains "selfhost_workflow" && ltasks.contains "\"transitions\":")
  let lprops ← pvCall "{\"stage\":\"requirements\",\"section\":\"properties\",\"task\":\"selfhost_workflow\"}"
  expect "the workflow's properties page has its CTL formulas and a never proof" (lprops.contains "AF (" && lprops.contains "AG ¬(" && lprops.contains "\"mode\":\"never\"")
  -- a task with where_ constraints, found from the tasks page
  let tasksJson := ((((← IO.ofExcept (Json.parse ltasks)).getObjValD "result").getObjValD "structuredContent").getObjValD "page").getObjValD "items"
  let withWhere := ((tasksJson.getArr?).toOption.getD #[]).find? fun t => ((t.getObjValAs? Nat "constraints").toOption.getD 0) > 0
  match withWhere.bind (fun t => (t.getObjValAs? String "id").toOption) with
  | some id =>
    let lwhere ← pvCall ("{\"stage\":\"requirements\",\"section\":\"constraints\",\"task\":\"" ++ id ++ "\"}")
    expect s!"the constraints page of {id} has where_ constraints" (lwhere.contains "\"origin\":\"where_\"")
  | none => throw <| IO.userError "no LeanFM task has where_ constraints"
  -- the clauses, page by page through next, reach the navigator clause
  let mut found := false
  let mut off : Option Nat := some 0
  let mut pages := 0
  while off.isSome && pages < 10 && !found do
    let r ← pvCall ("{\"stage\":\"requirements\",\"section\":\"clauses\",\"offset\":" ++ toString off.get! ++ "}")
    found := r.contains "selfhost.mcp.session.navigator"
    off := (((((← IO.ofExcept (Json.parse r)).getObjValD "result").getObjValD "structuredContent").getObjValD "page").getObjValAs? Nat "next").toOption
    pages := pages + 1
  expect s!"the clauses pages reach the navigator clause through next ({pages} pages)" (found && pages > 1)
  -- the requirement and implementation lists (selfhost.requirements.list, .map, selfhost.implementations.map)
  let overview := (((← IO.ofExcept (Json.parse lreq)).getObjValD "result").getObjValD "structuredContent").getObjValD "sections"
  let sec (n : String) := ((overview.getArr?).toOption.getD #[]).find? fun x => (x.getObjValAs? String "name").toOption == some n
  -- a clause an entry of LeanFM's map formalizes (its short name is the clause id) is not a sorry row
  let formalized := 9
  let nClauses := LeanFM.LLMGenerated.SelfHosting.clauses.length - formalized
  let num (j : Option Json) (k : String) : Nat := ((j.map (·.getObjValAs? Nat k |>.toOption)).join).getD 999999
  let rq := sec "requirements"
  let kinds := (rq.map (·.getObjValD "kinds"))
  -- the formulas are counted from LeanFM.leanfm's requirements block, so adding one needs no new number here
  let nFormulas := (((← IO.FS.readFile "LeanFM/LLMGenerated/LeanFM.leanfm").splitOn "requirements {").getLast!.splitOn "⊨").length - 1
  expect s!"the overview counts LeanFM's requirements: 1 protocol, {nFormulas} formulas (its requirements block), the clauses and eight entries Lean theorems answer as sorry, all {nFormulas + 1} met, none failing"
    (num kinds "protocol" == 1 && num kinds "formula" == nFormulas && num kinds "sorry" == nClauses + 8 && num rq "met" == nFormulas + 1 && num rq "failing" == 0)
  let im := sec "implementations"
  let leanImpl := (((im.map (·.getObjValD "implementations")).map (·.getArr?.toOption.getD #[])).getD #[]).find? fun x =>
    (x.getObjValAs? String "impl").toOption == some "Lean"
  let st := leanImpl.map (·.getObjValD "status")
  expect "the overview lists implementation Lean: all 17 proved, nine by real runs and eight by Lean theorems, none sorry, none failing, 3 hints"
    (num st "proved" == 17 && num st "tested" == 0 && num st "sorry" == 0 && num st "failing" == 0 && num leanImpl "hints" == 3)
  let itemsOf (r : String) : IO (Array Json) := do
    pure ((((((← IO.ofExcept (Json.parse r)).getObjValD "result").getObjValD "structuredContent").getObjValD "page").getObjValD "items").getArr?.toOption.getD #[])
  let ritems ← itemsOf (← pvCall "{\"stage\":\"requirements\",\"section\":\"requirements\"}")
  let field (it : Json) (k : String) := (it.getObjValAs? String k).toOption.getD ""
  let isTrue (it : Json) (k : String) := it.getObjValD k == Json.bool true
  expect "section requirements opens the protocol in the explorer, met, with its faithful rules"
    (ritems.any fun it => field it "kind" == "protocol" && field it "viewer" == "explore" && isTrue it "met" &&
      field it "file" == "LeanFM/LLMGenerated/LeanFM.leanfm" && ((it.getObjValD "ctl").getObjValAs? Nat "ruleCount").toOption.getD 0 > 1)
  expect "every formula opens in the CTL view, proved and met, its CTL the formula"
    ((ritems.filter (field · "kind" == "formula")).size == nFormulas && (ritems.filter (field · "kind" == "formula")).all fun it =>
      field it "viewer" == "ctl" && field it "verdict" == "proved" && isTrue it "met" && (it.getObjValD "ctl").compress.contains (field it "formula"))
  expect "a formalized clause is listed by its entry, not as a sorry row"
    (!(ritems.any fun it => field it "id" == "selfhost.session.event-log" && field it "kind" == "sorry") &&
     ritems.any fun it => field it "formalizes" == "selfhost.session.event-log" && field it "short" == "selfhost.session.event_log")
  expect "the clauses are sorry: never met, never failing, shown as text"
    (ritems.any fun it => field it "id" == "selfhost.revision" && field it "kind" == "sorry" && isTrue it "sorry" &&
      !isTrue it "met" && !isTrue it "failing" && field it "viewer" == "text")
  let iitems ← itemsOf (← pvCall "{\"stage\":\"requirements\",\"section\":\"implementations\"}")
  expect "section implementations: a conforming run that meets the McpCall formula stands proved; no bare test or sorry remains"
    (iitems.any (fun it => field it "kind" == "conform" && field it "status" == "proved" && field it "verdict" == "tested") &&
     iitems.all (fun it => field it "kind" != "test") &&
     iitems.all (fun it => field it "kind" != "sorry"))
  expect "the implementation's own CTL is proved, and its hints convert to true"
    (iitems.any (fun it => field it "id" == "Every read of the project root is answered" && field it "verdict" == "proved" && isTrue it "met") &&
     (iitems.filter (field · "kind" == "hint")).size == 3 && (iitems.filter (field · "kind" == "hint")).all (field · "verdict" == "true"))
  -- failing entries, through checkRow on rows the files do not carry
  let lean ← LeanFM.ProjectView.projects
  match lean.find? (·.isLeanFM) with
  | some p =>
    let (protos, _) ← LeanFM.ProjectView.protocolFiles p
    let (files, _) ← LeanFM.ProjectView.readMapFiles p protos
    let implRow (extra : List (String × Json)) : Json := Json.mkObj ([("list", Json.str "implementations"), ("impl", Json.str "Lean"),
      ("file", Json.str "LeanFM/LLMGenerated/LeanFMImplementation.leanfm"), ("of", Json.str "LeanFM.LLMGenerated.LeanFM")] ++ extra)
    let chk (r : Json) := LeanFM.ProjectView.checkRow p protos files r
    let failing (r : Json) : IO Bool := do pure ((← chk r).getObjValD "failing" == Json.bool true)
    expect "a disproved formula of the implementation's own is failing"
      (← failing (implRow [("id", Json.str "x"), ("kind", Json.str "formula"), ("name", Json.str "LeanFMMcp"), ("formula", Json.str "(always (not (on Page)))")]))
    expect "a refinement that breaks a requirement is failing"
      (← failing (implRow [("id", Json.str "refines"), ("kind", Json.str "refines"), ("from", Json.str "LeanFMMcp"), ("by", Json.str "Nope")]))
    expect "evidence for a key the imported map does not have is failing"
      (← failing (implRow [("id", Json.str "not a requirement"), ("kind", Json.str "test"), ("test", Json.str "t")]))
    expect "own CTL for an imported requirement is failing (it needs evidence)"
      (← failing (implRow [("id", Json.str "The session can always end"), ("kind", Json.str "formula"), ("name", Json.str "LeanFMMcp"), ("formula", Json.str "(always (possibly stop))")]))
    expect "an implementation of its own file is failing"
      (← failing ((implRow [("id", Json.str "h"), ("kind", Json.str "hint"), ("text", Json.str "x")]).setObjVal! "of" (Json.str "LeanFM.LLMGenerated.LeanFMImplementation")))
    expect "an implementation of an unlisted file is failing"
      (← failing ((implRow [("id", Json.str "h"), ("kind", Json.str "hint"), ("text", Json.str "x")]).setObjVal! "of" (Json.str "Etc.Passwd")))
    for log in ["/etc/passwd", "../x.json", "no/such/log.json"] do
      expect s!"a conform log {log} outside the root or missing is failing"
        (← failing (implRow [("id", Json.str "The MCP conversation follows LeanFMMcp"), ("kind", Json.str "conform"), ("log", Json.str log)]))
    -- LeanFM's lists come from its specification directory; the orders example is checked on its own
    expect "an example outside LeanFM/LLMGenerated is not one of LeanFM's requirements"
      (!(ritems.any fun it => (field it "file").startsWith "examples/") && (LeanFM.ProjectView.specProtocols p protos).all (·.startsWith "LeanFM/LLMGenerated/"))
    let ex := protos.filter (["examples/orders/Requirements.leanfm", "examples/orders/Implementation.leanfm"].contains ·)
    let (_, exImpls) ← LeanFM.ProjectView.listSummariesOf p ex (withClauses := false)
    let go := ((exImpls.getObjValD "implementations").getArr?.toOption.getD #[])[0]?.getD Json.null
    let gst := go.getObjValD "status"
    let gn (k : String) := (gst.getObjValAs? Nat k).toOption.getD 99
    expect "the orders example: implementation Go has 2 proved (by conforming runs), 4 sorry (a bare test among them), none failing, its refinement kept"
      (ex.size == 2 && gn "proved" == 2 && gn "tested" == 0 && gn "sorry" == 4 && gn "failing" == 0 && (exImpls.getObjValAs? Nat "failing").toOption == some 0)
    for f in ["/etc/passwd.leanfm", "LeanFM/../../x.leanfm", "LeanFM/LLMGenerated/SelfHosting.lean", "not/listed.leanfm"] do
      let r ← LeanFM.ProjectView.readProtocolText p protos f
      expect s!"an entry's file {f} outside the listing is never read" (match r with | .error _ => true | .ok _ => false)
  | none => throw <| IO.userError "no LeanFM project"
  let noTask ← pvCall "{\"stage\":\"requirements\",\"section\":\"transitions\"}"
  expect "a task's section without task is refused" (noTask.contains "needs task")
  let badTask ← pvCall "{\"stage\":\"requirements\",\"section\":\"transitions\",\"task\":\"nope\"}"
  expect "an unknown task is refused" (badTask.contains "task must be the id of one of")
  let greq ← pvCall "{\"project\":\"GoServer\",\"stage\":\"requirements\",\"section\":\"protocols\"}"
  expect "project_view requirements for GoServer reads spec/tasks.json and lists its protocol" (greq.contains "spec/tasks.json" && greq.contains "goserver.leanfm")
  let lcode ← pvCall "{\"stage\":\"code\"}"
  expect "project_view code for LeanFM pages its files and names the navigator mapping"
    (lcode.contains "\"next\":100" && lcode.contains "\"name\":\"session-navigator\"" && lcode.contains "clause:selfhost.mcp.session.navigator")
  expect "project_view code for LeanFM leaves the other projects out" (!lcode.contains "\"path\":\"projects/")
  let lfile ← pvCall "{\"stage\":\"code\",\"file\":\"LeanFM/SessionView.html\"}"
  expect "a large file's text comes a page at a time with its mappings"
    (lfile.contains "\"next\":40000" && lfile.contains "\"selected\"" && lfile.contains "\"tests\":" && lfile.length < LeanFM.ProjectView.maxAnswerChars)
  for bad in ["../../etc/passwd", "/etc/passwd", "projects/GoServer/source/server.go", "LeanFM/../../etc/passwd"] do
    let r ← pvCall ("{\"stage\":\"code\",\"file\":\"" ++ bad ++ "\"}")
    expect s!"project_view code refuses the file {bad}" (r.contains "file must be one of" && !r.contains "root:")
  let badProto ← pvCall "{\"stage\":\"requirements\",\"file\":\"Makefile\"}"
  expect "project_view requirements refuses a file that is not a listed protocol" (badProto.contains "file must be one of")
  let gfile ← pvCall "{\"project\":\"GoServer\",\"stage\":\"code\",\"file\":\"source/server.go\"}"
  expect "project_view code for GoServer shows a file with its traceability" (gfile.contains "\"selected\"" && gfile.contains "grammar:create_room")
  -- several implementations of one specification (clause selfhost.project.implementations)
  let mlist ← pvCall "{\"project\":\"Maqam\"}"
  expect "project_view lists Maqam's implementations and its default in every answer"
    (mlist.contains "\"implementations\":[\"rust\",\"zig\"]" && mlist.contains "\"defaultImplementation\":\"zig\"")
  let mzig ← pvCall "{\"project\":\"Maqam\",\"stage\":\"code\"}"
  expect "project_view code for Maqam shows the default implementation's source, its mapping and its check"
    (mzig.contains "\"implementation\":\"zig\"" && mzig.contains "impl/zig/source/README.md" && !mzig.contains "impl/rust/" &&
      mzig.contains "\"mapping\":\"impl/zig/Implementation.lean\"" && mzig.contains "\"check\":{")
  let mrust ← pvCall "{\"project\":\"Maqam\",\"stage\":\"code\",\"impl\":\"rust\"}"
  expect "project_view code with impl rust shows only the Rust source"
    (mrust.contains "\"implementation\":\"rust\"" && mrust.contains "\"root\":\"impl/rust/source\"" && mrust.contains "impl/rust/source/src/audio.rs" && !mrust.contains "impl/zig/")
  let crossed ← pvCall "{\"project\":\"Maqam\",\"stage\":\"code\",\"impl\":\"zig\",\"file\":\"impl/rust/source/src/audio.rs\"}"
  expect "project_view code refuses another implementation's file" (crossed.contains "file must be one of")
  let mspec ← pvCall "{\"project\":\"Maqam\",\"stage\":\"requirements\"}"
  expect "the spec overview names Maqam's specification files and protocols directly"
    (mspec.contains "\"files\":[\"spec/Requirements.lean\",\"spec/Requirements.proto\"]" && mspec.contains "spec/Maqam.leanfm")
  expect "the spec overview names Maqam's primary protocol, which the spec stage opens in the explorer"
    (mspec.contains "\"primary\":\"spec/Maqam.leanfm\"")
  let lspec ← pvCall "{\"stage\":\"requirements\"}"
  expect "LeanFM's spec overview names LeanFM.leanfm as its primary protocol"
    (lspec.contains "\"primary\":\"LeanFM/LLMGenerated/LeanFM.leanfm\"")
  let pspec ← pvCall "{\"project\":\"PaxosKV\",\"stage\":\"requirements\"}"
  expect "PaxosKV's spec overview names its protocol file under spec/ as its primary protocol"
    (pspec.contains "\"primary\":\"spec/PaxosKV.leanfm\"")
  -- every project now has protocol files, so the rule for none is checked on the function itself
  let some paxos := (← LeanFM.ProjectView.projects).find? (·.name == "PaxosKV")
    | throw (IO.userError "PaxosKV is not listed")
  expect "a project without protocol files names no primary protocol, so its spec stage opens on the index"
    (LeanFM.ProjectView.primaryProtocol paxos #[] == none)
  let mbook ← pvCall "{\"project\":\"Maqam\",\"stage\":\"book\"}"
  expect "a project's written book is found" (mbook.contains "\"found\":true" && mbook.contains "\"file\":\"book/main-dark.pdf\"")
  -- every project in the checkout has a book now, so the unwritten case is a temporary empty root
  let tmp : System.FilePath := s!"/tmp/leanfm-unwritten-book-{← IO.monoNanosNow}"
  IO.FS.createDirAll tmp
  let unwritten ← LeanFM.ProjectView.book { name := "Unwritten", root := tmp, real := tmp, manifest := Json.mkObj [], isLeanFM := false } 1 true
  IO.FS.removeDirAll tmp
  let ub := match unwritten with | .ok j => j.compress | .error e => e
  expect "a book whose PDF and source are both missing says it has not been written, not that it needs building"
    (ub.contains "\"found\":false" && ub.contains "\"written\":false" && ub.contains "has not been written" && !ub.contains "make book")
  let mreq ← pvCall "{\"project\":\"Maqam\",\"stage\":\"requirements\",\"file\":\"spec/Requirements.lean\"}"
  expect "the spec stage shows Requirements.lean's text a page at a time" (mreq.contains "\"selected\"" && mreq.contains "Observable hooks every implementation provides")
  let mimpl ← pvCall "{\"project\":\"Maqam\",\"stage\":\"impl\",\"impl\":\"zig\"}"
  expect "the impl stage shows the picked implementation's mapping and its check, with every error it found"
    (mimpl.contains "\"file\":\"impl/zig/Implementation.lean\"" && mimpl.contains "\"errorList\":[]" && mimpl.contains "\"status\":\"validated\"")
  let mimplR ← pvCall "{\"project\":\"Maqam\",\"stage\":\"impl\",\"impl\":\"rust\"}"
  expect "the impl stage switches to another implementation" (mimplR.contains "\"file\":\"impl/rust/Implementation.lean\"" && mimplR.contains "\"status\":\"validated\"")
  let mimplD ← pvCall "{\"project\":\"Maqam\",\"stage\":\"impl\"}"
  expect "the impl stage defaults to the default implementation" (mimplD.contains "\"file\":\"impl/zig/Implementation.lean\"")
  let badSpec ← pvCall "{\"project\":\"Maqam\",\"stage\":\"requirements\",\"file\":\"impl/rust/source/src/audio.rs\"}"
  expect "the spec stage refuses a file that is neither a spec file nor a protocol" (badSpec.contains "file must be one of")
  let unknownImpl ← pvCall "{\"project\":\"Maqam\",\"stage\":\"code\",\"impl\":\"cobol\"}"
  expect "project_view refuses an implementation the manifest does not list" (unknownImpl.contains "impl must be one of rust, zig")
  let noImpls ← pvCall "{\"project\":\"GoServer\",\"stage\":\"code\",\"impl\":\"rust\"}"
  expect "project_view refuses impl for a project that lists no implementations" (noImpls.contains "lists no implementations")
  -- a symlink out of a project root is never read
  IO.FS.createDirAll ".cache/tests/pvroot"
  let link : System.FilePath := ".cache/tests/pvroot/escape"
  if ← link.pathExists then IO.FS.removeFile link
  discard <| IO.Process.output { cmd := "ln", args := #["-s", "/etc", link.toString] }
  let tp : LeanFM.ProjectView.Project := { name := "t", root := ".cache/tests/pvroot", real := ← IO.FS.realPath ".cache/tests/pvroot", manifest := Json.mkObj [], isLeanFM := false }
  expect "project_view refuses a symlink out of the project root" ((← LeanFM.ProjectView.inside tp "escape/hostname").isNone && (← LeanFM.ProjectView.inside tp "escape").isNone)
  let (walked, _) ← LeanFM.ProjectView.walk tp "" ["conf", ""]
  expect "project_view never lists files through a symlink out of the root" walked.isEmpty

set_option maxRecDepth 4096 in
def main : IO Unit := do
  let initialized ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}"
  assertContains "MCP initialization supplies durable book instructions" initialized.body "durable agent context"
  assertContains "MCP negotiates a protocol version" initialized.body "2025-06-18"
  let listed ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"resources/list\",\"params\":{}}"
  assertContains "MCP lists the central book" listed.body "leanfm://project/book/main.pdf"
  assertContains "MCP lists canonical requirements" listed.body "Requirements.lean"
  let book ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"resources/read\",\"params\":{\"uri\":\"leanfm://project/book/main.pdf\"}}"
  let .ok json := Json.parse book.body | throw (IO.userError "MCP PDF reply is not JSON")
  let .ok result := json.getObjVal? "result" | throw (IO.userError "MCP PDF resource failed")
  let .ok contents := (result.getObjVal? "contents").bind Json.getArr? | throw (IO.userError "MCP PDF contents missing")
  let some item := contents[0]? | throw (IO.userError "MCP PDF contents empty")
  let .ok blob := (item.getObjVal? "blob").bind Json.getStr? | throw (IO.userError "MCP PDF blob missing")
  let bytes ← IO.FS.readBinFile "book/main.pdf"
  if blob.length != ((bytes.size + 2) / 3) * 4 || !blob.startsWith "JVBER" then
    throw (IO.userError "MCP PDF encoding is incomplete")
  IO.println "ok: MCP reads the complete central PDF without overflowing the stack"
  let called ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"validate_generated_artifacts\",\"arguments\":{}}}"
  assertContains "MCP validation tool returns checked reports" called.body "generated implementation plan"
  let unknown ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"no/such/method\"}"
  assertContains "MCP rejects unknown methods" unknown.body "-32601"
  let toolsListed ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/list\"}"
  assertContains "MCP lists check_ctl with an input schema" toolsListed.body "\"name\":\"check_ctl\""
  assertContains "MCP logic tools require their arguments" toolsListed.body "\"required\":[\"task\",\"formula\"]"
  let reference ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"resources/read\",\"params\":{\"uri\":\"leanfm://language/logic-reference\"}}"
  assertContains "MCP serves the logic reference" reference.body "Terminal convention"
  let ctl ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"tools/call\",\"params\":{\"name\":\"check_ctl\",\"arguments\":{\"task\":\"mcp_logic_consult\",\"formula\":{\"never\":{\"on\":\"LogicInputRejected\"}}}}}"
  assertContains "MCP check_ctl passes arguments and returns a verdict" ctl.body "\"verdict\":\"disproved\""
  assertContains "MCP check_ctl returns a counterexample" ctl.body "\"kind\":\"counterexample\""
  let bad ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{\"name\":\"check_ctl\",\"arguments\":{\"task\":\"mcp_logic_consult\",\"formula\":{\"G\":\"stop\"}}}}"
  assertContains "MCP rejects malformed logic as a tool error" bad.body "\"isError\":true"
  assertContains "MCP rejection names the typing error" bad.body "always (AG, on every path)"
  let known ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"tools/call\",\"params\":{\"name\":\"knows\",\"arguments\":{\"actor\":\"Ivo\",\"at\":\"e1\",\"initial\":[{\"sk\":\"I\"}],\"query\":{\"atom\":\"nb\"},\"events\":[{\"id\":\"e1\",\"src\":\"Alice\",\"dst\":\"Ivo\",\"term\":{\"enc\":{\"key\":{\"pk\":\"I\"},\"body\":{\"atom\":\"nb\"}}}}]}}}"
  assertContains "MCP knows decides a query" known.body "\"verdict\":\"proved\""
  assertContains "MCP knows returns the derivation" known.body "\"kind\":\"derivation\""
  assertContains "MCP lists check_protocol" toolsListed.body "\"name\":\"check_protocol\""
  assertContains "MCP lists check_reassembly" toolsListed.body "\"name\":\"check_reassembly\""
  assertContains "MCP lists check_signal" toolsListed.body "\"name\":\"check_signal\""
  let sig ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":13,\"method\":\"tools/call\",\"params\":{\"name\":\"check_signal\",\"arguments\":{\"claim\":\"(always (below temp 26))\",\"samples\":[{\"t\":0,\"temp\":20},{\"t\":600,\"temp\":27.1}]}}}"
  assertContains "MCP check_signal answers a verdict" sig.body "\"verdict\":\"fails\""
  assertContains "MCP check_signal answers the margin" sig.body "\"margin\":-1.1"
  let sigLog ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":14,\"method\":\"tools/call\",\"params\":{\"name\":\"check_signal\",\"arguments\":{\"claim\":\"(always (below temp 26))\",\"serverLog\":\"devices\"}}}"
  assertContains "MCP check_signal refuses serverLog where server_logs is not served" sigLog.body "\"isError\":true"
  let bye ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":16,\"method\":\"leanfm/bye\",\"params\":{}}"
  assertContains "MCP answers leanfm/bye, the end of a host's conversation, with an empty result" bye.body "\"result\":{}"
  assertContains "MCP lists reduce_run" toolsListed.body "\"name\":\"reduce_run\""
  let red ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":15,\"method\":\"tools/call\",\"params\":{\"name\":\"reduce_run\",\"arguments\":{\"program\":\"(/ (count (events \\\"Refund\\\")) (count (events)))\",\"events\":[{\"label\":\"Order\"},{\"label\":\"Order\"},{\"label\":\"Refund\"}]}}}"
  assertContains "MCP reduce_run answers an exact value" red.body "\"exact\":\"1/3\""
  assertContains "MCP reduce_run reports its ticks" red.body "\"tickBudget\":1000000"
  let reasm ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"tools/call\",\"params\":{\"name\":\"check_reassembly\",\"arguments\":{\"signature\":\"AB\"}}}"
  assertContains "MCP check_reassembly finds an evasion with defaults" reasm.body "\"verdict\":\"disproved\""
  assertContains "MCP check_reassembly lists the segments" reasm.body "{\"data\":\"AB\",\"offset\":\"0\"}"
  let proto ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"tools/call\",\"params\":{\"name\":\"check_protocol\",\"arguments\":{\"roles\":[{\"name\":\"Alice\",\"steps\":[{\"send\":{\"to\":{\"atom\":\"Bob\"},\"message\":{\"atom\":\"pin_secr\"}}}]}],\"attacker\":{\"name\":\"Ivo\"},\"formula\":{\"never\":{\"knows\":{\"actor\":\"Ivo\",\"term\":{\"atom\":\"pin_secr\"}}}}}}}"
  assertContains "MCP check_protocol finds a plaintext leak" proto.body "\"verdict\":\"disproved\""
  -- a knows atom asks about a marked secret only: the same question about an unmarked atom is refused
  let unmarked ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"tools/call\",\"params\":{\"name\":\"check_protocol\",\"arguments\":{\"roles\":[{\"name\":\"Alice\",\"steps\":[{\"send\":{\"to\":{\"atom\":\"Bob\"},\"message\":{\"atom\":\"pin\"}}}]}],\"attacker\":{\"name\":\"Ivo\"},\"formula\":{\"never\":{\"knows\":{\"actor\":\"Ivo\",\"term\":{\"atom\":\"pin\"}}}}}}}"
  assertContains "MCP check_protocol refuses a knows question about an unmarked term" unmarked.body "pin, which is not marked secret"
  assertContains "MCP check_protocol shows the send to its addressee, via the attacker" proto.body "{\"event\":\"send\",\"from\":\"Alice\",\"term\":\"pin_secr\",\"to\":\"Bob\",\"via\":\"Ivo\"}"
  -- The answer appears once, as structuredContent; the text block is a one-line summary, not a copy.
  let summaryOf (label body : String) : IO String := do
    let json ← IO.ofExcept (Json.parse body)
    let block ← IO.ofExcept ((json.getObjValD "result").getObjValD "content" |>.getArrVal? 0)
    let text ← IO.ofExcept (block.getObjValAs? String "text")
    let structured := json.getObjValD "result" |>.getObjValD "structuredContent"
    if structured.isNull then throw <| IO.userError s!"{label}: no structuredContent"
    if text.contains '\n' || text.contains '{' || text.length > LeanFM.MCP.logicSummaryLimit then
      throw <| IO.userError s!"{label}: text block is not a one-line summary: {text}"
    IO.println s!"ok: {label}"
    return text
  let protoText ← summaryOf "MCP check_protocol text is a summary, not a second copy" proto.body
  assertContains "MCP check_protocol summary gives verdict and reading" protoText "check_protocol disproved: on every path, never Ivo can derive pin_secr"
  let badText ← summaryOf "MCP rejection text is a summary" bad.body
  assertContains "MCP rejection summary gives the reason" badText "rejected: "
  let ctlText ← summaryOf "MCP check_ctl text is a summary" ctl.body
  assertContains "MCP check_ctl summary gives the verdict" ctlText "check_ctl disproved"
  -- The MCP Apps view (clause selfhost.mcp.logic.view).
  let toolsJson ← IO.ofExcept (Json.parse toolsListed.body)
  let listedTools ← IO.ofExcept ((toolsJson.getObjValD "result").getObjValD "tools" |>.getArr?)
  for t in listedTools do
    let name ← IO.ofExcept (t.getObjValAs? String "name")
    let uri := ((t.getObjValD "_meta").getObjValD "ui").getObjValAs? String "resourceUri" |>.toOption
    let expected := if logicViewTools.contains name then some logicViewUri
      else if sessionViewTools.contains name then some sessionViewUri else none
    if uri != expected then throw <| IO.userError s!"MCP view: {name} declares {uri}, not {expected}"
  IO.println "ok: MCP views are declared on exactly the tools they draw"
  assertContains "MCP lists the view resource" listed.body logicViewUri
  assertContains "MCP lists the view with the MCP Apps MIME type" listed.body "\"mimeType\":\"text/html;profile=mcp-app\""
  let view ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":20,\"method\":\"resources/read\",\"params\":{\"uri\":\"ui://leanfm/logic-view\"}}"
  let viewJson ← IO.ofExcept (Json.parse view.body)
  let viewItem ← IO.ofExcept ((viewJson.getObjValD "result").getObjValD "contents" |>.getArrVal? 0)
  let html ← IO.ofExcept (viewItem.getObjValAs? String "text")
  if html != logicViewHtml then throw <| IO.userError "MCP view: resources/read does not return the compiled view"
  let mime ← IO.ofExcept (viewItem.getObjValAs? String "mimeType")
  if mime != logicViewMimeType then throw <| IO.userError s!"MCP view: wrong MIME type {mime}"
  let csp := ((viewItem.getObjValD "_meta").getObjValD "ui").getObjValD "csp"
  for key in ["connectDomains", "resourceDomains", "frameDomains", "baseUriDomains"] do
    if csp.getObjValD key != Json.arr #[] then throw <| IO.userError s!"MCP view: {key} is not empty"
  IO.println "ok: MCP reads the view with its MIME type and no CSP domains"
  -- Negative requirements: no network, no data as HTML or code, no paths.
  let withoutNamespace := html.replace "http://www.w3.org/2000/svg" ""
  for needle in ["http://", "https://", "src=", "href=", "fetch(", "XMLHttpRequest", "WebSocket", "EventSource",
      "import(", "innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "eval(", "new Function",
      "/home/", "/Users/", "leanfm://"] do
    if withoutNamespace.contains needle then throw <| IO.userError s!"MCP view: forbidden text {needle}"
  IO.println "ok: MCP view has no network access, no HTML or code from data, and no paths"
  assertContains "MCP view speaks the MCP Apps handshake" html "\"ui/initialize\""
  assertContains "MCP view announces it is ready" html "\"ui/notifications/initialized\""
  assertContains "MCP view renders tool results" html "\"ui/notifications/tool-result\""
  assertContains "MCP view reports its size" html "\"ui/notifications/size-changed\""
  assertContains "MCP view bounds the drawing" html "MAX_STEPS = 64, MAX_ITEMS = 256"
  let unknownUi ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":21,\"method\":\"resources/read\",\"params\":{\"uri\":\"ui://leanfm/other\"}}"
  assertContains "MCP rejects an undeclared ui:// URI" unknownUi.body "unknown resource URI"
  -- Hosts without the extension still get one summary line and the structured answer.
  let protoAgain ← summaryOf "MCP check_protocol result is unchanged by the view" proto.body
  assertContains "MCP check_protocol summary is unchanged" protoAgain "check_protocol disproved"
  -- The session tools and their view (clauses selfhost.mcp.session.tools and .view).
  for t in ["session_check", "session_diagram", "session_mdp", "session_sla", "session_simulate", "session_conform", "session_spans", "session_skeleton", "session_next", "session_compat", "session_ctl", "session_instances", "session_openapi", "session_types", "session_review", "session_actor", "session_dataset", "session_explore", "session_deployment"] do
    assertContains s!"MCP lists {t}" toolsListed.body s!"\"name\":\"{t}\""
  assertContains "MCP instructions point to the session tools" initialized.body "session_check"
  assertContains "MCP instructions require features with strong implication" initialized.body "Require features with strong implication"
  assertContains "MCP instructions require security guarantees with weak implication" initialized.body "security guarantees with weak implication, (weaklyImplies a b)"
  assertContains "MCP lists the session reference" listed.body "leanfm://language/session-reference"
  let sref ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":30,\"method\":\"resources/read\",\"params\":{\"uri\":\"leanfm://language/session-reference\"}}"
  assertContains "MCP serves the session reference" sref.body "# LeanFM session types"
  let sess ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":31,\"method\":\"tools/call\",\"params\":{\"name\":\"session_check\",\"arguments\":{\"lean\":\"protocol PingPong (A, B) { p: Ping from A to B; Pong from B to A cause p status 200; }\"}}}"
  assertContains "MCP session_check reads Lean protocol text through the dispatch" sess.body "\"verdict\":\"ok\""
  assertContains "MCP session_check echoes the Lean text" sess.body "protocol PingPong (A, B)"
  let sessText ← summaryOf "MCP session_check text is a one-line summary" sess.body
  assertContains "MCP session_check summary gives the reading" sessText "session_check ok: PingPong: no issues"
  -- instances interleaved (clause selfhost.session.instances): two paths taking two serial instances in opposite orders
  let inst ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":33,\"method\":\"tools/call\",\"params\":{\"name\":\"session_instances\",\"arguments\":{\"instances\":1,\"lean\":\"protocol P (C, X, Y) { a: A from C to X; b: B from C to Y cause a; Z from C to X cause a; } protocol Q (C, X, Y) { b: B2 from C to Y; a: A2 from C to X cause b; Z2 from C to Y cause b; } system S { instance x : X serial; instance y : Y serial; accept P (fresh C, x, y); accept Q (fresh C, x, y); }\"}}}"
  assertContains "MCP session_instances finds the deadlock through the dispatch" inst.body "\"verdict\":\"deadlock\""
  let instText ← summaryOf "MCP session_instances text is a one-line summary" inst.body
  assertContains "MCP session_instances summary names the path" instText "deadlock after A@s1 from C/s1 to X/x -> B2@s2 from C/s2 to Y/y"
  let sessBad ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":32,\"method\":\"tools/call\",\"params\":{\"name\":\"session_check\",\"arguments\":{\"protocol\":{\"roles\":[\"A\"],\"steps\":[{\"exec\":\"x\"}]}}}}"
  assertContains "MCP session_check rejects an unknown step as a tool error" sessBad.body "\"isError\":true"
  let skel ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":37,\"method\":\"tools/call\",\"params\":{\"name\":\"session_skeleton\",\"arguments\":{\"lean\":\"protocol PingPong (A, B) { p: Ping from A to B; Pong from B to A cause p; }\"}}}"
  -- unlike the other tools, the text is not a one-line summary: the generated code is the answer
  let skelJson ← IO.ofExcept (Json.parse skel.body)
  let skelText ← IO.ofExcept (((skelJson.getObjValD "result").getObjValD "content" |>.getArrVal? 0) >>= (·.getObjValAs? String "text"))
  assertContains "MCP session_skeleton puts the code in the text a model reads" skelText "```python"
  assertContains "MCP session_skeleton writes each state as a class" skelText "class BS1(State):"
  let compatCall ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":40,\"method\":\"tools/call\",\"params\":{\"name\":\"session_compat\",\"arguments\":{\"lean\":\"protocol P (A, B) { x: Ping from A to B; }\",\"old\":\"protocol P (A, B) { x: Ping from A to B; Pong from B to A cause x; }\"}}}"
  assertContains "MCP session_compat answers per role" compatCall.body "\"verdict\":\"incompatible\""
  assertContains "MCP session_compat says who waits" compatCall.body "A waits to receive Pong from B"
  let reviewCall ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":41,\"method\":\"tools/call\",\"params\":{\"name\":\"session_review\",\"arguments\":{\"lean\":\"protocol P (A, B) { Ask from A to B route \\\"GET /x\\\"; }\"}}}"
  assertContains "MCP session_review puts its findings in the text" reviewCall.body "1. [http] Ask from A to B never gets a response"
  let slaCall ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"tools/call\",\"params\":{\"name\":\"session_sla\",\"arguments\":{\"lean\":\"protocol P (A, B) { q: Ask from A to B; Answer from B to A cause q after 100 ms; }\\nrequire per q { every q reaches Answer within 1 second; }\"}}}"
  assertContains "MCP session_sla answers the design verdict" slaCall.body "session_sla met"
  assertContains "MCP session_sla puts the report in the text" slaCall.body "Requirements against the stated assumptions"
  let checks ← LeanFM.CheckMetrics.checkStats.get
  assertContains "MCP counts session_sla in the check metrics" checks.render "leanfm_check_calls_total{tool=\"session_sla\",verdict=\"met\"} 1"
  assertContains "MCP check metrics time every call" checks.render "leanfm_check_duration_seconds_count{tool=\"session_sla\",verdict=\"met\"} 1"
  let skelTs ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":39,\"method\":\"tools/call\",\"params\":{\"name\":\"session_skeleton\",\"arguments\":{\"lean\":\"protocol PingPong (A, B) { p: Ping from A to B; Pong from B to A cause p; }\",\"language\":\"typescript\"}}}"
  assertContains "MCP session_skeleton writes TypeScript in a typescript fence" skelTs.body "```typescript"
  assertContains "MCP session_skeleton TypeScript states extend State" skelTs.body "export class BS1 extends State"
  let skelBad ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":38,\"method\":\"tools/call\",\"params\":{\"name\":\"session_skeleton\",\"arguments\":{\"lean\":\"protocol PingPong (A, B) { }\",\"language\":\"rust\"}}}"
  assertContains "MCP session_skeleton rejects an unknown language" skelBad.body "language rust is not supported"
  let sim ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":33,\"method\":\"tools/call\",\"params\":{\"name\":\"session_simulate\",\"arguments\":{\"seed\":5,\"instances\":3,\"protocol\":{\"roles\":[\"A\",\"B\"],\"steps\":[{\"msg\":\"Ping\",\"id\":\"p\",\"from\":\"A\",\"to\":\"B\"},{\"msg\":\"Pong\",\"from\":\"B\",\"to\":\"A\",\"cause\":\"p\"}]}}}}"
  assertContains "MCP session_simulate runs concurrent copies" sim.body "6 events from 3 sessions"
  assertContains "MCP lists the session view" listed.body sessionViewUri
  assertContains "the session view's address carries its version" sessionViewUri "ui://leanfm/session-view/"
  let versioned ← dispatch ("{\"jsonrpc\":\"2.0\",\"id\":35,\"method\":\"resources/read\",\"params\":{\"uri\":\"" ++ sessionViewUri ++ "\"}}")
  assertContains "MCP reads the session view at its versioned address" versioned.body "text/html;profile=mcp-app"
  let sview ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":34,\"method\":\"resources/read\",\"params\":{\"uri\":\"ui://leanfm/session-view\"}}"
  let sviewJson ← IO.ofExcept (Json.parse sview.body)
  let sviewItem ← IO.ofExcept ((sviewJson.getObjValD "result").getObjValD "contents" |>.getArrVal? 0)
  let shtml ← IO.ofExcept (sviewItem.getObjValAs? String "text")
  if shtml != sessionViewHtml then throw <| IO.userError "MCP session view: resources/read does not return the compiled view"
  -- the view is larger than the tool-result limit; reading it must still return the whole view
  if compactReply sview.body != sview.body then throw <| IO.userError "MCP session view: resources/read was compacted (the host would get no view)"
  if compactReply sview.body 1000 != sview.body then throw <| IO.userError "MCP session view: a resource read is compacted under a small limit"
  if (sviewItem.getObjValAs? String "mimeType").toOption != some logicViewMimeType then
    throw <| IO.userError "MCP session view: wrong MIME type"
  let scsp := ((sviewItem.getObjValD "_meta").getObjValD "ui").getObjValD "csp"
  for key in ["connectDomains", "resourceDomains", "frameDomains", "baseUriDomains"] do
    if scsp.getObjValD key != Json.arr #[] then throw <| IO.userError s!"MCP session view: {key} is not empty"
  -- Each view's script must parse: a syntax error leaves the view blank in the host, and the
  -- substring checks here cannot see one. Node checks the syntax without running anything.
  let checkScript (label page : String) : IO Unit := do
    let script := match page.splitOn "<script>" with
      | [_, rest] => (rest.splitOn "</script>").headD ""
      | _ => ""
    if script.isEmpty then throw <| IO.userError s!"{label}: no single script element"
    IO.FS.createDirAll ".cache/tests"
    let path := s!".cache/tests/{label.replace " " "-"}.js"
    IO.FS.writeFile path script
    let out ← try IO.Process.output { cmd := "node", args := #["--check", path] }
      catch _ => throw <| IO.userError s!"{label}: node is needed to check the view's script (install Node.js)"
    if out.exitCode != 0 then throw <| IO.userError s!"{label}: the script does not parse:\n{out.stderr}"
    IO.println s!"ok: {label} script parses"
  checkScript "logic view" html
  checkScript "session view" shtml
  -- ...and must run: the view is driven in Node (scripts/session_view_smoke.js, a stub DOM and host)
  -- with real results for the lending example, through the editor, the walk-through, the
  -- animation and every session tool's result. Any exception fails.
  assertContains "MCP exposes external probability layers" toolsListed.body "\"overlay\""
  assertContains "MCP exposes observation horizons" toolsListed.body "\"horizonMs\""
  let lendingLean ← IO.FS.readFile "examples/vibecode/lending/Lending.protocol"
  let bugLog ← IO.ofExcept (Json.parse (← IO.FS.readFile "examples/vibecode/lending/bug-log.json"))
  let callTool (name : String) (args : List (String × Json)) : IO Json := do
    let req := Json.mkObj [("jsonrpc", "2.0"), ("id", 90), ("method", "tools/call"),
      ("params", Json.mkObj [("name", Json.str name), ("arguments", Json.mkObj (("lean", Json.str lendingLean) :: args))])]
    let r ← dispatch req.compress
    let j ← IO.ofExcept (Json.parse r.body)
    pure (j.getObjValD "result")
  let borrow := Json.arr #[Json.mkObj [("id", "w1"), ("from", "Member"), ("to", "Desk"), ("label", "Borrow")]]
  let timedLean ← IO.FS.readFile "examples/sessions/DepositSettlement.leanfm"
  let timedOverlay := Json.mkObj [("name", "test-layer"), ("choices", toJson [
    Json.mkObj [("choice", "illustrative-settlement-v1"), ("weights", toJson ["0", "1"])]] )]
  let timedRequest := Json.mkObj [("jsonrpc", "2.0"), ("id", 91), ("method", "tools/call"),
    ("params", Json.mkObj [("name", "session_simulate"), ("arguments", Json.mkObj [
      ("lean", timedLean), ("overlay", timedOverlay), ("instances", 2), ("seed", 11)])])]
  let timedResponse ← dispatch timedRequest.compress
  assertContains "MCP generates timed traces with an external overlay" timedResponse.body "deadlineReports"
  let timedJson ← IO.ofExcept (Json.parse timedResponse.body)
  let mdpRequest := timedRequest.setObjVal! "params" (Json.mkObj [
    ("name", "session_mdp"), ("arguments", Json.mkObj [("lean", timedLean), ("overlay", timedOverlay)])])
  let mdpResponse ← dispatch mdpRequest.compress
  assertContains "MCP renders the native decision view" mdpResponse.body "terminalProbability"
  let mdpJson ← IO.ofExcept (Json.parse mdpResponse.body)
  let mdpResult := mdpJson.getObjValD "result"
  if (mdpResult.getObjValD "structuredContent").getObjValD "terminalProbability" != Json.str "1" then
    throw (IO.userError "MCP terminal probability is not one")
  let mdpDefinition := (LeanFM.MCP.tools.find? (fun t => (t.getObjValAs? String "name").toOption == some "session_mdp")).getD Json.null
  assertContains "MCP attaches decision diagram to the session app" mdpDefinition.compress "ui://leanfm/session-view"
  let results := Json.mkObj [
    ("mdp", mdpResult),
    ("timed", timedJson.getObjValD "result"),
    ("check", ← callTool "session_check" []),
    ("simulate", ← callTool "session_simulate" [("instances", (5 : Nat)), ("seed", (3 : Nat))]),
    ("conform", ← callTool "session_conform" [("events", bugLog)]),
    ("diagram", ← callTool "session_diagram" []),
    -- groups (selfhost.session.group): one foldable between two roles, one beside a parallel branch
    ("groupDiagram", ← callTool "session_diagram" [("lean", Json.str "protocol Upload (Client, Server, Log) {\n  group Request {\n    Headers from Client to Server;\n    Data from Client to Server;\n    End from Client to Server;\n  }\n  Saved from Server to Client;\n  parallel {\n    group Audit {\n      Note from Server to Log;\n      Ack from Log to Server;\n    }\n  } and {\n    Done from Server to Client;\n  }\n}")]),
    ("skeleton", ← callTool "session_skeleton" []),
    ("ctl", ← callTool "session_ctl" [("formula", (Json.parse "{\"AG\": {\"implies\": [{\"on\": \"Approved\"}, {\"AG\": {\"not\": {\"on\": \"Waitlisted\"}}}]}}").toOption.get!)]),
    ("compat", ← callTool "session_compat" [("old", Json.str lendingLean)]),
    ("actor", ← callTool "session_actor" [("role", "Member")]),
    ("dataset", ← callTool "session_dataset" [("sessions", (500 : Nat))]),
    ("types", ← callTool "session_types" []),
    ("explore", ← callTool "session_explore" []),
    ("exploreFocus", ← callTool "session_explore" [("focus", "Lending")]),
    ("exploreStates", ← callTool "session_explore" [("states", "Desk")]),
    ("exploreMessage", ← callTool "session_explore" [("message", "Borrow")]),
    ("next", Json.arr #[← callTool "session_next" [], ← callTool "session_next" [("events", borrow)]])]
  assertContains "session_simulate derives the stream's sessions" (results.getObjValD "simulate").compress "\"derivedSessions\""
  assertContains "the session tools' diagrams carry their calls for folding" (results.getObjValD "check").compress "\"calls\":[{"
  let results := results.setObjVal! "projectView" (← projectViewResults)
  IO.FS.writeFile ".cache/tests/session-view.html" shtml
  IO.FS.writeFile ".cache/tests/session-view-results.json" results.compress
  let smoke ← IO.Process.output { cmd := "node", args := #["scripts/session_view_smoke.js",
    ".cache/tests/session-view.html", ".cache/tests/session-view-results.json"] }
  if smoke.exitCode != 0 then
    throw <| IO.userError s!"MCP session view fails when driven:\n{smoke.stdout}{smoke.stderr}"
  IO.println s!"ok: MCP session view runs every session tool's result, the walk-through and the animation ({(smoke.stdout.splitOn "\n").length - 1} checks)"
  -- the view in a whole browser window (clause selfhost.mcp.session.standalone)
  let expect (label : String) (ok : Bool) : IO Unit :=
    if ok then IO.println s!"ok: {label}" else throw <| IO.userError s!"failed: {label}"
  let host := LeanFM.MCP.sessionHostHtml
  expect "the standalone page frames the view with scripts only" (host.contains "sandbox=\"allow-scripts\" src=\"/view/app\"")
  expect "the standalone page forwards tool calls to this server's /mcp" (host.contains "fetch(\"/mcp\"")
  expect "the standalone page offers only full screen" (host.contains "availableDisplayModes: [\"fullscreen\"]")
  let hostListed := ((host.splitOn "const VIEW_TOOLS = [").getD 1 "").splitOn "];" |>.headD ""
  let hostNames : List String := (hostListed.splitOn "\"").zipIdx.filterMap (fun (x, i) => if i % 2 == 1 then some x else none)
  expect "the standalone page forwards exactly the view's tools and session_next"
    (hostNames.length == LeanFM.MCP.sessionHostTools.length && LeanFM.MCP.sessionHostTools.all hostNames.contains)
  for needle in ["http://", "https://", "innerHTML", "outerHTML", "eval(", "new Function", "allow-same-origin"] do
    if host.contains needle then throw <| IO.userError s!"standalone session page: forbidden text {needle}"
  IO.FS.writeFile ".cache/tests/session-host.js" (((host.splitOn "<script>").getD 1 "").splitOn "</script>" |>.headD "")
  let hostCheck ← IO.Process.output { cmd := "node", args := #["--check", ".cache/tests/session-host.js"] }
  if hostCheck.exitCode != 0 then throw <| IO.userError s!"standalone session page script does not parse:\n{hostCheck.stderr}"
  IO.println "ok: the standalone session page's script parses"
  let sbare := shtml.replace "http://www.w3.org/2000/svg" ""
  for needle in ["http://", "https://", "src=", "href=", "fetch(", "XMLHttpRequest", "WebSocket", "EventSource",
      "import(", "innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "eval(", "new Function",
      "DOMParser", "/home/", "/Users/", "leanfm://"] do
    if sbare.contains needle then throw <| IO.userError s!"MCP session view: forbidden text {needle}"
  IO.println "ok: MCP session view has no network access, no HTML or code from data, and no paths"
  assertContains "MCP session view speaks the MCP Apps handshake" shtml "\"ui/initialize\""
  assertContains "MCP session view renders tool results" shtml "\"ui/notifications/tool-result\""
  assertContains "MCP session view reports its size" shtml "\"ui/notifications/size-changed\""
  assertContains "MCP session view builds SVG elements, not markup" shtml "createElementNS"
  assertContains "MCP session view bounds the drawing" shtml "MAX_SHAPES = 4000, MAX_EVENTS = 600"
  assertContains "MCP session view starts the animation in full detail" shtml "detail = true"
  assertContains "MCP session view scrolls the animation both ways" shtml ".seq { overflow: auto;"
  assertContains "MCP session view tries seeds until every role takes part" shtml "const ANIM_TRIES = 8;"
  assertContains "MCP session view offers full screen" shtml "availableDisplayModes: [\"inline\", \"fullscreen\"]"
  assertContains "MCP session view asks the host for full screen" shtml "\"ui/request-display-mode\""
  assertContains "MCP session view plays one session alone" shtml "function sessionBody(body, keepIt)"
  assertContains "MCP session view picks sessions derived by LeanFM, not read from the events" shtml "body.derivedSessions"
  assertContains "MCP session view folds calls and elides the roles they hide" shtml "CALL_ROW = 30"
  assertContains "MCP session view shows every role's OpenAPI" shtml "async function openapiAll()"
  assertContains "MCP session view shows OpenAPI as coloured YAML" shtml "function yamlPre(text)"
  assertContains "MCP session view builds properties from the protocol's messages" shtml "const PROP_PATTERNS = ["
  assertContains "MCP session view scales its text and drawings, down to 10%" shtml "const UI_SCALES = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1, 1.1, 1.25, 1.5];"
  assertContains "MCP session view shrinks every drawing to the width in full screen" shtml ":root[data-mode=\"fullscreen\"] .scroll > svg, :root[data-mode=\"fullscreen\"] .scroll > img { max-width: 100%; height: auto; }"
  assertContains "MCP session view fits a state machine at any zoom" shtml "zoom = Math.max(0.02, Math.min(1, (seen - 20) / Math.max(1, fit.w)))"
  assertContains "MCP session view offers the walk-through" shtml "const WALK_TOOL = \"session_next\", MAX_WALK = 200;"
  let promptsListed ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":35,\"method\":\"prompts/list\"}"
  assertContains "MCP offers the session design prompt" promptsListed.body "design_with_session_types"
  let promptGot ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":36,\"method\":\"prompts/get\",\"params\":{\"name\":\"design_with_session_types\"}}"
  assertContains "MCP session design prompt ends at session_conform" promptGot.body "session_conform"
  assertContains "MCP session view edits through tools/call" shtml "\"tools/call\""
  assertContains "MCP session view calls only the session tools, bounded" shtml "const EDIT_TOOLS = [\"session_check\", \"session_simulate\", \"session_mdp\", \"session_actor\", \"session_dataset\", \"session_types\", \"session_explore\", \"session_review\", \"session_ctl\", \"session_sla\", \"session_instances\", \"session_skeleton\", \"session_openapi\"], MAX_EDIT_BYTES = 65536"
  -- The hosted endpoint (clause selfhost.mcp.hosting).
  let cfg : HostConfig := { burst := 3, ratePerMinute := 60, maxInflight := 1 }
  let limits ← Limits.new
  let ping := "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}"
  let post (hs : List (String × String)) (body : String := ping) (path := "/mcp") (peer := "10.0.0.1") : Req :=
    { method := "POST", path, headers := [("Content-Type", "application/json")] ++ hs, body, peer }
  let hdr (r : Resp) (k : String) : Option String := (r.headers.find? (fun (n, _) => n.toLower == k.toLower)).map (·.2)
  let expect (label : String) (ok : Bool) : IO Unit :=
    if ok then IO.println s!"ok: {label}" else throw <| IO.userError s!"MCP host: {label}"
  let t := 1000000
  let pre ← handle cfg limits { method := "OPTIONS", path := "/mcp", headers := [("Origin", "https://claude.ai"),
    ("Access-Control-Request-Method", "POST")], peer := "p0" } t
  expect "MCP host answers a preflight from claude.ai" (pre.status == 204 && hdr pre "Access-Control-Allow-Origin" == some "https://claude.ai")
  expect "MCP host allows the MCP request headers" (((hdr pre "Access-Control-Allow-Headers").getD "").contains "Mcp-Protocol-Version" &&
    ((hdr pre "Access-Control-Allow-Headers").getD "").contains "Mcp-Session-Id" && hdr pre "Access-Control-Expose-Headers" == some "Mcp-Session-Id")
  let evil ← handle cfg limits (post [("Origin", "https://evil.example")] (peer := "p1")) t
  expect "MCP host refuses an unlisted origin without CORS headers" (evil.status == 403 && (hdr evil "Access-Control-Allow-Origin").isNone)
  let noOrigin ← handle cfg limits (post [] (peer := "p2")) t
  expect "MCP host serves a server-side client with no Origin" (noOrigin.status == 200 && noOrigin.body.contains "\"result\"")
  let fromClaude ← handle cfg limits (post [("Origin", "https://claude.ai")] (peer := "p3")) t
  expect "MCP host adds CORS headers for claude.ai" (fromClaude.status == 200 && hdr fromClaude "Access-Control-Allow-Origin" == some "https://claude.ai" && hdr fromClaude "Vary" == some "Origin")
  let get ← handle cfg limits { method := "GET", path := "/mcp", peer := "p4" } t
  expect "MCP host answers GET /mcp with 405" (get.status == 405 && hdr get "Allow" == some "POST, OPTIONS")
  for path in ["/api/llm", "/api/session", "/", "/renders/", "/api/projects"] do
    let r ← handle cfg limits (post [] (path := path) (peer := "p5")) t
    expect s!"MCP host does not serve {path}" (r.status == 404)
  let ct ← handle cfg limits { method := "POST", path := "/mcp", headers := [("Content-Type", "text/plain")], body := ping, peer := "p6" } t
  expect "MCP host refuses a non-JSON body" (ct.status == 415)
  let acc ← handle cfg limits (post [("Accept", "text/html")] (peer := "p7")) t
  expect "MCP host refuses an Accept without JSON" (acc.status == 406)
  let streamable ← handle cfg limits (post [("Accept", "application/json, text/event-stream")] (peer := "p7b")) t
  expect "MCP host serves a Streamable HTTP Accept header" (streamable.status == 200)
  let ver ← handle cfg limits (post [("Mcp-Protocol-Version", "1999-01-01")] (peer := "p8")) t
  expect "MCP host refuses an unsupported protocol version" (ver.status == 400)
  let verOk ← handle cfg limits (post [("Mcp-Protocol-Version", "2025-06-18")] (peer := "p8b")) t
  expect "MCP host accepts protocol version 2025-06-18" (verOk.status == 200)
  let big ← handle cfg limits (post [] (body := String.ofList (List.replicate 300000 ' ')) (peer := "p9")) t
  expect "MCP host refuses a body over 256 KiB" (big.status == 413)
  let tcfg : HostConfig := { cfg with token := some "s3cret" }
  let noTok ← handle tcfg limits (post [] (peer := "t1")) t
  let badTok ← handle tcfg limits (post [("Authorization", "Bearer wrong")] (peer := "t2")) t
  let goodTok ← handle tcfg limits (post [("Authorization", "Bearer s3cret")] (peer := "t3")) t
  expect "MCP host requires the configured token" (noTok.status == 401 && badTok.status == 401 && hdr noTok "WWW-Authenticate" == some "Bearer realm=\"leanfm\"" && goodTok.status == 200)
  let note ← handle cfg limits (post [] (body := "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}") (peer := "p10")) t
  expect "MCP host acknowledges a notification with 202 and no body" (note.status == 202 && note.body.isEmpty)
  let a ← handle cfg limits (post [] (peer := "burst")) t
  let b ← handle cfg limits (post [] (peer := "burst")) t
  let c ← handle cfg limits (post [] (peer := "burst")) t
  let d ← handle cfg limits (post [] (peer := "burst")) t
  expect "MCP host serves the burst, then rate limits with Retry-After" (a.status == 200 && b.status == 200 && c.status == 200 && d.status == 429 && (hdr d "Retry-After").isSome)
  let later ← handle cfg limits (post [] (peer := "burst")) (t + 1000)
  expect "MCP host refills a client's allowance over time" (later.status == 200)
  limits.inflight.set 1
  let busy ← handle cfg limits (post [] (body := "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"check_reassembly\",\"arguments\":{}}}") (peer := "p11")) t
  limits.inflight.set 0
  expect "MCP host refuses a tool call beyond the in-flight limit" (busy.status == 503 && hdr busy "Retry-After" == some "1")
  let health ← handle cfg limits { method := "GET", path := "/healthz", peer := "p12" } t
  expect "MCP host answers /healthz" (health.status == 200 && health.body == "ok\n")
  -- compaction to the 25,000-token limit
  let step (i : Nat) : Json := Json.mkObj [("state", Json.str s!"s{i}"), ("message", Json.str "m"),
    ("holds", Json.mkObj [("Ivo", Json.arr ((List.range 40).map (fun k => Json.str s!"term-{i}-{k}")).toArray)])]
  let replyWith (n : Nat) : String := (Json.mkObj [("jsonrpc", "2.0"), ("id", (7 : Nat)), ("result", Json.mkObj
    [("structuredContent", Json.mkObj [("verdict", "disproved"), ("evidence", Json.mkObj [("path", Json.arr ((List.range n).map step).toArray)])])])]).compress
  let huge := replyWith 400
  let compacted := compactReply huge 20000
  expect "MCP host compacts an oversized reply below the limit, keeping its verdict" (huge.length > 20000 && compacted.length ≤ 20000 && compacted.contains "\"verdict\":\"disproved\"" && compacted.contains "omitted")
  let irreducible := compactReply huge 200
  expect "MCP host replaces an irreducible reply with error -32000" (irreducible.contains "-32000" && irreducible.length < 400)
  for r in [pre, evil, noOrigin, fromClaude, get, ct, acc, ver, big, noTok, goodTok, note, d, busy, health] do
    if hdr r "Access-Control-Allow-Origin" == some "*" || (hdr r "Access-Control-Allow-Credentials").isSome then
      throw <| IO.userError "MCP host: a response allowed every origin or credentials"
    if hdr r "Cache-Control" != some "no-store" then throw <| IO.userError "MCP host: a response lacks Cache-Control: no-store"
  IO.println "ok: MCP host never allows every origin or credentials, and never caches"
  let line := logLine (post [("Authorization", "Bearer s3cret")] (body := "{\"secret\":1}") (peer := "203.0.113.9")) goodTok 5
  expect "MCP host log line holds no body, token or client address" (!line.contains "s3cret" && !line.contains "secret" && !line.contains "203.0.113.9")
  -- standard input and output (clause selfhost.mcp.stdio): the same dispatch, one message per line
  let sInit ← stdioReply "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}\r\n"
  expect "MCP stdio answers initialize on one line" (match sInit with
    | some l => l.contains "\"protocolVersion\"" && !l.contains "\n" && l.contains "\"id\":1"
    | none => false)
  expect "MCP stdio writes nothing for a notification" ((← stdioReply "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}").isNone)
  expect "MCP stdio writes nothing for a blank line" ((← stdioReply "  \n").isNone)
  expect "MCP stdio writes nothing for a response the client sends" ((← stdioReply "{\"jsonrpc\":\"2.0\",\"id\":9,\"result\":{}}").isNone)
  expect "MCP stdio answers a line that is not JSON with -32700" (match ← stdioReply "not json" with
    | some l => l.contains "-32700" && !l.contains "\n"
    | none => false)
  let hugeLine := "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\",\"params\":{\"x\":\"" ++ String.ofList (List.replicate (maxBodyBytes + 1) 'a') ++ "\"}}"
  expect "MCP stdio refuses a message over 256 KiB with -32600" (match ← stdioReply hugeLine with
    | some l => l.contains "-32600" && l.length < 400
    | none => false)
  let sTools ← stdioReply "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/list\"}"
  let hTools ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/list\"}"
  expect "MCP stdio lists the same tools as HTTP" (sTools == some hTools.body)
  let sActor ← stdioReply "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"session_actor\",\"arguments\":{\"role\":\"B\",\"lean\":\"protocol PingPong (A, B) { p: Ping from A to B; Pong from B to A cause p status 200; }\"}}}"
  expect "MCP stdio runs session_actor" (match sActor with
    | some l => l.contains "\"verdict\":\"projected\"" && l.contains "PingPong as B sees it"
    | none => false)
  let sData ← stdioReply "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"session_dataset\",\"arguments\":{\"sessions\":50,\"lean\":\"protocol PingPong (A, B) { p: Ping from A to B; Pong from B to A cause p status 200; }\"}}}"
  expect "MCP stdio runs session_dataset" (match sData with
    | some l => l.contains "\"verdict\":\"generated\"" && l.contains "\"sessions\":50"
    | none => false)
  -- the examples LeanFM carries (clause selfhost.session.explorer): compiled in, each still the file it came from
  for (name, path, text) in LeanFM.SessionTools.examples do
    let onDisk ← IO.FS.readFile path
    expect s!"MCP example {name} is the current {path} (rebuild LeanFM.SessionTools after changing it)" (onDisk == text)
  let ex ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":40,\"method\":\"tools/call\",\"params\":{\"name\":\"session_explore\",\"arguments\":{\"example\":\"goserver\"}}}"
  expect "MCP session_explore outlines the GoServer example" (ex.body.contains "\"verdict\":\"outlined\"" && ex.body.contains "include Challenge" && ex.body.length < 100000)
  let exFocus ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":41,\"method\":\"tools/call\",\"params\":{\"name\":\"session_explore\",\"arguments\":{\"example\":\"goserver\",\"focus\":\"Challenge\"}}}"
  expect "MCP session_explore draws one GoServer protocol" (exFocus.body.contains "\"verdict\":\"drawn\"" && exFocus.body.contains "\"focus\":\"Challenge\"")
  let exMsg ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":47,\"method\":\"tools/call\",\"params\":{\"name\":\"session_explore\",\"arguments\":{\"example\":\"goserver\",\"message\":\"PlayMove\"}}}"
  expect "MCP session_explore describes a GoServer message: example JSON, schema and protobuf" (exMsg.body.contains "\"verdict\":\"described\"" && exMsg.body.contains "message PlayMove {" && exMsg.body.contains "\"moveNo\":\"0\"")
  let exStates ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":48,\"method\":\"tools/call\",\"params\":{\"name\":\"session_explore\",\"arguments\":{\"example\":\"goserver\",\"states\":\"Bot\"}}}"
  expect "MCP session_explore gives the Bot's state machine, End included" (exStates.body.contains "\"verdict\":\"states\"" && exStates.body.contains "receive BotTurn from Server" && exStates.body.contains "\"to\":\"End\"")
  let exNoRole ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":49,\"method\":\"tools/call\",\"params\":{\"name\":\"session_explore\",\"arguments\":{\"example\":\"goserver\",\"states\":\"Mallory\"}}}"
  expect "MCP session_explore refuses a state machine of a role the protocol does not have" (exNoRole.body.contains "Mallory is not a role of GoServer")
  let exFocusStates ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":51,\"method\":\"tools/call\",\"params\":{\"name\":\"session_explore\",\"arguments\":{\"example\":\"goserver\",\"focus\":\"Turn\",\"states\":\"Bot\"}}}"
  expect "MCP session_explore gives a role's state machine in one protocol of the text" (exFocusStates.body.contains "\"verdict\":\"states\"" && exFocusStates.body.contains "\"name\":\"Turn\"" && exFocusStates.body.contains "receive BotTurn from Server")
  let exFocusNoRole ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":52,\"method\":\"tools/call\",\"params\":{\"name\":\"session_explore\",\"arguments\":{\"example\":\"goserver\",\"focus\":\"CreateRoomP\",\"states\":\"Bot\"}}}"
  expect "MCP session_explore refuses a role the focused protocol does not have" (exFocusNoRole.body.contains "Bot is not a role of CreateRoomP")
  let exNoMsg ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":50,\"method\":\"tools/call\",\"params\":{\"name\":\"session_explore\",\"arguments\":{\"example\":\"goserver\",\"message\":\"Nope\"}}}"
  expect "MCP session_explore refuses a message the protocol does not have" (exNoMsg.body.contains "Nope is not a message of GoServer")
  -- the walk names its state, the same after a loop's pass as at its start
  let n0 ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":51,\"method\":\"tools/call\",\"params\":{\"name\":\"session_next\",\"arguments\":{\"lean\":\"protocol L (A, B) { loop Loop { choice { More from A to B; continue Loop; } or { Stop from A to B; } } }\"}}}"
  let n1 ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":52,\"method\":\"tools/call\",\"params\":{\"name\":\"session_next\",\"arguments\":{\"lean\":\"protocol L (A, B) { loop Loop { choice { More from A to B; continue Loop; } or { Stop from A to B; } } }\",\"events\":[{\"id\":\"e1\",\"from\":\"A\",\"to\":\"B\",\"label\":\"More\"}]}}}"
  let n2 ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":53,\"method\":\"tools/call\",\"params\":{\"name\":\"session_next\",\"arguments\":{\"lean\":\"protocol L (A, B) { loop Loop { choice { More from A to B; continue Loop; } or { Stop from A to B; } } }\",\"events\":[{\"id\":\"e1\",\"from\":\"A\",\"to\":\"B\",\"label\":\"Stop\"}]}}}"
  let stateOf (r : Response) : String := match Json.parse r.body with
    | .ok j => (((j.getObjValD "result").getObjValD "structuredContent").getObjValAs? String "state").toOption.getD ""
    | .error _ => ""
  expect "MCP session_next names the state: a loop's pass returns to it, an end does not" (stateOf n0 != "" && stateOf n0 == stateOf n1 && stateOf n0 != stateOf n2)
  -- GoServer is an HTTP site: its session type routes 17 requests (sign-in, joining a game and sign-out among them) (route "POST /api/..."), so the
  -- Server's projection is an OpenAPI document of 17 operations, and the review checks HTTP
  let oa ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":54,\"method\":\"tools/call\",\"params\":{\"name\":\"session_openapi\",\"arguments\":{\"example\":\"goserver\",\"role\":\"Server\"}}}"
  expect "MCP session_openapi gives GoServer's Server 17 operations within the result limit" (oa.body.contains "OpenAPI 3.1 for Server, 17 operations" && oa.body.contains "/api/play_move" && compactReply oa.body == oa.body)
  let srv ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":55,\"method\":\"tools/call\",\"params\":{\"name\":\"session_actor\",\"arguments\":{\"example\":\"goserver\",\"role\":\"Server\"}}}"
  expect "MCP session_actor of GoServer's Server serves 17 routes within the result limit, naming what it left out" (srv.body.contains "serves 17 routes" && srv.body.contains "the same document is in openapiYaml" && compactReply srv.body == srv.body)
  let rv ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":56,\"method\":\"tools/call\",\"params\":{\"name\":\"session_review\",\"arguments\":{\"example\":\"goserver\"}}}"
  expect "MCP session_review of GoServer checks HTTP and liveness over its whole state graph: clean" (rv.body.contains "\"verdict\":\"clean\"" && rv.body.contains "HTTP from 17 routed requests, liveness" && !rv.body.contains "not checked")
  -- GoServer's properties are decided, not skipped: its state graph is 10969 states (each game, seat and polled list played once in place) once a state is
  -- keyed by the set of names it bound (keyed by their order it looked unbounded)
  let gEf ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":57,\"method\":\"tools/call\",\"params\":{\"name\":\"session_ctl\",\"arguments\":{\"example\":\"goserver\",\"formula\":{\"EF\":{\"on\":\"PlayMove\"}}}}}"
  expect "MCP session_ctl proves PlayMove can happen in GoServer, over 10969 states, with a witness path" (gEf.body.contains "\"verdict\":\"proved\"" && gEf.body.contains "\"states\":10969" && gEf.body.contains "TakeSeat -> SeatTaken -> PlayMove")
  expect "MCP session_ctl answers the formula in CTL notation" (gEf.body.contains "\"notation\":\"possibly PlayMove\"")
  let gAf ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":58,\"method\":\"tools/call\",\"params\":{\"name\":\"session_ctl\",\"arguments\":{\"example\":\"goserver\",\"formula\":{\"AF\":{\"on\":\"PlayMove\"}}}}}"
  expect "MCP session_ctl disproves that PlayMove always happens in GoServer, with a counterexample that loops" (gAf.body.contains "\"verdict\":\"disproved\"" && gAf.body.contains "counterexample:" && gAf.body.contains "then repeats from")
  let exBad ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"tools/call\",\"params\":{\"name\":\"session_check\",\"arguments\":{\"example\":\"../../etc/passwd\"}}}"
  expect "MCP refuses an example LeanFM does not carry, naming the ones it does" (exBad.body.contains "example must be one of goserver" && !exBad.body.contains "root:")
  let exBoth ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":43,\"method\":\"tools/call\",\"params\":{\"name\":\"session_check\",\"arguments\":{\"example\":\"ride\",\"lean\":\"protocol P (A, B) { X from A to B; }\"}}}"
  expect "MCP refuses example and lean together" (exBoth.body.contains "give example or lean")
  let chk ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":44,\"method\":\"tools/call\",\"params\":{\"name\":\"session_check\",\"arguments\":{\"example\":\"goserver\"}}}"
  expect "MCP session_check of GoServer fits the result limit, saying what it left out" (chk.body.contains "\"verdict\":\"ok\"" && (chk.body.contains "projections (each role" || !chk.body.contains "\"omitted\"") && compactReply chk.body == chk.body)
  let big ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":45,\"method\":\"tools/call\",\"params\":{\"name\":\"session_dataset\",\"arguments\":{\"example\":\"goserver\",\"sessions\":10000}}}"
  expect "MCP session_dataset runs 10000 GoServer sessions within the result limit" (big.body.contains "\"sessions\":10000" && big.body.contains "distinct paths" && big.body.length < 100000)
  let tooBig ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":46,\"method\":\"tools/call\",\"params\":{\"name\":\"session_dataset\",\"arguments\":{\"sessions\":2000,\"lean\":\"protocol Forever (A, B) { loop L { Ping from A to B; continue L; } }\"}}}"
  expect "MCP session_dataset refuses more than 1000000 events rather than truncating" (tooBig.body.contains "would exceed 1000000 events")
  -- LeanFM's own requirements and mappings are readable resources
  for uri in ["leanfm://project/specification/SelfHosting.lean", "leanfm://project/specification/McpLogicImplementation.lean",
      "leanfm://project/specification/SessionImplementation.lean"] do
    let r ← dispatch ("{\"jsonrpc\":\"2.0\",\"id\":30,\"method\":\"resources/read\",\"params\":{\"uri\":\"" ++ uri ++ "\"}}")
    assertContains s!"MCP lists {uri}" listed.body uri
    assertContains s!"MCP reads {uri}" r.body "\"contents\""
  assertContains "MCP instructions point at LeanFM's own requirements" initialized.body "SelfHosting.lean"
  -- server_logs (LeanFM/ServerLogs.lean): off and unlisted until the executable turns it on
  let offList ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":70,\"method\":\"tools/list\"}"
  expect "MCP does not list server_logs on a host that has not enabled it" (!offList.body.contains "\"server_logs\"")
  let offCall ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":71,\"method\":\"tools/call\",\"params\":{\"name\":\"server_logs\",\"arguments\":{\"log\":\"serve\"}}}"
  expect "MCP refuses server_logs where it is off" (offCall.body.contains "server_logs is off on this host" && !offCall.body.contains "\"lines\"")
  projectViewOffTests offList.body
  projectFilesOffTests
  serverInfoOffTests offList.body
  LeanFM.ServerLogs.enable
  serverInfoTests
  projectViewTests
  projectFilesTests
  let onList ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":72,\"method\":\"tools/list\"}"
  expect "MCP lists server_logs once enabled" (onList.body.contains "\"name\":\"server_logs\"")
  let idx ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":73,\"method\":\"tools/call\",\"params\":{\"name\":\"server_logs\",\"arguments\":{}}}"
  expect "MCP server_logs without log lists the logs it can show" (idx.body.contains "desktop-mcp" && idx.body.contains "logs/serve.log")
  let trav ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":74,\"method\":\"tools/call\",\"params\":{\"name\":\"server_logs\",\"arguments\":{\"log\":\"../../etc/passwd\"}}}"
  expect "MCP server_logs refuses a path, naming the logs it serves" (trav.body.contains "log must be one of desktop-mcp" && !trav.body.contains "root:")
  let zero ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":75,\"method\":\"tools/call\",\"params\":{\"name\":\"server_logs\",\"arguments\":{\"log\":\"serve\",\"lines\":0}}}"
  expect "MCP server_logs refuses lines outside 1 to 2000" (zero.body.contains "lines must be between 1 and 2000")
  let serve ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":76,\"method\":\"tools/call\",\"params\":{\"name\":\"server_logs\",\"arguments\":{\"log\":\"serve\",\"lines\":5}}}"
  expect "MCP server_logs answers a named log within the result limit" (serve.body.contains "\"log\":\"serve\"" && serve.body.length < 100000)
  expect "server_logs redacts bearer tokens, API keys and token= values"
    (LeanFM.ServerLogs.redactLine "Authorization: Bearer abc123 key=sk-ABCDEFGHIJKLMNOPQRSTUV token=s3cret token=none"
      == "Authorization: Bearer [redacted] [redacted] token=[redacted] token=none")
  expect "server_logs prints times as UTC" (LeanFM.ServerLogs.isoUtc 1794853518 == "2026-11-16T18:25:18Z")
  let (st, _, _) ← LeanFM.ServerLogs.httpAnswer "/tools/logs?log=..%2F..%2Fetc%2Fpasswd"
  expect "GET /tools/logs refuses a path with 400" (st == 400)
  -- the model token (selfhost.mcp.model-token): a held token for the same text is a hit with the same answer
  let ctlCall (id : Nat) (text : String) (extra : String) : IO Json := do
    let r ← dispatch s!"\{\"jsonrpc\":\"2.0\",\"id\":{id},\"method\":\"tools/call\",\"params\":\{\"name\":\"session_ctl\",\"arguments\":\{\"lean\":{(Json.str text).compress},\"formula\":\"(possibly (on Quote))\"{extra}}}}"
    pure ((((Json.parse r.body).toOption.getD Json.null).getObjValD "result").getObjValD "structuredContent")
  let shop := "protocol Shop (Client, Shop) { o: Order from Client to Shop; choice { Quote from Shop to Client cause o; } or { SoldOut from Shop to Client cause o; } }"
  let first ← ctlCall 400 shop ""
  let token := (first.getObjValAs? String "model").toOption.getD ""
  expect "session_ctl hands out a 32-hex-digit model token on a miss"
    (token.length == 32 && token.all (fun c => c.isDigit || ('a' ≤ c && c ≤ 'f')) && (first.getObjValAs? String "cache").toOption == some "miss")
  let second ← ctlCall 401 shop s!",\"model\":\"{token}\""
  let strip (j : Json) : String := match j with
    | .obj kv => (Json.mkObj (kv.toList.filter fun (k, _) => k != "model" && k != "cache")).compress | _ => j.compress
  expect "the same text with its token is a hit, and the answer is the same apart from model and cache"
    ((second.getObjValAs? String "cache").toOption == some "hit" && (second.getObjValAs? String "model").toOption == some token && strip second == strip first)
  let other ← ctlCall 402 (shop.replace "SoldOut" "Gone") s!",\"model\":\"{token}\""
  expect "a token used with another text is a miss with a new token"
    ((other.getObjValAs? String "cache").toOption == some "miss" && (other.getObjValAs? String "model").toOption != some token)
  LeanFM.ModelCache.clear
  LeanFM.ModelCache.capacity.set 2
  let t1 := (((← ctlCall 403 shop "").getObjValAs? String "model").toOption.getD "")
  let _ ← ctlCall 404 (shop.replace "Quote" "Offer") ""
  let _ ← ctlCall 405 (shop.replace "Order" "Ask") ""
  let again ← ctlCall 406 shop s!",\"model\":\"{t1}\""
  expect "the cache holds at most its size and drops the least recently used"
    ((← LeanFM.ModelCache.size) == 2 && (again.getObjValAs? String "cache").toOption == some "miss")
  LeanFM.ModelCache.capacity.set LeanFM.ModelCache.defaultCapacity
  -- per-call limits (selfhost.mcp.limits): listed on every tool, reported when changed, capped, one call only
  let listed ← dispatch "{\"jsonrpc\":\"2.0\",\"id\":300,\"method\":\"tools/list\"}"
  let listedTools := match (Json.parse listed.body).toOption.map (fun j => (j.getObjValD "result").getObjValD "tools") with
    | some (.arr a) => a.toList | _ => []
  expect "MCP every tool LeanFM's checks run in lists the limits argument"
    (!listedTools.isEmpty && listedTools.all fun t =>
      let n := (t.getObjValAs? String "name").toOption.getD ""
      n == "server_logs" || n == "project_view" || n == "server_info" || n == "introduction" || (((t.getObjValD "inputSchema").getObjValD "properties").getObjVal? "limits").isOk)
  expect "MCP the instructions say how to raise a limit and list the limits" (LeanFM.MCP.instructions.contains "\"limits\": {\"states\": 100000}" && LeanFM.MCP.instructions.contains "datasetEvents 1000000")
  expect "MCP tools/list stays under the client's result limit" (listed.body.length < 100000)
  let imagesLean := (Json.str "protocol Images (Browser, Server) {\n  g: GetImage from Browser to Server;\n  choice {\n    Image from Server to Browser cause g;\n  } or {\n    NotFound from Server to Browser cause g;\n  }\n}").compress
  let callWith (id : Nat) (extra : String) : IO LeanFM.MCP.Response :=
    dispatch s!"\{\"jsonrpc\":\"2.0\",\"id\":{id},\"method\":\"tools/call\",\"params\":\{\"name\":\"session_ctl\",\"arguments\":\{\"lean\":{imagesLean},\"formula\":\{\"AF\":\"stop\"}{extra}}}}"
  let raised ← callWith 301 ",\"limits\":{\"states\":40000}"
  expect "MCP an answer under a raised limit carries limitsApplied and a warning line"
    (raised.body.contains "\"limitsApplied\"" && raised.body.contains "limits changed for this call: states 40000 (default 20000)" && raised.body.contains "\"verdict\":\"proved\"")
  let plain ← callWith 302 ""
  expect "MCP one call's limits do not reach the next call" (!plain.body.contains "limitsApplied" && plain.body.contains "\"verdict\":\"proved\"")
  let lowered ← callWith 303 ",\"limits\":{\"states\":2}"
  expect "MCP a limit an answer runs into is named with the argument that raises it"
    (lowered.body.contains "the states limit (2)" && lowered.body.contains "\"isError\":true")
  let unknown ← callWith 304 ",\"limits\":{\"stats\":5}"
  expect "MCP an unknown limit is refused naming the limits" (unknown.body.contains "unknown limit stats" && unknown.body.contains "\"isError\":true")
  let factor ← LeanFM.CallLimits.ceilingFactor.get
  LeanFM.CallLimits.ceilingFactor.set 2
  let capped ← callWith 305 ",\"limits\":{\"states\":999999999}"
  LeanFM.CallLimits.ceilingFactor.set factor
  expect "MCP a request past the operator's ceiling is capped and says so"
    (capped.body.contains "\"applied\":40000" && capped.body.contains "capped at the operator's ceiling")
