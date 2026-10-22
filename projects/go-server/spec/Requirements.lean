import LeanFM.ChatUI.Server

namespace GoServer.Requirements
open LeanFM Lean

def revision := "playable-v1"
def protoSource := include_str "Requirements.proto"
def rulesSource := include_str "working-contract.json"

-- Compatibility-visible HTTP conversions are REQUIREMENTS, not codegen choices.
structure HttpContract where
  task : String
  requests : List String
  method : String
  path : String
  responses : List String
  authentication : String
  requestCodec : String := "application/json; strict UTF-8 JSON; unknown fields rejected; 1 MiB limit"
  responseCodec : String := "application/json; Response protobuf value, snake_case field names"
  statuses : List Nat
deriving Repr

def httpContracts : List HttpContract :=
  [ { task:="create_game", requests:=["CreateGame"], method:="POST", path:="/api/games", responses:=["GameCreated","ErrorEvent"], authentication:="public; same-origin when Origin is supplied", statuses:=[201,400,403,429,500] }
  , { task:="join_game", requests:=["JoinGame"], method:="POST", path:="/api/games/{id}/join", responses:=["Joined","ErrorEvent"], authentication:="unguessable invitation id; same-origin", statuses:=[200,400,403,404,409,500] }
  , { task:="play_turn", requests:=["MakeMove","Pass","Resign"], method:="POST", path:="/api/games/{id}/actions", responses:=["MoveEvent","GameState","ErrorEvent"], authentication:="Authorization: Bearer seat-token; current seat; exact revision; action.kind discriminates move/pass/resign", statuses:=[200,400,401,403,404,409,422,500] }
  , { task:="inspect_game", requests:=["InspectGame"], method:="GET", path:="/api/games/{id}", responses:=["GameState","ErrorEvent"], authentication:="invitation id grants read-only access", requestCodec:="path id; no request body", statuses:=[200,404,500] }
  , { task:="inspect_history", requests:=["InspectHistory"], method:="GET", path:="/api/games/{id}/history", responses:=["HistoryReturned","ErrorEvent"], authentication:="invitation id grants read-only access", requestCodec:="path id; no request body", statuses:=[200,404,500] }
  , { task:="export_gif", requests:=["ExportGIF"], method:="POST", path:="/api/export", responses:=["GIFCreated","ErrorEvent"], authentication:="same-origin; replayed local actions; no arbitrary path input", responseCodec:="image/gif on success; X-GoServer-Artifact and X-GoServer-Final-Ply; text/plain error; X-GoServer-Trace is base64 UTF-8 JSON request/terminal Event array on both outcomes", statuses:=[200,400,403,422,429,500] } ]

def framing : MessageFraming := {kind:=.transportEnvelope,dispatchField:=some "message",note:="Normalized observed event in Response.events; HTTP route and action.kind identify requests. Export has the same events in X-GoServer-Trace, with GIF bytes independently verified. Loopback Host and Origin rejection are pre-protocol admission failures (plain HTTP 403), not accepted task starts."}
def field (number : Nat) (name : String) (scalar : ProtoScalar) : ProtoFieldSchema := {number,name,scalar}
def fieldsFor : String → List ProtoFieldSchema
  | "CreateGame" => [field 1 "size" .uint32,field 2 "players" .uint32,field 3 "max_turns" .uint32,field 4 "name" .string]
  | "JoinGame" => [field 1 "name" .string]
  | "MakeMove" | "Pass" | "Resign" => [field 1 "revision" .uint32,field 2 "action" (.message "Action")]
  | "InspectGame" | "InspectHistory" => [field 1 "id" .string]
  | "ExportGIF" => [field 1 "size" .uint32,field 2 "players" .uint32,field 3 "max_turns" .uint32,field 4 "actions" (.repeated (.message "Action"))]
  | "GIFCreated" => [field 1 "project_path" .string,field 2 "final_ply" .uint32]
  | "ErrorEvent" => [field 4 "error" .string,field 5 "events" (.repeated (.message "TraceEvent"))]
  | "GameCreated" | "Joined" => [field 1 "game" (.message "Room"),field 2 "token" .string,field 3 "seat" .int32,field 5 "events" (.repeated (.message "TraceEvent"))]
  | _ => [field 1 "game" (.message "Room"),field 5 "events" (.repeated (.message "TraceEvent"))]
