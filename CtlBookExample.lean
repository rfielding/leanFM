import LeanFM.SessionTools
import LeanFM.MCP
import LeanFM.Logic
import LeanFM.Session.Faithful
import Lean.Data.Json.Elab

/-!
Generates every listing, typestate graph, rule, table and MCP transcript in the book
(book/main.tex: multiparty session types reduced to CTL) through the same functions the MCP tools
call. Nothing in those chapters is drawn or typed by hand: a typestate graph is LeanFM's own
bisimulation classes laid out by depth, a rule is Faithful.rules written by Formula.symbols, and a
transcript is the request a client sends and an excerpt of the answer LeanFM gives.

Run from the LeanFM root:
  lake env lean --run CtlBookExample.lean
  python3 scripts/svg_to_pdf.py book/generated/ctl-*.svg
  for f in book/generated/ctl-*-ts-*.dot; do dot -Tpdf "$f" -o "${f%.dot}.pdf"; done
-/

namespace CtlBookExample
open Lean LeanFM LeanFM.SessionTools LeanFM.Session.Faithful

def out := "book/generated/"

def listing (body : String) : String :=
  "\\begin{lstlisting}[language={},basicstyle=\\ttfamily\\footnotesize,breaklines=true]\n" ++ body.trimAscii.toString ++ "\n\\end{lstlisting}\n"

def str (j : Json) (k : String) : String := (j.getObjValD k).getStr?.toOption.getD ""
def strs (j : Json) (k : String) : List String :=
  match j.getObjValD k with
  | .arr a => a.toList.filterMap fun (x : Json) => x.getStr?.toOption
  | _ => []

def withLean (text : String) (more : List (String × Json) := []) : Json :=
  Json.mkObj ([("lean", Json.str text)] ++ more)

/-- Run a tool; a refusal is a generator failure, never a silent gap in the book. -/
def tool (name : String) (r : Except String Json) : IO Json :=
  match r with
  | .ok j => pure j
  | .error e => throw <| IO.userError s!"{name}: {e}"

def write (name body : String) : IO Unit := IO.FS.writeFile (out ++ name) body

def tex (t : String) : String := t.foldl (fun acc ch => acc ++ match ch with
  | '_' => "\\_" | '&' => "\\&" | '#' => "\\#" | '%' => "\\%" | '{' => "\\{" | '}' => "\\}" | '$' => "\\$" | ch => ch.toString) ""

/-- An answer cut down for print: long strings and arrays shortened, and only the keys asked for. -/
partial def trim (j : Json) (maxStr : Nat := 150) (maxArr : Nat := 6) : Json :=
  match j with
  | .str s => if s.length > maxStr then .str ((s.take maxStr).toString ++ " ...") else .str s
  | .arr a =>
    let kept := (a.toList.take maxArr).map (trim · maxStr maxArr)
    .arr (if a.size > maxArr then (kept ++ [Json.str s!"... {a.size - maxArr} more"]).toArray else kept.toArray)
  | .obj kvs => Json.mkObj (kvs.toList.map fun (k, v) => (k, trim v maxStr maxArr))
  | other => other

def pick (j : Json) (keys : List String) : Json :=
  Json.mkObj (keys.filterMap fun k => match j.getObjVal? k with | .ok v => some (k, v) | .error _ => none)

/-- A request and the answer's chosen keys, as a client sees them over MCP. -/
def transcript (toolName : String) (args : Json) (answer : Json) (keys : List String) (maxStr : Nat := 150) : String :=
  listing s!"tools/call {toolName}\n{(trim args 400 4).pretty 96}\n\nanswer (excerpt)\n{(trim (pick answer keys) maxStr).pretty 96}"

/-- A protocol's checker model and typestates, from its text. -/
def typestatesOf (text : String) : IO (LGraph × Typestates) := do
  let p ← IO.ofExcept (parseProtocol (withLean text))
  let (d, _) ← IO.ofExcept (p.global.draft p.name)
  let g ← IO.ofExcept (modelOfDraft d)
  return (g, typestates g)

