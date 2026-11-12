import LeanFM.Session

/-!
# GoServer as session types

The whole of GoServer as one global type, built from the task groups of `Requirements.lean`:
rooms, challenges, play, teams, and watching. Every `#guard` runs when the file is elaborated:
`lake env lean projects/GoServer/spec/Session.lean` from the LeanFM root.

Three roles. `Person` is one browser session; `Server` is `ServerCore`; `Bot` is one slot of the
`BotPool`, a goroutine in the same process.
-/

namespace Project.Session
open LeanFM.Session

inductive Role | person | server | bot
  deriving DecidableEq, Repr, Inhabited

instance : ToString Role := ⟨fun | .person => "Person" | .server => "Server" | .bot => "Bot"⟩

/-! ## Vocabulary: only the fields guards read are typed here; the rest are in Requirements.proto -/

--@begin Types
-- Generated from spec/Requirements.proto by spec/SessionTypes.lean; regenerate it rather than editing.
-- Fields carry their protobuf JSON names, as the Go server sends them.
structure EnterRoom where
  sessionId : String
  roomId : String
  requestId : Nat
  deriving TypeName

structure RoomEntered where
  roomId : String
  gameIds : List String
  requestId : Nat
  deriving TypeName

structure ListGames where
  roomId : String
  sessionId : String
  requestId : Nat
  deriving TypeName

structure GameListed where
  gameId : String
  creator : String
  status : String
  gameName : String
  boardSize : Nat
  seats : Nat
  seatsFilled : Nat
  deriving TypeName

structure GamesListed where
  games : List GameListed
  requestId : Nat
  roomId : String
  deriving TypeName

structure SendRoomChat where
  sessionId : String
  roomId : String
  body : String
  requestId : Nat
  deriving TypeName

structure RoomChat where
  roomId : String
  sender : String
  body : String
  timeMs : Int
  requestId : Nat
  deriving TypeName

structure RequestRejected where
  requestId : Nat
  code : String
  task : String
  scopeId : String
  deriving TypeName

structure CreateRoom where
  sessionId : String
  roomName : String
  requestId : Nat
  deriving TypeName

structure RoomCreated where
  roomId : String
  requestId : Nat
  deriving TypeName

structure SeatPlan where
  seat : Nat
  controller : String
  team : Nat
  deriving TypeName

structure CreateGame where
  sessionId : String
  roomId : String
  gameName : String
  boardSize : Nat
  seats : Nat
  mainTimeMs : Nat
  koRule : Int
  byoyomiMs : Nat
  exploreMilli : Nat
  rewardMode : String
  softness : Nat
  seatPlan : List SeatPlan
  requestId : Nat
  byoyomiPeriods : Nat
  deriving TypeName

structure GameCreated where
  gameId : String
  roomId : String
  creator : String
  status : String
  requestId : Nat
  gameName : String
  boardSize : Nat
  seats : Nat
  mainTimeMs : Nat
  koRule : Int
  byoyomiMs : Nat
  exploreMilli : Nat
  rewardMode : String
  softness : Nat
  seatPlan : List SeatPlan
  byoyomiPeriods : Nat
  deriving TypeName

structure SetSeatPlan where
  sessionId : String
  gameId : String
  seat : Nat
  controller : String
  team : Nat
  requestId : Nat
  deriving TypeName

structure SeatPlanSet where
  gameId : String
  seat : Nat
  controller : String
  team : Nat
  requestId : Nat
  deriving TypeName

structure TakeSeat where
  sessionId : String
  gameId : String
  seat : Nat
  requestId : Nat
  deriving TypeName

structure SeatTaken where
  gameId : String
  seat : Nat
  requestId : Nat
  deriving TypeName

structure LeaveSeat where
  sessionId : String
  gameId : String
  requestId : Nat
  deriving TypeName

structure SeatLeft where
  gameId : String
  seat : Nat
  requestId : Nat
  deriving TypeName

structure StartGame where
  sessionId : String
  gameId : String
  requestId : Nat
  deriving TypeName

