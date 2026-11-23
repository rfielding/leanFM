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
#guard has (reason (check (a (site.replace "with token = sid" "with token = user")))) "include Order with token = user: user is not in scope"
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
def login (n s : String) : List Json :=
  [sevn s!"l{n}" "Login" true none [("body", json% {user: "u"})], sevn s!"i{n}" "LoggedIn" false (some s!"l{n}") [("headers", hdr "sid" s)]]
def task (n s o : String) (tok : String := s) : List Json :=
  [ sevn s!"c{n}" "Create" true none [("headers", hdr "token" tok), ("body", json% {item: "tea"})]
  , sevn s!"m{n}" "Made" false (some s!"c{n}") [("headers", hdr "token" tok), ("body", hdr "orderId" o)]
  , sevn s!"g{n}" "Get" true none [("headers", hdr "token" tok), ("path", hdr "orderId" o)]
  , sevn s!"t{n}" "Got" false (some s!"g{n}") [("body", hdr "orderId" o)] ]
def logout (n s : String) : List Json :=
  [sevn s!"o{n}" "Logout" true none [("headers", hdr "sid" s)], sevn s!"b{n}" "Bye" false (some s!"o{n}") []]
def siteRun (evs : List Json) : Except String Json := conform (a site [("events", Json.arr evs.toArray)])
-- one login running two orders, then logging out: one session, every task message linked to it
-- (replaying each order as its own child session is selfhost.session.identity.graph; here the
-- marks place every event, with no identity problem)
#guard (fun t => !has t "Link" && !has t "join") (issues (siteRun (login "1" "s1" ++ task "1" "s1" "o1" ++ task "2" "s1" "o2" ++ logout "1" "s1")))
#guard keys (siteRun (login "1" "s1" ++ task "1" "s1" "o1" ++ task "2" "s1" "o2" ++ logout "1" "s1")) == [("chain from l1", 12)]
-- two logins interleaved: two sessions
#guard (keys (siteRun (login "1" "s1" ++ login "2" "s2" ++ task "1" "s1" "o1" ++ task "2" "s2" "o2" ++ logout "1" "s1" ++ logout "2" "s2"))).map (·.2) == [8, 8]
-- negative: an order task carrying another login's token links two live sessions, and is reported
#guard has (issues (siteRun (login "1" "s1" ++ login "2" "s2" ++ task "1" "s1" "o1" ++
  [sevn "gx" "Get" true none [("headers", hdr "token" "s2"), ("path", hdr "orderId" "o1")]]))) "event gx (Get) links sid=s2 and orderId=o1, which are different live sessions"
-- negative: a token no login minted
#guard has (issues (siteRun (login "1" "s1" ++ task "1" "s1" "o1" "s9"))) "event c1 (Create) carries the Link sid=s9, but no live session minted sid=s9"

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
