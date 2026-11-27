import Lean
import LeanFM.Artifacts
import LeanFM.LLMGenerated.Requirements
import LeanFM.LLMGenerated.Implementation
import LeanFM.Logic
import LeanFM.MCPView
import LeanFM.SessionView
import LeanFM.SessionTools
import LeanFM.CheckMetrics
import LeanFM.ServerLogs
import LeanFM.Launch
import LeanFM.ServerInfo
import LeanFM.ProjectView
import LeanFM.ModelCache

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
  "session_check, draw it with session_diagram, animate it with session_simulate and check run logs with session_conform, show one role's view (its diagram, OpenAPI and payloads) with session_actor, generate a large dataset to see how sessions distribute with session_dataset, browse a protocol's tree of included protocols, branches and roles like a file explorer with session_explore (example goserver is a whole specification to show), generate code to implement it with session_skeleton, writing the protocol in " ++
  "LeanFM protocol syntax as the lean argument (leanfm://language/session-reference). Show people the diagrams and streams these tools " ++
  "generate rather than drawing interaction diagrams by hand. " ++
  "A limit is a warning, not a wall: when an answer says it stopped at a limit (states, logEvents, datasetEvents, formulaNodes and the others " ++
  "listed in each tool's limits argument), and the work is worth the memory and time, call the same tool again with the optional " ++
  "limits argument, for example {\"limits\": {\"states\": 100000}}; it applies to that call only, is capped at the operator's ceiling, " ++
  "and the answer's limitsApplied says what was used. Over HTTP the same limits can be raised for one whole request with the " ++
  "header LeanFM-Limits: name=value, name=value (for example LeanFM-Limits: argumentBytes=1048576, requestBytes=4194304); " ++
  "a name the call's own limits argument gives wins, and only the header can raise requestBytes, since the body is sized before it is read. " ++
  "Sizes are limits too, and each has a way around it: a log larger than argumentBytes is named instead of sent (serverLog, read " ++
  "on the server, with fromLine and lineCount or lastLines to read a window), a project's protocol is named by file, and " ++
  "argumentBytes, textBytes, protoBytes, requestBytes, signalSamples, signalWords and signalPoints are raised like any other limit; " ++
  "a stdio client sends no headers, so it names large data rather than sending it. The limits and their defaults: " ++ LeanFM.CallLimits.listing ++ ". " ++
  "When a LeanFM tool, view or server fails, and server_logs is listed, read the logs with it (no log argument " ++
  "lists them) before asking the user to paste a log."

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
    "Read a CTL formula (JSON, or an s-expression string) back in English with its negation, mode, unknown atoms and lints (vacuity, AF AG vs AG AF, quantifier mismatch with an optional sentence), and write it back as a canonical one-line s-expression (sexpr) and an indented one (sexprPretty), so it also parses and formats a formula, and read it out as indented English (readingIndented, also in check_ctl and session_ctl answers), and unfold it (unfolded): every word (possibly, inevitably, always, someAlways, allNext, someNext, allUntil, someUntil, allUnless, someUnless) and function (outcomes, follows, leadsTo, precedes, stronglyImplies) replaced by the CTL primitives it means. Needs no task. Read leanfm://language/logic-reference first."
    (schema [("formula", anyJson "JSON formula, or an s-expression string such as (AG (implies (on Pay) (AF (on Receipt))))"), ("task", anyJson "optional canonical task id or inline draft"),
      ("sentence", stringSchema "optional English requirement the formula is meant to state")] ["formula"]),
  tool "check_ctl" "Check a CTL formula against a task"
    "Decide a JSON CTL formula over a canonical task or inline draft. Returns proved, disproved, unknown, unsupported or resource-limit with a witness or counterexample path. A draft may give transitions symbolic terms and declare actors' knowledge; then {knows: {actor, term}} is an atom, decided from what reached the actor on each path."
    (schema [("task", anyJson "canonical task id or inline draft {states, initial, terminals, transitions[{src, dst, message, from?, to?, term?}], knowledge?}"),
      ("formula", anyJson "JSON formula, or an s-expression string such as \"(AG (implies (on Ping) (EF stop)))\" with shared parts labelled #1= and reused as #1#")] ["task", "formula"]),
  tool "check_trace" "Check an event trace and draw it"
    "Check event envelopes (id, prevIds, causeIds, task, src, dst, message) for ids, causality, schemas, concurrency and task acceptance; returns a Mermaid sequence diagram and causal graph."
    (schema [("events", Json.mkObj [("type", "array"), ("items", Json.mkObj [("type", "object")])]),
      ("drafts", Json.mkObj [("type", "array"), ("items", Json.mkObj [("type", "object")])])] ["events"]),
  tool "classify_requirement" "Classify requirement observability"
    "Classify each atom of a formula, or each predicate text, as observable, derived or implementation-only, and propose events that would make hidden predicates testable."
    (schema [("formula", anyJson "JSON formula"), ("predicates", Json.mkObj [("type", "array"), ("items", stringSchema "predicate text")]),
      ("task", anyJson "optional canonical task id or inline draft")] []),
  tool "check_protocol" "Find attacks on a security protocol"
    "Declare honest roles as scripts over message patterns ({choose: {var, values}}, {fresh: var}, {send: {to, message}}, {recv: pattern}, {claim: {name, args}}; patterns are terms with {var: x}), each with an optional number of concurrent sessions (1 to 4; later sessions are named Alice#2, ..., and fresh values na#2, ...), an attacker {name, knows} who is the network, finite domains for received variables, and one formula, which may use {claimed: \"commit(B, A)\"} and {knows: {actor, term}}. An optional defender {name, protects: [roles], knows: [keys], drop: [patterns], rewrite: [{match, replace}]} sits between the network and the roles it protects: it drops a message when a drop pattern matches any part it can see (it opens a ciphertext only with a key it can build) and rewrites a whole message that matches a rewrite. Returns check_ctl's verdict and evidence over the generated model, and the messages on the returned path: {event: send, from, to, via, term} for an honest send (to is its addressee, via the attacker) and {event: recv, from, to, term} for a delivery. Bounded: each session runs once. Secrets: an atom or symmetric key named with the suffix _secr (passwd_secr; a hash a server accepts in place of the password is named too, hpasswd_secr) is a question, and naming is the only mark, so knows(Ivo, nb) is refused and knows(Ivo, nb_secr) is the question: does the attacker ever derive it? Each gets kept, leaked (with the path and the wire) or resource-limit, the keys that protect it are named with the step that sends them, and names that look secret but are unmarked come back as warnings. With secrets the formula is optional."
    (schema [("roles", Json.mkObj [("type", "array"), ("items", Json.mkObj [("type", "object")])]),
      ("attacker", anyJson "{name, knows: [terms]}"),
      ("domain", Json.mkObj [("type", "array"), ("items", Json.mkObj [("type", "object")])]),
      ("domains", anyJson "variable name to an array of terms"),
      ("defender", anyJson "optional {name, protects: [role names], knows: [terms], drop: [patterns], rewrite: [{match, replace}]}"),
      ("formula", anyJson "JSON formula; optional when the protocol marks secrets by naming them with _secr, the only mark; a knows atom asks about a name ending in _secr")] ["roles", "attacker"]),
  tool "check_signal" "Check a claim over measured values"
    "Check a claim about measured values over one recorded run (an Arduino's water, food and temperature readings, a webcam's motion level) in time linear in the run. The claim is an s-expression in these words only: (above f c), (below f c), (on M), not, and, or, implies, (within d p) (p at some sample in the next d seconds), (throughout d p) (p at every sample in the next d seconds), always, never, and possibly or inevitably (the same over one run: p now or later). A field's value is its latest reading. Returns holds or fails with the margin (how far from failing, in the readings' units; unbounded when infinite), the first failing sample of an always or never with its readings, the moments whose window was cut short by the end of the run, and series of each field and of the margin for drawing."
    (schema [("claim", stringSchema "an s-expression such as (always (and (above temp 18) (below temp 26)))"),
      ("samples", Json.mkObj [("type", "array"), ("items", Json.mkObj [("type", "object")]), ("description", "[{t: seconds, label?: name, field: number, ...}] in time order")]),
      ("log", stringSchema "event lines instead of samples: each {\"type\":\"leanFM\",...} line's ts (nanoseconds), label and payload numbers"),
      ("serverLog", stringSchema "instead of samples or log: the name of a log server_logs lists (devices is logs/devices.log, for a project's own devices), read on the server, so a log over the 64 KiB a client may send is checked by name"),
      ("fromLine", Json.mkObj [("type", "integer"), ("minimum", 1), ("description", Json.str "with serverLog: the first line to read (default 1)")]),
      ("lineCount", Json.mkObj [("type", "integer"), ("minimum", 1), ("maximum", 100000), ("description", Json.str "with serverLog: how many lines to read")]),
      ("lastLines", Json.mkObj [("type", "integer"), ("minimum", 1), ("maximum", 100000), ("description", Json.str "with serverLog, instead of fromLine and lineCount: the last N lines")]),
      ("from", Json.mkObj [("type", "number"), ("description", Json.str "a time in seconds: check the claim from the first sample at or after it (every field it reads needs a reading by then); needed when the claim's branches would otherwise start at different samples")]),
      ("theme", stringSchema "light or dark: also draw the chart as an SVG")] ["claim"]),
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
    (schema [("lean", stringSchema "LeanFM protocol text: protocol Name (Role, ...) { statements }"), ("proto", stringSchema "optional: the text of the proto3 file that declares the message types"),
      ("overlay", anyJson "optional named layer {name, choices:[{choice, weights:[fraction strings]}], timings:[{message, at: time expression}]} replacing matching inline entries"), ("protocol", anyJson "alternative to lean: {name?, roles, steps} in the JSON form"),
      ("mayCall", Json.mkObj [("type", "array"), ("items", Json.mkObj [("type", "array")])]),
      ("notHttp", Json.mkObj [("type", "array"), ("items", Json.mkObj [("type", "array")]),
        ("description", Json.str "pairs of roles whose messages are not HTTP (a text message, a queue)")])] []),
  tool "session_diagram" "Draw a session type"
    "Draw a protocol as a UML sequence diagram generated from the session type: alt frames naming the role that decides, parallel and loop frames, dashed responses, activation bars, routes and status codes. Returns SVG text and the shapes the view draws."
    (schema [("lean", stringSchema "LeanFM protocol text"), ("model", stringSchema "optional: the model token of an earlier answer about this protocol; send the text too, a token held for it skips rebuilding the state graph"), ("proto", stringSchema "optional: the text of the proto3 file that declares the message types"), ("overlay", anyJson "optional named layer {name, choices:[{choice, weights:[fraction strings]}], timings:[{message, at: time expression}]} replacing matching inline entries"), ("protocol", anyJson "alternative to lean: the JSON form"),
      ("theme", stringSchema "dark (default) or light")] []),
  tool "session_mdp" "Render a session decision process and terminal probabilities"
    "Render a finite sequential session under its inline or external probability policy as a decision tree, with action selections, chance transitions, times and terminal deadline reports. Returns SVG and an interactive MCP Apps view, exact terminal probabilities whose total is checked to equal 1, and violationProbability counting each violating terminal once. Messages with amounts (amount 1000 USD, or amount sample { 1000 USD : 9/10; 700 USD : 1/10; }) and obligations with penalties (on breach record Label pays 2000 USD to Role) give each terminal every role's net balance per unit, and expectedBalances gives each role's exact expected net balance. A session with loops (loop and continue) or rates (accrue { 1000 USD per week; -1 roomweek per week; } from A to B), or view chain, is solved as an absorbing Markov chain instead: expected visits, traversals and time (after 1 week is a delay after the previous step), each outcome's probability and conditional expectations, and each role's expected balance per unit (trade vectors per traversal plus rates in force times time), all exact. With events (an event stream) or walk, it gives the realized rewards of those walks instead. A session with one periodic gate (Rent from Tenant to Landlord amount 1000 USD at next 1 week) and a horizon (52 weeks) gives totals over that many whole periods: a weekly trade that always continues passes exactly 52 times. With optimize ({role, unit, goal: max or min}, unit time for duration), choices without probabilities are open actions and exact policy iteration picks the best branch at each for that role, among policies that end; it returns the policy, every branch's value and the chain solved under it. Zero-probability paths remain. Without optimize, every choice needs weights; unsupported scheduling and output limits fail explicitly."
    (schema [("lean", stringSchema "LeanFM protocol text"), ("proto", stringSchema "optional: the text of the proto3 file that declares the message types"), ("protocol", anyJson "alternative JSON protocol"),
      ("overlay", anyJson "optional external named choice weights and message timings replacing inline entries"),
      ("view", stringSchema "auto (default: chain when the session has loop or accrue, else tree), tree, or chain"),
      ("events", Json.mkObj [("type", "array"), ("items", Json.mkObj [("type", "object")]), ("description", Json.str "an event stream (session_conform's format, with timeMs): realized rewards per session and in total, instead of expectations")]),
      ("optimize", anyJson "optional {role, unit, goal}: the best branch at every choice without probabilities for that role's expected amount in unit (or time), goal max or min"),
      ("horizon", stringSchema "a duration such as 52 weeks: whole periods behind the session's one periodic gate (at next 1 week), whether or not the session ever ends"),
      ("walk", Json.mkObj [("type", "array"), ("items", Json.mkObj [("type", "object")]), ("description", Json.str "one hand-written walk: steps {label, from?, to?, afterMs?}")]),
      ("theme", stringSchema "dark (default) or light")] []),
  tool "session_sla" "Check a session type's service-level requirements"
    "A protocol may end with require per q { ... }: per entry q (a message id of the main protocol), every q reaches A, B within 2 seconds; (a hard deadline: one miss is a counterexample) or at least|at most 99/100 of q reach A within 300 ms over 1 hour [confidence 95/100] [expecting 500 per hour]; (a promised minimum or maximum, judged only over a closed observation window, by time or by entries). Choice probabilities are assumptions about what peers decide; requirements are what is promised. At design time each requirement is checked against the assumptions on the chain: the exact interval of the per-entry probability, met, violated or undecided, the most probable path that breaks it with the assumptions it passes through, and how many entries a window needs to tell the promise apart from a 0 or 1 failure rate. With events, an execution (events keyed by unique ts, linked to earlier events by prev and cause, optionally carrying a full reward vector {role: {unit: amount}} only where it changes) is judged: an entry hits when a target lies in its causal future within the deadline, an entry whose deadline outlives the stream is pending, and each closed window gets an exact binomial verdict; an unclosed window is open. With at (a ts), returns that event's reward (found by walking prev back to the latest vector) and causal past."
    (schema [("lean", stringSchema "LeanFM protocol text with a require per block"), ("proto", stringSchema "optional: the text of the proto3 file that declares the message types"), ("overlay", anyJson "optional named layer replacing inline weights and timings"),
      ("events", Json.mkObj [("type", "array"), ("items", Json.mkObj [("type", "object")]), ("description", Json.str "an execution: {ts, label, from, to, prev?, cause?, reward?}; ts, prev and cause are nanosecond timestamps as decimal strings")]),
      ("at", Json.mkObj [("type", "string"), ("description", Json.str "the ts of an event (nanoseconds, a decimal string) to show its reward vector and causal past")]),
      ("theme", stringSchema "dark (default) or light")] ["lean"]),
  tool "session_simulate" "Generate an event stream from a session type"
    "Run a protocol with a seed: sessions blocks (or, without one, concurrent copies of the protocol) start instances at staggered times, parallel branches interleave, choices pick branches. Each event carries ts (nanoseconds as a decimal string, unique in the stream and later than what it happened after), prior (what it happened after), cause and answers (the request it responds to). The view animates the stream. Inline or external generation layers use finite sequential choices, exact probabilities and session-relative milliseconds; deadlineReports are separate from structural conformance. Timed parallel, recursion, spread and loops are rejected."
    (schema [("lean", stringSchema "LeanFM protocol text"), ("proto", stringSchema "optional: the text of the proto3 file that declares the message types"), ("overlay", anyJson "optional named layer {name, choices:[{choice, weights:[fraction strings]}], timings:[{message, at: time expression}]} replacing matching inline entries"), ("protocol", anyJson "alternative to lean: the JSON form"),
      ("seed", Json.mkObj [("type", "integer")]), ("instances", Json.mkObj [("type", "integer")]),
      ("spread", Json.mkObj [("type", "integer")]), ("loops", Json.mkObj [("type", "integer")]),
      ("maxEvents", Json.mkObj [("type", "integer")])] []),
  tool "session_conform" "Check a recorded run against a session type"
    "Check events a running program logged ({ts or id, session, from, to, label, cause, fields?}, or {ts or id, session, at, label, act: true} for an event; session_simulate's events also work) against the protocol: in every session each event must be allowed at that point, carry the cause the protocol names, and the session must end where the protocol can end (unless allowIncomplete). Returns conforms or violates with the first problem per session and what the protocol allowed instead. Each event's fields must fit its message type, with integers as decimal strings; a sessions block with a key (sessions by a.caller) requires each session's events to name the key's value as their session. With timing annotations, every event needs ts (nanoseconds) or timeMs; horizonMs advances observation of incomplete traces. Deadline reports do not change the structural verdict."
    (schema [("lean", stringSchema "LeanFM protocol text"), ("proto", stringSchema "optional: the text of the proto3 file that declares the message types"), ("overlay", anyJson "optional named layer {name, choices:[{choice, weights:[fraction strings]}], timings:[{message, at: time expression}]} replacing matching inline entries"), ("protocol", anyJson "alternative to lean: the JSON form"),
      ("events", Json.mkObj [("type", "array"), ("items", Json.mkObj [("type", "object")])]),
      ("fromLine", Json.mkObj [("type", "integer"), ("minimum", 1), ("description", Json.str "with log or serverLog: the first line to read, 1-based (default 1); poll a running log by asking from the last answer's nextLine")]),
      ("lineCount", Json.mkObj [("type", "integer"), ("minimum", 1), ("maximum", 100000), ("description", Json.str "with log or serverLog: how many lines to read from fromLine (default to the end)")]),
      ("lastLines", Json.mkObj [("type", "integer"), ("minimum", 1), ("maximum", 100000), ("description", Json.str "with log or serverLog, instead of fromLine and lineCount: read the last N complete lines; the answer's fromLine says where they start")]),
      ("serverLog", stringSchema "instead of events or log: the name of a log server_logs lists (serve is make serve's output), read on the server; its event lines are checked as log's are"),
      ("log", stringSchema "instead of events: the text of a log; its lines that are JSON objects with type leanFM (LeanFM writes them beginning {\"type\":\"leanFM\",) are the events, every other line, JSON or not, is ignored and counted, and a line beginning with that marker that is malformed is refused naming its line number"),
      ("horizonMs", anyJson "optional observation horizon in milliseconds relative to each session"), ("allowIncomplete", Json.mkObj [("type", "boolean"), ("description", Json.str "sessions still running are not reported")])] []),
  tool "session_spans" "Time the calls in a log, without trusting clocks across machines"
    "Given a protocol and a log whose events carry sentAt (the sender's clock when it sent) and receivedAt (the receiver's clock when it received), in nanoseconds as decimal strings, and whose from and to may name actors as Role/instance: every call (a request and the reply that names it as cause) with the caller's view (reply received minus request sent, on the caller's clock) and the callee's own (reply sent minus request received, on its clock); their difference, the network and queueing time of both directions together; the sub-calls the callee made while handling it, which ran concurrently where they overlap on its clock; the critical path, the chain of sub-calls one after another that set the time; and each call tree laid on its root caller's timeline, a callee anchored where its request was sent. No two clocks are ever compared. A callee that took longer than its caller waited, or sub-calls whose own durations along a chain exceed the call that contains them, are reported as inconsistent with both numbers."
    (schema [("lean", stringSchema "LeanFM protocol text"), ("proto", stringSchema "optional: the text of the proto3 file that declares the message types"), ("protocol", anyJson "alternative to lean: the JSON form"),
      ("events", Json.mkObj [("type", "array"), ("items", Json.mkObj [("type", "object")]), ("description", Json.str "{id, session?, from, to, label, cause?, prev?, sentAt?, receivedAt?}; from and to are Role or Role/instance; prev is the previous event the same actor sent")])] ["events"]),
  tool "session_next" "What may happen next in a session"
    "Given a protocol and the events of one session so far (in session_conform's format; none for the start), list every step the protocol allows next, with the event each must give as its cause, and whether the session may stop here. A walk that breaks the protocol answers violates with the first problem."
    (schema [("lean", stringSchema "LeanFM protocol text"), ("proto", stringSchema "optional: the text of the proto3 file that declares the message types"), ("overlay", anyJson "optional named layer {name, choices:[{choice, weights:[fraction strings]}], timings:[{message, at: time expression}]} replacing matching inline entries"), ("protocol", anyJson "alternative to lean: the JSON form"),
      ("events", Json.mkObj [("type", "array"), ("items", Json.mkObj [("type", "object")])])] []),
  tool "session_ctl" "Check a temporal property of a session type"
    "Decide a JSON CTL formula over one session of a protocol: its state graph (the states conformance explores, nested sessions played once) checked by the same checker as check_ctl. {\"on\": \"Label\"} holds in the state a Label message or event has just reached, \"stop\" where the session may stop, {\"secret\": {from?, to?, field?}} where the step just taken carried a field ending in _secr (secrecy is a question a project's protocol tests ask, not a rule every project keeps). Returns proved or disproved with a witness or counterexample path, for example: every request answered before the session ends, {\"AG\": {\"implies\": [{\"on\": \"Order\"}, {\"AU\": [{\"not\": \"stop\"}, {\"or\": [{\"on\": \"Confirmed\"}, {\"on\": \"Refused\"}]}]}]}}; no refund before a charge, {\"not\": {\"EU\": [{\"not\": {\"on\": \"Charge\"}}, {\"on\": \"Refund\"}]}}; never charge after no seat, {\"AG\": {\"implies\": [{\"on\": \"NoSeat\"}, {\"AG\": {\"not\": {\"on\": \"Charge\"}}}]}}; no secret reaches Log, {\"AG\": {\"not\": {\"secret\": {\"to\": \"Log\"}}}}. Without a formula it suggests up to 12 properties built from this protocol (its calls answered, responses only after requests, how it starts, traps, livelock, its secrets), each already decided."
    (schema [("lean", stringSchema "LeanFM protocol text"), ("proto", stringSchema "optional: the text of the proto3 file that declares the message types"), ("overlay", anyJson "optional named layer {name, choices:[{choice, weights:[fraction strings]}], timings:[{message, at: time expression}]} replacing matching inline entries"), ("protocol", anyJson "alternative to lean: the JSON form"),
      ("formula", anyJson "CTL formula over on(label), stop and secret({from?, to?, field?}), as JSON or as an s-expression string such as \"(AG (implies (on Ping) (AX (or (on Pong) (on SlowPong)))))\" whose shared parts may be labelled #1= and reused as #1#; omit it for properties suggested from the protocol, each decided"),
      ("faithful", anyJson "\"rules\" for the protocol's typestates and its faithful CTL (one rule per typestate: each next typestate possible, nothing else); {task: inline draft} or {lean: another protocol text} to decide whether that model is faithful to this protocol (one bisimulation check)")] []),
  tool "session_instances" "Find deadlocks and races between instances of a system"
    "Explore the text's last system block (system Name { instance db : Db serial; accept Order (fresh Client, db); }) with 1 to 4 instances of each accept interleaved: each instance has its own session id and fresh actors (Role/s1, Role/s2, ...) and shares only the instances it was given; a serial instance serves one session at a time. Returns ok, deadlock (each deadlock with the steps that reach it and what each instance waits for, nearest first), isolation (a step of one instance involving another's actor) or disproved, with the number of states and each formula's verdict and path. perInstance formulas are checked for every instance ({\"on\": \"Label\"} is that instance's Label, \"stop\" that it has finished); properties formulas are about the system (any instance's Label; terminal when every instance can end)."
    (schema [("lean", stringSchema "LeanFM protocol text with protocols and a system block"), ("proto", stringSchema "optional: the text of the proto3 file that declares the message types"),
      ("instances", Json.mkObj [("type", "integer"), ("description", Json.str "instances of each accept, 1 to 4 in all (default 2)")]),
      ("perInstance", Json.mkObj [("type", "array"), ("items", Json.mkObj [("type", "object")]), ("description", Json.str "JSON CTL formulas checked for every instance")]),
      ("properties", Json.mkObj [("type", "array"), ("items", Json.mkObj [("type", "object")]), ("description", Json.str "JSON CTL formulas about the whole system")])] ["lean"]),
  tool "session_realizable" "Check what a deployment can actually do"
    ("A protocol says the order its messages should happen in; a deployment can only enforce some of it. Each role runs its own projection " ++
     "and every actor has a FIFO inbox that loses nothing, of the size written where it is named, protocol Shop (Client, Api[8], Bank[2]) " ++
     "(no size: 0, a rendezvous). Answers realizable, or unrealizable with the first problem and the deliveries leading to it: an order the " ++
     "protocol does not allow (unrelated roles cannot be held to the protocol's order), or a deadlock with each role's inbox and what it waits " ++
     "for. Lists the sizes and guarantees assumed. Roles that run parallel branches or serve sessions are refused for now. The protocol's text " ++
     "stays the specification: no other tool's answer depends on inbox sizes.")
    (schema [("lean", stringSchema "LeanFM protocol text; roles may carry inbox sizes, Api[8]")] ["lean"]),
  tool "session_deployment" "Check where a protocol's roles run"
    "Read the text's last deployment block (deployment Production of P { outside { Client; } island us { machine m1 { Api { ingress https : ingressHttps; } } } }), or the one named by deployment, and check it against protocol P: every role placed once, and every message arriving on an interface of its receiver that its sender can reach (ingress: anyone; peering: any island; internal: the same island; local: the same machine; a role with no interfaces is unrestricted). Answers placed or refused, each role's groups and interfaces, each link with the interface it uses and the conditions its kind and placement add (hostile, partition, reject, per-key order), every issue, and an SVG of the tree with its links. A deployment adds no message to P."
    (schema [("lean", stringSchema "LeanFM protocol text with a protocol and a deployment block after it"),
      ("deployment", stringSchema "optional: the name of the deployment to check (default: the last)"),
      ("theme", stringSchema "dark (default) or light")] ["lean"]),
  tool "session_review" "Review a session type design"
    "Run every check that applies to a protocol and answer findings, each with an edit to try: the core rules (one decider per choice, every role can tell the branch, causes it saw); HTTP wherever a message has a route (no flags needed), including requests that never get a response and responses without a status; sessions that can never end; roles that take no part. Use it after every change while designing; clean means nothing was found."
    (schema [("lean", stringSchema "LeanFM protocol text"), ("proto", stringSchema "optional: the text of the proto3 file that declares the message types"), ("overlay", anyJson "optional named layer {name, choices:[{choice, weights:[fraction strings]}], timings:[{message, at: time expression}]} replacing matching inline entries"), ("protocol", anyJson "alternative to lean: the JSON form")] []),
  tool "session_openapi" "A role's HTTP interface as OpenAPI"
    "Write the requests a role receives, with their routes (route \"POST /orders\") and the responses the protocol allows (with their status), as an OpenAPI 3.1 document: one operation per route, the request's label as operationId and request body, each response under its status. Each body's schema is its message type (the structure its label names), admitting no other fields. A server framework or client generator can start from it."
    (schema [("lean", stringSchema "LeanFM protocol text"), ("proto", stringSchema "optional: the text of the proto3 file that declares the message types"), ("overlay", anyJson "optional named layer {name, choices:[{choice, weights:[fraction strings]}], timings:[{message, at: time expression}]} replacing matching inline entries"), ("protocol", anyJson "alternative to lean: the JSON form"),
      ("role", stringSchema "the role whose interface to write")] ["role"]),
  tool "session_types" "The message types as protobuf, Lean and JSON schema"
    "Write the protocol's message types (from proto, the text of a proto3 file, or from structures declared before the protocols) as a proto3 file with the Event envelope, as Lean structures, and as one JSON schema per message; and the whole session as one Lean module (leanModule): the payload types, the roles, the payload and Event types, and each role's states with start, step, final and accepts. A label with no message is an empty one."
    (schema [("lean", stringSchema "LeanFM protocol text"), ("proto", stringSchema "optional: the text of the proto3 file that declares the message types"), ("protocol", anyJson "alternative to lean: the JSON form")] []),
  tool "session_compat" "Which roles can upgrade on their own"
    "Compare two versions of a protocol (lean: the new one, old: the previous one). For each role in both, answer whether its new version can be deployed first, running with the old version of every other role, and whether its old version can stay deployed after the others upgrade, by exploring each mixed system to every reachable state. A no comes with the steps to the stuck state and what each role still expects. It also names a clean upgrade path: an order to upgrade the roles one at a time with every mixed deployment on the way checked, or why there is none."
    (schema [("lean", stringSchema "the new version: LeanFM protocol text"), ("proto", stringSchema "optional: the text of the proto3 file that declares the message types"), ("old", stringSchema "the previous version: LeanFM protocol text; optional when lean keeps two versions (protocol Name (...) version 1 { ... } then version 2)"),
      ("overlay", anyJson "optional named layer {name, choices:[{choice, weights:[fraction strings]}], timings:[{message, at: time expression}]} replacing matching inline entries"), ("protocol", anyJson "alternative to lean: the JSON form")] []),
  tool "session_actor" "A protocol as one role sees it"
    "Project a protocol onto one role: its local type and typestate, a sequence diagram of only the steps the role takes part in (its lifeline and its peers'), its messages (sends, receives or its own event, each with peer, route, status and payload field number), the HTTP interface it serves as OpenAPI (JSON and YAML), the routes it calls on others, and the whole protocol's proto file, whose payload numbers the role's messages keep. Every check still runs on the whole protocol; the role's diagram is for reading."
    (schema [("lean", stringSchema "LeanFM protocol text"), ("proto", stringSchema "optional: the text of the proto3 file that declares the message types"), ("overlay", anyJson "optional named layer {name, choices:[{choice, weights:[fraction strings]}], timings:[{message, at: time expression}]} replacing matching inline entries"), ("protocol", anyJson "alternative to lean: the JSON form"),
      ("role", stringSchema "the role to project onto"), ("theme", stringSchema "dark (default) or light")] ["role"]),
  tool "session_dataset" "Generate many sessions and summarize them"
    "Generate a large dataset of sessions from a protocol (default 1000, at most 10000 sessions and 1000000 events) and answer how it is distributed: the paths taken with their counts (top 12; the rest counted), each message with how many sessions contain it, messages sent and received per role, and histograms of events per session and of duration. When almost every session interleaves its parallel branches in its own order, the answer says to compare messages rather than paths. With a probability layer (weights on choices, loops, rates) sessions follow its exact weights and durations are in ms; without one, each walk takes one allowed step or the end, equally likely, and the answer says these frequencies describe the walker, not the system. Sessions cut at 600 events or stuck are counted, never reported as ended. Use it to see whether a protocol fits its requirements at volume: which paths dominate, which messages are rare, which role carries the load."
    (schema [("lean", stringSchema "LeanFM protocol text"), ("proto", stringSchema "optional: the text of the proto3 file that declares the message types"), ("overlay", anyJson "optional named layer {name, choices:[{choice, weights:[fraction strings]}], timings:[{message, at: time expression}]} replacing matching inline entries"), ("protocol", anyJson "alternative to lean: the JSON form"),
      ("sessions", Json.mkObj [("type", "integer"), ("description", Json.str "sessions to generate, 1 to 10000 (default 1000)")]),
      ("seed", Json.mkObj [("type", "integer")])] []),
  tool "session_explore" "Browse a protocol as a tree"
    "Answer a protocol as a tree to browse, listed by the view like a file explorer, folded at the start: the main protocol's structure (each included protocol as a node with its own lines, choices naming the role that decides, their branches, parallel branches, loops, independent sessions, messages and events), the roles (open one for its view) and every protocol the text defines, each node with the lines of the text it comes from. Click a row to see it, click its arrow or double click to open it; a node shows its source, a protocol's sequence diagram (focus) or a role's view (session_actor). With focus: Name, answers the sequence diagram of protocol Name as the text defines it. Use example: \"goserver\" to browse the GoServer specification LeanFM carries."
    (schema [("lean", stringSchema "LeanFM protocol text"), ("proto", stringSchema "optional: the text of the proto3 file that declares the message types"),
      ("focus", stringSchema "optional: a protocol the text defines, to draw its sequence diagram"),
      ("states", stringSchema "optional: a role, to answer its state machine; with focus, the role's state machine in that protocol"),
      ("theme", stringSchema "dark (default) or light")] []),
  tool "session_skeleton" "Generate code to implement a session type"
    "Write a self-contained Python or TypeScript module from a protocol: every role's typestate as classes, one per state (in TypeScript a step the state does not allow does not type-check). A method sends only what its state allows, fills in the cause the protocol names, logs the event in session_conform's format and returns the next state; receive accepts only what the state allows; a state used twice raises. Implement the roles by writing only the decisions (which branch, what each message carries) and the transport."
    (schema [("lean", stringSchema "LeanFM protocol text"), ("proto", stringSchema "optional: the text of the proto3 file that declares the message types"), ("protocol", anyJson "alternative to lean: the JSON form"),
      ("language", stringSchema "python (default) or typescript")] [])
]

