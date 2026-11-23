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
  sessionId : Link String
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
  sessionId : Link String
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

structure JoinGame where
  sessionId : Link String
  gameId : String
  requestId : Nat
  deriving TypeName

structure GameJoined where
  gameId : String
  participants : List String
  requestId : Nat
  deriving TypeName

structure SendRoomChat where
  sessionId : Link String
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
  sessionId : Link String
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
  sessionId : Link String
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
  gameId : Fresh String
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
  sessionId : Link String
  gameId : Link String
  seat : Nat
  controller : String
  team : Nat
  requestId : Nat
  deriving TypeName

structure SeatPlanSet where
  gameId : Link String
  seat : Nat
  controller : String
  team : Nat
  requestId : Nat
  deriving TypeName

structure TakeSeat where
  sessionId : Link String
  gameId : Link String
  seat : Nat
  requestId : Nat
  deriving TypeName

structure SeatTaken where
  gameId : Link String
  seat : Nat
  requestId : Nat
  deriving TypeName

structure LeaveSeat where
  sessionId : Link String
  gameId : Link String
  requestId : Nat
  deriving TypeName

structure SeatLeft where
  gameId : Link String
  seat : Nat
  requestId : Nat
  deriving TypeName

structure StartGame where
  sessionId : Link String
  gameId : Link String
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
  gameId : Link String
  seats : List SeatView
  requestId : Nat
  deriving TypeName

structure SetAutopilot where
  sessionId : Link String
  gameId : Link String
  on : Bool
  requestId : Nat
  deriving TypeName

structure AutopilotSet where
  gameId : Link String
  seat : Nat
  on : Bool
  requestId : Nat
  deriving TypeName

structure PlayMove where
  sessionId : Link String
  gameId : Link String
  moveNo : Nat
  kind : String
  x : Nat
  y : Nat
  requestId : Nat
  deriving TypeName

structure MovePlayed where
  gameId : Link String
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
  sessionId : Link String
  gameId : Link String
  otherTeam : Nat
  requestId : Nat
  deriving TypeName

structure MergeProposed where
  gameId : Link String
  proposalId : Nat
  teamA : Nat
  teamB : Nat
  requestId : Nat
  deriving TypeName

structure RespondMerge where
  sessionId : Link String
  gameId : Link String
  proposalId : Nat
  accept : Bool
  requestId : Nat
  deriving TypeName

structure MergeResponded where
  gameId : Link String
  proposalId : Nat
  status : String
  requestId : Nat
  deriving TypeName

structure GetGameState where
  sessionId : Link String
  gameId : Link String
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
  gameId : Link String
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
  gameId : Link String
  turnSeq : Nat
  seat : Nat
  moveNo : Nat
  budgetMs : Nat
  deriving TypeName

structure BotMoveChosen where
  gameId : Link String
  turnSeq : Nat
  kind : String
  x : Nat
  y : Nat
  search : SearchSummary
  deriving TypeName

structure BotMovePlayed where
  gameId : Link String
  record : MoveRecord
  deriving TypeName

structure TurnTimedOut where
  gameId : Link String
  moveNo : Nat
  seat : Nat
  deriving TypeName

structure AutoPassed where
  gameId : Link String
  moveNo : Nat
  seat : Nat
  deriving TypeName

structure TeamsMerged where
  gameId : Link String
  proposalId : Nat
  team : Nat
  seats : List Nat
  deriving TypeName

structure MergeWithdrawn where
  gameId : Link String
  proposalId : Nat
  reason : String
  deriving TypeName

structure IssueSession where
  identity : String
  password : String
  requestId : Nat
  deriving TypeName

structure SessionIssued where
  sessionId : Fresh String
  identity : String
  claimed : Bool
  requestId : Nat
  deriving TypeName

/-- A refused sign-in: a wrong password, a claimed name, or too many attempts (HTTP 401 or 429). -/
structure SignInRefused where
  error : String
  deriving TypeName

structure SignOut where
  sessionId : Link String
  requestId : Nat
  deriving TypeName

structure SignedOut where
  requestId : Nat
  deriving TypeName

structure Applied where deriving TypeName

structure Stale where deriving TypeName

structure ClockRanOut where deriving TypeName

structure Passed where deriving TypeName

structure Finished where deriving TypeName
--@end Types

/-! ## Rooms -/

--@begin Rooms
protocol CreateRoomP (Person, Server) given sessionId {
  q: CreateRoom from Person to Server route "POST /api/create_room";
  choice {
    a: RoomCreated from Server to Person cause q status 200 where a.requestId = q.requestId;
  } or {
    x: RequestRejected from Server to Person cause q status 200 where x.requestId = q.requestId;
  }
}

protocol EnterRoomP (Person, Server) {
  q: EnterRoom from Person to Server route "POST /api/enter_room";
  choice {
    a: RoomEntered from Server to Person cause q status 200
       where a.requestId = q.requestId ∧ a.roomId = q.roomId;
  } or {
    x: RequestRejected from Server to Person cause q status 200 where x.requestId = q.requestId;
  }
}