structure SeatView where
  seat : Nat
  player : String
  controller : String
  team : Nat
  territory : Int
  losses : Int
  score : Int
  resigned : Bool
  lossesBy : List Nat
  mainLeftMs : Nat
  periodsLeft : Nat
  deriving TypeName

structure GameStarted where
  gameId : String
  seats : List SeatView
  requestId : Nat
  deriving TypeName

structure SetAutopilot where
  sessionId : String
  gameId : String
  on : Bool
  requestId : Nat
  deriving TypeName

structure AutopilotSet where
  gameId : String
  seat : Nat
  on : Bool
  requestId : Nat
  deriving TypeName

structure PlayMove where
  sessionId : String
  gameId : String
  moveNo : Nat
  kind : String
  x : Nat
  y : Nat
  requestId : Nat
  deriving TypeName

structure MovePlayed where
  gameId : String
  moveNo : Nat
  seat : Nat
  kind : String
  x : Nat
  y : Nat
  captured : Nat
  requestId : Nat
  victims : List Nat
  suicide : Nat
  deriving TypeName

structure ProposeMerge where
  sessionId : String
  gameId : String
  otherTeam : Nat
  requestId : Nat
  deriving TypeName

structure MergeProposed where
  gameId : String
  proposalId : Nat
  teamA : Nat
  teamB : Nat
  requestId : Nat
  deriving TypeName

structure RespondMerge where
  sessionId : String
  gameId : String
  proposalId : Nat
  accept : Bool
  requestId : Nat
  deriving TypeName

structure MergeResponded where
  gameId : String
  proposalId : Nat
  status : String
  requestId : Nat
  deriving TypeName

structure GetGameState where
  sessionId : String
  gameId : String
  sinceMove : Nat
  requestId : Nat
  sinceReview : Nat
  deriving TypeName

structure TeamView where
  team : Nat
  seats : List Nat
  territory : Int
  losses : Int
  score : Int
  deriving TypeName

structure MergeView where
  proposalId : Nat
  teamA : Nat
  teamB : Nat
  proposer : String
  acceptedBy : List String
  waitingFor : List String
  deriving TypeName

structure Candidate where
  kind : String
  x : Nat
  y : Nat
  visits : Nat
  rewardPermille : Int
  outlookPermille : List Int
  projMilli : List Int
  deriving TypeName

structure SearchSummary where
  playouts : Nat
  ms : Nat
  candidates : List Candidate
  rootProjMilli : List Int
  rootOutlookPermille : List Int
  guard : Bool
  stop : String
  plannedMs : Nat
  deriving TypeName

structure MoveRecord where
  moveNo : Nat
  seat : Nat
  kind : String
  x : Nat
  y : Nat
  captured : Nat
  source : String
  victims : List Nat
  suicide : Nat
  search : SearchSummary
  deriving TypeName

structure ReviewNode where
  id : String
  parent : String
  kind : String
  x : Nat
  y : Nat
  seat : Nat
  author : String
  timeMs : Int
  deriving TypeName

structure GameState where
  gameId : String
  gameName : String
  status : String
  creator : String
  boardSize : Nat
  koOn : Bool
  mainTimeMs : Nat
  byoyomiMs : Nat
  moveNo : Nat
  toMove : Nat
  remainingMs : Nat
  cells : List Int
  owner : List Int
  seats : List SeatView
  teams : List TeamView
  proposals : List MergeView
  moves : List MoveRecord
  winners : List Nat
  endReason : String
  exploreMilli : Nat
  rewardMode : String
  softness : Nat
  requestId : Nat
  byoyomiPeriods : Nat
  review : List ReviewNode
  reviewCount : Nat
  deriving TypeName

structure BotTurn where
  gameId : String
  turnSeq : Nat
  seat : Nat
  moveNo : Nat
  budgetMs : Nat
  deriving TypeName

structure BotMoveChosen where
  gameId : String
  turnSeq : Nat
  kind : String
  x : Nat
  y : Nat
  search : SearchSummary
  deriving TypeName

structure BotMovePlayed where
  gameId : String
  record : MoveRecord
  deriving TypeName