/-- Every session tool that takes protocol text also takes `example`, the name of a protocol LeanFM
carries (selfhost.session.explorer), for a client that cannot send a file. -/
def withExampleArgument (tool : Json) : Json :=
  let name := (tool.getObjValAs? String "name").toOption.getD ""
  let input := tool.getObjValD "inputSchema"
  let props := input.getObjValD "properties"
  if !name.startsWith "session_" || !(props.getObjVal? "lean").isOk then tool else
  let ex := Json.mkObj [("type", "string"), ("enum", Json.arr (LeanFM.SessionTools.exampleNames.map Json.str).toArray),
    ("description", Json.str "instead of lean: a protocol LeanFM carries (goserver is the GoServer specification)")]
  let project := Json.mkObj [("type", "string"), ("description", Json.str "with file, instead of lean: a project project_view lists (default LeanFM)")]
  let file := Json.mkObj [("type", "string"), ("description", Json.str "instead of lean: one protocol file of the project, as project_view stage requirements section protocols lists it (LeanFM's own protocol is LeanFM/LLMGenerated/LeanFM.leanfm); the file is read on the server, one file per call")]
  let pname := Json.mkObj [("type", "string"), ("description", Json.str "optional: the name of the protocol of the text (lean, file or example) to use instead of its last one, such as McpCall or ServerStart of LeanFM.leanfm for LeanFM's own logs")]
  tool.setObjVal! "inputSchema" (input.setObjVal! "properties" ((((props.setObjVal! "example" ex).setObjVal! "project" project).setObjVal! "file" file).setObjVal! "protocolName" pname))

