import Lean.Data.Json

/-!
# Per-call limits (selfhost.mcp.limits)

Every bound that can refuse or cut a tool's work is a named limit with a default. A client changes
it for one call with the optional `limits` argument, `{"limits": {"states": 100000}}`. A limit is a
warning, not a wall: whoever has the memory may do something wasteful. The operator caps what a call
may ask for with LEANFM_LIMIT_CEILING (a factor over each default), read once at startup
(selfhost.env.startup).

The MCP dispatcher validates `limits` and rewrites it to the applied values before a tool runs, so
the tools read `get args name` and never see a value past the ceiling. A tool called directly (tests,
the book's generator) gets the default for any limit not given.
-/

namespace LeanFM.CallLimits
open Lean

structure Limit where
  name : String
  default : Nat
  unit : String
  bounds : String
  deriving Repr

def registry : List Limit :=
  [ ⟨"states", 20000, "states", "protocol states explored (session_ctl, session_check, session_review, session_next)"⟩
  , ⟨"formulaNodes", 65536, "subformulas", "distinct subformulas of a session_ctl formula"⟩
  , ⟨"truthBytes", 1073741824, "bytes", "truth-set bytes held at once while evaluating CTL"⟩
  , ⟨"faithfulRules", 64, "rules", "faithful rules session_ctl writes out"⟩
  , ⟨"logEvents", 2000, "events", "events in one session_conform or session_spans log"⟩
  , ⟨"datasetSessions", 10000, "sessions", "sessions session_dataset generates"⟩
  , ⟨"datasetEvents", 1000000, "events", "events session_dataset generates in all"⟩
  , ⟨"sessionEvents", 600, "events", "events of one generated session (session_dataset)"⟩
  , ⟨"draftStates", 8192, "states", "states of a check_ctl draft"⟩
  , ⟨"draftTransitions", 16384, "transitions", "transitions of a check_ctl draft"⟩
  , ⟨"modelNodes", 4096, "nodes", "checker-model nodes check_ctl builds"⟩
  , ⟨"ctlFormulaNodes", 256, "subformulas", "distinct subformulas of a check_ctl formula"⟩
  -- sizes: each can also be raised for one HTTP request with the LeanFM-Limits header, and a log or
  -- protocol can be named instead of sent (serverLog, file), so the server reads it from disk
  , ⟨"argumentBytes", 65536, "bytes", "a tool's arguments as the client sends them (a log named by serverLog, or a protocol by file, is read on the server and not counted)"⟩
  , ⟨"textBytes", 65536, "bytes", "LeanFM protocol text"⟩
  , ⟨"protoBytes", 65536, "bytes", "a .proto file"⟩
  , ⟨"requestBytes", 262144, "bytes", "one HTTP request body to /mcp; raise it with the LeanFM-Limits header, which arrives before the body"⟩
  , ⟨"signalSamples", 100000, "samples", "samples one check_signal reads"⟩
  , ⟨"signalWords", 256, "words", "words of one check_signal claim"⟩
  , ⟨"signalPoints", 2000, "points", "points of each series check_signal returns or draws"⟩
  , ⟨"reduceEvents", 100000, "events", "events of the run one reduce_run reads"⟩ ]

def names : List String := registry.map (·.name)

/-- The HTTP header that raises limits for one request (see `parseHeader`). -/
def headerName : String := "LeanFM-Limits"

def defaultOf (name : String) : Nat := ((registry.find? (·.name == name)).map (·.default)).getD 0

/-- The operator's factor over each default; LEANFM_LIMIT_CEILING sets it at startup. -/
def defaultCeilingFactor : Nat := 100

initialize ceilingFactor : IO.Ref Nat ← IO.mkRef defaultCeilingFactor

/-- LEANFM_LIMIT_CEILING as read at startup: absent is the default; anything but a whole number of
at least 1 is refused, so a server never starts with it wrong. -/
def parseCeiling (raw : Option String) : Except String Nat :=
  match raw with
  | none => .ok defaultCeilingFactor
  | some r => match r.trimAscii.toString.toNat? with
    | some n => if n ≥ 1 then .ok n else .error "LEANFM_LIMIT_CEILING must be a whole number of at least 1"
    | none => .error "LEANFM_LIMIT_CEILING must be a whole number of at least 1 (a factor over each limit's default)"

/-- Read and set LEANFM_LIMIT_CEILING; throws (stopping startup) when it is malformed. -/
def configureFromEnv : IO Unit := do
  match parseCeiling (← IO.getEnv "LEANFM_LIMIT_CEILING") with
  | .ok n => ceilingFactor.set n
  | .error e => throw (IO.userError e)

/-- The value of a limit for this call: the `limits` argument's, else the default. -/
def get (args : Json) (name : String) : Nat :=
  match ((args.getObjValD "limits").getObjValD name).getNat? with
  | .ok n => if n ≥ 1 then n else defaultOf name
  | .error _ => defaultOf name

def known : String := ", ".intercalate (registry.map fun l => s!"{l.name} ({l.default})")

/-- One requested limit: its name, the value asked for and the value applied. -/
structure Applied where
  name : String
  requested : Nat
  applied : Nat
  deriving Repr

/-- Check the `limits` argument and cap each value at its default times `factor`. Absent is
nothing; anything malformed is refused naming the known limits. -/
def validate (args : Json) (factor : Nat) : Except String (List Applied) := do
  match args.getObjVal? "limits" with
  | .error _ => return []
  | .ok Json.null => return []
  | .ok (.obj kvs) =>
    kvs.toList.mapM fun (k, v) => do
      let some l := registry.find? (·.name == k)
        | throw s!"limits: unknown limit {k}; the limits are {known}"
      let n ← match v.getNat? with
        | .ok n => if n ≥ 1 then pure n else throw s!"limits: {k} must be a whole number of at least 1"
        | .error _ => throw s!"limits: {k} must be a whole number of at least 1"
      pure { name := k, requested := n, applied := min n (l.default * factor) }
  | .ok _ => throw s!"limits must be an object of limit names and whole numbers, such as \{\"states\": 100000}; the limits are {known}"

/-- The arguments with `limits` replaced by the applied values. -/
def rewrite (args : Json) (as : List Applied) : Json :=
  if as.isEmpty then args else
  args.setObjVal! "limits" (Json.mkObj (as.map fun a => (a.name, toJson a.applied)))

def warning (as : List Applied) : String :=
  let capped := as.filter (fun a => a.applied < a.requested)
  let parts := as.map fun a =>
    if a.applied < a.requested then s!"{a.name} {a.applied} (asked {a.requested}, capped at the operator's ceiling)"
    else s!"{a.name} {a.applied} (default {defaultOf a.name})"
  s!"limits changed for this call: {", ".intercalate parts}" ++
    (if capped.isEmpty then "; a raised limit trades memory and time for the answer"
     else "; the operator's ceiling is LEANFM_LIMIT_CEILING times each default")

/-- What an answer carries when its call changed a limit. -/
def report (as : List Applied) : Json :=
  Json.mkObj
    [ ("limits", Json.mkObj (as.map fun a => (a.name, Json.mkObj [("requested", toJson a.requested), ("applied", toJson a.applied)])))
    , ("warning", Json.str (warning as)) ]

/-- The sentence a refusal ends with: the limit in force and the argument that raises it. -/
def raise (name : String) (value : Nat) : String :=
  s!"this is the {name} limit ({value}); to allow more, call again with \"limits\": \{\"{name}\": {2 * value}}, or over HTTP send the header {headerName}: {name}={2 * value} (a warning, not a wall: raise it when the machine has the memory)"

/-! ## The LeanFM-Limits header

An HTTP client may raise limits for one request with a header instead of, or as well as, the
`limits` argument: `LeanFM-Limits: argumentBytes=1048576, states=100000`. It applies to every tool
call in the request; a name the call's own `limits` argument gives wins. Only the header can raise
requestBytes, since the body is sized before it is read. The operator's ceiling applies the same way.
A stdio client, which sends no headers, uses the argument. -/

/-- The header's value as a `limits` object: `name=value` pairs separated by commas. -/
def parseHeader (value : String) : Except String Json := do
  let parts := (value.splitOn ",").map (·.trimAscii.toString) |>.filter (· != "")
  let kvs ← parts.mapM fun p => do
    let [k, v] := (p.splitOn "=").map (·.trimAscii.toString)
      | throw s!"{headerName}: write name=value, such as argumentBytes=1048576, not {p}"
    unless names.contains k do throw s!"{headerName}: unknown limit {k}; the limits are {known}"
    let some n := v.toNat? | throw s!"{headerName}: {k} must be a whole number of at least 1"
    if n == 0 then throw s!"{headerName}: {k} must be a whole number of at least 1"
    pure (k, toJson n)
  return Json.mkObj kvs

/-- A JSON-RPC message with the header's limits merged into each tools/call's `limits` argument
(names the call already gives keep their own values). -/
def withHeader (message header : Json) : Json :=
  let one (m : Json) : Json :=
    if m.getObjValD "method" != Json.str "tools/call" then m else
    let params := m.getObjValD "params"
    let args := params.getObjValD "arguments"
    let given := match args.getObjValD "limits" with | .obj kvs => kvs | _ => {}
    let merged := match header with
      | .obj hs => hs.toList.foldl (fun acc (k, v) => if acc.contains k then acc else acc.insert k v) given
      | _ => given
    let args := (match args with | .obj _ => args | _ => Json.mkObj []).setObjVal! "limits" (Json.obj merged)
    m.setObjVal! "params" ((match params with | .obj _ => params | _ => Json.mkObj []).setObjVal! "arguments" args)
  match message with
  | .arr ms => Json.arr (ms.map one)
  | m => one m

/-- The most body bytes one request may have: the header's requestBytes, capped at the operator's
ceiling, else `default`. Never less than `default`. -/
def requestCap (header : Option String) (default factor : Nat) : Nat :=
  match header.map parseHeader with
  | some (.ok j) => match (j.getObjValD "requestBytes").getNat? with
    | .ok n => max default (min n (defaultOf "requestBytes" * factor))
    | .error _ => default
  | _ => default

/-- The limits, their defaults and what each bounds: said once, in the server instructions. -/
def listing : String :=
  "; ".intercalate (registry.map fun l => s!"{l.name} {l.default} ({l.bounds})")

/-- The schema of the `limits` argument every tool takes; short, because it is repeated on every
tool and tools/list must stay under the client's result limit. -/
def schema : Json :=
  Json.mkObj
    [ ("type", "object")
    , ("description", Json.str "optional, this call only: raise or lower a limit an answer stopped at, as name: whole number, such as {\"states\": 100000}; the server instructions list the limits")
    , ("additionalProperties", Json.mkObj [("type", "integer"), ("minimum", toJson (1 : Nat))]) ]

end LeanFM.CallLimits
