import LeanFM.SessionTools
import LeanFM.Session.Syntax

/-! Tests for selfhost.session.identity.marks (decision session-identity-marks): a field says whether
it mints a session (Fresh) or names one (Link), and where it travels (header, path, query, body). -/
namespace LeanFM.Session.IdentityTests
open Lean LeanFM LeanFM.Session LeanFM.SessionTools

def orders := "structure CreateOrder where
  item : String
structure Created where
  orderId : Header (Fresh String)
structure GetOrder where
  orderId : PathParam (Link String)
  verbose : QueryParam Bool
structure Order where
  orderId : Link String
  item : String
protocol Orders (Client, Api) {
  c: CreateOrder from Client to Api route \"POST /orders\";
  Created from Api to Client cause c status 201;
  g: GetOrder from Client to Api route \"GET /orders/{orderId}\";
  Order from Api to Client cause g status 200;
}"
def a (t : String) (extra : List (String × Json) := []) : Json := Json.mkObj ([("lean", Json.str t)] ++ extra)
def has (s part : String) : Bool := (s.splitOn part).length > 1
def reason (r : Except String Json) : String := match r with | .error e => e | .ok _ => ""
def out (r : Except String Json) (k : String) : String := match r with
  | .ok j => (j.getObjValD k).getStr?.toOption.getD "" | .error e => e

-- the marks are read, typed and kept: the protocol text writes them back
#guard reason (check (a orders)) == ""
#guard (match Text.parse orders with
  | .ok r => ((r.types.find? (·.name == "GetOrder")).map fun m => m.fields.map fun f => (f.name, f.mark, f.place)) ==
      some [("orderId", .link, .path), ("verbose", .plain, .query)]
  | .error _ => false)
#guard (match Text.parse orders with
  | .ok r => ((r.types.find? (·.name == "Created")).map fun m => m.fields.map Types.Field.render) == some ["Header (Fresh String)"]
  | .error _ => false)
-- generated code carries plain values, the marks as comments
#guard has (out (types (a orders)) "proto") "string orderId = 1; // fresh, header"
#guard has (out (types (a orders)) "proto") "string orderId = 1; // link, path"
#guard has (out (types (a orders)) "leanTypes") "orderId : String -- fresh, header"
-- OpenAPI puts each field where it travels
#guard has (out (openapi (a orders [("role", "Api")])) "code") "- in: \"path\"\n          name: \"orderId\"\n          required: true"
#guard has (out (openapi (a orders [("role", "Api")])) "code") "- in: \"query\"\n          name: \"verbose\""

-- conformance reads fields from headers, path, query and body alike
def ev (id label src dst : String) (cause : Option String) (extra : List (String × Json)) : Json :=
  Json.mkObj ([("id", Json.str id), ("session", "1"), ("label", Json.str label), ("from", Json.str src), ("to", Json.str dst)] ++
    (cause.map fun c => [("cause", Json.str c)]).getD [] ++ extra)
def placedLog : List Json :=
  [ ev "e1" "CreateOrder" "Client" "Api" none [("body", json% {item: "tea"})]
  , ev "e2" "Created" "Api" "Client" (some "e1") [("headers", json% {orderId: "o7"})]
  , ev "e3" "GetOrder" "Client" "Api" none [("path", json% {orderId: "o7"}), ("query", json% {verbose: true})]
  , ev "e4" "Order" "Api" "Client" (some "e3") [("body", json% {orderId: "o7", item: "tea"})] ]
#guard out (conform (a orders [("events", Json.arr placedLog.toArray)])) "verdict" == "conforms"
-- negative: a placed field is still a field of its message, of its declared type
#guard has (reason (conform (a orders [("events", Json.arr (placedLog.set 1 (ev "e2" "Created" "Api" "Client" (some "e1") [("headers", json% {orderId: 7})])).toArray)]))) "event e2: Created.orderId is String, and the log has 7"