/-- Every tool takes the optional per-call `limits` argument (selfhost.mcp.limits). -/
def withLimitsArgument (tool : Json) : Json :=
  let input := tool.getObjValD "inputSchema"
  let props := match input.getObjValD "properties" with | .obj _ => input.getObjValD "properties" | _ => Json.mkObj []
  tool.setObjVal! "inputSchema" ((input.setObjVal! "type" (Json.str "object")).setObjVal! "properties" (props.setObjVal! "limits" LeanFM.CallLimits.schema))

/-- An answer computed under changed limits says so: limitsApplied in its structured content and the
warning as a line of its text (selfhost.mcp.limits). -/
def withLimitsReport (applied : List LeanFM.CallLimits.Applied) (result : Json) : Json :=
  if applied.isEmpty then result else
  let report := LeanFM.CallLimits.report applied
  let result := match result.getObjVal? "structuredContent" with
    | .ok sc => result.setObjVal! "structuredContent" (sc.setObjVal! "limitsApplied" report)
    | .error _ => result.setObjVal! "structuredContent" (Json.mkObj [("limitsApplied", report)])
  match result.getObjValD "content" with
  | .arr cs =>
    let line := Json.mkObj [("type", "text"), ("text", Json.str (LeanFM.CallLimits.warning applied))]
    result.setObjVal! "content" (Json.arr (cs.push line))
  | _ => result