/-- The typestate graph for Graphviz: each class a box named by its last message (a double border
where the session may stop), the start marked by an arrow, an ended session's stutter a loop. dot
only places the boxes; the classes and their steps are LeanFM's. Themes: light, dark, cover. -/
def dotOf (t : Typestates) (theme : String) : String := Id.run do
  let (ink, fill, bg) := match theme with
    | "dark" => ("#e8e8eb", "#22242a", "#121214")
    | "cover" => ("#e2b94b", "#1e3a5e", "#1e3a5e")
    | _ => ("#141416", "#f7f7f9", "#ffffff")
  let start := t.final[0]!
  let esc := fun (x : String) => x.replace "\"" "\\\""
  let mut out := s!"digraph T \{\n  rankdir=LR; bgcolor=\"{bg}\"; nodesep=0.25; ranksep=0.45; margin=0.1;\n" ++
    s!"  node [shape=box, style=\"rounded,filled\", color=\"{ink}\", fillcolor=\"{fill}\", fontcolor=\"{ink}\", fontname=\"Helvetica\", fontsize=11, penwidth=1.3, height=0.32];\n" ++
    s!"  edge [color=\"{ink}\", arrowsize=0.7, penwidth=1.2];\n  s [shape=point, width=0.08, color=\"{ink}\"];\n  s -> t{start};\n"
  for c in [0:t.count] do
    let (msg, ends) := t.labelOf c
    out := out ++ s!"  t{c} [label=\"{esc (msg.getD "start")}\"{if ends then ", peripheries=2" else ""}];\n"
  for c in [0:t.count] do
    for d in t.next[c]! do
      out := out ++ s!"  t{c} -> t{d};\n"
  return out ++ "}\n"

/-- Write a typestate graph in every theme. -/
def writeDot (name : String) (t : Typestates) : IO Unit := do
  for theme in ["light", "dark", "cover"] do
    IO.FS.writeFile s!"book/generated/{name}-ts-{theme}.dot" (dotOf t theme)

def rulesText (t : Typestates) : String :=
  "\n\n".intercalate ((rules t).map fun (n, f) => s!"{n}\n  {f.symbols}")

def images : String := "structure GetImage where
  id : String

structure Image where
  imageId : Header String
  contentLength : Header Nat
  cacheControl : Header String
  cached : cacheControl = \"max-age=3600\" or cacheControl = \"no-store\"
  small : size <= 5000000
  measured : contentLength = size

protocol Images (Browser, Server) {
  g: GetImage from Browser to Server route \"GET /images/{id}\";
  choice {
    i: Image from Server to Browser cause g status 200 media \"image/png\" where i.imageId = g.id;
  } or {
    NotFound from Server to Browser cause g status 404;
  }
}"

/-! `include`, shown on a login that mints `sid` and an order protocol that is given it as `token`. -/

/-- The site's own messages: LoggedIn mints the session id sid, Logout names it again. -/
def siteStructs : String := "structure Login where
  user : String
structure LoggedIn where
  sid : Header (Fresh String)
structure Logout where
  sid : Header (Link String)
"

/-- The order's messages, carrying the session id under `tokenField`. -/
def orderStructs (tokenField : String) : String := s!"structure Create where
  {tokenField} : Header (Link String)
  item : String
structure Made where
  {tokenField} : Header (Link String)
  orderId : Fresh String
"

def includeStructs (tokenField : String) : String := siteStructs ++ orderStructs tokenField

def includeProtocols : String := "protocol Order (Client, Shop) given token {
  c: Create from Client to Shop;
  Made from Shop to Client cause c;
}

protocol Site (Customer, Store) {
  l: Login from Customer to Store;
  LoggedIn from Store to Customer cause l;
  include Order Customer Store with token = sid;
  o: Logout from Customer to Store;
  Bye from Store to Customer cause o;
}"

def pastedProtocol : String := "protocol Site (Customer, Store) {
  l: Login from Customer to Store;
  LoggedIn from Store to Customer cause l;
  c: Create from Customer to Store;
  Made from Store to Customer cause c;
  o: Logout from Customer to Store;
  Bye from Store to Customer cause o;
}"