-- negative: a Link with no Fresh of its name and type, a mark on a structure, a mark inside a mark
#guard has (reason (check (a (orders.replace "orderId : Header (Fresh String)" "orderId : Header String")))) "GetOrder.orderId: Link String names a session no message mints"
#guard has (reason (check (a (orders.replace "orderId : Header (Fresh String)" "orderId : Header (Fresh Nat)")))) "Link String names a session no message mints"
#guard has (reason (check (a (orders.replace "item : String\nstructure Created" "item : Fresh CreateOrder\nstructure Created")))) "holds one plain value"
#guard has (reason (check (a (orders.replace "verbose : QueryParam Bool" "verbose : Fresh (Link Bool)")))) "Fresh holds one plain type"
#guard has (reason (check (a (orders.replace "verbose : QueryParam Bool" "verbose : Link Fresh")))) "Link holds one plain type"
#guard has (reason (check (a (orders.replace "verbose : QueryParam Bool" "verbose : Header (Option Bool)")))) "inside the parentheses comes Fresh or Link"

/-! Sessions from the marks, checked per value (selfhost.session.identity.checks) -/

/-- An event without a session id: the marks and causes place it. -/
def evn (id label src dst : String) (cause : Option String) (extra : List (String × Json)) : Json :=
  Json.mkObj ([("id", Json.str id), ("label", Json.str label), ("from", Json.str src), ("to", Json.str dst)] ++
    (cause.map fun c => [("cause", Json.str c)]).getD [] ++ extra)
def create (id : String) : Json := evn id "CreateOrder" "Client" "Api" none [("body", json% {item: "tea"})]
def created (id cause oid : String) : Json := evn id "Created" "Api" "Client" (some cause) [("headers", Json.mkObj [("orderId", Json.str oid)])]
def get (id oid : String) : Json := evn id "GetOrder" "Client" "Api" none [("path", Json.mkObj [("orderId", Json.str oid)]), ("query", json% {verbose: false})]
def order (id cause oid : String) : Json := evn id "Order" "Api" "Client" (some cause) [("body", Json.mkObj [("orderId", Json.str oid), ("item", "tea")])]
def run (evs : List Json) : Except String Json := conform (a orders [("events", Json.arr evs.toArray)])
def issues (r : Except String Json) : String := match r with | .ok j => (j.getObjValD "issues").compress | .error e => e
def keys (r : Except String Json) : List (String × Nat) := match r with
  | .ok j => match (j.getObjValD "derivedSessions").getObjValD "sessions" with
    | .arr xs => xs.toList.map fun x => ((x.getObjValAs? String "key").toOption.getD "", (x.getObjValAs? Nat "count").toOption.getD 0)
    | _ => []
  | .error _ => []

-- two orders interleaved, no session ids: each GetOrder joins its order by the orderId it links
def two : List Json := [create "c1", create "c2", created "k2" "c2" "o2", created "k1" "c1" "o1",
  get "g1" "o1", get "g2" "o2", order "r2" "g2" "o2", order "r1" "g1" "o1"]
#guard out (run two) "verdict" == "conforms"
#guard keys (run two) == [("chain from c1", 4), ("chain from c2", 4)]
-- negative: minted again while that order is still live
#guard has (issues (run [create "c1", created "k1" "c1" "o7", create "c2", created "k2" "c2" "o7"])) "event k2 (Created) mints orderId=o7 again while the session k1 minted it is still live"
-- once the order's session has ended, o7 is free and names a new session
def again : List Json := [create "c1", created "k1" "c1" "o7", get "g1" "o7", order "r1" "g1" "o7",
  create "c2", created "k2" "c2" "o7", get "g2" "o7", order "r2" "g2" "o7"]