/-- Tool definitions as listed: the logic tools the view draws carry `_meta.ui.resourceUri`. -/
def tools : Array Json := toolDefinitions.map (withLimitsArgument ∘ withSessionView ∘ withLogicView ∘ withExampleArgument)

/-- Listed only where `LeanFM.ServerLogs.enabled` is on: leanfm-mcp --stdio and leanfm-server on
127.0.0.1, never the hosted HTTP endpoint unless LEANFM_MCP_LOGS=1 (LeanFM/ServerLogs.lean). -/
def serverLogsTool : Json :=
  tool "server_logs" "Read LeanFM's and Claude Desktop's logs"
    ("Read the end of a log, to diagnose a failure yourself instead of asking the user to paste it. Without log, list the logs with " ++
     "their paths, sizes and last change. Logs: desktop-mcp (Claude Desktop's log of this MCP server: messages, " ++
     "disconnects, its standard error), desktop-mcp-all, desktop-main (Claude Desktop restarts), serve (make serve output), " ++
     "server, diagnostics (JSON lines), devices, and <Project>/events, each project app's protocol events (logs/events.log under its root, one LeanFM event line per message), which session_conform and check_signal also read by serverLog. Times in the answer are UTC. Tokens and API keys are redacted. Read-only.")
    (schema [("log", Json.mkObj [("type", "string"),
        ("description", Json.str ("which log, omit to list them: " ++ ", ".intercalate LeanFM.ServerLogs.names ++ ", or <Project>/events for a project app's protocol events (GoServer/events)"))]),
      ("lines", Json.mkObj [("type", "integer"), ("description", Json.str s!"newest lines to return, 1 to {LeanFM.ServerLogs.maxLines} (default {LeanFM.ServerLogs.defaultLines})")]),
      ("grep", stringSchema "optional: only lines containing this text, ignoring case")] [])