structure TurnTimedOut where
  gameId : String
  moveNo : Nat
  seat : Nat
  deriving TypeName

structure AutoPassed where
  gameId : String
  moveNo : Nat
  seat : Nat
  deriving TypeName

structure TeamsMerged where
  gameId : String
  proposalId : Nat
  team : Nat
  seats : List Nat
  deriving TypeName

structure MergeWithdrawn where
  gameId : String
  proposalId : Nat
  reason : String
  deriving TypeName

structure Applied where deriving TypeName

structure Stale where deriving TypeName

structure ClockRanOut where deriving TypeName

structure Passed where deriving TypeName

structure Finished where deriving TypeName
--@end Types

/-! ## Rooms -/

--@begin Rooms
protocol CreateRoomP (Person, Server) {
  q: CreateRoom from Person to Server;
  choice {
    a: RoomCreated from Server to Person cause q where a.requestId = q.requestId;
  } or {
    x: RequestRejected from Server to Person cause q where x.requestId = q.requestId;
  }
}

protocol EnterRoomP (Person, Server) {
  q: EnterRoom from Person to Server;
  choice {
    a: RoomEntered from Server to Person cause q
       where a.requestId = q.requestId ∧ a.roomId = q.roomId;
  } or {
    x: RequestRejected from Server to Person cause q where x.requestId = q.requestId;
  }
}

protocol ListGamesP (Person, Server) {
  q: ListGames from Person to Server;
  choice {
    a: GamesListed from Server to Person cause q
       where a.requestId = q.requestId ∧ a.roomId = q.roomId;
  } or {
    x: RequestRejected from Server to Person cause q where x.requestId = q.requestId;
  }
}

protocol RoomChatP (Person, Server) {
  q: SendRoomChat from Person to Server;
  choice {
    a: RoomChat from Server to Person cause q where a.requestId = q.requestId;
  } or {
    x: RequestRejected from Server to Person cause q where x.requestId = q.requestId;
  }
}
--@end Rooms

/-! ## Challenges: from CreateGame to StartGame -/

--@begin Challenge
protocol CreateGameP (Person, Server) {
  q: CreateGame from Person to Server;
  choice {
    a: GameCreated from Server to Person cause q where a.requestId = q.requestId;
  } or {
    x: RequestRejected from Server to Person cause q where x.requestId = q.requestId;
  }
}

protocol TakeSeatP (Person, Server) {
  q: TakeSeat from Person to Server;
  choice {
    a: SeatTaken from Server to Person cause q where a.requestId = q.requestId;
  } or {
    x: RequestRejected from Server to Person cause q where x.requestId = q.requestId;
  }
}

protocol StartGameP (Person, Server) {
  q: StartGame from Person to Server;
  choice {
    a: GameStarted from Server to Person cause q where a.requestId = q.requestId;
  } or {
    x: RequestRejected from Server to Person cause q where x.requestId = q.requestId;
  }
}

/-- Before the start the creator plans seats, people take and leave them, and anyone in the
room may watch; the creator ends the phase with StartGame. -/
protocol Challenge (Person, Server) {
  include CreateGameP Person Server;
  rec Open {
    choice {
      p: SetSeatPlan from Person to Server;
      choice {
        SeatPlanSet from Server to Person cause p;
      } or {
        RequestRejected from Server to Person cause p;
      }
      continue Open;
    } or {
      include TakeSeatP Person Server;
      continue Open;
    } or {
      l: LeaveSeat from Person to Server;
      choice {
        SeatLeft from Server to Person cause l;
      } or {
        RequestRejected from Server to Person cause l;
      }
      continue Open;
    } or {
      include StartGameP Person Server;
    }
  }
}
--@end Challenge

/-! ## Play: who ends a turn -/

--@begin Play
/-- A person's move is a request in its own session. The server answers it, or refuses it:
not this person's turn, a stale move number, the seat's byo-yomi clock already run out. -/
protocol PlayMoveP (Person, Server) {
  m: PlayMove from Person to Server;
  choice {
    p: MovePlayed from Server to Person cause m
       where p.requestId = m.requestId ∧ p.moveNo = m.moveNo;
  } or {
    x: RequestRejected from Server to Person cause m where x.requestId = m.requestId;
  }
}

