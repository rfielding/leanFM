import LeanFM.Logic
import LeanFM.CTL

/-! Conformance tests for LeanFM.Logic (decisions logic-* in McpLogicImplementation). -/

open Lean
open LeanFM.Logic

def parseJ (s : String) : Json := (Json.parse s).toOption.getD Json.null

def expect (label : String) (ok : Bool) : IO Unit :=
  if ok then IO.println s!"ok: {label}" else throw <| IO.userError s!"FAILED: {label}"

def verdictOf (o : ToolOutcome) : String :=
  match o with
  | .ok j => (j.getObjValD "verdict").getStr?.toOption.getD "?"
  | .error _ => "rejected"

def reasonOf (o : ToolOutcome) : String := match o with | .error r => r | .ok _ => ""

def call (tool args : String) : ToolOutcome := (run tool (parseJ args)).getD (.error "no tool")

def lastStep (o : ToolOutcome) : Json :=
  match o with
  | .ok j => match (j.getObjValD "evidence").getObjValD "path" with
    | .arr steps => steps.back?.getD Json.null
    | _ => Json.null
  | .error _ => Json.null

instance : Inhabited (LeanFM.CTL Nat) := ⟨.atom fun _ => true⟩

/-- Translate an observable formula to the reference evaluator LeanFM.CTL over model nodes. -/
partial def toCTL (m : Model) : Formula → LeanFM.CTL Nat
  | .tt => .atom fun _ => true
  | .ff => .atom fun _ => false
  | .atState s => .atom fun i => (m.nodes[i]?.map (·.state == s)).getD false
  | .after msg => .atom fun i => (m.nodes[i]?.map (·.message == some msg)).getD false
  | .terminal => .atom fun i => (m.nodes[i]?.map (fun n => m.task.terminals.contains n.state)).getD false
  | .not f => .neg (toCTL m f)
  | .and fs => fs.foldl (fun acc f => .and acc (toCTL m f)) (.atom fun _ => true)
  | .or fs => fs.foldl (fun acc f => .or acc (toCTL m f)) (.atom fun _ => false)
  | .implies a b => LeanFM.CTL.implies (toCTL m a) (toCTL m b)
  | .ex f => .ex (toCTL m f) | .ax f => .ax (toCTL m f)
  | .ef f => .ef (toCTL m f) | .af f => .af (toCTL m f)
  | .eg f => .eg (toCTL m f) | .ag f => .ag (toCTL m f)
  | .eu a b => .eu (toCTL m a) (toCTL m b) | .au a b => .au (toCTL m a) (toCTL m b)
  | .ew a b => .ew (toCTL m a) (toCTL m b) | .aw a b => .aw (toCTL m a) (toCTL m b)
  | _ => .atom fun _ => false