def main : IO Unit := do
  IO.FS.createDirAll out
  let order ← IO.FS.readFile "examples/sessions/PlaceOrder.leanfm"
  let leanfm ← IO.FS.readFile "LeanFM/LLMGenerated/LeanFM.leanfm"
  let goserver ← IO.FS.readFile "projects/GoServer/source/cmd/demo/static/session/goserver.leanfm"

  /- Part I: the language -/
  -- include: the same protocol written with include and with Order's body pasted in place
  let withInclude := includeStructs "token" ++ "\n" ++ includeProtocols
  let pasted := includeStructs "sid" ++ "\n" ++ pastedProtocol
  -- the listings show the checked text: every field the protocols name is declared in it
  write "ctl-include.tex" (listing withInclude)
  write "ctl-include-pasted.tex" (listing pasted)
  for theme in ["light", "dark"] do
    let d ← tool "session_diagram" (diagram (withLean withInclude [("theme", Json.str theme)]))
    write s!"ctl-include-{theme}.svg" (str d "svg")
  let incF ← tool "session_ctl" (ctl (withLean withInclude [("faithful", Json.mkObj [("lean", Json.str pasted)])]))
  write "ctl-include-faithful.tex" (listing (str incF "reading"))
  write "ctl-images.tex" (listing images)
  write "ctl-placeorder.tex" (listing order)
  for theme in ["light", "dark"] do
    for (name, text) in [("images", images), ("placeorder", order)] do
      let d ← tool "session_diagram" (diagram (withLean text [("theme", Json.str theme)]))
      write s!"ctl-{name}-{theme}.svg" (str d "svg")
  let c ← tool "session_check" (check (withLean order))
  let proj := c.getObjValD "projections"
  write "ctl-placeorder-locals.tex" (listing ("\n\n".intercalate (["Client", "Shop", "Bank"].map fun r => s!"-- {r}\n" ++ str (proj.getObjValD r) "local")))
  write "ctl-placeorder-check.tex" (listing (str c "reading"))
  -- the standards a protocol already is: the server's HTTP API as OpenAPI, the messages as protobuf
  let imgApi ← tool "session_openapi" (openapi (withLean images [("role", Json.str "Server")]))
  write "ctl-images-openapi.tex" (listing (str imgApi "code"))
  write "ctl-images-openapi-reading.tex" (str imgApi "reading")
  let orderTypes ← tool "session_types" (types (withLean order))
  write "ctl-placeorder-proto.tex" (listing (str orderTypes "proto"))
  let race := "protocol Race (Client, Shop) {\n  choice {\n    Cancel from Client to Shop;\n  } or {\n    Ship from Shop to Client;\n  }\n}"
  let blind := "protocol Blind (Client, Shop, Bank) {\n  h: Hold from Client to Bank;\n  choice {\n    Capture from Shop to Bank;\n    Ship from Shop to Client;\n  } or {\n    SoldOut from Shop to Client;\n  }\n}"
  for (name, text) in [("race", race), ("blind", blind)] do
    let r ← tool "session_check" (check (withLean text))
    write s!"ctl-{name}.tex" (listing text)
    write s!"ctl-{name}-issues.tex" (listing ("\n".intercalate (strs r "issues")))
  -- where clauses run on a log: the client pays 12 against a quote of 10
  let wrongAmount := json% [
    {id: "e1", session: "7", «from»: "Client", to: "Shop", label: "CreateOrder"},
    {id: "e2", session: "7", «from»: "Shop", to: "Client", label: "Quote", cause: "e1", fields: {price: 10}},
    {id: "e3", session: "7", «from»: "Client", to: "Shop", label: "Pay", cause: "e2", fields: {amount: 12}}]
  let wf ← tool "session_conform" (conform (withLean order [("events", wrongAmount), ("allowIncomplete", Json.bool true)]))
  write "ctl-where-log.tex" (listing ("\n".intercalate ((match wrongAmount with | .arr a => a.toList | _ => []).map Json.compress)))
  write "ctl-where.tex" (listing (str wf "reading"))
  -- two sessions in one log without session ids: told apart by their causes
  let interleaved := json% [
    {id: "a1", «from»: "Browser", to: "Server", label: "GetImage", fields: {id: "cat"}},
    {id: "b1", «from»: "Browser", to: "Server", label: "GetImage", fields: {id: "dog"}},
    {id: "b2", «from»: "Server", to: "Browser", label: "NotFound", cause: "b1"},
    {id: "a2", «from»: "Server", to: "Browser", label: "Image", cause: "a1", fields: {imageId: "cat"}}]
  let ic ← tool "session_conform" (conform (withLean images [("events", interleaved)]))
  -- a raw body's size against its Content-Length header (selfhost.session.wire-constraints)
  let wrongLength := json% [
    {id: "a1", «from»: "Browser", to: "Server", label: "GetImage", fields: {id: "cat"}},
    {id: "a2", «from»: "Server", to: "Browser", label: "Image", cause: "a1",
     fields: {imageId: "cat", contentLength: "48213", cacheControl: "no-store", size: "48000"}}]
  let wl ← tool "session_conform" (conform (withLean images [("events", wrongLength)]))
  write "ctl-images-size-log.tex" (listing ("\n".intercalate ((match wrongLength with | .arr a => a.toList | _ => []).map Json.compress)))
  write "ctl-images-size.tex" (listing (str wl "reading" ++ "\n" ++ "\n".intercalate (strs wl "issues")))
  write "ctl-interleaved-log.tex" (listing ("\n".intercalate ((match interleaved with | .arr a => a.toList | _ => []).map Json.compress)))
  write "ctl-interleaved.tex" (listing (str ic "reading" ++ "\n\nderived sessions:\n" ++ "\n".intercalate
    ((match (ic.getObjValD "derivedSessions").getObjValD "sessions" with | .arr a => a.toList | _ => []).map fun s => s!"  {str s "key"}: events {(s.getObjValD "events").compress}")))
  -- GoServer: games as sessions of their own, and a seat that joins a person and a game
  let lines := goserver.splitOn "\n"
  let block := fun (name : String) =>
    let from_ := lines.dropWhile (fun l => !l.startsWith s!"protocol {name} ")
    "\n".intercalate ((from_.takeWhile (· != "}")) ++ ["}"])
  -- excerpts of a file the book checks whole say where they are from (selfhost.book.listings)
  let goserverPath := "projects/GoServer/source/cmd/demo/static/session/goserver.leanfm"
  write "ctl-goserver-gamep.tex" (listing (s!"-- from {goserverPath}\n" ++ block "GameP"))
  write "ctl-goserver-seatp.tex" (listing (s!"-- from {goserverPath}\n" ++ block "SeatP"))
  let persons ← IO.FS.readFile "projects/GoServer/events/two-persons.json"
  let personsJ ← IO.ofExcept (Json.parse persons)
  let gc ← tool "session_conform" (conform (withLean goserver [("events", personsJ), ("allowIncomplete", Json.bool true)]))
  let sessions := match (gc.getObjValD "derivedSessions").getObjValD "sessions" with | .arr a => a.toList | _ => []
  write "ctl-goserver-conform.tex" (listing (str gc "reading" ++ "\n\n" ++ "\n".intercalate (sessions.take 12 |>.map fun s =>
    let parents := strs s "parents"
    s!"{str s "key"}: {(match s.getObjValD "events" with | .arr a => a.size | _ => 0)} events" ++
      (if parents.isEmpty then (match s.getObjValD "parent" with | .str p => s!", child of {p}" | _ => "") else s!", joins {", ".intercalate parents}"))))

  /- Part II: the reduction to CTL -/
  let (_, imgT) ← typestatesOf images
  writeDot "ctl-images" imgT
  write "ctl-images-rules.tex" (listing (rulesText imgT))
  let (orderG, orderT) ← typestatesOf order
  writeDot "ctl-placeorder" orderT
  write "ctl-placeorder-rules.tex" (listing (rulesText orderT))
  write "ctl-placeorder-counts.tex" s!"{orderG.size} checker nodes, {orderT.count} typestates, lookahead {orderT.lookahead}"
  -- one construct at a time: what each costs in typestates and lookahead
  let constructs : List (String × String × String) :=
    [ ("sequence", "a request and its answer", "protocol Seq (A, B) {\n  q: Ask from A to B;\n  Answer from B to A cause q;\n}")
    , ("choice", "an answer of two kinds", images)
    , ("loop", "ask again until done", "protocol Poll (A, B) {\n  loop L {\n    choice {\n      q: Ask from A to B;\n      Answer from B to A cause q;\n      continue L;\n    } or {\n      Bye from A to B;\n    }\n  }\n}")
    , ("bounded loop", "at most three tries", "protocol Retry (A, B) {\n  loop Try at most 3 {\n    q: Ask from A to B;\n    choice {\n      Ok from B to A cause q;\n    } or {\n      Busy from B to A cause q;\n      continue Try;\n    }\n  } otherwise {\n    GiveUp from A to B;\n  }\n}")
    , ("parallel", "two independent requests", "protocol Both (A, B, C) {\n  parallel {\n    q: Ask from A to B;\n    Answer from B to A cause q;\n  } and {\n    r: Ask2 from A to C;\n    Answer2 from C to A cause r;\n  }\n}") ]
  let mut crow : Array String := #[]
  for (name, what, text) in constructs do
    let (g, t) ← typestatesOf text
    if name != "choice" then write s!"ctl-construct-{name.replace " " "-"}.tex" (listing text)
    crow := crow.push s!"{name} & {what} & {g.size} & {t.count} & {t.lookahead} & {if t.deterministic then "yes" else "no"} \\\\"
    if name == "parallel" then
      writeDot "ctl-parallel" t
    if name == "bounded loop" then
      writeDot "ctl-retry" t
      -- the name of the start typestate needs lookahead 4: as a tree it is large, as a DAG it is not
      let rs := rules t
      let lines := rs.map fun (n, f) => let d := LeanFM.Logic.Dag.ofFormula f; s!"{n}: {d.treeSize 1000000000} nodes as a tree, {d.size} distinct subformulas"
      write "ctl-retry-sizes.tex" (listing ("\n".intercalate lines))
      let start := LeanFM.Logic.Dag.ofFormula ((rs.headD ("", .tt)).2)
      write "ctl-retry-start.tex" (listing start.toSexprPretty)
      write "ctl-retry-start-english.tex" (listing start.toReadingIndented)
  write "ctl-constructs.tex" ("\\begin{tabular}{@{}llrrrl@{}}\n\\toprule\nConstruct & Example & Nodes & Typestates & Lookahead & Deterministic \\\\\n\\midrule\n" ++ "\n".intercalate crow.toList ++ "\n\\bottomrule\n\\end{tabular}\n")
  -- the protocols LeanFM carries
  let corpus : List (String × String) :=
    [ ("Ping (examples)", "examples/sessions/Ping.leanfm"), ("PlaceOrder (examples)", "examples/sessions/PlaceOrder.leanfm")
    , ("Ride (examples)", "examples/sessions/Ride.leanfm"), ("BoundedRide (examples)", "examples/sessions/BoundedRide.leanfm")
    , ("UserLookup (examples)", "examples/sessions/UserLookup.leanfm"), ("OAuth sign-in", "examples/oauth/SessionType.leanfm")
    , ("LeanFM's own MCP protocol", "LeanFM/LLMGenerated/LeanFM.leanfm"), ("IslandUploads Socket", "reports/ctl-translation/faithful/islanduploads.leanfm")
    , ("Maqam audio period", "projects/Maqam/spec/Maqam.leanfm"), ("GoServer", "projects/GoServer/source/cmd/demo/static/session/goserver.leanfm") ]
  let mut rows : Array String := #[]
  for (name, path) in corpus do
    let text ← IO.FS.readFile path
    let (g, t) ← typestatesOf text
    rows := rows.push s!"{tex name} & {g.size} & {t.count} & {t.lookahead} & {(rules t).length} & {if t.deterministic then "yes" else "no"} \\\\"
  write "ctl-corpus.tex" ("\\begin{tabular}{@{}lrrrrl@{}}\n\\toprule\nProtocol & Nodes & Typestates & Lookahead & Rules & Deterministic \\\\\n\\midrule\n" ++ "\n".intercalate rows.toList ++ "\n\\bottomrule\n\\end{tabular}\n")
  -- faithfulness: a candidate that never answers 404, and the two branches that choose at different steps
  let no404 := images.replace "  choice {\n    i: Image from Server to Browser cause g status 200 media \"image/png\" where i.imageId = g.id;\n  } or {\n    NotFound from Server to Browser cause g status 404;\n  }" "  i: Image from Server to Browser cause g status 200 media \"image/png\" where i.imageId = g.id;"
  let fc ← tool "session_ctl" (ctl (withLean images [("faithful", Json.mkObj [("lean", Json.str no404)])]))
  write "ctl-images-no404.tex" (listing (str fc "reading"))
  let selfc ← tool "session_ctl" (ctl (withLean leanfm [("faithful", Json.mkObj [("lean", Json.str leanfm)])]))
  write "ctl-leanfm-self.tex" (listing (str selfc "reading"))
  let gsm := goserver.replace "SignInRefused from Server to Person cause i status 401;\n      continue SignIn;" "SignInRefused from Server to Person cause i status 401;"
  let gsc ← tool "session_ctl" (ctl (withLean goserver [("faithful", Json.mkObj [("lean", Json.str gsm)])]))
  write "ctl-goserver-mutant.tex" (listing (str gsc "reading"))
  let draftOf := fun (s : String) => (Json.parse s).toOption.getD Json.null
  let two := draftOf "{\"id\": \"x\", \"states\": [\"s0\", \"s1\", \"s2\", \"s3\"], \"initial\": \"s0\", \"terminals\": [\"s3\"], \"transitions\": [{\"src\": \"s0\", \"dst\": \"s1\", \"message\": \"a\"}, {\"src\": \"s0\", \"dst\": \"s2\", \"message\": \"a\"}, {\"src\": \"s1\", \"dst\": \"s3\", \"message\": \"b\"}, {\"src\": \"s2\", \"dst\": \"s3\", \"message\": \"c\"}]}"
  let one := draftOf "{\"id\": \"y\", \"states\": [\"t0\", \"t1\", \"t3\"], \"initial\": \"t0\", \"terminals\": [\"t3\"], \"transitions\": [{\"src\": \"t0\", \"dst\": \"t1\", \"message\": \"a\"}, {\"src\": \"t1\", \"dst\": \"t3\", \"message\": \"b\"}, {\"src\": \"t1\", \"dst\": \"t3\", \"message\": \"c\"}]}"
  let vt := compare ((modelOfDraft two).toOption.getD default) ((modelOfDraft one).toOption.getD default)
  write "ctl-branching.tex" (listing s!"faithful: {vt.faithful}\nmethod: {vt.method}\npath: {vt.path}\nprotocol next: {vt.protocolNext}\ncandidate next: {vt.candidateNext}\nnote: {vt.note}")

  /- Part III: the MCP server -/
  let imgCheckArgs := withLean images
  write "ctl-mcp-check.tex" (transcript "session_check" (Json.mkObj [("lean", Json.str "protocol Images (Browser, Server) { ... }")])
    (← tool "session_check" (check imgCheckArgs)) ["verdict", "reading", "issues"])
  let sexpr := "(always (implies (on GetImage) (inevitably (or (on Image) (on NotFound)))))"
  write "ctl-mcp-ctl.tex" (transcript "session_ctl" (Json.mkObj [("lean", Json.str "protocol Images ..."), ("formula", Json.str sexpr)])
    (← tool "session_ctl" (ctl (withLean images [("formula", Json.str sexpr)]))) ["verdict", "notation", "reading", "report", "states"])
  let bad := "(not (someUntil (not (on GetImage)) (on NotFound)))"
  write "ctl-mcp-ctl-order.tex" (transcript "session_ctl" (Json.mkObj [("lean", Json.str "protocol Images ..."), ("formula", Json.str bad)])
    (← tool "session_ctl" (ctl (withLean images [("formula", Json.str bad)]))) ["verdict", "notation", "report"])
  let ev := "(always (implies (on GetImage) (possibly (on NotFound))))"
  let disp ← tool "session_ctl" (ctl (withLean images [("formula", Json.str "(always (implies (on GetImage) (allNext (on Image))))")]))
  write "ctl-mcp-ctl-disproved.tex" (transcript "session_ctl" (Json.mkObj [("lean", Json.str "protocol Images ..."), ("formula", Json.str "(always (implies (on GetImage) (allNext (on Image))))")])
    disp ["verdict", "notation", "report"])
  let _ := ev
  let sug ← tool "session_ctl" (ctl (withLean order))
  let sugRows := (match sug.getObjValD "suggestions" with | .arr a => a.toList | _ => []).map fun s =>
    s!"{str s "verdict"}: {str s "name"}\n  {str s "notation"}"
  write "ctl-mcp-suggest.tex" (listing (str sug "reading" ++ "\n\n" ++ "\n\n".intercalate sugRows))
  let rulesAns ← tool "session_ctl" (ctl (withLean images [("faithful", Json.str "rules")]))
  write "ctl-mcp-rules.tex" (transcript "session_ctl" (Json.mkObj [("lean", Json.str "protocol Images ..."), ("faithful", Json.str "rules")])
    rulesAns ["verdict", "typestates", "lookahead", "deterministic", "ruleCount", "rules"] 400)
  write "ctl-mcp-faithful.tex" (transcript "session_ctl" (Json.mkObj [("lean", Json.str "protocol Images ..."), ("faithful", Json.mkObj [("lean", Json.str "protocol Images ... (no NotFound branch)")])])
    fc ["verdict", "method", "path", "protocolNext", "candidateNext", "reading"] 300)
  -- limits: a warning, not a wall (selfhost.mcp.limits), through the MCP dispatcher as a client calls it
  let viaMcp := fun (args : Json) => do
    let r ← LeanFM.MCP.dispatchJson (Json.mkObj [("jsonrpc", Json.str "2.0"), ("id", toJson (1 : Nat)), ("method", Json.str "tools/call"),
      ("params", Json.mkObj [("name", Json.str "session_ctl"), ("arguments", args)])])
    let j ← IO.ofExcept (Json.parse r.body)
    pure ((j.getObjValD "result").getObjValD "structuredContent")
  let everyEnd := Json.mkObj [("inevitably", Json.str "stop")]
  let lowArgs := Json.mkObj [("lean", Json.str "protocol PlaceOrder ..."), ("formula", everyEnd), ("limits", Json.mkObj [("states", toJson (5 : Nat))])]
  let low ← viaMcp ((withLean order [("formula", everyEnd), ("limits", Json.mkObj [("states", toJson (5 : Nat))])]))
  let highArgs := Json.mkObj [("lean", Json.str "protocol PlaceOrder ..."), ("formula", everyEnd), ("limits", Json.mkObj [("states", toJson (40000 : Nat))])]
  let high ← viaMcp ((withLean order [("formula", everyEnd), ("limits", Json.mkObj [("states", toJson (40000 : Nat))])]))
  write "ctl-mcp-limits-low.tex" (transcript "session_ctl" lowArgs low ["verdict", "reason"] 400)
  write "ctl-mcp-limits-high.tex" (transcript "session_ctl" highArgs high ["verdict", "limitsApplied"] 300)
  let nx ← tool "session_next" (next (withLean order [("events", json% [{id: "e1", «from»: "Client", to: "Shop", label: "CreateOrder"}])]))
  write "ctl-mcp-next.tex" (transcript "session_next" (Json.mkObj [("lean", Json.str "protocol PlaceOrder ..."), ("events", json% [{id: "e1", «from»: "Client", to: "Shop", label: "CreateOrder"}])])
    nx ["verdict", "reading", "next", "mayEnd"])
  let loopy := draftOf "{\"id\": \"loopy\", \"states\": [\"s0\", \"s1\", \"s2\"], \"initial\": \"s0\", \"terminals\": [\"s2\"], \"transitions\": [{\"src\": \"s0\", \"dst\": \"s1\", \"message\": \"a\"}, {\"src\": \"s1\", \"dst\": \"s0\", \"message\": \"b\"}, {\"src\": \"s1\", \"dst\": \"s2\", \"message\": \"c\"}]}"
  let shared := "(and #1=(possibly (on c)) (always (implies (on a) #1#)))"
  let cc ← tool "check_ctl" ((LeanFM.Logic.run "check_ctl" (Json.mkObj [("task", loopy), ("formula", Json.str shared)])).getD (.error "no tool"))
  write "ctl-mcp-checkctl.tex" (transcript "check_ctl" (Json.mkObj [("task", loopy), ("formula", Json.str shared)]) cc ["verdict", "notation", "reading", "reachableNodes"])
  write "ctl-mcp-conform.tex" (transcript "session_conform" (Json.mkObj [("lean", Json.str "protocol Images ..."), ("events", interleaved)])
    ic ["verdict", "reading", "derivedSessions"] 200)
  let api ← tool "session_openapi" (openapi (withLean images [("role", "Server")]))
  write "ctl-mcp-openapi.tex" (transcript "session_openapi" (Json.mkObj [("lean", Json.str "protocol Images ..."), ("role", Json.str "Server")])
    (api.setObjVal! "code" (Json.str ("\n".intercalate ((((str api "code").splitOn "\n").take 6) ++ ["..."])))) ["verdict", "reading", "language", "unrouted", "code"] 400)
  -- every tool the server lists
  let rowsT := LeanFM.MCP.tools.toList.map fun t =>
    let req := match (t.getObjValD "inputSchema").getObjValD "required" with
      | .arr a => a.toList.filterMap fun (x : Json) => x.getStr?.toOption | _ => []
    let args := match (t.getObjValD "inputSchema").getObjValD "properties" with
      | .obj kvs => kvs.toList.map fun (k, _) => if req.contains k then k ++ "*" else k | _ => []
    s!"\\texttt\{{(tex (str t "name")).replace "\\_" "\\_\\allowbreak{}"}} & {tex (str t "title")} & \\texttt\{{tex (", ".intercalate args)}} \\\\"
  write "ctl-mcp-tools.tex" ("\n".intercalate (["{\\footnotesize\\begin{tabular}{@{}p{.25\\textwidth}p{.33\\textwidth}p{.36\\textwidth}@{}}",
    "\\toprule", "Tool & What it does & Arguments (* required) \\\\", "\\midrule"] ++ rowsT ++ ["\\bottomrule", "\\end{tabular}}"]) ++ "\n")
  write "ctl-provenance.txt" <| "\n".intercalate
    [ "prompt: completely rewrite the book: a much deeper focus on multiparty session types, reducing them to pure CTL, easily diagrammed, with proofs; less repetition; deep on the protocol language, how it reduces to CTL and fits with where clauses; detailed examples of the MCP server."
    , "question: what does a LeanFM protocol say, what CTL does it reduce to, and how does an agent use the MCP server to ask?"
    , "eventSource: examples/sessions/*.leanfm, LeanFM/LLMGenerated/LeanFM.leanfm, projects/GoServer (protocol and events/two-persons.json), reports/ctl-translation/faithful/islanduploads.leanfm, projects/Maqam/spec/Maqam.leanfm, and the small protocols and logs written in CtlBookExample.lean"
    , "reducer: LeanFM.SessionTools (check, diagram, conform, ctl with formula and faithful, next, openapi), LeanFM.Logic (check_ctl), LeanFM.Session.Faithful (typestates, rules, compare)"
    , "unit: checker nodes, typestates (bisimulation classes), rounds of refinement (lookahead), rules, events"
    , "boundary: one session of each protocol"
    , "generator: CtlBookExample.lean, then scripts/svg_to_pdf.py for the diagrams" ] ++ "\n"
  IO.println s!"wrote {out}ctl-*: PlaceOrder {orderT.count} typestates; GoServer conform {str gc "verdict"}; images vs no404 {str fc "verdict"}"

end CtlBookExample

def main : IO Unit := CtlBookExample.main