/-- One bot search, bound to its turn revision. The result is applied only if the turn it was
dispatched for is still the current one; otherwise it is dropped. -/
protocol BotTurnP (Server, Bot) {
  t: BotTurn from Server to Bot;
  c: BotMoveChosen from Bot to Server cause t where c.turnSeq = t.turnSeq;
  choice {
    Applied at Server;
  } or {
    Stale at Server;
  }
}

/-- The server's side of one turn: a bot (or autopilot) plays it, the seat's byo-yomi clock ends it, or a
resigned seat passes. A person's own move ends it through PlayMoveP, in another session.
Everything here is recorded at the server; people see it through GameState. -/
protocol Turn (Server, Bot) {
  choice {
    include BotTurnP Server Bot;
  } or {
    ClockRanOut at Server;
  } or {
    Passed at Server;
  }
}

/-- A first attempt: the person's move as one more branch of the turn. -/
protocol TurnNaive (Person, Server, Bot) {
  choice {
    include BotTurnP Server Bot;
  } or {
    ClockRanOut at Server;
  } or {
    m: PlayMove from Person to Server;
    MovePlayed from Server to Person cause m;
  }
}

/-- A first attempt at telling people: the server sends each outcome as it happens. -/
protocol TurnPushed (Person, Server, Bot) {
  choice {
    t: BotTurn from Server to Bot;
    c: BotMoveChosen from Bot to Server cause t;
    BotMovePlayed from Server to Person cause c;
  } or {
    ClockRanOut at Server;
    TurnTimedOut from Server to Person;
  } or {
    AutoPassed from Server to Person;
  }
}
--@end Play

/-! ## Teams -/

--@begin Teams
protocol ProposeMergeP (Person, Server) {
  q: ProposeMerge from Person to Server;
  choice {
    a: MergeProposed from Server to Person cause q where a.requestId = q.requestId;
  } or {
    x: RequestRejected from Server to Person cause q where x.requestId = q.requestId;
  }
}

/-- A first attempt at one answer to a proposal: the response, then perhaps the outcome. -/
protocol RespondMergeNaive (Person, Server) {
  q: RespondMerge from Person to Server;
  choice {
    MergeResponded from Server to Person cause q;
    choice {
      TeamsMerged from Server to Person;
    } or {
      MergeWithdrawn from Server to Person;
    } or {
    }
  } or {
    RequestRejected from Server to Person cause q;
  }
}

/-- One answer to a proposal. The response says where the proposal stands: still pending,
merged (this was the last acceptance) or withdrawn (a decline, or a team changed). -/
protocol RespondMergeP (Person, Server) {
  q: RespondMerge from Person to Server;
  choice {
    a: MergeResponded from Server to Person cause q
       where a.requestId = q.requestId ∧ a.proposalId = q.proposalId ∧
             (a.status = "pending" ∨ a.status = "merged" ∨ a.status = "withdrawn");
  } or {
    x: RequestRejected from Server to Person cause q where x.requestId = q.requestId;
  }
}
--@end Teams

/-! ## Watching -/

--@begin Watch
protocol GameStateP (Person, Server) {
  q: GetGameState from Person to Server;
  choice {
    a: GameState from Server to Person cause q where a.requestId = q.requestId;
  } or {
    x: RequestRejected from Server to Person cause q where x.requestId = q.requestId;
  }
}
--@end Watch

/-! ## The whole project -/