#guard out (run again) "verdict" == "conforms"
#guard (keys (run again)).length == 2
-- negative: a Link to a value no live session minted
#guard has (issues (run [create "c1", created "k1" "c1" "o1", get "g9" "o9"])) "event g9 (GetOrder) carries the Link orderId=o9, but no live session minted orderId=o9"
-- negative: after its session ended, the value no longer names it
#guard has (issues (run [create "c1", created "k1" "c1" "o7", get "g1" "o7", order "r1" "g1" "o7", get "g2" "o7"])) "event g2 (GetOrder) carries the Link orderId=o7, but no live session minted"

-- negative: one event linking two live sessions is a join, reported, never merged
def shop := "structure Cart where
  cartId : Fresh String
structure Customer where
  customerId : Fresh String
structure Checkout where
  cartId : Link String
  customerId : Link String
protocol Shop (C, S) {
  a: NewCart from C to S;
  Cart from S to C cause a;
  b: NewCustomer from C to S;
  Customer from S to C cause b;
  Checkout from C to S;
}"
def joinLog : List Json := [evn "a" "NewCart" "C" "S" none [], evn "k" "Cart" "S" "C" (some "a") [("body", json% {cartId: "k1"})],
  evn "b" "NewCustomer" "C" "S" none [], evn "u" "Customer" "S" "C" (some "b") [("body", json% {customerId: "u1"})],
  evn "x" "Checkout" "C" "S" none [("body", json% {cartId: "k1", customerId: "u1"})]]
#guard has (issues (conform (a shop [("events", Json.arr joinLog.toArray), ("allowIncomplete", Json.bool true)]))) "event x (Checkout) links cartId=k1 and customerId=u1, which are different live sessions: a join"

/-! How ids pass into included tasks (selfhost.session.identity.scopes) -/

/-- A login mints sid; each order task is given it as token and mints its own orderId. -/
def site := "structure Login where
  user : String
structure LoggedIn where
  sid : Header (Fresh String)
structure Create where
  token : Header (Link String)
  item : String
structure Made where
  token : Header (Link String)
  orderId : Fresh String
structure Get where
  token : Header (Link String)
  orderId : PathParam (Link String)
structure Got where
  orderId : Link String
structure Logout where
  sid : Header (Link String)
protocol Order (Client, Shop) given token {
  c: Create from Client to Shop;
  Made from Shop to Client cause c;
  g: Get from Client to Shop;
  Got from Shop to Client cause g;
}
protocol Site (Client, Shop) {
  l: Login from Client to Shop;
  LoggedIn from Shop to Client cause l;
  sessions { include Order Client Shop with token = sid; }
  o: Logout from Client to Shop;
  Bye from Shop to Client cause o;
}"
def notes (r : Except String Json) : String := match r with | .ok j => (j.getObjValD "identity").compress | .error e => e

-- the text reads, checks and writes back given and with; the copies are told apart by orderId
#guard reason (check (a site)) == ""
#guard notes (check (a site)) == "[]"
#guard (match Text.parse site with | .ok r => r.linkTargets.contains (("Create", "token"), "sid") | .error _ => false)
#guard (match Text.readText site with
  | .ok (ds, _) => (Text.Def.write (ds.find? (·.name == "Order")).get!).startsWith "protocol Order (Client, Shop) given token {" &&
      has (Text.Def.write ds.getLast!) "include Order Client Shop with token = sid;"
  | .error _ => false)
