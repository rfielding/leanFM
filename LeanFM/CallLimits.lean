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
  , ⟨"ctlFormulaNodes", 256, "subformulas", "distinct subformulas of a check_ctl formula"⟩ ]

def names : List String := registry.map (·.name)

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
  s!"this is the {name} limit ({value}); to allow more, call again with \"limits\": \{\"{name}\": {2 * value}} (a warning, not a wall: raise it when the machine has the memory)"

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
