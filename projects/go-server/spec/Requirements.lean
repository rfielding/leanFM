import LeanFM.Artifacts

namespace GoServer.Requirements
open LeanFM

def protoSource : String := include_str "Requirements.proto"
def framing : MessageFraming := { kind := .protobufOneof, dispatchField := some "payload", note := "One observable command or event." }
def field (number : Nat) (name : String) (scalar : ProtoScalar) : ProtoFieldSchema := { number, name, scalar }
def message (name src dst : String) (fields : List ProtoFieldSchema) : MessageSchema := { name, src, dst, framing, fields }

-- Core messages (kept in sync with Requirements.proto)
def messages : List MessageSchema :=
  [ message "LoginRequest" "Client" "GoServer" [field 1 "username" .string, field 2 "password" .string]
  , message "LoginResponse" "GoServer" "Client" [field 1 "account_id" .string, field 2 "token" .string, field 3 "expires" .int64]
  , message "Logout" "Client" "GoServer" [field 1 "account_id" .string, field 2 "token" .string]
  , message "CreateGame" "Client" "GoServer" [field 1 "name" .string, field 2 "board" .string, field 3 "rules" .string, field 4 "max_players" .uint64]
  , message "GameCreated" "GoServer" "Client" [field 1 "game_id" .string, field 2 "name" .string]
  , message "JoinGame" "Client" "GoServer" [field 1 "game_id" .string, field 2 "player_name" .string]
  , message "Joined" "GoServer" "Client" [field 1 "game_id" .string, field 2 "player_id" .string, field 3 "assigned_color" .string]
  , message "MakeMove" "Client" "GoServer" [field 1 "game_id" .string, field 2 "player_id" .string, field 3 "x" .uint64, field 4 "y" .uint64]
  , message "Pass" "Client" "GoServer" [field 1 "game_id" .string, field 2 "player_id" .string]
  , message "Resign" "Client" "GoServer" [field 1 "game_id" .string, field 2 "player_id" .string]
  , message "MoveEvent" "GoServer" "Client" [field 1 "game_id" .string, field 2 "player_id" .string, field 3 "changes" .bytes]
  , message "GameState" "GoServer" "Client" [field 1 "game_id" .string, field 2 "players" .bytes, field 3 "board" .bytes, field 4 "to_move_index" .uint64, field 5 "finished" .bool]
  , message "ErrorEvent" "GoServer" "Client" [field 1 "code" .string, field 2 "message" .string] ]

-- Requirement states and transitions

def state (id label group : String) (terminal : Bool := false) : RequirementState := { id, label, group, markdown := label, terminal }
def transition (src dst msg : String) : RequirementTransition := { src, dst, message := msg, probabilityNum := 1, probabilityDen := 1, dwellMs := 0 }

def loginTask : TaskRequirement :=
  { id := "login", title := "Authenticate a client session", actors := ["Client", "GoServer"], initialState := "logged_out"
  , states := [state "logged_out" "not authenticated" "client", state "authenticating" "auth in progress" "server", state "logged_in" "authenticated session" "terminal" true, state "auth_failed" "authentication failed" "terminal" true]
  , transitions := [transition "logged_out" "authenticating" "LoginRequest", transition "authenticating" "logged_in" "LoginResponse", transition "authenticating" "auth_failed" "ErrorEvent"] }

def createTask : TaskRequirement :=
  { id := "create_game", title := "Create an n-player game", actors := ["Client", "GoServer"], initialState := "ready"
  , states := [state "ready" "creation form ready" "client", state "checking" "parameters under validation" "server", state "created" "game created" "terminal" true, state "rejected" "request rejected visibly" "terminal" true]
  , transitions := [transition "ready" "checking" "CreateGame", transition "checking" "created" "GameCreated", transition "checking" "rejected" "ErrorEvent"] }

def joinTask : TaskRequirement :=
  { id := "join_game", title := "Join an open game", actors := ["Client", "GoServer"], initialState := "outside"
  , states := [state "outside" "outside game" "client", state "assigning" "seat assignment pending" "server", state "joined" "joined with one color" "terminal" true, state "rejected" "join rejected visibly" "terminal" true]
  , transitions := [transition "outside" "assigning" "JoinGame", transition "assigning" "joined" "Joined", transition "assigning" "rejected" "ErrorEvent"] }

def turnTask : TaskRequirement :=
  { id := "play_turn", title := "Play, pass, or resign one turn", actors := ["Client", "GoServer"], initialState := "turn"
  , states := [state "turn" "alive player's turn" "client", state "checking" "action legality under validation" "server", state "applied" "action and captures applied" "server", state "updated" "authoritative state visible" "terminal" true, state "rejected" "illegal action rejected without mutation" "terminal" true]
  , transitions := [transition "turn" "checking" "MakeMove", transition "turn" "checking" "Pass", transition "turn" "checking" "Resign", transition "checking" "applied" "MoveEvent", transition "applied" "updated" "GameState", transition "checking" "rejected" "ErrorEvent"] }

-- Grammars for interaction UI and test harnesses