-- the diagram's box says how the id passes in; the outline still opens it as protocol Order
#guard has (out (diagram (a site)) "svg") "Order with token = sid"
#guard Global.boxProtocol "Order with token = sid" == "Order"
-- negative: an unbound, unknown, twice-bound, out-of-scope or mistyped binding, and a given field minted inside
#guard has (reason (check (a (site.replace " with token = sid;" ";")))) "include Order: Order is given token, so bind it to a field in scope"
#guard has (reason (check (a (site.replace "with token = sid" "with token = sid, cart")))) "include Order with cart: Order is not given cart; it is given token"
#guard has (reason (check (a (site.replace "with token = sid" "with token = sid, token")))) "include Order binds token twice"
#guard has (reason (check (a (site.replace "with token = sid" "with token = cart")))) "include Order with token = cart: cart is not in scope"
-- a plain field of an earlier message is a reference that may be bound (a gameId picked from a listing)
#guard reason (check (a (site.replace "with token = sid" "with token = user"))) == ""
#guard has (reason (check (a ((site.replace "sid : Header (Fresh String)" "sid : Header (Fresh Nat)").replace "sid : Header (Link String)" "sid : Header (Link Nat)")))) "include Order with token = sid: Order's token is String, but sid is Nat"
#guard has (reason (check (a (site.replace "structure Made where\n  token : Header (Link String)" "structure Made where\n  token : Header (Fresh String)")))) "Made.token is Fresh, but Order is given token by whoever includes it"
#guard has (reason (check (a (site.replace "  l: Login from Client to Shop;\n  LoggedIn from Shop to Client cause l;\n  sessions" "  sessions")))) "sid is not in scope"

-- a sessions body whose copies cannot be told apart is noted, the verdict unchanged
def untold := "protocol Lend (M, D) { sessions { b: Borrow from M to D; Lent from D to M cause b; Return from M to D; } }"
#guard out (check (a untold)) "verdict" == "ok"
#guard has (notes (check (a untold))) "in Lend: the copies of sessions { ... } run at once and cannot be told apart: Return names no cause and carries no Link to an id the copy mints"
-- a cause, a key or a single message tells copies apart
#guard notes (check (a "protocol Lend (M, D) { sessions { b: Borrow from M to D; Lent from D to M cause b; } }")) == "[]"
#guard notes (check (a "protocol Lend (M, D) { sessions { Ping from M to D; } }")) == "[]"
#guard notes (check (a "structure Borrow where\n  who : String\nprotocol Lend (M, D) { sessions by b.who { b: Borrow from M to D; Lent from D to M cause b; Return from M to D; } }")) == "[]"
-- negative: a Link to the given token names the parent, so it does not tell copies apart
#guard has (notes (check (a (site.replace "orderId : PathParam (Link String)" "item : String")))) "Get names no cause and carries no Link to an id the copy mints"

-- conformance reads token as naming the session that minted sid
def sevn (id label : String) (fromClient : Bool) (cause : Option String) (extra : List (String × Json)) : Json :=
  evn id label (if fromClient then "Client" else "Shop") (if fromClient then "Shop" else "Client") cause extra
def hdr (k v : String) : Json := Json.mkObj [(k, Json.str v)]
def login (n s : String) (k : String := "sid") : List Json :=
  [sevn s!"l{n}" "Login" true none [("body", json% {user: "u"})], sevn s!"i{n}" "LoggedIn" false (some s!"l{n}") [("headers", hdr k s)]]
def task (n s o : String) (tok : String := s) : List Json :=
  [ sevn s!"c{n}" "Create" true none [("headers", hdr "token" tok), ("body", json% {item: "tea"})]
  , sevn s!"m{n}" "Made" false (some s!"c{n}") [("headers", hdr "token" tok), ("body", hdr "orderId" o)]
  , sevn s!"g{n}" "Get" true none [("headers", hdr "token" tok), ("path", hdr "orderId" o)]
  , sevn s!"t{n}" "Got" false (some s!"g{n}") [("body", hdr "orderId" o)] ]
def logout (n s : String) (k : String := "sid") : List Json :=
  [sevn s!"x{n}" "Logout" true none [("headers", hdr k s)], sevn s!"b{n}" "Bye" false (some s!"x{n}") []]
def siteRun (evs : List Json) (text : String := site) : Except String Json :=
  conform (a text [("events", Json.arr evs.toArray)])
/-- each derived session's key and its parent's key -/
def parents (r : Except String Json) : List (String × String) := match r with
  | .ok j => match (j.getObjValD "derivedSessions").getObjValD "sessions" with
    | .arr xs => xs.toList.map fun x => ((x.getObjValAs? String "key").toOption.getD "", (x.getObjValAs? String "parent").toOption.getD "")
    | _ => []
  | .error _ => []