/-- The session view's navigator: one stage of one project, read-only (clause
selfhost.mcp.session.navigator, LeanFM/ProjectView.lean). Listed exactly where server_logs is. -/
def projectViewTool : Json :=
  withSessionView <| tool "project_view" "Show a project's chat, book, requirements or code"
    ("Show one stage of a project's distillation chain in the session view: chat (a page of its saved conversation log " ++
     "from the newest, or where the conversation happens), book (one page of its PDF as an image), requirements " ++
     "(without section, the sections and their counts; section tasks, clauses or protocols, or transitions, properties " ++
     "or constraints of one task, a page at a time from offset; with file, one protocol's text) or code (a page of its " ++
     "source tree with traceability mappings; with file, a page of one file's text and its mappings; for a project with several " ++
     "implementations, impl picks which one, the default otherwise). Every answer is " ++
     s!"under {LeanFM.ProjectView.maxAnswerChars} characters; follow next or older for more. Without stage, only the project " ++
     "names. Projects: LeanFM (default) and each projects/ child with a manifest. Read-only.")
    (schema [("project", stringSchema "a project name from the list (default LeanFM)"),
      ("stage", Json.mkObj [("type", "string"), ("enum", Json.arr (LeanFM.ProjectView.stages.map Json.str).toArray),
        ("description", Json.str "which stage; omit to list the projects")]),
      ("page", Json.mkObj [("type", "integer"), ("description", Json.str "book: the page to show (default 1)")]),
      ("theme", stringSchema "book: dark (default) or light"),
      ("file", stringSchema "requirements: a listed protocol file; code: a listed source file"),
      ("section", Json.mkObj [("type", "string"), ("enum", Json.arr (LeanFM.ProjectView.sections.map Json.str).toArray),
        ("description", Json.str "requirements: which section to page; transitions, properties and constraints need task")]),
      ("task", stringSchema "requirements: a task id from section tasks"),
      ("offset", Json.mkObj [("type", "integer"), ("description", Json.str "the first item (or, for a file's text, character; for chat, messages back from the newest) of the page: the next or older value of the previous answer")]),
      ("impl", stringSchema "code: which of the project's implementations to show (its manifest lists them; default the manifest's default_implementation); every answer lists implementations")] [])