def main : IO Unit := do
  -- logic-formula-ast
  for op in ["EX", "AX", "EF", "AF", "EG", "AG", "never", "not"] do
    expect s!"parses {op}" ((parseBounded (parseJ s!"\{\"{op}\": \"terminal\"}")).toOption.isSome)
  for op in ["EU", "AU", "EW", "AW", "implies", "stronglyImplies"] do
    expect s!"parses {op}" ((parseBounded (parseJ s!"\{\"{op}\": [\"terminal\", \{\"at\": \"s\"}]}")).toOption.isSome)
  expect "bare F is a typing error naming AF/EF"
    ((reasonOf (call "explain_formula" "{\"formula\": {\"F\": \"terminal\"}}")).contains "AF (on every path) or EF")
  expect "unknown operator rejected" (verdictOf (call "explain_formula" "{\"formula\": {\"exec\": \"rm -rf /\"}}") == "rejected")
  expect "code-shaped text stays an inert predicate atom"
    (match parseBounded (parseJ "{\"predicate\": \"$(rm -rf /)\"}") with | .ok (.predicate _) => true | _ => false)
  let deep := (List.range 80).foldl (fun acc _ => "{\"not\": " ++ acc ++ "}") "\"terminal\""
  expect "depth bound rejects" ((reasonOf (call "explain_formula" ("{\"formula\": " ++ deep ++ "}"))).contains "depth")
  let wide := "{\"and\": [" ++ ",".intercalate ((List.range 300).map fun _ => "\"terminal\"") ++ "]}"
  expect "node bound rejects" ((reasonOf (call "explain_formula" ("{\"formula\": " ++ wide ++ "}"))).contains "nodes")
  let long := String.ofList (List.replicate 300 'x')
  expect "string bound rejects" ((reasonOf (call "explain_formula" ("{\"formula\": {\"at\": \"" ++ long ++ "\"}}"))).contains "longer")
  -- logic-ctl-model: agreement with LeanFM.CTL on canonical tasks
  let formulas := [
    "{\"AG\": {\"implies\": [{\"after\": \"LogicConsultRequested\"}, {\"AF\": \"terminal\"}]}}",
    "{\"EF\": \"terminal\"}", "{\"AF\": \"terminal\"}", "{\"EG\": {\"not\": \"terminal\"}}",
    "{\"AU\": [{\"not\": \"terminal\"}, \"terminal\"]}", "{\"EU\": [true, \"terminal\"]}",
    "{\"AW\": [{\"not\": \"terminal\"}, \"terminal\"]}", "{\"EW\": [{\"not\": \"terminal\"}, false]}",
    "{\"AX\": {\"not\": \"terminal\"}}", "{\"EX\": \"terminal\"}"]
  let mut compared := 0
  for t in canonicalTasks do
    match buildModel (ofRequirement t) with
    | none => pure ()
    | some m =>
      for fs in formulas do
        let f := (parseBounded (parseJ fs)).toOption.getD .tt
        let mine := Model.get (Model.sat m f) 0
        let succ := fun (i : Nat) => (m.succ[i]?.getD #[]).toList
        let ref := LeanFM.CTL.holds succ 0 (toCTL m f)
        if mine != ref then throw <| IO.userError s!"disagreement on {t.id}: {fs}"
        compared := compared + 1
  expect s!"fixpoint labelling agrees with LeanFM.CTL ({compared} checks)" (compared > 0)
  let draftChain := fun (n : Nat) =>
    let states := (List.range n).map (fun i => "\"s" ++ toString i ++ "\"")
    let trs := (List.range (n - 1)).map fun i =>
      "{\"src\": \"s" ++ toString i ++ "\", \"dst\": \"s" ++ toString (i + 1) ++ "\", \"message\": \"M" ++ toString i ++ "\"}"
    "{\"states\": [" ++ ",".intercalate states ++ "], \"initial\": \"s0\", \"terminals\": [\"s" ++ toString (n - 1) ++
      "\"], \"transitions\": [" ++ ",".intercalate trs ++ "]}"
  let big := checkCtl (parseJ ("{\"task\": " ++ draftChain 5000 ++ ", \"formula\": {\"AF\": \"terminal\"}}"))
  expect "5000-state draft yields resource-limit, never proved" (verdictOf big == "resource-limit")
  expect "predicate atom yields unknown, never proved"
    (verdictOf (call "check_ctl" "{\"task\": \"mcp_logic_consult\", \"formula\": {\"AG\": {\"predicate\": \"cache is consistent\"}}}") == "unknown")
  expect "K yields unsupported"
    (verdictOf (call "check_ctl" "{\"task\": \"mcp_logic_consult\", \"formula\": {\"K\": \"terminal\"}}") == "unsupported")
  expect "misspelled message is rejected, not false"
    (verdictOf (call "check_ctl" "{\"task\": \"mcp_logic_consult\", \"formula\": {\"EF\": {\"after\": \"LogicVerdikt\"}}}") == "rejected")
  -- logic-evidence
  let cex := call "check_ctl" "{\"task\": \"mcp_logic_consult\", \"formula\": {\"never\": {\"after\": \"LogicInputRejected\"}}}"
  expect "never-claim disproved" (verdictOf cex == "disproved")
  expect "counterexample ends with LogicInputRejected"
    ((lastStep cex).getObjValD "message" == Json.str "LogicInputRejected")
  let wit := call "check_ctl" "{\"task\": \"mcp_logic_consult\", \"formula\": {\"EF\": {\"at\": \"answered\"}}}"
  expect "EF proved with witness reaching answered" (verdictOf wit == "proved" && (lastStep wit).getObjValD "state" == Json.str "answered")
  let cyc := "{\"states\": [\"a\", \"b\", \"done\"], \"initial\": \"a\", \"terminals\": [\"done\"], \"transitions\": [{\"src\": \"a\", \"dst\": \"b\", \"message\": \"Ping\"}, {\"src\": \"b\", \"dst\": \"a\", \"message\": \"Pong\"}, {\"src\": \"b\", \"dst\": \"done\", \"message\": \"Stop\"}]}"
  let lassoOut := call "check_ctl" ("{\"task\": " ++ cyc ++ ", \"formula\": {\"AF\": \"terminal\"}}")
  expect "AF disproved on a ping-pong cycle with a lasso"
    (verdictOf lassoOut == "disproved" && match lassoOut with
      | .ok j => ((j.getObjValD "evidence").getObjValD "loopsBackTo").getNat?.toOption.isSome
      | _ => false)
  let vac := call "check_ctl" ("{\"task\": " ++ cyc ++ ", \"formula\": {\"stronglyImplies\": [{\"after\": \"Never\"}, \"terminal\"]}}")
  expect "unknown message in stronglyImplies rejected" (verdictOf vac == "rejected")
  let orphan := "{\"states\": [\"a\", \"done\", \"z\"], \"initial\": \"a\", \"terminals\": [\"done\"], \"transitions\": [{\"src\": \"a\", \"dst\": \"done\", \"message\": \"Finish\"}, {\"src\": \"z\", \"dst\": \"done\", \"message\": \"Ghost\"}]}"
  let vacOut := call "check_ctl" ("{\"task\": " ++ orphan ++ ", \"formula\": {\"stronglyImplies\": [{\"after\": \"Ghost\"}, \"terminal\"]}}")
  expect "unreachable antecedent: stronglyImplies disproved as vacuous" (verdictOf vacOut == "disproved" && match vacOut with
    | .ok j => (j.getObjValD "evidence").getObjValD "kind" == Json.str "vacuous" | _ => false)
  expect "plain AG implies with unreachable antecedent is proved (the vacuity the lint warns about)"
    (verdictOf (call "check_ctl" ("{\"task\": " ++ orphan ++ ", \"formula\": {\"AG\": {\"implies\": [{\"after\": \"Ghost\"}, false]}}}")) == "proved")
  let dead := "{\"states\": [\"a\", \"stuck\", \"done\"], \"initial\": \"a\", \"terminals\": [\"done\"], \"transitions\": [{\"src\": \"a\", \"dst\": \"stuck\", \"message\": \"Go\"}, {\"src\": \"a\", \"dst\": \"done\", \"message\": \"Finish\"}]}"
  let deadOut := call "check_ctl" ("{\"task\": " ++ dead ++ ", \"formula\": {\"AF\": \"terminal\"}}")
  expect "deadlock reported and AF disproved"
    (verdictOf deadOut == "disproved" && match deadOut with
      | .ok j => (j.getObjValD "deadlocks").compress.contains "stuck" | _ => false)
  -- logic-explain
  let ex := call "explain_formula" "{\"formula\": {\"AG\": {\"implies\": [{\"after\": \"LogicConsultRequested\"}, {\"AF\": \"terminal\"}]}}, \"sentence\": \"every consultation ends\"}"
  let exs := match ex with | .ok j => j.compress | _ => ""
  expect "reading is English" (exs.contains "on every path, always (if LogicConsultRequested was just delivered then (on every path, eventually the task has ended))")
  expect "negation pushed through duals" (exs.contains "\"EF\":{\"and\":[{\"after\":\"LogicConsultRequested\"},{\"EG\"")
  expect "stronglyImplies lint" (exs.contains "stronglyImplies(a, b)")
  expect "mode is always" (exs.contains "\"mode\":\"always\"")
  let mis := call "explain_formula" "{\"formula\": {\"EF\": \"terminal\"}, \"sentence\": \"the task must always end\"}"
  expect "quantifier mismatch lint" (match mis with | .ok j => j.compress.contains "sounds universal" | _ => false)
  -- logic-trace
  let good := "{\"events\": [{\"id\": \"e1\", \"task\": \"mcp_logic_consult\", \"src\": \"Agent\", \"dst\": \"LeanFMServer\", \"message\": \"LogicConsultRequested\"}, {\"id\": \"e2\", \"prevIds\": [\"e1\"], \"causeIds\": [\"e1\"], \"task\": \"mcp_logic_consult\", \"src\": \"LeanFMServer\", \"dst\": \"Agent\", \"message\": \"LogicVerdict\"}]}"
  let goodOut := call "check_trace" good
  expect "valid consultation trace admissible" (verdictOf goodOut == "admissible")
  expect "trace yields a sequence diagram" (match goodOut with
    | .ok j => ((j.getObjValD "sequenceDiagram").getStr?.toOption.getD "").contains "LeanFMServer->>Agent: e2 LogicVerdict" | _ => false)
  let bad := "{\"events\": [{\"id\": \"e1\", \"causeIds\": [\"e3\"], \"task\": \"mcp_logic_consult\", \"src\": \"LeanFMServer\", \"dst\": \"Agent\", \"message\": \"LogicConsultRequested\"}, {\"id\": \"e1\", \"prevIds\": [\"ghost\"], \"task\": \"mcp_logic_consult\", \"src\": \"LeanFMServer\", \"dst\": \"Agent\", \"message\": \"LogicVerdict\"}, {\"id\": \"e3\", \"task\": \"mcp_logic_consult\", \"src\": \"LeanFMServer\", \"dst\": \"Agent\", \"message\": \"LogicVerdict\"}]}"
  let badS := match call "check_trace" bad with | .ok j => j.compress | _ => ""
  expect "duplicate id reported" (badS.contains "duplicate id e1")
  expect "dangling reference reported" (badS.contains "ghost does not exist")
  expect "forward cause reported" (badS.contains "e3 does not precede")
  expect "wrong src reported" (badS.contains "declared Agent -> LeanFMServer")
  expect "out-of-grammar event reported" (badS.contains "firstRejected")
  let conc := "{\"events\": [{\"id\": \"a1\", \"task\": \"mcp_logic_consult\", \"src\": \"Agent\", \"dst\": \"LeanFMServer\", \"message\": \"LogicConsultRequested\"}, {\"id\": \"b1\", \"task\": \"other\", \"src\": \"Agent\", \"dst\": \"LeanFMServer\", \"message\": \"LogicConsultRequested\"}], \"drafts\": [{\"id\": \"other\", \"states\": [\"x\", \"y\"], \"initial\": \"x\", \"terminals\": [\"y\"], \"transitions\": [{\"src\": \"x\", \"dst\": \"y\", \"message\": \"LogicConsultRequested\"}]}]}"
  expect "independent requests are concurrent" (match call "check_trace" conc with
    | .ok j => j.getObjValD "concurrentCount" == toJson (1 : Nat) | _ => false)
  let backwards := "{\"events\": [{\"id\": \"e1\", \"timeAt\": 50, \"task\": \"mcp_logic_consult\", \"src\": \"Agent\", \"dst\": \"LeanFMServer\", \"message\": \"LogicConsultRequested\"}, {\"id\": \"e2\", \"timeAt\": 10, \"causeIds\": [\"e1\"], \"task\": \"mcp_logic_consult\", \"src\": \"LeanFMServer\", \"dst\": \"Agent\", \"message\": \"LogicVerdict\"}]}"
  expect "an edge that runs backwards in time is reported" (match call "check_trace" backwards with
    | .ok j => j.compress.contains "later timeAt" | _ => false)
  -- logic-observability
  let cls := match call "classify_requirement" "{\"predicates\": [\"the cache is consistent\", \"LogicVerdict count stays below 10\"], \"task\": \"mcp_logic_consult\"}" with
    | .ok j => j.compress | _ => ""
  expect "hidden predicate is implementation-only with a proposed event" (cls.contains "implementation-only" && cls.contains "CacheConsistentObserved")
  expect "event-mentioning predicate is derived" (cls.contains "\"class\":\"derived\"")
  expect "no predicate text is observable" (!cls.contains "\"class\":\"observable\"")
  let mixed := match call "classify_requirement" "{\"formula\": {\"AG\": {\"implies\": [{\"after\": \"LogicVerdict\"}, {\"predicate\": \"evidence is complete\"}]}}, \"task\": \"mcp_logic_consult\"}" with
    | .ok j => j.compress | _ => ""
  expect "formula atoms classified separately" (mixed.contains "\"class\":\"observable\"" && mixed.contains "implementation-only")
  expect "knows answers unsupported" (verdictOf (call "knows" "{}") == "unsupported")
  expect "oversized arguments rejected"
    (verdictOf ((run "explain_formula" (Json.mkObj [("formula", Json.str (String.ofList (List.replicate 70000 'x')))])).getD (.error "")) == "rejected")
  IO.println "ok: all LeanFM.Logic tests passed"
