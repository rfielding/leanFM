import Lean
import LeanFM.Artifacts
import LeanFM.LLMGenerated.Requirements
import LeanFM.LLMGenerated.Implementation
import LeanFM.Logic
import LeanFM.MCPView
import LeanFM.SessionView
import LeanFM.SessionTools

namespace LeanFM.MCP

open Lean

structure Response where
  status : Nat
  body : String
  deriving Repr

def protocolVersion := "2025-06-18"

def instructions : String :=
  "LeanFM's book is durable agent context, not optional human documentation. " ++
  "Before requirements, design, or implementation work, read leanfm://project/book/main.pdf, " ++
  "leanfm://project/specification/SelfHosting.lean (LeanFM's own requirements), " ++
  "leanfm://project/specification/Requirements.lean (the registry), leanfm://project/specification/Requirements.proto, " ++
  "and leanfm://project/specification/Implementation.lean. Treat the book like a maintained portion " ++
  "of the system prompt. Work in order: observable requirements and their derived views, then the " ++
  "traceable implementation specification, then source, checking each layer before the next. Review " ++
  "and acceptance happen in git: LeanFM records no approvals, so do not stop to ask for one. The MCP " ++
  "surface is read-only: it supplies canonical context and deterministic checks. " ++
  "Before writing temporal properties, event sequences or requirements over hidden state, consult the logic " ++
  "tools (explain_formula, check_ctl, check_trace, classify_requirement) described by leanfm://language/logic-reference. " ++
  "For interactions between roles (services, clients, actors, APIs), design a session type and check it with " ++
  "session_check, draw it with session_diagram, animate it with session_simulate and check run logs with session_conform, generate code to implement it with session_skeleton, writing the protocol in " ++
  "LeanFM protocol syntax as the lean argument (leanfm://language/session-reference). Show people the diagrams and streams these tools " ++
  "generate rather than drawing interaction diagrams by hand."

def ok (id result : Json) : Response :=
  { status := 200
  , body := (Json.mkObj [("jsonrpc", "2.0"), ("id", id), ("result", result)]).compress }

def rpcError (id : Json) (code : Int) (message : String) (status := 200) : Response :=
  { status
  , body := (Json.mkObj
      [("jsonrpc", "2.0"), ("id", id),
       ("error", Json.mkObj [("code", code), ("message", message)])]).compress }

