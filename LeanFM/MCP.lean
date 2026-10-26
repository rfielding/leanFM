import Lean
import LeanFM.Artifacts
import LeanFM.LLMGenerated.Requirements
import LeanFM.LLMGenerated.Implementation
import LeanFM.Logic

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
  "leanfm://project/specification/Requirements.lean, leanfm://project/specification/Requirements.proto, " ++
  "and leanfm://project/specification/Implementation.lean. Treat the book like a maintained portion " ++
  "of the system prompt. Preserve two explicit gates: acceptance of observable requirements and their " ++
  "derived views, then acceptance of the traceable implementation specification. Only after both gates " ++
  "may the book, specifications, and repository be used to produce a one-shot software PR. The MCP " ++
  "surface is read-only: it supplies canonical context and deterministic checks; it cannot accept a gate. " ++
  "Before writing temporal properties, event sequences or requirements over hidden state, consult the logic " ++
  "tools (explain_formula, check_ctl, check_trace, classify_requirement) described by leanfm://language/logic-reference."

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
    "Canonical requirements" "Accepted observable requirements and derived-output declarations." "text/plain",
  resource "leanfm://project/specification/Requirements.proto" "requirements-proto"
    "Canonical protobuf schema" "Byte-level message schema paired with the requirements." "text/x-protobuf",
  resource "leanfm://project/specification/Implementation.lean" "implementation"
    "Canonical implementation specification" "Traceable implementation choices, mappings, and checks." "text/plain",
  resource "leanfm://language/requirements-reference" "requirements-reference"
    "LeanFM requirements language reference" "Live constructors and rules; do not guess these from memory." "text/markdown",
  resource "leanfm://language/implementation-reference" "implementation-reference"
    "LeanFM implementation language reference" "Live implementation and traceability constructors." "text/markdown",
  resource "leanfm://language/logic-reference" "logic-reference"
    "LeanFM logic reference" "JSON formula grammar, operator readings, verdicts, evidence and terminal convention for the logic tools." "text/markdown"
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

def tools : Array Json := #[
  tool "validate_generated_artifacts" "Validate generated artifacts"
    "Run the deterministic in-memory validations for the canonical requirements and implementation specifications.",
  tool "requirements_interrogation" "Read requirements interrogation"
    "Return the internal requirements completeness checklist. The agent resolves reversible defaults; this is not a questionnaire for the user.",
  tool "code_generation_prompt" "Read one-shot implementation prompt"
    "Return the canonical post-acceptance prompt that maps the book and accepted specifications to source changes.",
  tool "explain_formula" "Explain a CTL formula"
    "Read a JSON CTL formula back in English with its negation, mode, unknown atoms and lints (vacuity, AF AG vs AG AF, quantifier mismatch with an optional sentence). Read leanfm://language/logic-reference first."
    (schema [("formula", anyJson "JSON formula"), ("task", anyJson "optional canonical task id or inline draft"),
      ("sentence", stringSchema "optional English requirement the formula is meant to state")] ["formula"]),
  tool "check_ctl" "Check a CTL formula against a task"
    "Decide a JSON CTL formula over a canonical task or inline draft. Returns proved, disproved, unknown, unsupported or resource-limit with a witness or counterexample path."
    (schema [("task", anyJson "canonical task id or inline draft {states, initial, terminals, transitions}"),
      ("formula", anyJson "JSON formula")] ["task", "formula"]),
  tool "check_trace" "Check an event trace and draw it"
    "Check event envelopes (id, prevIds, causeIds, task, src, dst, message) for ids, causality, schemas, concurrency and task acceptance; returns a Mermaid sequence diagram and causal graph."
    (schema [("events", Json.mkObj [("type", "array"), ("items", Json.mkObj [("type", "object")])]),
      ("drafts", Json.mkObj [("type", "array"), ("items", Json.mkObj [("type", "object")])])] ["events"]),
  tool "classify_requirement" "Classify requirement observability"
    "Classify each atom of a formula, or each predicate text, as observable, derived or implementation-only, and propose events that would make hidden predicates testable."
    (schema [("formula", anyJson "JSON formula"), ("predicates", Json.mkObj [("type", "array"), ("items", stringSchema "predicate text")]),
      ("task", anyJson "optional canonical task id or inline draft")] []),
  tool "knows" "Derivable knowledge (deferred)"
    "Accepted but deferred: always answers unsupported."
    (schema [("events", Json.mkObj [("type", "array")]), ("actor", stringSchema "actor"), ("at", stringSchema "event id")] [])
]

/-- LogicVerdict or LogicInputRejected, carried as an MCP tool result. -/
def logicResult (name : String) (outcome : LeanFM.Logic.ToolOutcome) : Json :=
  let (body, isError) := match outcome with
    | .ok json => (json, false)
    | .error reason => (Json.mkObj [("tool", name), ("verdict", "rejected"), ("reason", reason)], true)
  Json.mkObj [("content", Json.arr #[Json.mkObj [("type", "text"), ("text", body.pretty)]]),
    ("structuredContent", body), ("isError", isError)]

def toolResult (name : String) (arguments : Json := Json.mkObj []) : Except String Json :=
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

def prompts : Array Json := #[
  Json.mkObj [("name", "requirements_interrogation"),
    ("title", "Argue observable requirements"),
    ("description", "Use the book and live language reference to discover durable observable requirements."),
    ("arguments", Json.arr #[])],
  Json.mkObj [("name", "one_shot_implementation"),
    ("title", "Implement an accepted LeanFM specification"),
    ("description", "Use only after both explicit acceptance gates."),
    ("arguments", Json.arr #[])]
]

def promptResult (name : String) : Except String Json := do
  let text ← match name with
    | "requirements_interrogation" => pure LeanFM.requirementsInterrogationChecklist
    | "one_shot_implementation" => pure LeanFM.codeGenerationSystemPrompt
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