--@begin GoServer
/-- GoServer, all of it. In a room a person creates rooms, lists games and chats; a challenge
runs to its start; then the server plays turn after turn until the game finishes, while any
number of independent request sessions run beside it. -/
protocol GoServer (Person, Server, Bot) {
  include EnterRoomP Person Server;
  rec Lobby {
    choice {
      include CreateRoomP Person Server;
      continue Lobby;
    } or {
      include ListGamesP Person Server;
      continue Lobby;
    } or {
      include RoomChatP Person Server;
      continue Lobby;
    } or {
      include Challenge Person Server;
    }
  }
  par {
    rec Turns {
      choice {
        include Turn Server Bot;
        continue Turns;
      } or {
        Finished at Server;
      }
    }
  } and {
    sessions { include PlayMoveP Person Server; }
  } and {
    sessions {
      a: SetAutopilot from Person to Server;
      choice {
        AutopilotSet from Server to Person cause a;
      } or {
        RequestRejected from Server to Person cause a;
      }
    }
  } and {
    sessions {
      choice {
        include ProposeMergeP Person Server;
      } or {
        include RespondMergeP Person Server;
      }
    }
  } and {
    sessions { include GameStateP Person Server; }
  }
}
--@end GoServer

def roles : List Role := [.person, .server, .bot]
def goServer : Global Role := GoServer .person .server .bot

/-! ## Checks -/

def ps : List Role := [.person, .server]
def sb : List Role := [.server, .bot]

/-- The task groups, each with the roles that take part in it. -/
def groups : List (String × Global Role × List Role) :=
  [ ("enterRoom", EnterRoomP .person .server, ps), ("createRoom", CreateRoomP .person .server, ps)
  , ("listGames", ListGamesP .person .server, ps), ("roomChat", RoomChatP .person .server, ps)
  , ("challenge", Challenge .person .server, ps)
  , ("playMove", PlayMoveP .person .server, ps), ("botTurn", BotTurnP .server .bot, sb)
  , ("turn", Turn .server .bot, sb)
  , ("proposeMerge", ProposeMergeP .person .server, ps), ("respondMerge", RespondMergeP .person .server, ps)
  , ("gameState", GameStateP .person .server, ps) ]

-- Every group is well formed: one decider per choice, causes a role has seen, and a projection
-- for every role that takes part.
#guard groups.all (fun (_, g, rs) => g.issues rs == [])

-- The whole project too.
#guard goServer.issues roles == []

-- The first attempt at a turn is not: the person's move races the server's clock and the bot.
#guard (TurnNaive Role.person Role.server Role.bot).issues roles ==
  [ "no single role decides a choice, so it is a race: Server starts BotTurn or ClockRanOut; Person starts PlayMove" ]

-- Nor is the first attempt at answering a merge: after MergeResponded the person cannot tell
-- whether an outcome is still coming.
#guard (RespondMergeNaive Role.person Role.server).issues ps ==
  [ "Person cannot tell which branch Server chose" ]

/-! ## HTTP: who may call whom -/

/-- People and the server talk HTTP; the bot pool is an in-process channel. -/
def isHttp : Role → Role → Bool
  | .bot, _ | _, .bot => false
  | _, _ => true

/-- A person calls the server. The server calls nobody over HTTP. -/
def mayCall : Role → Role → Bool
  | .person, .server => true
  | _, _ => false

-- Pushing outcomes is not HTTP: they answer nothing a person asked, so they are cuts.
#guard (TurnPushed Role.person Role.server Role.bot).httpCuts isHttp mayCall ==
  [ "BotMovePlayed is a request from Server to Person, which Server may not call"
  , "TurnTimedOut is a request from Server to Person, which Server may not call"
  , "AutoPassed is a request from Server to Person, which Server may not call"
  , "BotMovePlayed from Server to Person never gets a response"
  , "TurnTimedOut from Server to Person never gets a response"
  , "AutoPassed from Server to Person never gets a response" ]

-- Recorded at the server and read through GameState, every message of the whole project is a
-- request a person may make, or the answer to one, going back to that person.
#guard goServer.httpCuts isHttp mayCall == []

/-! ## Physics, handled conditions and the deployment -/

def physics : Physics Role :=
  { channels := [ (.person, .server, http), (.server, .person, http)
                , (.server, .bot, reliable 8), (.bot, .server, reliable 8) ] }

/-- `request_id` makes a retried request harmless (the replay cache answers it again); a busy
server rejects without mutation; a closed connection is retried; a timeout is the client's. -/
def handles : List (Role × Role × List Condition) :=
  let httpAll : List Condition := [.timeout, .duplicate, .reorder, .reject, .close]
  [ (.person, .server, httpAll), (.server, .person, httpAll) ]