def message (name src dst : String) : MessageSchema := {name,src,dst,framing,fields:=fieldsFor name}
def requestNames := ["CreateGame","JoinGame","MakeMove","Pass","Resign","InspectGame","InspectHistory","ExportGIF"]
def responseNames := ["GameCreated","Joined","MoveEvent","GameState","HistoryReturned","GIFCreated","ErrorEvent"]
def messages := (requestNames.map (fun n=>message n "Client" "GoServer")) ++ (responseNames.map (fun n=>message n "GoServer" "Client"))
def state (id : String) (terminal : Bool := false) : RequirementState := {id,label:=id,group:="protocol",markdown:=id,terminal}
def transition (src dst name : String) : RequirementTransition := {src,dst,message:=name,probabilityNum:=1,probabilityDen:=1,dwellMs:=0}
def atom (task src dst name : String) : GrammarExpr := .event {task,src,dst,message:=name}
def tasks : List TaskRequirement := httpContracts.map fun contract=>
  {id:=contract.task,title:=contract.task,actors:=["Client","GoServer"],initialState:="ready",
   states:=[state "ready",state "checking",state "applied",state "done" true,state "rejected" true],
   transitions:=(contract.requests.map (transition "ready" "checking")) ++
     (if contract.task=="play_turn" then [transition "checking" "applied" "MoveEvent",transition "applied" "done" "GameState"]
      else [transition "checking" "done" (contract.responses.headD "ErrorEvent")]) ++ [transition "checking" "rejected" "ErrorEvent"]}
def grammars : List TaskGrammar := httpContracts.map fun contract=>
  {task:=contract.task,entry:="ready",terminals:=["done","rejected"],body:=
   .choice (contract.requests.map fun req=>
     atom contract.task "Client" "GoServer" req >>> GrammarExpr.choice
       [atom contract.task "GoServer" "Client" "ErrorEvent",
        if contract.task=="play_turn" then atom contract.task "GoServer" "Client" "MoveEvent" >>> atom contract.task "GoServer" "Client" "GameState"
        else atom contract.task "GoServer" "Client" (contract.responses.headD "ErrorEvent")])}
def processes : List RequirementProcess := httpContracts.flatMap fun c=>
  [{actor:="Client",task:=c.task,states:=["ready","done","rejected"],sends:=c.requests,receives:=c.responses},
   {actor:="GoServer",task:=c.task,states:=["checking","applied","done","rejected"],sends:=c.responses,receives:=c.requests}]
def invariants : List (String × String × String) :=
  [("R1","play_turn","Legal actions produce one immutable state transition; rejected actions leave the board and ledgers unchanged."),
   ("R2","play_turn","Both runtimes agree on captures, allowed suicide, cumulative losses, signed matrix, and territory-minus-losses scores."),
   ("R3","play_turn","Only the authenticated current seat at the exact revision can play. Deadline expiry is an explicit automatic Pass, never an invented placement."),
   ("R4","inspect_history","Review never changes a live network game. Local analysis preserves sibling variations and immutable ancestors."),
   ("R5","export_gif","GIF frames are Go-rule replays of exactly the selected root-to-node actions; the final frame is that endpoint."),
   ("R6","create_game","Boards 3..19, players 2..6, at most 512 turns, 2048 local history nodes, 32 rooms, 64 stored exports, 200 export actions, 1 MiB JSON bodies, 60-second turns and bounded cancellable worker search; project state stays under this root. Loopback Host only, same-origin mutation, strict duplicate-free UTF-8 JSON.")]
def outputs : List DesiredOutput := httpContracts.flatMap fun c=>
  [{id:="goserver."++c.task++".schema",prompt:="Produce specifications that lead to a working application.",question:="Which requests and outcomes belong to "++c.task++"?",kind:=.interactionDiagram,eventSource:=c.task++" requirement grammar",reducer:="render requirement-schema alternatives, explicitly not an observed trace",unit:="messages per scenario"},
   {id:="goserver."++c.task++".observed",prompt:="Actually play a game between two users.",question:="Did this actual HTTP exchange follow the declared grammar?",kind:=.interactionDiagram,eventSource:="evidence/playable-v1/browser.json observed_scenarios",reducer:="validate actor/message sequence and cause/prior links, then render this observed exchange",unit:="observed events per request"}]