/-! Child sessions from given and with (selfhost.session.identity.children) -/

-- one login running two orders, then logging out: the login keeps its own four messages, each order
-- is a child session naming it as parent, and every session follows the protocol
def oneLogin := login "1" "s1" ++ task "1" "s1" "o1" ++ task "2" "s1" "o2" ++ logout "1" "s1"
#guard out (siteRun oneLogin) "verdict" == "conforms"
#guard keys (siteRun oneLogin) == [("chain from l1", 4), ("chain from c1", 4), ("chain from c2", 4)]
#guard parents (siteRun oneLogin) == [("chain from l1", ""), ("chain from c1", "chain from l1"), ("chain from c2", "chain from l1")]
-- two logins interleaved, each running an order: four sessions, each order under its own login
def twoLogins := login "1" "s1" ++ login "2" "s2" ++ task "1" "s1" "o1" ++ task "2" "s2" "o2" ++ logout "1" "s1" ++ logout "2" "s2"
#guard out (siteRun twoLogins) "verdict" == "conforms"
#guard parents (siteRun twoLogins) == [("chain from l1", ""), ("chain from l2", ""), ("chain from c1", "chain from l1"), ("chain from c2", "chain from l2")]
-- an order's orderId is freed when the order ends: a second order minting it again conforms
#guard out (siteRun (login "1" "s1" ++ task "1" "s1" "o7" ++ task "2" "s1" "o7" ++ logout "1" "s1")) "verdict" == "conforms"
-- with token under its own name derives children as with token = sid does
def siteSame := ((site.replace "  sid : Header" "  token : Header").replace " with token = sid;" " with token;")
#guard reason (check (a siteSame)) == ""
#guard parents (siteRun (login "1" "s1" "token" ++ task "1" "s1" "o1" ++ logout "1" "s1" "token") siteSame) ==
  [("chain from l1", ""), ("chain from c1", "chain from l1")]
-- negative: an order message carrying another login's token names a second parent, is reported
-- naming both sessions, and stays in its order's session
def crossed := login "1" "s1" ++ login "2" "s2" ++ (task "1" "s1" "o1").take 2 ++
  [sevn "gx" "Get" true none [("headers", hdr "token" "s2"), ("path", hdr "orderId" "o1")]]
#guard has (issues (siteRun crossed)) "event gx (Get) carries token=s2, naming session chain from l2 as its parent, but its session chain from c1 is a child of chain from l1"
#guard keys (siteRun crossed) == [("chain from l1", 2), ("chain from l2", 2), ("chain from c1", 3)]
-- negative: a token no login minted
#guard has (issues (siteRun (login "1" "s1" ++ task "1" "s1" "o1" "s9"))) "event c1 (Create) carries the Link sid=s9, but no live session minted sid=s9"
-- negative: after logout the login's sid is freed, so a task carrying it names no live session
#guard has (issues (siteRun (login "1" "s1" ++ logout "1" "s1" ++ task "1" "s1" "o1"))) "event c1 (Create) carries the Link sid=s1, but no live session minted sid=s1"

-- an include in sequence continues its includer's session: a given Link there joins, it names no parent
def siteSeq := site.replace "  sessions { include Order Client Shop with token = sid; }" "  include Order Client Shop with token = sid;"
#guard reason (check (a siteSeq)) == ""
#guard out (siteRun (login "1" "s1" ++ task "1" "s1" "o1" ++ logout "1" "s1") siteSeq) "verdict" == "conforms"
#guard parents (siteRun (login "1" "s1" ++ task "1" "s1" "o1" ++ logout "1" "s1") siteSeq) == [("chain from l1", "")]

/-! Threads: an actor's own order, its prev chain (selfhost.mcp.session.view) -/

