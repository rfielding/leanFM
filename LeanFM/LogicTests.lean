import LeanFM.Logic
import LeanFM.CTL
import Lean.Data.Json.Elab

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
  -- logic-knows: Lowe's attack on Needham-Schroeder, as the network (Ivo) sees it
  let pkT := fun (a : String) => json% {pk: $(a)}
  let at_ := fun (n : String) => json% {atom: $(n)}
  let enc := fun (k b : Json) => json% {enc: {key: $(k), body: $(b)}}
  let ev := fun (id src dst : String) (causes : List String) (t : Json) =>
    json% {id: $(id), src: $(src), dst: $(dst), causeIds: $(causes), term: $(t)}
  let lowe := [
    ev "e1" "Alice" "Ivo" [] (enc (pkT "I") (json% {tuple: [$(at_ "na"), $(at_ "A")]})),
    ev "e2" "Ivo" "Bob" ["e1"] (enc (pkT "B") (json% {tuple: [$(at_ "na"), $(at_ "A")]})),
    ev "e3" "Bob" "Ivo" ["e2"] (enc (pkT "A") (json% {tuple: [$(at_ "na"), $(at_ "nb")]})),
    ev "e4" "Ivo" "Alice" ["e3"] (enc (pkT "A") (json% {tuple: [$(at_ "na"), $(at_ "nb")]})),
    ev "e5" "Alice" "Ivo" ["e4"] (enc (pkT "I") (at_ "nb")),
    ev "e6" "Ivo" "Bob" ["e5"] (enc (pkT "B") (at_ "nb")) ]
  let ivo := [json% {sk: "I"}, pkT "A", pkT "B", pkT "I", at_ "ni"]
  let ask := fun (evs : List Json) (atEv : String) (q : Option Json) =>
    let base := [("events", Json.arr evs.toArray), ("actor", Json.str "Ivo"), ("at", Json.str atEv),
      ("initial", Json.arr ivo.toArray)]
    (run "knows" (Json.mkObj (base ++ (match q with | some j => [("query", j)] | none => [])))).getD (.error "no tool")
  expect "knows: before Alice answers, Ivo cannot derive nb" (verdictOf (ask lowe "e3" (some (at_ "nb"))) == "disproved")
  let leaked := ask lowe "e5" (some (at_ "nb"))
  expect "knows: after Alice answers, Ivo can derive nb" (verdictOf leaked == "proved")
  expect "knows: the derivation names the delivering event and the key used" (match leaked with
    | .ok j => let d := ((j.getObjValD "evidence").getObjValD "derivation").compress
               d.contains "\"held\":\"e5\"" && d.contains "opened {nb}pk(I) with sk(I)"
    | _ => false)
  expect "knows: Ivo learns na from Alice's first message" (match ask lowe "e5" none with
    | .ok j => verdictOf (.ok j) == "derived" && (j.getObjValD "holds").compress.contains "{\"from\":\"e1\",\"how\":\"first part of na, A\",\"term\":\"na\"}"
    | _ => false)
  -- an event outside the causal past never contributes; the same event inside it does
  let leak := ev "z" "Mallory" "Ivo" [] (json% {sk: "A"})
  expect "knows: a concurrent leak of sk(A) does not count" (verdictOf (ask (leak :: lowe) "e3" (some (at_ "nb"))) == "disproved")
  let linked := leak :: lowe.map (fun e => if (e.getObjValD "id") == Json.str "e3" then e.setObjVal! "causeIds" (json% ["e2", "z"]) else e)
  expect "knows: the same leak in the causal past opens Bob's reply" (verdictOf (ask linked "e3" (some (at_ "nb"))) == "proved")
  let one := fun (t q : Json) (init : List Json) =>
    (run "knows" (Json.mkObj [("events", Json.arr #[ev "m" "Bob" "Ivo" [] t]), ("actor", Json.str "Ivo"),
      ("at", Json.str "m"), ("initial", Json.arr init.toArray), ("query", q)])).getD (.error "no tool")
  expect "knows: a signature opens with the public key" (verdictOf (one (enc (json% {sk: "B"}) (at_ "m")) (at_ "m") [pkT "B"]) == "proved")
  expect "knows: a public-key ciphertext stays closed without the private key" (verdictOf (one (enc (pkT "B") (at_ "m")) (at_ "m") [pkT "B"]) == "disproved")
  expect "knows: a hash is never inverted" (verdictOf (one (json% {hash: $(at_ "pw")}) (at_ "pw") []) == "disproved")
  expect "knows: a hash can be recomputed from its input" (verdictOf (one (at_ "pw") (json% {hash: $(at_ "pw")}) []) == "proved")
  expect "knows: a malformed term is rejected" (verdictOf (one (json% {atom: 3}) (at_ "m") []) == "rejected")
  expect "knows: a term with two constructors is rejected" (verdictOf (one (json% {atom: "a", key: "k"}) (at_ "m") []) == "rejected")
  expect "knows: an unknown event is rejected" (verdictOf (ask lowe "e9" none) == "rejected")
  -- logic-knows-atom: knowledge as a state label inside check_ctl
  let nsDraft := fun (lowe : Bool) =>
    let m2 := if lowe then json% {tuple: [$(at_ "na"), $(at_ "nb"), $(at_ "B")]} else json% {tuple: [$(at_ "na"), $(at_ "nb")]}
    let tr := fun (src dst msg frm to_ : String) (t : Json) =>
      json% {src: $(src), dst: $(dst), message: $(msg), «from»: $(frm), to: $(to_), term: $(t)}
    -- Alice talks to Ivo; Ivo replays her message to Bob. With Lowe's fix Alice refuses Bob's
    -- reply, because it names Bob and she chose Ivo.
    let toAlice := if lowe then [tr "s3" "refused" "AliceRefuses" "Alice" "Alice" (at_ "refused"),
        -- Bob's last step is still declared; nothing reaches it
        tr "s4" "done" "BobFinishes" "Ivo" "Bob" (enc (pkT "B") (at_ "nb"))]
      else [tr "s3" "s4" "AliceAnswers" "Alice" "Ivo" (enc (pkT "I") (at_ "nb")),
            tr "s4" "done" "BobFinishes" "Ivo" "Bob" (enc (pkT "B") (at_ "nb"))]
    json% {id: "ns", states: ["s0", "s1", "s2", "s3", "s4", "done", "refused"], initial: "s0",
           terminals: ["done", "refused"],
           transitions: $([tr "s0" "s1" "AliceToIvo" "Alice" "Ivo" (enc (pkT "I") (json% {tuple: [$(at_ "na"), $(at_ "A")]})),
                           tr "s1" "s2" "IvoAsAlice" "Ivo" "Bob" (enc (pkT "B") (json% {tuple: [$(at_ "na"), $(at_ "A")]})),
                           tr "s2" "s3" "BobReplies" "Bob" "Alice" (enc (pkT "A") m2)] ++ toAlice),
           knowledge: {Net: {initial: $(ivo), seesAll: true}}}
  let breach := json% {never: {and: [{after: "BobFinishes"}, {knows: {actor: "Net", term: {atom: "nb"}}}]}}
  let nsRes := call "check_ctl" ((Json.mkObj [("task", nsDraft false), ("formula", breach)]).compress)
  expect "knows atom: the 1978 protocol leaks Bob's nonce" (verdictOf nsRes == "disproved")
  expect "knows atom: the counterexample shows the network holding nb" (match nsRes with
    | .ok j => ((lastStep (.ok j)).getObjValD "holds").compress.contains "\"nb\"" | _ => false)
  expect "knows atom: with Lowe's fix the leak is gone"
    (verdictOf (call "check_ctl" ((Json.mkObj [("task", nsDraft true), ("formula", breach)]).compress)) == "proved")
  -- one state, two histories: reached with and without a leak, it is two nodes of the model
  let fork := json% {id: "fork", states: ["s0", "s1", "s2"], initial: "s0", terminals: ["s2"],
    transitions: [{src: "s0", dst: "s1", message: "Leak", «from»: "X", to: "Eve", term: {key: "k"}},
                  {src: "s0", dst: "s1", message: "Quiet", «from»: "X", to: "Y", term: {key: "k"}},
                  {src: "s1", dst: "s2", message: "Sealed", «from»: "X", to: "Eve", term: {enc: {key: {key: "k"}, body: {atom: "s"}}}}],
    knowledge: {Eve: {initial: []}}}
  let at2 := fun (f : Json) => verdictOf (call "check_ctl" ((Json.mkObj [("task", fork), ("formula", f)]).compress))
  expect "knows atom: some history reaches the end knowing s"
    (at2 (json% {EF: {and: [{"at": "s2"}, {knows: {actor: "Eve", term: {atom: "s"}}}]}}) == "proved")
  expect "knows atom: another reaches it without knowing s"
    (at2 (json% {EF: {and: [{"at": "s2"}, {not: {knows: {actor: "Eve", term: {atom: "s"}}}}]}}) == "proved")
  expect "knows atom: so it is not true on every path"
    (at2 (json% {AG: {implies: [{"at": "s2"}, {knows: {actor: "Eve", term: {atom: "s"}}}]}}) == "disproved")
  expect "knows atom: an undeclared actor is rejected"
    (at2 (json% {EF: {knows: {actor: "Mallory", term: {atom: "s"}}}}) == "rejected")
  expect "knows atom: canonical tasks declare no knowledge"
    (verdictOf (call "check_ctl" "{\"task\": \"mcp_logic_consult\", \"formula\": {\"EF\": {\"knows\": {\"actor\": \"Agent\", \"term\": {\"atom\": \"x\"}}}}}") == "rejected")
  -- logic-protocol: Needham-Schroeder declared as data, the attacker generated
  let v := fun (x : String) => json% {var: $(x)}
  let encP := fun (k b : Json) => json% {enc: {key: $(k), body: $(b)}}
  let nsRoles := fun (lowe : Bool) =>
    let reply := if lowe then json% {tuple: [$(v "m"), $(at_ "nb"), $(at_ "B")]} else json% {tuple: [$(v "m"), $(at_ "nb")]}
    let expect2 := if lowe then json% {tuple: [$(at_ "na"), $(v "n"), $(v "peer")]} else json% {tuple: [$(at_ "na"), $(v "n")]}
    json% [
      {name: "Alice", steps: [
        {choose: {var: "peer", values: [$(at_ "B"), $(at_ "I")]}},
        {claim: {name: "running", args: [$(at_ "A"), $(v "peer")]}},
        {send: {to: $(v "peer"), message: $(encP (json% {pk: $(v "peer")}) (json% {tuple: [$(at_ "na"), $(at_ "A")]}))}},
        {recv: $(encP (pkT "A") expect2)},
        {send: {to: $(v "peer"), message: $(encP (json% {pk: $(v "peer")}) (v "n"))}},
        {claim: {name: "finished", args: [$(at_ "A"), $(v "peer")]}}]},
      {name: "Bob", steps: [
        {recv: $(encP (pkT "B") (json% {tuple: [$(v "m"), $(v "x")]}))},
        {send: {to: $(v "x"), message: $(encP (json% {pk: $(v "x")}) reply)}},
        {recv: $(encP (pkT "B") (at_ "nb"))},
        {claim: {name: "commit", args: [$(at_ "B"), $(v "x")]}}]}]
  let nsArgs := fun (lowe : Bool) (f : Json) => Json.mkObj
    [ ("roles", nsRoles lowe)
    , ("attacker", json% {name: "Ivo", knows: [$(at_ "A"), $(at_ "B"), $(at_ "I"), $(pkT "A"), $(pkT "B"), $(pkT "I"), {sk: "I"}, $(at_ "ni")]})
    , ("domain", json% [$(at_ "na"), $(at_ "nb"), $(at_ "ni")])
    , ("domains", json% {x: [$(at_ "A"), $(at_ "B"), $(at_ "I")]})
    , ("formula", f) ]
  let secrecy := json% {never: {and: [{claimed: "commit(B, A)"}, {knows: {actor: "Ivo", term: {atom: "nb"}}}]}}
  let agreement := json% {never: {and: [{claimed: "commit(B, A)"}, {not: {claimed: "running(A, B)"}}]}}
  let proto := fun (lowe : Bool) (f : Json) => (run "check_protocol" (nsArgs lowe f)).getD (.error "no tool")
  let attack := proto false secrecy
  expect "check_protocol: the 1978 protocol leaks Bob's nonce" (verdictOf attack == "disproved")
  expect "check_protocol: the attack is Lowe's, through Ivo" (match attack with
    | .ok j => let w := (j.getObjValD "wire").compress
               w.contains "{\"from\":\"Alice\",\"term\":\"{na, A}pk(I)\",\"to\":\"Ivo\"}" &&
               w.contains "{\"from\":\"Ivo\",\"term\":\"{na, A}pk(B)\",\"to\":\"Bob\"}" &&
               w.contains "{\"from\":\"Alice\",\"term\":\"{nb}pk(I)\",\"to\":\"Ivo\"}"
    | _ => false)
  expect "check_protocol: authentication fails in 1978" (verdictOf (proto false agreement) == "disproved")
  expect "check_protocol: Lowe's fix keeps the nonce secret" (verdictOf (proto true secrecy) == "proved")
  expect "check_protocol: Lowe's fix keeps agreement" (verdictOf (proto true agreement) == "proved")
  expect "check_protocol: an honest run can still complete"
    (verdictOf (proto true (json% {EF: {and: [{claimed: "commit(B, A)"}, {claimed: "finished(A, B)"}]}})) == "proved")
  expect "check_protocol: sending an unbound variable is rejected"
    (reasonOf ((run "check_protocol" (Json.mkObj [("roles", json% [{name: "R", steps: [{send: {to: {atom: "S"}, message: {var: "y"}}}]}]),
      ("attacker", json% {name: "Ivo"}), ("formula", json% true)])).getD (.error "")) |>.contains "sends y before anything binds it")
  expect "check_protocol: the attacker cannot be an honest role"
    (verdictOf ((run "check_protocol" (Json.mkObj [("roles", json% [{name: "Ivo", steps: []}]),
      ("attacker", json% {name: "Ivo"}), ("formula", json% true)])).getD (.error "")) == "rejected")
  expect "check_protocol: a claim no role makes is an unknown name"
    (verdictOf (proto false (json% {EF: {claimed: "commit(B, Z)"}})) == "rejected")
  expect "knows: a dangling reference is rejected" (verdictOf (ask [ev "e1" "A" "Ivo" ["e0"] (at_ "x")] "e1" none) == "rejected")
  expect "oversized arguments rejected"
    (verdictOf ((run "explain_formula" (Json.mkObj [("formula", Json.str (String.ofList (List.replicate 70000 'x')))])).getD (.error "")) == "rejected")
  IO.println "ok: all LeanFM.Logic tests passed"