def spec : RequirementSpec :=
  {id:="goserver.playable-v1",title:="Playable n-player Go experiment",actors:=["Client","GoServer"],
   actorPopulations:=[{actorSpec:="Client",instancePrefix:="client-",count:=6,routing:=.sticky "seat"},{actorSpec:="GoServer",instancePrefix:="server-",count:=1,routing:=.sticky "game_id"}],
   actorResources:=[{actor:="Client",inboundCapacity:=8,outboundCapacity:=8,maxInFlight:=1,memoryBudgetBytes:=134217728},{actor:="GoServer",inboundCapacity:=32,outboundCapacity:=32,maxInFlight:=1,memoryBudgetBytes:=536870912}],
   actorReliability:=[{actor:="Client",outageProbability:={numerator:=0,denominator:=1},meanTimeToRepairMs:=0},{actor:="GoServer",outageProbability:={numerator:=0,denominator:=1},meanTimeToRepairMs:=0}],
   reliabilityGates:=[],actorCosts:=[],messages,tasks,grammars,processes,
   properties:=(invariants.map (fun (name,task,expression)=>{name,task,expression,mode:=.always,probability:=none})) ++
     (httpContracts.map (fun c=>{name:="Visible completion of "++c.task,task:=c.task,expression:="Success or explicit ErrorEvent",mode:=.eventually,probability:=none})),
   requiredProofs:=[{name:="Action atomicity",task:="play_turn",mode:=.always,predicate:="R1: reject without mutation or commit exactly one validated state",probability:=none}],performance:=[],charts:=[],desiredOutputs:=outputs,
   markdown:=[{id:="rules",title:="Exact working rules and negative requirements",body:=rulesSource},{id:="status",title:="Evidence boundary",body:="The operator explicitly requested working implementation experiments. The prior draft's unaccepted gates are not fabricated as accepted. Passing structural, differential, protocol and browser tests is empirical evidence, not a proof of deployed-code refinement or optimal MCTS play."}]}

def validationErrors := validateRequirementSpec spec

-- The ChatUI convenience wrapper closes over ChatUI.spec. Use the reusable
-- grammar renderer with THIS project's grammar and actors, never that wrapper.
def interactionMermaid (task : TaskRequirement) : String :=
  let body := (grammars.find? (·.task==task.id)).map (·.body) |>.getD .empty
  joinWithNewline (["sequenceDiagram"] ++ task.actors.map (fun actor=>"    participant "++actor) ++
    LeanFM.ChatUI.Requirements.grammarInteractionLines "Client,GoServer" body)

def main : IO Unit := do
  let errors := validationErrors ++ validateRequirementProtoFile spec protoSource
  unless errors.isEmpty do throw (IO.userError (joinWithNewline errors))
  IO.FS.createDirAll "spec/views"
  let rows : List Json := (grammars.zip tasks).map fun (pair : TaskGrammar × TaskRequirement) =>
    let g := pair.1
    let t := pair.2
    Json.mkObj
    [("id",toJson t.id),("task",toJson t.id),("title",toJson t.title),("entry",toJson g.entry),
     ("terminals",toJson g.terminals),("actors",toJson t.actors),
     ("states",toJson (t.states.map fun s=>Json.mkObj [("name",toJson s.id),("description",toJson s.label)])),
     ("transitions",toJson (t.transitions.map fun tr=>let m:=messages.find? (·.name==tr.message); Json.mkObj [("message",toJson tr.message),("source",toJson tr.src),("target",toJson tr.dst),("source_actor",toJson (m.map (·.src) |>.getD "")),("destination_actor",toJson (m.map (·.dst) |>.getD ""))])),
     ("properties",toJson (spec.properties.filter (·.task==t.id) |>.map fun p=>Json.mkObj [("name",toJson p.name),("mode",toJson (propertyModeName p.mode)),("expression",toJson p.expression),("formula",toJson (LeanFM.ChatUI.Server.propertyCtlFormula p.mode p.expression)),("origin",toJson "Requirements.lean"),("evidence_kind",toJson "test obligation; not a deployed-code proof")])),
     ("constraints",toJson ([] : List String)),
     ("grammar",(Json.parse (LeanFM.ChatUI.Server.grammarExprJson g.body)).toOption.getD Json.null),
     ("interaction_mermaid",toJson (interactionMermaid t)),
     ("state_mermaid",toJson (LeanFM.ChatUI.Requirements.stateMachineMermaid t))]
  let bindings:=httpContracts.map fun c=>Json.mkObj [("task",toJson c.task),("requests",toJson c.requests),("method",toJson c.method),("path",toJson c.path),("responses",toJson c.responses),("authentication",toJson c.authentication),("request_codec",toJson c.requestCodec),("response_codec",toJson c.responseCodec),("statuses",toJson c.statuses)]
  IO.FS.writeFile "spec/tasks.json" ((Json.mkObj [("source",toJson "spec/Requirements.lean"),("revision",toJson revision),("validation",Json.mkObj [("errors",toJson (0:Nat)),("warnings",toJson (0:Nat))]),("tasks",toJson rows),("http",toJson bindings)]).pretty++"\n")
  for task in tasks do
    IO.FS.writeFile ("spec/views/"++task.id++"-schema.mermaid") (interactionMermaid task++"\n")
  IO.println "ok: playable GoServer requirements and requirements-owned HTTP contracts; six task grammars generated"
end GoServer.Requirements

def main : IO Unit := GoServer.Requirements.main