/-- An event from one actor to another, with the sender's previous send as prev. -/
def aev (id label src dst : String) (cause prev : Option String) (extra : List (String × Json)) : Json :=
  Json.mkObj ([("id", Json.str id), ("label", Json.str label), ("from", Json.str src), ("to", Json.str dst)] ++
    (cause.map fun c => [("cause", Json.str c)]).getD [] ++ (prev.map fun c => [("prev", Json.str c)]).getD [] ++ extra)
def oid (o : String) : List (String × Json) := [("headers", hdr "orderId" o)]
-- one server thread Api/a1 serves two orders in turn: its prev chain runs through both sessions
def served : List Json :=
  [ aev "c1" "CreateOrder" "Client/c1" "Api/a1" none none [("body", json% {item: "tea"})]
  , aev "c2" "CreateOrder" "Client/c2" "Api/a1" none none [("body", json% {item: "tea"})]
  , aev "k1" "Created" "Api/a1" "Client/c1" (some "c1") none (oid "o1")
  , aev "k2" "Created" "Api/a1" "Client/c2" (some "c2") (some "k1") (oid "o2")
  , aev "g2" "GetOrder" "Client/c2" "Api/a1" none (some "c2") [("path", hdr "orderId" "o2"), ("query", json% {verbose: false})]
  , aev "g1" "GetOrder" "Client/c1" "Api/a1" none (some "c1") [("path", hdr "orderId" "o1"), ("query", json% {verbose: false})]
  , aev "r2" "Order" "Api/a1" "Client/c2" (some "g2") (some "k2") [("body", json% {orderId: "o2", item: "tea"})]
  , aev "r1" "Order" "Api/a1" "Client/c1" (some "g1") (some "r2") [("body", json% {orderId: "o1", item: "tea"})] ]
def threadsOf (r : Except String Json) : List String := match r with
  | .ok j => match j.getObjValD "events" with
    | .arr xs => xs.toList.map fun x => (x.getObjValAs? String "thread").toOption.getD ""
    | _ => []
  | .error e => [e]
#guard out (run served) "verdict" == "conforms"
-- prev orders the server's thread; it never joins the two orders it served
#guard keys (run served) == [("chain from c1", 4), ("chain from c2", 4)]
#guard threadsOf (run served) == ["Client/c1", "Client/c2", "Api/a1", "Api/a1", "Client/c2", "Client/c1", "Api/a1", "Api/a1"]
-- every stream event names its actors, so each instance is its own lifeline
def actorsOf (r : Except String Json) : List (String × String) := match r with
  | .ok j => match j.getObjValD "events" with
    | .arr xs => xs.toList.map fun x => ((x.getObjValAs? String "srcActor").toOption.getD "", (x.getObjValAs? String "dstActor").toOption.getD "")
    | _ => []
  | .error e => [(e, "")]
#guard (actorsOf (run served)).take 3 == [("Client/c1", "Api/a1"), ("Client/c2", "Api/a1"), ("Api/a1", "Client/c1")]
-- a log naming only roles: its actors are the roles
#guard (actorsOf (run two)).take 1 == [("Client", "Api")]
-- a log naming only roles: each role is its own thread in each session
#guard (threadsOf (run two)).take 3 == ["Client@chain from c1", "Client@chain from c2", "Api@chain from c2"]

/-! Joins: a play belongs to its player and to its game (selfhost.session.identity.joins) -/

/-- A person signs in; then creates a game (a session of its own, minting gameId, live until it is over), or finds one
(a plain gameId: a reference, not a membership) and plays in it, given both ids. -/
def games := "structure Login where
  user : String
structure In where
  sid : Header (Fresh String)
structure Make where
  sid : Header (Link String)
structure Made where
  gameId : Fresh String
structure Find where
  sid : Header (Link String)
structure Found where
  gameId : String
structure Move where
  sid : Header (Link String)
  gameId : Link String
structure Moved where
  gameId : Link String