/-- Which build is answering (clause selfhost.mcp.server-info, LeanFM/ServerInfo.lean). Listed exactly
where server_logs is. -/
def serverInfoTool : Json :=
  tool "server_info" "Which build of LeanFM is answering"
    ("The git commit the server started from (with how many tracked files differed from it), when it started, " ++
     "which executable it runs and when that was built, and stale: true when the executable has been rebuilt since, " ++
     "so the server should be restarted before trusting its answers about new code. No arguments. Read-only.")
    (schema [] [])

/-- The tools listed on this host. -/
def listedTools : IO (Array Json) := do
  if ← LeanFM.ServerLogs.enabled.get then return ((tools.push serverLogsTool).push projectViewTool).push serverInfoTool
  return tools

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
  if line.length ≤ logicSummaryLimit then line else (line.take (logicSummaryLimit - 1)).toString ++ "..."

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
    | .error _ => match body.getObjValAs? String "report" with
      | .ok report => if report.isEmpty then logicSummary name body else logicSummary name body ++ "\n\n" ++ report
      | .error _ => logicSummary name body
  -- the reply carries the text and the structured answer together, and the host refuses a reply
  -- over its limit; when generated code would be sent twice and that is too much, the protocol
  -- text's echo goes first, then the code leaves the text and stays in structuredContent, which
  -- the view draws from
  let over (t : String) (b : Json) : Bool := t.length + b.compress.length > LeanFM.SessionTools.limits.maxResult
  let body := if over text body && body.getObjValD "lean" != Json.null then body.setObjVal! "lean" Json.null else body
  let text := match body.getObjValAs? String "code" with
    | .ok code => if over text body then
        logicSummary name body ++ s!"\n\nThe {(body.getObjValAs? String "language").toOption.getD "generated"} document ({code.length} characters) is too large to send twice: it is in structuredContent, and the view shows it."
      else text
    | .error _ => text
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

/-- session_ctl with the model token (selfhost.mcp.model-token): a token held for exactly this call's
text and arguments reuses its state graph (hit); otherwise the graph is built once, kept under a new
token (miss). The answer is the same either way apart from model and cache. -/
def ctlCached (args : Json) : IO (Except String Json) := do
  let key := LeanFM.ModelCache.keyOf args
  let held ← match (args.getObjValAs? String "model").toOption with
    | some t => LeanFM.ModelCache.lookup t key
    | none => pure none
  let tag (token cache : String) (r : Except String Json) : Except String Json :=
    r.map fun j => (j.setObjVal! "model" (Json.str token)).setObjVal! "cache" (Json.str cache)
  match held with
  | some e => return .ok (logicResult "session_ctl" (tag e.token "hit" (LeanFM.SessionTools.ctlWith args (some (e.draft, e.states)))))
  | none =>
    match LeanFM.SessionTools.ctlDraft args with
    | .ok (some (d, n)) =>
      let token ← LeanFM.ModelCache.store key d n
      return .ok (logicResult "session_ctl" (tag token "miss" (LeanFM.SessionTools.ctlWith args (some (d, n)))))
    | _ => return toolResult "session_ctl" args

/-- The workflow for building software from a session type, as a prompt Claude Desktop can offer. -/
def sessionDesignPrompt : String :=
  "Help me build software by designing it as a session type with LeanFM, then implementing it.\n\n" ++
  "1. Ask me in a sentence or two what the software does, and name the roles (people, clients, services, " ++
  "workers) that exchange messages. Read leanfm://language/session-reference before writing a protocol.\n" ++
  "2. Write the protocol in LeanFM protocol syntax, declaring each message's fields first as a Lean structure " ++
  "(structure Pay where amount : Nat), and call session_review with it as the lean argument " ++
  "(it runs every check that applies and suggests an edit for each finding; give requests a route to " ++
  "check them as HTTP); session_check shows the projections, typestates and calls. " ++
  "Fix every issue it reports, and explain each fix in one line. For HTTP services pass mayCall (who may call " ++
  "whom) and notHttp for channels that are something else (a text message, a queue); then every request must " ++
  "get a response.\n" ++
  "3. Show me the result: the view draws the diagram, each role's typestate API and the calls; I can edit " ++
  "the protocol there or sketch it by clicking lifelines, and LeanFM rechecks it; Walk through lets me play one session step by step " ++
  "(session_next). Then call session_simulate so I can watch many sessions run.\n" ++
  "4. When I agree with the protocol, call session_skeleton for a module with each role's typestate as " ++
  "classes (Python by default, or language typescript, where a step the protocol forbids does not compile), " ++
  "and implement each role with it: its methods send only what each state allows, fill in causes and log " ++
  "every message in session_conform's format, so the code adds only the decisions and the transport. For a " ++
  "role that serves HTTP, session_openapi gives its interface as OpenAPI to start the server from, and " ++
  "session_types writes the .proto and the session as a Lean module (payload types, events and each role's states). In " ++
  "another language, write a handler per state the same way and log every message as JSON " ++
  "{id, session, from, to, label, cause}, and every event as {id, session, at, label, act: true}.\n" ++
  "5. When I paste a log from running it, call session_conform with the protocol and the events, and fix the " ++
  "code until every session conforms. If the protocol itself was wrong, change the protocol first and " ++
  "recheck it.\n" ++
  "6. For each rule the protocol must keep that its structure does not show (never charge after a refusal; " ++
  "every hold is confirmed or released), call session_ctl with a CTL formula over on(label), and fix the " ++
  "protocol when it is disproved, using the counterexample path. Call session_ctl without a formula first: it suggests " ++
  "properties built from this protocol (each call answered, no response before its request, how a session starts, " ++
  "traps and livelock), already decided, to adopt or sharpen. If the project needs secrecy, mark the fields _secr " ++
  "and state where secrets may go as a property, such as {\"AG\": {\"not\": {\"secret\": {\"to\": \"Log\"}}}}; " ++
  "it is a test the project chooses, not a rule for every protocol.\n" ++
  "7. When I change a protocol that is already running, call session_compat with the new version as lean and " ++
  "the old one as old, and tell me which roles can be deployed first.\n\n" ++
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