def textContent (value : String) : Json :=
  Json.mkObj [("content", Json.arr #[Json.mkObj [("type", "text"), ("text", value)]])]

def resource (uri name title description mimeType : String) : Json :=
  Json.mkObj [("uri", uri), ("name", name), ("title", title),
    ("description", description), ("mimeType", mimeType)]

def resources : Array Json := #[
  resource "leanfm://project/book/main.pdf" "book" "LeanFM Software Engineering"
    "The central project book and durable agent context." "application/pdf",
  resource "leanfm://project/book/main-dark.pdf" "book-dark" "LeanFM Software Engineering (dark)"
    "Accessible dark rendering of the same central project book." "application/pdf",
  resource "leanfm://project/specification/Requirements.lean" "requirements"
    "Requirements registry" "The component registry: selfHostingRequirement (LeanFM itself, from SelfHosting.lean), the accepted components, and the preserved Worker example." "text/plain",
  resource "leanfm://project/specification/SelfHosting.lean" "self-hosting-requirements"
    "LeanFM's own requirements" "Every clause LeanFM is held to: MCP context, transport and hosting, the logic tools and their view, the session-type library, and the proposed workflow." "text/plain",
  resource "leanfm://project/specification/McpLogicImplementation.lean" "mcp-logic-implementation"
    "MCP and logic implementation mapping" "How each MCP, hosting and logic clause is implemented and tested." "text/plain",
  resource "leanfm://project/specification/SessionImplementation.lean" "session-implementation"
    "Session-type library implementation mapping" "How each selfhost.session clause is implemented and tested." "text/plain",
  resource "leanfm://project/specification/Requirements.proto" "requirements-proto"
    "Canonical protobuf schema" "Byte-level message schema paired with the requirements." "text/x-protobuf",
  resource "leanfm://project/specification/Implementation.lean" "implementation"
    "Canonical implementation specification" "Traceable implementation choices, mappings, and checks." "text/plain",
  resource "leanfm://language/requirements-reference" "requirements-reference"
    "LeanFM requirements language reference" "Live constructors and rules; do not guess these from memory." "text/markdown",
  resource "leanfm://language/implementation-reference" "implementation-reference"
    "LeanFM implementation language reference" "Live implementation and traceability constructors." "text/markdown",
  resource "leanfm://language/logic-reference" "logic-reference"
    "LeanFM logic reference" "JSON formula grammar, operator readings, verdicts, evidence and terminal convention for the logic tools." "text/markdown",
  resource "leanfm://language/session-reference" "session-reference"
    "LeanFM session types" "How to write a protocol in LeanFM protocol syntax for session_check, session_diagram and session_simulate: an example, the statements, limits, how to read the answers, and the JSON alternative." "text/markdown",
  resource sessionViewUri "session-view" "LeanFM session view"
    "Interactive view of session_check, session_diagram and session_simulate results: the generated diagram, typestate, calls and the animated event stream (MCP Apps)." logicViewMimeType,
  resource logicViewUri "logic-view" "LeanFM logic view"
    "Interactive view of check_protocol, check_ctl, check_reassembly and knows results (MCP Apps)." logicViewMimeType
]

private def alphabet : Array Char :=
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".toList.toArray

private def base64 (bytes : ByteArray) : String :=
  Id.run do
    -- The central PDF is megabytes, so recursion per three bytes overflows
    -- the server stack. Keep encoding iterative and avoid byte/character lists.
    let mut encoded := ""
    let mut index := 0
    while index < bytes.size do
      let a := bytes[index]!.toNat
      let b := if index + 1 < bytes.size then bytes[index + 1]!.toNat else 0
      let c := if index + 2 < bytes.size then bytes[index + 2]!.toNat else 0
      encoded := encoded.push alphabet[(a >>> 2)]!
      encoded := encoded.push alphabet[(((a &&& 3) <<< 4) ||| (b >>> 4))]!
      encoded := encoded.push (if index + 1 < bytes.size then alphabet[(((b &&& 15) <<< 2) ||| (c >>> 6))]! else '=')
      encoded := encoded.push (if index + 2 < bytes.size then alphabet[(c &&& 63)]! else '=')
      index := index + 3
    return encoded

private def readText (path : String) : IO String := IO.FS.readFile path
private def readBlob (path : String) : IO String := base64 <$> IO.FS.readBinFile path

def resourceContents (uri : String) : IO (Except String Json) := do
  try
    let contents ← match uri with
      | "leanfm://project/book/main.pdf" =>
          pure <| Json.mkObj [("uri", uri), ("mimeType", "application/pdf"),
            ("blob", ← readBlob "book/main.pdf")]
      | "leanfm://project/book/main-dark.pdf" =>
          pure <| Json.mkObj [("uri", uri), ("mimeType", "application/pdf"),
            ("blob", ← readBlob "book/main-dark.pdf")]
      | "leanfm://project/specification/Requirements.lean" =>
          pure <| Json.mkObj [("uri", uri), ("mimeType", "text/plain"),
            ("text", ← readText "LeanFM/LLMGenerated/Requirements.lean")]
      | "leanfm://project/specification/SelfHosting.lean" =>
          pure <| Json.mkObj [("uri", uri), ("mimeType", "text/plain"),
            ("text", ← readText "LeanFM/LLMGenerated/SelfHosting.lean")]
      | "leanfm://project/specification/McpLogicImplementation.lean" =>
          pure <| Json.mkObj [("uri", uri), ("mimeType", "text/plain"),
            ("text", ← readText "LeanFM/LLMGenerated/McpLogicImplementation.lean")]
      | "leanfm://project/specification/SessionImplementation.lean" =>
          pure <| Json.mkObj [("uri", uri), ("mimeType", "text/plain"),
            ("text", ← readText "LeanFM/LLMGenerated/SessionImplementation.lean")]
      | "leanfm://project/specification/Requirements.proto" =>
          pure <| Json.mkObj [("uri", uri), ("mimeType", "text/x-protobuf"),
            ("text", ← readText "LeanFM/LLMGenerated/Requirements.proto")]
      | "leanfm://project/specification/Implementation.lean" =>
          pure <| Json.mkObj [("uri", uri), ("mimeType", "text/plain"),
            ("text", ← readText "LeanFM/LLMGenerated/Implementation.lean")]
      | "leanfm://language/requirements-reference" =>
          pure <| Json.mkObj [("uri", uri), ("mimeType", "text/markdown"),
            ("text", LeanFM.leanFMRequirementsReference)]
      | "leanfm://language/implementation-reference" =>
          pure <| Json.mkObj [("uri", uri), ("mimeType", "text/markdown"),
            ("text", LeanFM.leanFMImplementationReference)]
      | "leanfm://language/logic-reference" =>
          pure <| Json.mkObj [("uri", uri), ("mimeType", "text/markdown"),
            ("text", LeanFM.Logic.reference)]
      | "leanfm://language/session-reference" =>
          pure <| Json.mkObj [("uri", uri), ("mimeType", "text/markdown"),
            ("text", LeanFM.SessionTools.reference)]
      | "ui://leanfm/session-view" =>
          pure <| Json.mkObj [("uri", uri), ("mimeType", logicViewMimeType),
            ("text", sessionViewHtml), ("_meta", logicViewResourceMeta)]
      | "ui://leanfm/logic-view" =>
          pure <| Json.mkObj [("uri", uri), ("mimeType", logicViewMimeType),
            ("text", logicViewHtml), ("_meta", logicViewResourceMeta)]
      | _ => return .error s!"unknown resource URI: {uri}"
    return .ok contents
  catch err => return .error s!"resource unavailable: {err}"

def noArguments : Json :=
  Json.mkObj [("type", "object"), ("properties", Json.mkObj []), ("additionalProperties", false)]

def tool (name title description : String) (inputSchema : Json := noArguments) : Json :=
  Json.mkObj [("name", name), ("title", title), ("description", description),
    ("inputSchema", inputSchema),
    ("annotations", Json.mkObj [("readOnlyHint", true), ("destructiveHint", false),
      ("idempotentHint", true), ("openWorldHint", false)])]

def stringSchema (description : String) : Json :=
  Json.mkObj [("type", "string"), ("description", description)]

def anyJson (description : String) : Json :=
  Json.mkObj [("description", description)]

def schema (properties : List (String × Json)) (required : List String) : Json :=
  Json.mkObj [("type", "object"), ("properties", Json.mkObj properties),
    ("required", Json.arr (required.map Json.str).toArray), ("additionalProperties", false)]

def toolDefinitions : Array Json := #[
  tool "validate_generated_artifacts" "Validate generated artifacts"
    "Run the deterministic in-memory validations for the canonical requirements and implementation specifications.",
  tool "requirements_interrogation" "Read requirements interrogation"
    "Return the internal requirements completeness checklist. The agent resolves reversible defaults; this is not a questionnaire for the user.",
  tool "code_generation_prompt" "Read one-shot implementation prompt"
    "Return the canonical prompt that maps the book and checked specifications to source changes.",
  tool "explain_formula" "Explain a CTL formula"
    "Read a JSON CTL formula back in English with its negation, mode, unknown atoms and lints (vacuity, AF AG vs AG AF, quantifier mismatch with an optional sentence). Read leanfm://language/logic-reference first."
    (schema [("formula", anyJson "JSON formula"), ("task", anyJson "optional canonical task id or inline draft"),
      ("sentence", stringSchema "optional English requirement the formula is meant to state")] ["formula"]),
  tool "check_ctl" "Check a CTL formula against a task"
    "Decide a JSON CTL formula over a canonical task or inline draft. Returns proved, disproved, unknown, unsupported or resource-limit with a witness or counterexample path. A draft may give transitions symbolic terms and declare actors' knowledge; then {knows: {actor, term}} is an atom, decided from what reached the actor on each path."
    (schema [("task", anyJson "canonical task id or inline draft {states, initial, terminals, transitions[{src, dst, message, from?, to?, term?}], knowledge?}"),
      ("formula", anyJson "JSON formula")] ["task", "formula"]),
  tool "check_trace" "Check an event trace and draw it"
    "Check event envelopes (id, prevIds, causeIds, task, src, dst, message) for ids, causality, schemas, concurrency and task acceptance; returns a Mermaid sequence diagram and causal graph."
    (schema [("events", Json.mkObj [("type", "array"), ("items", Json.mkObj [("type", "object")])]),
      ("drafts", Json.mkObj [("type", "array"), ("items", Json.mkObj [("type", "object")])])] ["events"]),
  tool "classify_requirement" "Classify requirement observability"
    "Classify each atom of a formula, or each predicate text, as observable, derived or implementation-only, and propose events that would make hidden predicates testable."
    (schema [("formula", anyJson "JSON formula"), ("predicates", Json.mkObj [("type", "array"), ("items", stringSchema "predicate text")]),
      ("task", anyJson "optional canonical task id or inline draft")] []),
  tool "check_protocol" "Find attacks on a security protocol"
    "Declare honest roles as scripts over message patterns ({choose: {var, values}}, {fresh: var}, {send: {to, message}}, {recv: pattern}, {claim: {name, args}}; patterns are terms with {var: x}), each with an optional number of concurrent sessions (1 to 4; later sessions are named Alice#2, …, and fresh values na#2, …), an attacker {name, knows} who is the network, finite domains for received variables, and one formula, which may use {claimed: \"commit(B, A)\"} and {knows: {actor, term}}. An optional defender {name, protects: [roles], knows: [keys], drop: [patterns], rewrite: [{match, replace}]} sits between the network and the roles it protects: it drops a message when a drop pattern matches any part it can see (it opens a ciphertext only with a key it can build) and rewrites a whole message that matches a rewrite. Returns check_ctl's verdict and evidence over the generated model, and the messages on the returned path: {event: send, from, to, via, term} for an honest send (to is its addressee, via the attacker) and {event: recv, from, to, term} for a delivery. Bounded: each session runs once."
    (schema [("roles", Json.mkObj [("type", "array"), ("items", Json.mkObj [("type", "object")])]),
      ("attacker", anyJson "{name, knows: [terms]}"),
      ("domain", Json.mkObj [("type", "array"), ("items", Json.mkObj [("type", "object")])]),
      ("domains", anyJson "variable name to an array of terms"),
      ("defender", anyJson "optional {name, protects: [role names], knows: [terms], drop: [patterns], rewrite: [{match, replace}]}"),
      ("formula", anyJson "JSON formula")] ["roles", "attacker", "formula"]),
  tool "check_reassembly" "Find stream-reassembly evasions"
    "A defender scans a TCP stream for a signature, and the host behind it reassembles the same stream; the attacker chooses every segment (any offset and length, the signature's bytes or others, repeated with different bytes). Each side keeps the first or the last bytes of an overlap. Returns check_ctl's verdict over every segmentation and, for an evasion, the segments that make it. Defaults: signature EVIL, box first, host last, mode blocking (an IPS resets the stream on a match; passive is an IDS that alerts), formula never claimed delivered(sig) in blocking mode and never (delivered and not alerted) in passive mode. Claims for a formula: alerted(sig), delivered(sig)."
    (schema [("signature", stringSchema "1 to 4 characters, no ."),
      ("box", stringSchema "first or last: the defender's overlap policy"),
      ("host", stringSchema "first or last: the host's overlap policy"),
      ("mode", stringSchema "blocking (IPS) or passive (IDS)"),
      ("formula", anyJson "optional JSON formula over the claims alerted(sig) and delivered(sig)")] []),
  tool "knows" "What an actor can derive"
    "Given event envelopes (id, prevIds, causeIds, src, dst, term), an actor and an event id, take apart every message the actor sent or received in that event's causal past (pairs split; ciphertexts opened with keys it can build) and return the pieces it holds, each with the event that gave it. With a query term, answer proved with the derivation or disproved. Terms: {atom|key|pk|sk: name}, {pair: [a, b]}, {tuple: [a, b, ...]}, {enc: {key, body}}, {hash: t}."
    (schema [("events", Json.mkObj [("type", "array"), ("items", Json.mkObj [("type", "object")])]),
      ("actor", stringSchema "actor"), ("at", stringSchema "event id to ask at"),
      ("initial", Json.mkObj [("type", "array"), ("items", Json.mkObj [("type", "object")])]),
      ("query", anyJson "optional term to decide"),
      ("seesAll", Json.mkObj [("type", "boolean"), ("description", Json.str "the actor sees every channel (a network attacker)")])]
      ["events", "actor", "at"]),
  tool "session_check" "Check a session type"
    "Check a protocol between roles written as a session type in LeanFM protocol syntax, sent as the lean string (read leanfm://language/session-reference; a JSON protocol object is also accepted). Returns ok or the issues (races, roles that cannot tell which branch was taken, causes a sender never saw), each role's local type and typestate API, the calls (request, responses with status, nested calls), and the generated diagram. With mayCall [[caller, callee], ...] every channel is HTTP and calls that break request/response are reported."
    (schema [("lean", stringSchema "LeanFM protocol text: protocol Name (Role, ...) { statements }"),
      ("protocol", anyJson "alternative to lean: {name?, roles, steps} in the JSON form"),
      ("mayCall", Json.mkObj [("type", "array"), ("items", Json.mkObj [("type", "array")])])] []),
  tool "session_diagram" "Draw a session type"
    "Draw a protocol as a UML sequence diagram generated from the session type: alt frames captioned in session-type notation (⊕ the role that selects, & the roles that offer), par and loop frames, dashed responses, activation bars, routes and status codes. Returns SVG text and the shapes the view draws."
    (schema [("lean", stringSchema "LeanFM protocol text"), ("protocol", anyJson "alternative to lean: the JSON form"),
      ("theme", stringSchema "dark (default) or light")] []),
  tool "session_simulate" "Generate an event stream from a session type"
    "Run a protocol with a seed: sessions blocks (or, without one, concurrent copies of the protocol) start instances at staggered times, par branches interleave, choices pick branches. Each event carries prior (what it happened after), cause and answers (the request it responds to). The view animates the stream."
    (schema [("lean", stringSchema "LeanFM protocol text"), ("protocol", anyJson "alternative to lean: the JSON form"),
      ("seed", Json.mkObj [("type", "integer")]), ("instances", Json.mkObj [("type", "integer")]),
      ("spread", Json.mkObj [("type", "integer")]), ("loops", Json.mkObj [("type", "integer")]),
      ("maxEvents", Json.mkObj [("type", "integer")])] []),
  tool "session_conform" "Check a recorded run against a session type"
    "Check events a running program logged ({id, session, from, to, label, cause}, or {id, session, at, label, act: true} for an event; session_simulate's events also work) against the protocol: in every session each event must be allowed at that point, carry the cause the protocol names, and the session must end where the protocol can end (unless allowIncomplete). Returns conforms or violates with the first problem per session and what the protocol allowed instead."
    (schema [("lean", stringSchema "LeanFM protocol text"), ("protocol", anyJson "alternative to lean: the JSON form"),
      ("events", Json.mkObj [("type", "array"), ("items", Json.mkObj [("type", "object")])]),
      ("allowIncomplete", Json.mkObj [("type", "boolean"), ("description", Json.str "sessions still running are not reported")])] ["events"]),
  tool "session_skeleton" "Generate code to implement a session type"
    "Write a self-contained Python or TypeScript module from a protocol: every role's typestate as classes, one per state (in TypeScript a step the state does not allow does not type-check). A method sends only what its state allows, fills in the cause the protocol names, logs the event in session_conform's format and returns the next state; receive accepts only what the state allows; a state used twice raises. Implement the roles by writing only the decisions (which branch, what each message carries) and the transport."
    (schema [("lean", stringSchema "LeanFM protocol text"), ("protocol", anyJson "alternative to lean: the JSON form"),
      ("language", stringSchema "python (default) or typescript")] [])
]