protocol ListGamesP (Person, Server) given sessionId {
  q: ListGames from Person to Server route "POST /api/list_games";
  choice {
    a: GamesListed from Server to Person cause q status 200
       where a.requestId = q.requestId ∧ a.roomId = q.roomId;
  } or {
    x: RequestRejected from Server to Person cause q status 200 where x.requestId = q.requestId;
  }
}

protocol RoomChatP (Person, Server) given sessionId {
  q: SendRoomChat from Person to Server route "POST /api/send_room_chat";
  choice {
    a: RoomChat from Server to Person cause q status 200 where a.requestId = q.requestId;
  } or {
    x: RequestRejected from Server to Person cause q status 200 where x.requestId = q.requestId;
  }
}
--@end Rooms

/-! ## Challenges: from CreateGame to StartGame -/

--@begin Challenge
protocol CreateGameP (Person, Server) {
  q: CreateGame from Person to Server route "POST /api/create_game";
  choice {
    a: GameCreated from Server to Person cause q status 200 where a.requestId = q.requestId;
  } or {
    x: RequestRejected from Server to Person cause q status 200 where x.requestId = q.requestId;
  }
}

protocol TakeSeatP (Person, Server) given sessionId gameId {
  q: TakeSeat from Person to Server route "POST /api/take_seat";
  choice {
    a: SeatTaken from Server to Person cause q status 200 where a.requestId = q.requestId;
  } or {
    x: RequestRejected from Server to Person cause q status 200 where x.requestId = q.requestId;
  }
}

protocol StartGameP (Person, Server) {
  q: StartGame from Person to Server route "POST /api/start_game";
  choice {
    a: GameStarted from Server to Person cause q status 200 where a.requestId = q.requestId;
  } or {
    x: RequestRejected from Server to Person cause q status 200 where x.requestId = q.requestId;
  }
}

/-- After GameCreated, before the start: the creator plans seats, people take and leave them,
and anyone in the room may watch. The phase ends only when StartGame is accepted; a rejected
StartGame (seats not filled, not the creator) leaves the challenge open. -/
protocol Challenge (Person, Server) given sessionId gameId {
  rec Open {
    choice {
      p: SetSeatPlan from Person to Server route "POST /api/set_seat_plan";
      choice {
        SeatPlanSet from Server to Person cause p status 200;
      } or {
        RequestRejected from Server to Person cause p status 200;
      }
      continue Open;
    } or {
      include TakeSeatP Person Server with sessionId, gameId;
      continue Open;
    } or {
      l: LeaveSeat from Person to Server route "POST /api/leave_seat";
      choice {
        SeatLeft from Server to Person cause l status 200;
      } or {
        RequestRejected from Server to Person cause l status 200;
      }
      continue Open;
    } or {
      s: StartGame from Person to Server route "POST /api/start_game";
      choice {
        a: GameStarted from Server to Person cause s status 200 where a.requestId = s.requestId;
      } or {
        x: RequestRejected from Server to Person cause s status 200 where x.requestId = s.requestId;
        continue Open;
      }
    }
  }
}
--@end Challenge

/-! ## Play: who ends a turn -/