def specs : List (Spec Role) :=
  groups.map (fun (_, g, rs) => { global := g, roles := rs, physics, handles })

#guard specs.all (fun s => s.issues == [])

open Node in
def deployment : Topology Role :=
  { world := [
      outside [ .actor .person [] ],
      island "local" [ datacenter "host" [ machine "loopback" [
        .actor .server [ ingress "http" .ingressHttp ],
        .actor .bot [ «local» "slots" .queue ] ] ] ] ] }

def reach (src : Role) (name : String) : Bool :=
  ((deployment.find name).map (deployment.reachable src ·)).getD false

-- A browser reaches the server only through its HTTP ingress, and never a bot slot.
#guard reach .person "local.Server.ingress.http"
#guard !reach .person "local.Bot.local.slots"
#guard reach .server "local.Bot.local.slots"

/-! ## Report

`lake env lean --run projects/GoServer/spec/Session.lean` prints what the checker says, and keeps
it in `projects/GoServer/reports/session/report.json`. -/

open Lean in
def localText (g : Global Role) (r : Role) : String :=
  match g.project r with
  | .ok l => l.render
  | .error e => "rejected: " ++ e

open Lean in
def report : Json :=
  let strs (xs : List String) := Json.arr (xs.map Json.str).toArray
  Json.mkObj
    [ ("groups", Json.arr (groups.map (fun (n, g, rs) => Json.mkObj
        [("name", n), ("roles", strs (rs.map toString)), ("issues", strs (g.issues rs))])).toArray)
    , ("whole", strs (goServer.issues roles))
    , ("wholeCuts", strs (goServer.httpCuts isHttp mayCall))
    , ("turnNaive", strs ((TurnNaive Role.person Role.server Role.bot).issues roles))
    , ("respondMergeNaive", strs ((RespondMergeNaive Role.person Role.server).issues ps))
    , ("turnPushedCuts", strs ((TurnPushed Role.person Role.server Role.bot).httpCuts isHttp mayCall))
    , ("locals", Json.mkObj
        [ ("playMovePerson", localText (PlayMoveP .person .server) .person)
        , ("playMoveServer", localText (PlayMoveP .person .server) .server)
        , ("turnServer", localText (Turn .server .bot) .server)
        , ("turnBot", localText (Turn .server .bot) .bot)
        , ("challengeServer", localText (Challenge .person .server) .server)
        , ("wholeBot", localText goServer .bot)
        , ("wholePerson", localText goServer .person)
        , ("wholeServer", localText goServer .server) ])
    , ("reach", Json.mkObj
        [ ("personToServer", toJson (reach .person "local.Server.ingress.http"))
        , ("personToBot", toJson (reach .person "local.Bot.local.slots"))
        , ("serverToBot", toJson (reach .server "local.Bot.local.slots")) ])
    , ("tftpStyleIssues", Json.arr (specs.map (fun sp => strs sp.issues)).toArray) ]

def main : IO Unit := do
  for (n, g, rs) in groups do
    let is := g.issues rs
    IO.println s!"{n}: {if is.isEmpty then "well formed" else toString is}"
  IO.println s!"GoServer (whole): {if (goServer.issues roles).isEmpty then "well formed" else toString (goServer.issues roles)}"
  IO.println s!"GoServer over HTTP: {if (goServer.httpCuts isHttp mayCall).isEmpty then "no cuts" else "cuts"}"
  IO.println s!"TurnNaive: {(TurnNaive Role.person Role.server Role.bot).issues roles}"
  IO.println s!"RespondMergeNaive: {(RespondMergeNaive Role.person Role.server).issues ps}"
  IO.println s!"TurnPushed over HTTP: {(TurnPushed Role.person Role.server Role.bot).httpCuts isHttp mayCall}"
  IO.FS.createDirAll "projects/GoServer/reports/session"
  IO.FS.writeFile "projects/GoServer/reports/session/report.json" report.pretty

end Project.Session

def main : IO Unit := Project.Session.main