def atom (task src dst msg : String) : GrammarExpr := .event { task, src, dst, message := msg }
def response (task success : String) : GrammarExpr := .choice [atom task "GoServer" "Client" success, atom task "GoServer" "Client" "ErrorEvent"]
def loginGrammar : TaskGrammar := { task := "login", entry := "logged_out", terminals := ["logged_in","auth_failed"], body := atom "login" "Client" "GoServer" "LoginRequest" >>> response "login" "LoginResponse" }
def createGrammar : TaskGrammar := { task := "create_game", entry := "ready", terminals := ["created", "rejected"], body := atom "create_game" "Client" "GoServer" "CreateGame" >>> response "create_game" "GameCreated" }
def joinGrammar : TaskGrammar := { task := "join_game", entry := "outside", terminals := ["joined", "rejected"], body := atom "join_game" "Client" "GoServer" "JoinGame" >>> response "join_game" "Joined" }
def actionBranch (name : String) : GrammarExpr := atom "play_turn" "Client" "GoServer" name >>> (GrammarExpr.choice [atom "play_turn" "GoServer" "Client" "ErrorEvent", atom "play_turn" "GoServer" "Client" "MoveEvent" >>> atom "play_turn" "GoServer" "Client" "GameState"])
def turnGrammar : TaskGrammar := { task := "play_turn", entry := "turn", terminals := ["updated", "rejected"], body := .choice [actionBranch "MakeMove", actionBranch "Pass", actionBranch "Resign"] }


def process (actor task : String) (states sends receives : List String) : RequirementProcess := { actor, task, states, sends, receives }
def processes : List RequirementProcess :=
  [ process "Client" "login" ["logged_out","logged_in","auth_failed"] ["LoginRequest"] ["LoginResponse","ErrorEvent"], process "GoServer" "login" ["authenticating","logged_in","auth_failed"] ["LoginResponse","ErrorEvent"] ["LoginRequest"]
  , process "Client" "create_game" ["ready","created","rejected"] ["CreateGame"] ["GameCreated","ErrorEvent"], process "GoServer" "create_game" ["checking","created","rejected"] ["GameCreated","ErrorEvent"] ["CreateGame"]
  , process "Client" "join_game" ["outside","joined","rejected"] ["JoinGame"] ["Joined","ErrorEvent"], process "GoServer" "join_game" ["assigning","joined","rejected"] ["Joined","ErrorEvent"] ["JoinGame"]
  , process "Client" "play_turn" ["turn","updated","rejected"] ["MakeMove","Pass","Resign"] ["MoveEvent","GameState","ErrorEvent"], process "GoServer" "play_turn" ["checking","applied","updated","rejected"] ["MoveEvent","GameState","ErrorEvent"] ["MakeMove","Pass","Resign"] ]

def tasks := [loginTask, createTask, joinTask, turnTask]
def grammars := [loginGrammar, createGrammar, joinGrammar, turnGrammar]

def outputs : List DesiredOutput := tasks.flatMap fun task =>
  [{id := "goserver." ++ task.id ++ ".interaction", prompt := "Show " ++ task.title ++ ".", question := "Which actor messages complete this scenario?", kind := .interactionDiagram, eventSource := task.id ++ " events", reducer := "render one session/scenario prior order", unit := "events"},
   {id := "goserver." ++ task.id ++ ".state", prompt := "Show " ++ task.title ++ " states.", question := "Which residual states are reachable?", kind := .stateMachine, eventSource := task.id ++ " grammar", reducer := "render grammar residuals", unit := "states and transitions"}]


def spec : RequirementSpec :=
  { id := "goserver.observable", title := "KGS-like n-player Go server", actors := ["Client", "GoServer"]
  , actorPopulations := [{actorSpec := "Client", instancePrefix := "client-", count := 100, routing := .sticky "session_id"}, {actorSpec := "GoServer", instancePrefix := "server-", count := 1, routing := .sticky "game_id"}]
  , actorResources := [{actor := "Client", inboundCapacity := 64, outboundCapacity := 64, maxInFlight := 8, memoryBudgetBytes := 67108864}, {actor := "GoServer", inboundCapacity := 4096, outboundCapacity := 4096, maxInFlight := 1024, memoryBudgetBytes := 1073741824}]
  , actorReliability := [{actor := "Client", outageProbability := {numerator := 0, denominator := 1}, meanTimeToRepairMs := 0}, {actor := "GoServer", outageProbability := {numerator := 0, denominator := 1}, meanTimeToRepairMs := 0}]
  , reliabilityGates := [], actorCosts := [], messages, tasks, grammars, processes
  , properties :=
      [{name := "Creation terminates visibly", mode := .eventually, task := "create_game", expression := "GameCreated or ErrorEvent", probability := none},
       {name := "Joining terminates visibly", mode := .eventually, task := "join_game", expression := "Joined or ErrorEvent", probability := none},
       {name := "Login terminates visibly", mode := .eventually, task := "login", expression := "LoginResponse or ErrorEvent", probability := none},
       {name := "Illegal action cannot mutate board", mode := .always, task := "play_turn", expression := "ErrorEvent terminates without MoveEvent", probability := none},
       {name := "Captures are counted and reflected in GameState", mode := .always, task := "play_turn", expression := "When MoveEvent reports captures, subsequent GameState.players[].captures reflect aggregated counts", probability := none},
       {name := "Server does not autonomously play for clients", mode := .always, task := "play_turn", expression := "MakeMove messages originate from Client actors only (no server-originated MoveEvent without prior Client MakeMove)", probability := none}]
  , requiredProofs := [{name := "Every turn terminates visibly", mode := .eventually, task := "play_turn", predicate := "GameState or ErrorEvent", probability := none}]
  , performance := [], charts := [], desiredOutputs := outputs
  , markdown := [{id := "candidate", title := "Candidate requirements", body := "This typed grammar is a review draft and does not authorize implementation."}, {id := "ui", title := "UI display preference", body := "SVG images under spec/images/ should be displayed inline in the UI for discussion and review. The board_wall_visual.svg is an example and must be rendered inline so stakeholders can inspect board models and captures without downloading files."}] }


def validationErrors := validateRequirementSpec spec
def validationReport : String := if validationErrors.isEmpty then "ok: GoServer candidate requirements are well formed\n" else "invalid GoServer candidate requirements\n" ++ joinWithNewline validationErrors ++ "\n"
#eval IO.print validationReport

end GoServer.Requirements