/-- Tool definitions as listed: the logic tools the view draws carry `_meta.ui.resourceUri`. -/
def tools : Array Json := toolDefinitions.map (withSessionView ∘ withLogicView)

/-- The one-line text of a logic tool result: tool, verdict, and the reading or rejection reason, at most
`logicSummaryLimit` characters. The full answer is only in structuredContent. -/
def logicSummaryLimit : Nat := 400

def logicSummary (name : String) (body : Json) : String :=
  let field (k : String) : Option String := (body.getObjValAs? String k).toOption
  let tail := match field "reason", field "reading" with
    | some r, _ => s!": {r}"
    | none, some r => s!": {r}"
    | none, none => ""
  let line := s!"{name} {(field "verdict").getD "answered"}{tail}"
  if line.length ≤ logicSummaryLimit then line else (line.take (logicSummaryLimit - 1)).toString ++ "…"

/-- LogicVerdict or LogicInputRejected, carried as an MCP tool result: a one-line text summary for
people and the whole answer once, as structuredContent. -/
def logicResult (name : String) (outcome : LeanFM.Logic.ToolOutcome) : Json :=
  let (body, isError) := match outcome with
    | .ok json => (json, false)
    | .error reason => (Json.mkObj [("tool", name), ("verdict", "rejected"), ("reason", reason)], true)
  -- generated code is the answer itself, so it goes in the text a model reads, not only in structuredContent
  let text := match body.getObjValAs? String "code" with
    | .ok code =>
      let fence := (body.getObjValAs? String "language").toOption.getD "python"
      logicSummary name body ++ "\n\n```" ++ fence ++ "\n" ++ code ++ "```"
    | .error _ => logicSummary name body
  Json.mkObj [("content", Json.arr #[Json.mkObj [("type", "text"), ("text", text)]]),
    ("structuredContent", body), ("isError", isError)]

def toolResult (name : String) (arguments : Json := Json.mkObj []) : Except String Json :=
  match LeanFM.SessionTools.run name arguments with
  | some outcome => .ok (logicResult name outcome)
  | none =>
  match LeanFM.Logic.run name arguments with
  | some outcome => .ok (logicResult name outcome)
  | none =>
  match name with
  | "validate_generated_artifacts" => .ok <| textContent
      (LeanFM.LLMGenerated.Requirements.validationReport ++
       LeanFM.LLMGenerated.Implementation.validationReport)
  | "requirements_interrogation" => .ok <| textContent LeanFM.requirementsInterrogationChecklist
  | "code_generation_prompt" => .ok <| textContent LeanFM.codeGenerationSystemPrompt
  | _ => .error s!"unknown tool: {name}"

/-- The workflow for building software from a session type, as a prompt Claude Desktop can offer. -/
def sessionDesignPrompt : String :=
  "Help me build software by designing it as a session type with LeanFM, then implementing it.\n\n" ++
  "1. Ask me in a sentence or two what the software does, and name the roles (people, clients, services, " ++
  "workers) that exchange messages. Read leanfm://language/session-reference before writing a protocol.\n" ++
  "2. Write the protocol in LeanFM protocol syntax and call session_check with it as the lean argument. " ++
  "Fix every issue it reports, and explain each fix in one line. For HTTP services pass mayCall.\n" ++
  "3. Show me the result: the view draws the diagram, each role's typestate API and the calls; I can edit " ++
  "the protocol there and LeanFM rechecks it. Then call session_simulate so I can watch many sessions run.\n" ++
  "4. When I agree with the protocol, call session_skeleton for a Python module with each role's typestate " ++
  "as classes, and implement each role with it: its methods send only what each state allows, fill in causes " ++
  "and log every message in session_conform's format, so the code adds only the decisions and the transport. " ++
  "In another language, write a handler per state the same way and log every message as JSON " ++
  "{id, session, from, to, label, cause}, and every event as {id, session, at, label, act: true}.\n" ++
  "5. When I paste a log from running it, call session_conform with the protocol and the events, and fix the " ++
  "code until every session conforms. If the protocol itself was wrong, change the protocol first and " ++
  "recheck it.\n\n" ++
  "Keep the protocol text as the source of truth. Never draw interaction diagrams by hand: show the ones " ++
  "LeanFM generates."

def prompts : Array Json := #[
  Json.mkObj [("name", "design_with_session_types"),
    ("title", "Build software from a session type"),
    ("description", "Design the interactions as a LeanFM session type, check and animate it, implement each role from its typestate, and check run logs against the protocol."),
    ("arguments", Json.arr #[])],
  Json.mkObj [("name", "requirements_interrogation"),
    ("title", "Argue observable requirements"),
    ("description", "Use the book and live language reference to discover durable observable requirements."),
    ("arguments", Json.arr #[])],
  Json.mkObj [("name", "one_shot_implementation"),
    ("title", "Implement an accepted LeanFM specification"),
    ("description", "Use after the requirements and implementation specification check."),
    ("arguments", Json.arr #[])]
]

def promptResult (name : String) : Except String Json := do
  let text ← match name with
    | "requirements_interrogation" => pure LeanFM.requirementsInterrogationChecklist
    | "one_shot_implementation" => pure LeanFM.codeGenerationSystemPrompt
    | "design_with_session_types" => pure sessionDesignPrompt
    | _ => throw s!"unknown prompt: {name}"
  return Json.mkObj [("description", name),
    ("messages", Json.arr #[Json.mkObj [("role", "user"),
      ("content", Json.mkObj [("type", "text"), ("text", text)])]])]

private def field (json : Json) (name : String) : Except String Json := json.getObjVal? name
private def stringField (json : Json) (name : String) : Except String String := do
  (← field json name).getStr?

def dispatchJson (request : Json) : IO Response := do
  let id := (field request "id").toOption.getD Json.null
  let method ← match stringField request "method" with
    | .ok value => pure value
    | .error err => return rpcError id (-32600) err
  let params := (field request "params").toOption.getD (Json.mkObj [])
  match method with
  | "initialize" =>
      pure <| ok id <| Json.mkObj
        [("protocolVersion", protocolVersion),
         ("capabilities", Json.mkObj
           [("tools", Json.mkObj [("listChanged", false)]),
            ("resources", Json.mkObj [("subscribe", false), ("listChanged", false)]),
            ("prompts", Json.mkObj [("listChanged", false)])]),
         ("serverInfo", Json.mkObj [("name", "leanfm"), ("version", "0.1.0")]),
         ("instructions", instructions)]
  | "notifications/initialized" => pure { status := 202, body := "" }
  | "ping" => pure <| ok id (Json.mkObj [])
  | "resources/list" => pure <| ok id <| Json.mkObj [("resources", Json.arr resources)]
  | "resources/read" =>
      match stringField params "uri" with
      | .error err => pure <| rpcError id (-32602) err
      | .ok uri => match ← resourceContents uri with
        | .ok content => pure <| ok id <| Json.mkObj [("contents", Json.arr #[content])]
        | .error err => pure <| rpcError id (-32602) err
  | "tools/list" => pure <| ok id <| Json.mkObj [("tools", Json.arr tools)]
  | "tools/call" =>
      match stringField params "name" with
      | .error err => pure <| rpcError id (-32602) err
      | .ok name => match toolResult name ((field params "arguments").toOption.getD (Json.mkObj [])) with
        | .ok result => pure <| ok id result
        | .error err => pure <| rpcError id (-32602) err
  | "prompts/list" => pure <| ok id <| Json.mkObj [("prompts", Json.arr prompts)]
  | "prompts/get" =>
      match stringField params "name" with
      | .error err => pure <| rpcError id (-32602) err
      | .ok name => match promptResult name with
        | .ok result => pure <| ok id result
        | .error err => pure <| rpcError id (-32602) err
  | _ => pure <| rpcError id (-32601) s!"method not found: {method}"

def dispatch (body : String) : IO Response :=
  match Json.parse body with
  | .error err => pure <| rpcError Json.null (-32700) err 400
  | .ok request => dispatchJson request

end LeanFM.MCP