protocol Game (P, S) given sid {
  m: Make from P to S;
  Made from S to P cause m;
  rec Turns {
    choice {
      Tick at S;
      continue Turns;
    } or {
      Over at S;
    }
  }
}
protocol Play (P, S) given sid gameId {
  v: Move from P to S;
  Moved from S to P cause v;
}
protocol Lobby (P, S) {
  l: Login from P to S;
  In from S to P cause l;
  choice {
    sessions { include Game P S with sid; }
  } or {
    f: Find from P to S;
    Found from S to P cause f;
    sessions { include Play P S with sid, gameId; }
  }
}"
def gev (id label : String) (toS : Bool) (cause : Option String) (fs : List (String × Json)) : Json :=
  Json.mkObj ([("id", Json.str id), ("label", Json.str label), ("from", Json.str (if toS then "P" else "S")),
    ("to", Json.str (if toS then "S" else "P"))] ++ (cause.map fun c => [("cause", Json.str c)]).getD [] ++ [("fields", Json.mkObj fs)])
def gs (v : String) : Json := Json.str v
-- p1 creates game g1; p2 finds it and plays in it
def gameLog (gid : String := "g1") : List Json :=
  [ gev "l1" "Login" true none [("user", gs "a")], gev "i1" "In" false (some "l1") [("sid", gs "s1")]
  , gev "l2" "Login" true none [("user", gs "b")], gev "i2" "In" false (some "l2") [("sid", gs "s2")]
  , gev "m1" "Make" true none [("sid", gs "s1")], gev "d1" "Made" false (some "m1") [("gameId", gs "g1")]
  , gev "f2" "Find" true none [("sid", gs "s2")], gev "n2" "Found" false (some "f2") [("gameId", gs "g1")]
  , gev "v2" "Move" true none [("sid", gs "s2"), ("gameId", gs gid)], gev "o2" "Moved" false (some "v2") [("gameId", gs gid)] ]
def gamesRun (evs : List Json) : Except String Json :=
  conform (a games [("events", Json.arr evs.toArray), ("allowIncomplete", Json.bool true)])
def parentsAll (r : Except String Json) : List (String × List String) := match r with
  | .ok j => match (j.getObjValD "derivedSessions").getObjValD "sessions" with
    | .arr xs => xs.toList.map fun x => ((x.getObjValAs? String "key").toOption.getD "",
        match x.getObjValD "parents" with
        | .arr ps => ps.toList.filterMap (·.getStr?.toOption)
        | _ => ((x.getObjValAs? String "parent").toOption.toList))
    | _ => []
  | .error _ => []
#guard reason (check (a games)) == ""
#guard out (gamesRun (gameLog)) "verdict" == "conforms"
-- the game is a child of its creator; the play joins its player and the game; the listing stays with p2
#guard parentsAll (gamesRun (gameLog)) ==
  [("chain from l1", []), ("chain from l2", []), ("chain from m1", ["chain from l1"]), ("chain from v2", ["chain from l2", "chain from m1"])]
#guard keys (gamesRun (gameLog)) == [("chain from l1", 2), ("chain from l2", 4), ("chain from m1", 2), ("chain from v2", 2)]
-- negative: a play naming a game no session minted is a problem
#guard has (issues (gamesRun (gameLog "g9"))) "carries the Link gameId=g9, but no live session minted gameId=g9"

/-! GoServer: sign-in mints the person's session; a game is a session its players join (projects/GoServer) -/

/-- Two people sign in and enter the lobby; person 1 starts a game (a session of its own); both pick
it and take a seat, person 1 starts the game, and each asks for its state; interleaved, no session
ids: projects/GoServer/events/two-persons.json. -/
def goTwo : Json := (Json.parse (include_str "../../projects/GoServer/events/two-persons.json")).toOption.getD Json.null
def goRun (evs : Json) : Except String Json :=
  conform (Json.mkObj [("example", "goserver"), ("events", evs), ("allowIncomplete", Json.bool true)])
