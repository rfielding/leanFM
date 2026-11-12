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

-- Rooms
structure CreateRoom     where requestId : Nat deriving TypeName
structure RoomCreated    where requestId : Nat deriving TypeName
structure ListRooms      where requestId : Nat deriving TypeName
structure RoomsListed    where requestId : Nat deriving TypeName
structure EnterRoom      where
  requestId : Nat
  roomId : String
  deriving TypeName
structure RoomEntered    where
  requestId : Nat
  roomId : String
  deriving TypeName
structure ListGames      where
  requestId : Nat
  roomId : String
  deriving TypeName
structure GamesListed    where
  requestId : Nat
  roomId : String
  deriving TypeName
structure SendRoomChat   where requestId : Nat deriving TypeName
structure RoomChat       where requestId : Nat deriving TypeName
-- Challenges
structure CreateGame     where requestId : Nat deriving TypeName
structure GameCreated    where requestId : Nat deriving TypeName
structure SetSeatPlan    where requestId : Nat deriving TypeName
structure SeatPlanSet    where requestId : Nat deriving TypeName
structure TakeSeat       where requestId : Nat deriving TypeName
structure SeatTaken      where requestId : Nat deriving TypeName
structure LeaveSeat      where requestId : Nat deriving TypeName
structure SeatLeft       where requestId : Nat deriving TypeName
structure StartGame      where requestId : Nat deriving TypeName
structure GameStarted    where requestId : Nat deriving TypeName
structure JoinGame       where
  requestId : Nat
  gameId : String
  deriving TypeName
structure GameJoined     where
  requestId : Nat
  gameId : String
  deriving TypeName
structure SendGameChat   where requestId : Nat deriving TypeName
structure GameChat       where requestId : Nat deriving TypeName
-- Play
structure PlayMove       where
  requestId : Nat
  moveNo : Nat
  deriving TypeName
structure MovePlayed     where
  requestId : Nat
  moveNo : Nat
  deriving TypeName
structure SetAutopilot   where requestId : Nat deriving TypeName
structure AutopilotSet   where requestId : Nat deriving TypeName
structure BotTurn        where
  turnSeq : Nat
  moveNo : Nat
  deriving TypeName
structure BotMoveChosen  where turnSeq : Nat deriving TypeName
structure BotMovePlayed  where moveNo : Nat deriving TypeName
structure TurnTimedOut   where moveNo : Nat deriving TypeName
structure AutoPassed     where moveNo : Nat deriving TypeName
structure GameFinished   where deriving TypeName
-- Teams
structure ProposeMerge   where requestId : Nat deriving TypeName
structure MergeProposed  where
  requestId : Nat
  proposalId : Nat
  deriving TypeName
structure RespondMerge   where
  requestId : Nat
  proposalId : Nat
  deriving TypeName
structure MergeResponded where
  requestId : Nat
  proposalId : Nat
  status : String
  deriving TypeName
structure TeamsMerged    where proposalId : Nat deriving TypeName
structure MergeWithdrawn where proposalId : Nat deriving TypeName
-- Watching
structure GetGameState   where
  requestId : Nat
  sinceMove : Nat
  deriving TypeName
structure GameState      where requestId : Nat deriving TypeName
-- Every request can be refused, without mutation, naming the request it refuses.
structure RequestRejected where requestId : Nat deriving TypeName
-- Events at the server alone: its clock, a bot result applied or discarded, a recorded outcome.
structure ClockRanOut    where deriving TypeName
structure Applied        where deriving TypeName
structure Stale          where deriving TypeName
structure Passed         where deriving TypeName
structure Finished       where deriving TypeName

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