/-- The names of the listed tools: the only tool names a metric label may carry. -/
def listedToolNames : List String := tools.toList.filterMap fun t => (t.getObjValAs? String "name").toOption

/-! ## LeanFMMcp events (clause selfhost.session.real-events)

A host that names its conversation (params._meta leanfm/session) gets that protocol's own messages in
the log: the request and its answer, and between them the Disk reads the server made. -/

structure Trace where
  h : IO.FS.Stream
  actor : String
  session : String
  cause : Option String

def isHexRoot (s : String) : Bool :=
  16 ≤ s.length && s.length ≤ 32 && s.toList.all fun (c : Char) => c.isDigit || ('a' ≤ c && c ≤ 'f')

/-- A conversation's session: its hex root, then up to three child parts (-r12, -v1), as the
protocol's sessions blocks open child sessions. -/
def isHexSession (s : String) : Bool :=
  match s.splitOn "-" with
  | root :: parts => isHexRoot root && parts.length ≤ 3 &&
      parts.all fun p => 1 ≤ p.length && p.length ≤ 12 && p.toList.all fun (c : Char) => c.isDigit || ('a' ≤ c && c ≤ 'z')
  | [] => false

def rootOf (session : String) : String := (session.splitOn "-").headD session

initialize diskCounter : IO.Ref Nat ← IO.mkRef 0

def isCauseId (s : String) : Bool :=
  1 ≤ s.length && s.length ≤ 96 && s.toList.all fun (c : Char) => c.isAlphanum || "@._:-".toList.contains c

def hasText (s sub : String) : Bool := (s.splitOn sub).length > 1

/-- The host's conversation a request names, when this process logs events. -/
def traceOf (h : IO.FS.Stream) (request : Json) : IO (Option Trace) := do
  let m := (request.getObjValD "params").getObjValD "_meta"
  let some session := (m.getObjValAs? String "leanfm/session").toOption | return none
  unless isHexSession session do return none
  let cause := (m.getObjValAs? String "leanfm/cause").toOption.filter isCauseId
  return some { h, actor := ← LeanFM.Launch.actor "leanfm", session, cause }

def Trace.emit (t : Trace) (label src dst : String) (cause : Option String) (session : Option String := none) : IO String :=
  LeanFM.EventLog.emit t.h t.actor (session.getD t.session) "LeanFMMcp" label (.inl (src, dst)) (cause := cause)

/-- A read of the project's disk, written around the read itself: the request to Disk, the read, and
Disk's answer caused by the request. -/
def Trace.disk {α : Type} (t : Option Trace) (req resp : String) (act : IO α) : IO α := do
  match t with
  | none => act
  | some t =>
    -- each read is a child session of the request's, as the protocol's sessions block makes it
    let n ← diskCounter.modifyGet fun c => (c + 1, c + 1)
    let child := s!"{t.session}-r{n}"
    let r ← t.emit req "Server" "Disk" none child
    let a ← act
    let _ ← t.emit resp "Disk" "Server" (some r) child
    return a

/-- The protocol's name for a request, or none for one LeanFMMcp does not speak of. -/
def requestLabel (method tool : String) : Option String :=
  match method with
  | "initialize" => some "Initialize"
  | "tools/list" => some "ListTools"
  | "tools/call" => if tool == "project_view" then some "ProjectView" else if tool.startsWith "session_" then some "SessionTool" else none
  | _ => none

/-- Whether a project_view call asked for a page rather than a stage: a section or offset, or any
request of the view's browsing (a child session), where LeanFMMcp makes every request a page. -/
def asksPage (request : Json) (trace : Option Trace) : Bool :=
  let a := (request.getObjValD "params").getObjValD "arguments"
  (a.getObjVal? "section").isOk || (a.getObjVal? "offset").isOk || trace.any (fun t => (t.session.splitOn "-").length > 1)

/-- The answer as the protocol names it: success, or the refusal it was, never a refusal as success. -/
def answerLabel (req : String) (page : Bool) (reply : Response) : String :=
  let j := (Json.parse reply.body).toOption.getD Json.null
  let err := (j.getObjVal? "error").isOk
  let res := j.getObjValD "result"
  let isErr := err || (res.getObjValAs? Bool "isError").toOption.getD false
  let text := if err then ((j.getObjValD "error").getObjValAs? String "message").toOption.getD ""
    else match res.getObjValD "content" with
      | .arr xs => ((xs[0]?.getD Json.null).getObjValAs? String "text").toOption.getD ""
      | _ => ""
  let notListed := hasText text "must be one of" && hasText text "listed"
  let overBound := hasText text "bound" || hasText text "too large"
  match req with
  | "Initialize" => if isErr then "InitializeError" else "Initialized"
  | "ListTools" => if isErr then "ListToolsError" else "Tools"
  | "ProjectView" =>
    if !isErr then (if page then "PageShown" else "Shown")
    else if notListed then "NotListed" else if overBound then (if page then "OverBound" else "TooLarge") else "ViewError"
  | _ => if !isErr then "Checked" else if notListed then "NotListed" else "ToolError"

/-- The host's own steps (Agent, Host and View), each with the sender and receiver LeanFMMcp gives it. -/
def hostRoles : List (String × String × String) :=
  [("Open", "Agent", "Host"), ("Quit", "Agent", "Host"),
   ("Render", "Host", "View"), ("Paged", "Host", "View"), ("Drawn", "Host", "View"), ("Refused", "Host", "View"),
   ("Page", "View", "Host"), ("Load", "View", "Host"), ("Close", "View", "Host"),
   ("Done", "Host", "Agent"), ("Failed", "Host", "Agent")]

/-- Whether an id is the host's own: host@ROOT:N, one host through all its sessions. -/
def isHostId (session id : String) : Bool :=
  let pre := s!"host@{rootOf session}:"
  id.startsWith pre && (let n := (id.drop pre.length).toString; 1 ≤ n.length && n.length ≤ 9 && n.toList.all Char.isDigit)