#guard out (goRun goTwo) "verdict" == "conforms"
-- GoServer one game, two players: each person's session holds only their own requests; the game is
-- a child of its creator; each seat and each game-state request joins its person and the game
#guard parentsAll (goRun goTwo) ==
  [("chain from i1", []), ("chain from i2", []), ("chain from c1", ["chain from i1"]),
   ("chain from t1", ["chain from i1", "chain from c1"]), ("chain from t2", ["chain from i2", "chain from c1"]),
   ("chain from q1", ["chain from i1", "chain from c1"]), ("chain from q2", ["chain from i2", "chain from c1"])]
#guard (keys (goRun goTwo)).take 3 == [("chain from i1", 6), ("chain from i2", 6), ("chain from c1", 4)]
-- GoServer unknown sessionId: a request carrying a sessionId no sign-in issued is a problem
#guard has (issues (goRun ((Json.parse ((include_str "../../projects/GoServer/events/two-persons.json").replace "\"sessionId\": \"s2\",\n   \"gameId\": \"g1\",\n   \"requestId\": \"26\"" "\"sessionId\": \"s9\",\n   \"gameId\": \"g1\",\n   \"requestId\": \"26\"")).toOption.getD Json.null))) "carries the Link sessionId=s9, but no live session minted sessionId=s9"
-- GoServer unknown game: a request naming a game no live session created is a problem
#guard has (issues (goRun ((Json.parse ((include_str "../../projects/GoServer/events/two-persons.json").replace "\"sessionId\": \"s2\",\n   \"gameId\": \"g1\",\n   \"requestId\": \"26\"" "\"sessionId\": \"s2\",\n   \"gameId\": \"g7\",\n   \"requestId\": \"26\"")).toOption.getD Json.null))) "carries the Link gameId=g7, but no live session minted gameId=g7"

/-! sessions by: the key is freed when its session terminates (selfhost.session.identity.scopes) -/

def keyed := "structure Hello where
  caller : String
protocol K (A, B) { sessions by h.caller { h: Hello from A to B; Bye from B to A cause h; } }"
def kev (id label : String) (cause : Option String) (caller : Option String) (session : Option String := none) : Json :=
  Json.mkObj ([("id", Json.str id), ("label", Json.str label), ("from", Json.str (if label == "Hello" then "A" else "B")),
    ("to", Json.str (if label == "Hello" then "B" else "A"))] ++ (cause.map fun c => [("cause", Json.str c)]).getD [] ++
    (caller.map fun c => [("body", hdr "caller" c)]).getD [] ++ (session.map fun s => [("session", Json.str s)]).getD [])
-- alice's first session ends with Bye, so her second Hello starts a new session
def twice := [kev "h1" "Hello" none (some "alice"), kev "y1" "Bye" (some "h1") none,
  kev "h2" "Hello" none (some "alice"), kev "y2" "Bye" (some "h2") none]
#guard out (conform (a keyed [("events", Json.arr twice.toArray)])) "verdict" == "conforms"
#guard (keys (conform (a keyed [("events", Json.arr twice.toArray)]))).length == 2
end LeanFM.Session.IdentityTests

-- a session-type file is Lean: the marks are Lean types, the value itself
structure CreateOrderL where
  item : String
structure CreatedL where
  orderId : Header (Fresh String)
example : CreatedL := { orderId := "o7" }
example : (({ orderId := "o7" } : CreatedL).orderId : String) = "o7" := rfl

-- given and with in a compiled session file; the box shows the binding
structure TaskL where
  token : Link String
structure StartL where
  token : Fresh String
protocol TaskP (Client, Shop) given token {
  TaskL from Client to Shop;
}
protocol SiteP (Client, Shop) {
  StartL from Shop to Client;
  include TaskP Client Shop with token;
}
#guard (match SiteP "Client" "Shop" with
  | .msg _ (.box n _ _) => n == "TaskP with token"
  | _ => false)