--@begin Play
/-- A person's move is a request in its own session. The server answers it, or refuses it:
not this person's turn, a stale move number, the seat's byo-yomi clock already run out. -/
protocol PlayMoveP (Person, Server) given sessionId gameId {
  m: PlayMove from Person to Server route "POST /api/play_move";
  choice {
    p: MovePlayed from Server to Person cause m status 200
       where p.requestId = m.requestId ∧ p.moveNo = m.moveNo;
  } or {
    x: RequestRejected from Server to Person cause m status 200 where x.requestId = m.requestId;
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
    m: PlayMove from Person to Server route "POST /api/play_move";
    MovePlayed from Server to Person cause m status 200;
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
/-- Autopilot for one's own seat, a request in its own session. -/
protocol SetAutopilotP (Person, Server) given sessionId gameId {
  a: SetAutopilot from Person to Server route "POST /api/set_autopilot";
  choice {
    AutopilotSet from Server to Person cause a status 200;
  } or {
    RequestRejected from Server to Person cause a status 200;
  }
}
--@end Play

/-! ## Teams -/

--@begin Teams
protocol ProposeMergeP (Person, Server) given sessionId gameId {
  q: ProposeMerge from Person to Server route "POST /api/propose_merge";
  choice {
    a: MergeProposed from Server to Person cause q status 200 where a.requestId = q.requestId;
  } or {
    x: RequestRejected from Server to Person cause q status 200 where x.requestId = q.requestId;
  }
}

/-- A first attempt at one answer to a proposal: the response, then perhaps the outcome. -/
protocol RespondMergeNaive (Person, Server) {
  q: RespondMerge from Person to Server route "POST /api/respond_merge";
  choice {
    MergeResponded from Server to Person cause q status 200;
    choice {
      TeamsMerged from Server to Person;
    } or {
      MergeWithdrawn from Server to Person;
    } or {
    }
  } or {
    RequestRejected from Server to Person cause q status 200;
  }
}

/-- One answer to a proposal. The response says where the proposal stands: still pending,
merged (this was the last acceptance) or withdrawn (a decline, or a team changed). -/
protocol RespondMergeP (Person, Server) given sessionId gameId {
  q: RespondMerge from Person to Server route "POST /api/respond_merge";
  choice {
    a: MergeResponded from Server to Person cause q status 200
       where a.requestId = q.requestId ∧ a.proposalId = q.proposalId ∧
             (a.status = "pending" ∨ a.status = "merged" ∨ a.status = "withdrawn");
  } or {
    x: RequestRejected from Server to Person cause q status 200 where x.requestId = q.requestId;
  }
}
--@end Teams

/-! ## Watching -/

--@begin Watch
protocol GameStateP (Person, Server) given sessionId gameId {
  q: GetGameState from Person to Server route "POST /api/game_state";
  choice {
    a: GameState from Server to Person cause q status 200 where a.requestId = q.requestId;
  } or {
    x: RequestRejected from Server to Person cause q status 200 where x.requestId = q.requestId;
  }
}
--@end Watch

/-! ## The whole project -/

--@begin GoServer
/-- One game, a session of its own: its creator's CreateGame, answered by GameCreated, which mints the
game's id; then the challenge, run by the creator, and the server's turns until the game finishes.
A rejected CreateGame ends it. -/
protocol GameP (Person, Server, Bot) given sessionId {
  g: CreateGame from Person to Server route "POST /api/create_game";
  choice {
    c: GameCreated from Server to Person cause g status 200 where c.requestId = g.requestId;
    include Challenge Person Server with sessionId, gameId;
    rec Turns {
      choice {
        include Turn Server Bot;
        continue Turns;
      } or {
        Finished at Server;
      }
    }
  } or {
    x: RequestRejected from Server to Person cause g status 200 where x.requestId = g.requestId;
  }
}

/-- A person's place in a game they picked: taking a seat, then any number of independent requests,
each its own session given both the person's session and the game, so each belongs to both. -/
protocol SeatP (Person, Server) given sessionId gameId {
  include TakeSeatP Person Server with sessionId, gameId;
  par {
    sessions { include PlayMoveP Person Server with sessionId, gameId; }
  } and {
    sessions { include SetAutopilotP Person Server with sessionId, gameId; }
  } and {
    sessions {
      choice {
        include ProposeMergeP Person Server with sessionId, gameId;
      } or {
        include RespondMergeP Person Server with sessionId, gameId;
      }
    }
  } and {
    sessions { include GameStateP Person Server with sessionId, gameId; }
  }
}

/-- GoServer, one person's part of it. A person signs in, which mints the session every later request
carries (a refused sign-in, a wrong password, a claimed name or a throttled name, is retried); then
enters a room (a rejected entry is retried). Listing the room's games runs beside everything else, as the
browser polls it. In the room they create rooms and chat;
start a game, which runs as a session of its own beside the lobby; or pick a game (its id only a
reference) and take part in it, also beside the lobby; or sign out, which ends their session. -/
protocol GoServer (Person, Server, Bot) {
  rec SignIn {
    i: IssueSession from Person to Server route "POST /api/issue_session";
    choice {
      SessionIssued from Server to Person cause i status 200;
    } or {
      SignInRefused from Server to Person cause i status 401;
      continue SignIn;
    }
  }
  rec Enter {
    e: EnterRoom from Person to Server route "POST /api/enter_room";
    choice {
      a: RoomEntered from Server to Person cause e status 200
         where a.requestId = e.requestId ∧ a.roomId = e.roomId;
    } or {
      x: RequestRejected from Server to Person cause e status 200 where x.requestId = e.requestId;
      continue Enter;
    }
  }
  par {
    sessions { include ListGamesP Person Server with sessionId; }
  } and {
  rec Lobby {
    choice {
      include CreateRoomP Person Server with sessionId;
      continue Lobby;
    } or {
      include RoomChatP Person Server with sessionId;
      continue Lobby;
    } or {
      sessions { include GameP Person Server Bot with sessionId; }
      continue Lobby;
    } or {
      j: JoinGame from Person to Server route "POST /api/join_game";
      choice {
        GameJoined from Server to Person cause j status 200;
        sessions { include SeatP Person Server with sessionId, gameId; }
        continue Lobby;
      } or {
        RequestRejected from Server to Person cause j status 200;
        continue Lobby;
      }
    } or {
      o: SignOut from Person to Server route "POST /api/sign_out";
      SignedOut from Server to Person cause o status 200;
    }
  }
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