/-- One host event, checked: what it would write, or why it is dropped. -/
def hostEventFields (params : Json) (ts : Nat) : Except String (List (String × Json)) := do
  let str (k : String) := (params.getObjValAs? String k).toOption
  let some session := str "session" | throw "no session"
  unless isHexSession session do throw "session is not 16 to 32 hex digits"
  let some id := str "id" | throw "no id"
  unless isHostId session id do throw "id is not host@ROOT:N"
  let some label := str "label" | throw "no label"
  let some (_, src, dst) := hostRoles.find? (·.1 == label) | throw s!"{label} is not a host label of LeanFMMcp"
  let prev := str "prev"
  if prev.any (fun p => !isHostId session p) then throw "prev is not host@ROOT:N"
  let cause := str "cause"
  if cause.any (fun c => !isCauseId c) then throw "cause does not match its pattern"
  return [("ts", Json.str (toString ts)), ("id", Json.str id), ("session", Json.str session), ("label", Json.str label),
    ("from", Json.str src), ("to", Json.str dst)] ++
    (match prev with | some p => [("prev", Json.arr #[Json.str p])] | none => []) ++
    (match cause with | some c => [("cause", Json.str c)] | none => []) ++
    [("protocol", Json.str "LeanFMMcp"), ("actor", Json.str s!"host@{rootOf session}")]

def hostEvent (params : Json) : IO Unit := do
  let some h ← LeanFM.EventLog.sink.get | return
  match hostEventFields params (← LeanFM.EventLog.nowNs) with
  | .ok fields => h.putStr (LeanFM.EventLog.line fields ++ "\n"); h.flush
  | .error _ => LeanFM.EventLog.droppedHostEvents.modify (· + 1)

def dispatchJsonCore (request : Json) (trace : Option Trace := none) : IO Response := do
  let id := (field request "id").toOption.getD Json.null
  let method ← match stringField request "method" with
    | .ok value => pure value
    | .error err => return rpcError id (-32600) err
  let params := (field request "params").toOption.getD (Json.mkObj [])
  match method with
  | "initialize" =>
      let version ← if ← LeanFM.ServerLogs.enabled.get then LeanFM.ServerInfo.version else pure LeanFM.ServerInfo.baseVersion
      pure <| ok id <| Json.mkObj
        [("protocolVersion", protocolVersion),
         ("capabilities", Json.mkObj
           [("tools", Json.mkObj [("listChanged", false)]),
            ("resources", Json.mkObj [("subscribe", false), ("listChanged", false)]),
            ("prompts", Json.mkObj [("listChanged", false)])]),
         ("serverInfo", Json.mkObj [("name", "leanfm"), ("version", Json.str version)]),
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
  | "tools/list" => pure <| ok id <| Json.mkObj [("tools", Json.arr (← listedTools))]
  | "tools/call" =>
      match stringField params "name" with
      | .error err => pure <| rpcError id (-32602) err
      | .ok "server_logs" =>
        match ← LeanFM.ServerLogs.query ((field params "arguments").toOption.getD (Json.mkObj [])) with
        | .ok (text, body) =>
          let content := Json.arr #[Json.mkObj [("type", "text"), ("text", text)]]
          pure (ok id (Json.mkObj [("content", content), ("structuredContent", body)]))
        | .error err => pure <| rpcError id (-32602) err
      | .ok "server_info" =>
        if !(← LeanFM.ServerLogs.enabled.get) then pure <| rpcError id (-32602) LeanFM.ServerInfo.disabledMessage else
        match ← LeanFM.ServerInfo.answer ((field params "arguments").toOption.getD (Json.mkObj [])) with
        | .ok (text, body) =>
          let content := Json.arr #[Json.mkObj [("type", "text"), ("text", text)]]
          pure (ok id (Json.mkObj [("content", content), ("structuredContent", body)]))
        | .error err => pure <| rpcError id (-32602) err
      | .ok "project_view" =>
        let page := asksPage request trace
        match ← Trace.disk trace (if page then "ReadPage" else "ReadRoot") (if page then "Items" else "Listing")
            (LeanFM.ProjectView.query ((field params "arguments").toOption.getD (Json.mkObj []))) with
        | .ok (text, body) =>
          let content := Json.arr #[Json.mkObj [("type", "text"), ("text", text)]]
          pure (ok id (Json.mkObj [("content", content), ("structuredContent", body)]))
        | .error err => pure <| rpcError id (-32602) err
      | .ok name =>
        let t0 ← IO.monoNanosNow
        let args := (field params "arguments").toOption.getD (Json.mkObj [])
        -- the call's limits, checked and capped at the operator's ceiling before any tool runs (selfhost.mcp.limits)
        let factor ← LeanFM.CallLimits.ceilingFactor.get
        let result ← match LeanFM.CallLimits.validate args factor with
          | .error e => pure (.ok (logicResult name (.error e)))
          | .ok applied => do
            let args := LeanFM.CallLimits.rewrite args applied
            -- a session tool may name a project's protocol file instead of carrying its text
            let r ← if name.startsWith "session_" then do
                let names (k : String) := (args.getObjVal? k).isOk
                match ← (if names "file" then Trace.disk trace "ReadFile" "FileText" (LeanFM.ProjectView.protocolArgs args)
                    else LeanFM.ProjectView.protocolArgs args) with
                | .ok args =>
                  -- session_conform may name a server log instead of carrying it (selfhost.session.event-log)
                  match ← (if name == "session_conform" then
                      (if names "serverLog" then Trace.disk trace "ReadLog" "LogLines" (LeanFM.ServerLogs.logArgs args) else LeanFM.ServerLogs.logArgs args)
                    else pure (.ok args)) with
                  | .ok args => if name == "session_ctl" then ctlCached args else pure (toolResult name args)
                  | .error e => pure (.ok (logicResult name (.error e)))
                | .error e => pure (.ok (logicResult name (.error e)))
              -- check_signal may also name a server log (selfhost.mcp.logic.signal)
              else if name == "check_signal" then do
                match ← LeanFM.ServerLogs.logArgs args with
                | .ok args => pure (toolResult name args)
                | .error e => pure (.ok (logicResult name (.error e)))
              else pure (toolResult name args)
            pure (r.map (withLimitsReport applied))
        let t1 ← IO.monoNanosNow
        -- recorded after the answer is computed, so it can neither change nor fail it (selfhost.mcp.metrics)
        LeanFM.CheckMetrics.checkStats.modify (·.record listedToolNames name result (t1 - t0))
        match result with
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

/-- Every MCP request as event lines of protocol McpCall, when this process has an event sink
(selfhost.session.event-log): Call when it arrives, Answer when its answer is ready, the Answer's
payload carrying kind (the method, or the tool for tools/call), bytes and status. -/
def dispatchJson (request : Json) : IO Response := do
  let method := (request.getObjValAs? String "method").toOption.getD ""
  -- the host's own steps go to the log as they are, checked, and are not MCP calls (selfhost.session.real-events)
  if method == "notifications/leanfm/host-event" then
    hostEvent (request.getObjValD "params")
    return { status := 202, body := "" }
  let some h ← LeanFM.EventLog.sink.get | dispatchJsonCore request
  let kind := if method == "tools/call" then
      ((request.getObjValD "params").getObjValAs? String "name").toOption.getD method else method
  let me ← LeanFM.Launch.actor "leanfm"
  let n ← LeanFM.EventLog.counter.get
  let session := s!"{me}:call{n + 1}"
  let call ← LeanFM.EventLog.emit h me session "McpCall" "Call" (.inl ("Client", "Server"))
  -- a request of a named host conversation is also LeanFMMcp's own message, with its answer
  let trace ← traceOf h request
  let req := trace.bind fun _ => requestLabel method kind
  let reqId ← match trace, req with
    | some t, some r => some <$> t.emit r "Host" "Server" t.cause
    | _, _ => pure none
  let reply ← dispatchJsonCore request (if req.isSome then trace else none)
  if let (some t, some r, some rid) := (trace, req, reqId) then
    let _ ← t.emit (answerLabel r (asksPage request trace) reply) "Server" "Host" (some rid)
  let _ ← LeanFM.EventLog.emit h me session "McpCall" "Answer" (.inl ("Server", "Client")) (cause := some call)
    (payload := Json.mkObj [("kind", Json.str kind), ("bytes", toJson reply.body.utf8ByteSize), ("status", toJson reply.status)])
  return reply

def dispatch (body : String) : IO Response :=
  match Json.parse body with
  | .error err => pure <| rpcError Json.null (-32700) err 400
  | .ok request => dispatchJson request

/-- `dispatch` with the request's LeanFM-Limits header (selfhost.mcp.limits): its limits are merged
into every tool call of the request; a malformed header is refused, naming the limits. -/
def dispatchWith (body : String) (limitsHeader : Option String) : IO Response :=
  match Json.parse body with
  | .error err => pure <| rpcError Json.null (-32700) err 400
  | .ok request => match limitsHeader with
    | none => dispatchJson request
    | some h => match LeanFM.CallLimits.parseHeader h with
      | .error e => pure <| rpcError (request.getObjValD "id") (-32602) e 400
      | .ok lim => dispatchJson (LeanFM.CallLimits.withHeader request lim)

end LeanFM.MCP
