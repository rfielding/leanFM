import LeanFM.SessionTools
import LeanFM.Session.SessionTests

/-! Tests for the MCP session tools (clause selfhost.mcp.session.tools). Built with the library, so
`lake build` runs every `#guard`. -/

namespace LeanFM.SessionToolsTests
open Lean LeanFM.SessionTools

def parse! (s : String) : Json := (Json.parse s).toOption.getD Json.null

def call (f : Json → Except String Json) (s : String) : Except String Json := f (parse! s)

def verdict (r : Except String Json) : String :=
  match r with
  | .ok j => (j.getObjValAs? String "verdict").toOption.getD "?"
  | .error _ => "rejected"

def reason (r : Except String Json) : String := match r with | .error e => e | .ok _ => ""

def field (r : Except String Json) (k : String) : Json :=
  match r with | .ok j => j.getObjValD k | .error _ => Json.null

def strs (j : Json) : List String :=
  match j with | .arr a => a.toList.filterMap (·.getStr?.toOption) | _ => []

/-- The reference's example protocol: the documentation's own JSON is what the test checks. -/
def placeOrder : String := ((reference.splitOn "```json\n")[1]!.splitOn "\n```")[0]!

def withProtocol (p : String) (extra : String := "") : String :=
  "{\"protocol\": " ++ p ++ extra ++ "}"

-- the documented example checks ok, with the client's typestate and the calls tree
def po := call check (withProtocol placeOrder)
#guard verdict po == "ok"
#guard strs (field po "issues") == []
#guard ((field po "projections").getObjValD "Client" |>.getObjValAs? String "typestate").toOption ==
  some ("start : S0\nS0.sendCreateOrder(m : CreateOrder) : S1    -- to Shop\n" ++
        "S1.receive() : Quote × S2 (from Shop) | SoldOut × End (from Shop)\n" ++
        "S2.sendPay(m : Pay) : S3    -- to Shop\n" ++
        "S3.receive() : Receipt × End (from Shop) | PaymentDeclined × End (from Shop)")
#guard (field po "callsText").getStr?.toOption ==
  some ("o: CreateOrder  Client → Shop  POST /orders\n  returns Quote 201 | SoldOut 409\n" ++
        "p: Pay  Client → Shop\n  returns Receipt 200 | PaymentDeclined 402\n" ++
        "    c: Charge  Shop → Bank\n      returns Charged | Declined")
-- the diagram comes as shapes: an alt frame names the shop as the role that selects
#guard ((field po "diagram").getObjValD "shapes").compress.contains "[Shop decides]"
-- every answer echoes the protocol it checked, so the view can edit it
#guard (field po "protocol").compress == (parse! placeOrder).compress
#guard (field (call diagram (withProtocol placeOrder)) "protocol").compress == (parse! placeOrder).compress
-- the same arguments give the same answer
#guard (call check (withProtocol placeOrder)).toOption.map (·.compress) == po.toOption.map (·.compress)

-- the core rules report what SessionTests reports for the Lean versions
def race := call check (withProtocol r#"{"roles": ["Sender", "Receiver"], "steps": [
  {"rec": "Block", "steps": [
    {"msg": "Data", "id": "d", "from": "Sender", "to": "Receiver"},
    {"choice": [
      [{"event": "Timeout", "at": "Sender"}, {"continue": "Block"}],
      [{"msg": "Ack", "from": "Receiver", "to": "Sender", "cause": "d"}, {"continue": "Block"}]]}]}]}"#)
#guard verdict race == "issues"
#guard strs (field race "issues") ==
  ["no single role decides a choice, so it is a race: Sender starts Timeout; Receiver starts Ack"]

def hold := call check (withProtocol r#"{"roles": ["Client", "Shop", "Bank"], "steps": [
  {"msg": "Hold", "id": "h", "from": "Client", "to": "Bank"},
  {"msg": "Order", "id": "o", "from": "Client", "to": "Shop"},
  {"choice": [
    [{"msg": "Quote", "id": "q", "from": "Shop", "to": "Client", "cause": "o"},
     {"msg": "Pay", "id": "p", "from": "Client", "to": "Bank", "cause": "q"}],
    [{"msg": "SoldOut", "from": "Shop", "to": "Client", "cause": "o"}]]}]}"#)
#guard strs (field hold "issues") == ["Bank cannot tell which branch Shop chose"]
#guard (((field hold "projections").getObjValD "Bank").getObjValAs? String "error").toOption ==
  some "Bank cannot tell which branch Shop chose"

def borrowed := call check (withProtocol r#"{"roles": ["Client", "Shop", "Bank"], "steps": [
  {"msg": "Order", "id": "o", "from": "Client", "to": "Shop"},
  {"msg": "Paid", "from": "Bank", "to": "Shop", "cause": "o"}]}"#)
#guard (strs (field borrowed "issues")).contains "Paid: Bank never saw o"

-- with mayCall every channel is HTTP: Paid answers the client's call but goes to the shop
def purchase : String := r#"{"roles": ["Client", "Shop", "Bank"], "steps": [
  {"msg": "Order", "id": "o", "from": "Client", "to": "Shop"},
  {"choice": [
    [{"msg": "Quote", "id": "q", "from": "Shop", "to": "Client", "cause": "o"},
     {"msg": "Pay", "id": "p", "from": "Client", "to": "Bank", "cause": "q", "where": "p.amount = q.price"},
     {"msg": "Paid", "from": "Bank", "to": "Shop", "cause": "p"},
     {"msg": "Shipped", "from": "Shop", "to": "Client"}],
    [{"msg": "SoldOut", "from": "Shop", "to": "Client", "cause": "o"}]]}]}"#
def http := call check (withProtocol purchase r#", "mayCall": [["Client", "Shop"], ["Client", "Bank"], ["Shop", "Bank"]]"#)
#guard strs (field http "httpCuts") ==
  [ "Paid answers p, which Client sent to Bank, but goes to Shop"
  , "Shipped is a request from Shop to Client, which Shop may not call"
  , "Pay (p) from Client to Bank never gets a response"
  , "Paid from Bank to Shop never gets a response"
  , "Shipped from Shop to Client never gets a response" ]
#guard verdict http == "issues"
-- a where text is shown in the diagram, never evaluated
#guard ((field (call diagram (withProtocol purchase)) "svg").getStr?.toOption.getD "").contains "[p.amount = q.price]"

-- rejections name the step
def rejects (p : String) (needle : String) : Bool :=
  let r := call check (withProtocol p)
  verdict r == "rejected" && (reason r).contains needle
#guard rejects r#"{"roles": ["A", "B"], "steps": [{"msg": "X", "from": "A", "to": "C"}]}"# "steps[0]: to names C"
#guard rejects r#"{"roles": ["A", "B"], "steps": [{"msg": "X", "from": "A", "to": "B", "colour": "red"}]}"# "unknown keys [colour]"
#guard rejects r#"{"roles": ["A", "B"], "steps": [{"send": "X"}]}"# "unknown step"
#guard rejects r#"{"roles": ["A", "B"], "steps": [{"msg": "X", "event": "Y", "from": "A", "to": "B"}]}"# "exactly one kind"
#guard rejects r#"{"roles": ["A", "B"], "steps": [{"choice": [[{"continue": "L"}]]}]}"# "steps[0].choice[0].steps[0]: continue L is not inside rec L"
#guard rejects r#"{"roles": ["A", "B"], "steps": [{"rec": "L", "steps": [{"continue": "L"}, {"msg": "X", "from": "A", "to": "B"}]}]}"# "must be the last step"
#guard rejects r#"{"roles": ["A", "B"], "steps": [{"join": 3, "of": [[], []]}]}"# "out of range"
#guard rejects r#"{"roles": ["A", "A"], "steps": []}"# "distinct"
#guard rejects r#"{"roles": ["A", "B"], "steps": [{"msg": "X\u0007", "from": "A", "to": "B"}]}"# "control character"
#guard rejects r#"{"roles": [], "steps": []}"# "at least one role"
-- protocol text sent under the JSON form's key is pointed to lean, not met with "roles must be ..."
#guard let r := call check r#"{"protocol": "protocol P (A, B) { X from A to B; }"}"#
  verdict r == "rejected" && (reason r).contains "put LeanFM protocol text in lean"
#guard rejects r#"{"roles": ["A", "B"], "steps": [], "code": "rm -rf /"}"# "unknown keys [code]"
#guard verdict (call check "{}") == "rejected"
-- the limits hold
def manyRoles : String := "{\"roles\": [" ++ ",".intercalate ((List.range 13).map fun i => s!"\"R{i}\"") ++ "], \"steps\": []}"
#guard rejects manyRoles "at most 12 roles"
def manySteps : String := "{\"roles\": [\"A\", \"B\"], \"steps\": [" ++
  ",".intercalate ((List.range 201).map fun _ => "{\"msg\": \"X\", \"from\": \"A\", \"to\": \"B\"}") ++ "]}"
#guard rejects manySteps "more than 200 steps"
def deep : Nat → String
  | 0 => "[]"
  | n + 1 => "[{\"par\": [" ++ deep n ++ "]}]"
#guard rejects ("{\"roles\": [\"A\"], \"steps\": " ++ deep 30 ++ "}") "nested more than 24 deep"

-- a simulation is bounded, deterministic, and fits the result limit, saying what it left out
def sim (extra : String) := call simulate (withProtocol placeOrder extra)
#guard verdict (sim r#", "seed": 7, "instances": 20"#) == "generated"
#guard (field (sim r#", "seed": 7, "instances": 20"#) "sessions") == toJson 20
#guard (sim r#", "seed": 7"#).toOption.map (·.compress) == (sim r#", "seed": 7"#).toOption.map (·.compress)
#guard verdict (sim r#", "instances": 201"#) == "rejected"
#guard verdict (sim r#", "maxEvents": 601"#) == "rejected"
def big := sim r#", "seed": 3, "instances": 200, "maxEvents": 600, "spread": 400"#
#guard (big.toOption.map (·.compress.length)).getD 0 ≤ limits.maxResult
#guard !(strs (field big "omitted")).isEmpty || (big.toOption.map (·.compress.length)).getD 0 ≤ limits.maxResult

-- the light theme is a real theme
#guard ((field (call diagram (withProtocol placeOrder r#", "theme": "light""#)) "svg").getStr?.toOption.getD "").contains "#ffffff"

-- LeanFM's own MCP Apps handshake, specified with the session tools (examples/sessions)
def mcpApps : String := include_str "../examples/sessions/McpAppsToolCall.json"
def mcpAppsCheck := call check (withProtocol mcpApps)
#guard verdict mcpAppsCheck == "ok"
-- the view's acknowledgement answers the host's context, so it is its own call, not part of ui/initialize
#guard ((field mcpAppsCheck "callsText").getStr?.toOption.getD "").contains "Initialized  View → Host\n  returns no reply"

/-! ## Lean protocol text (the main input) -/

open LeanFM.Session in
/-- The text parser and the `protocol` command agree: the same diagram, issues and projections. -/
def agrees {R : Type} [DecidableEq R] [ToString R] (text : String) (g : Global R) (roles : List R) : Bool :=
  match LeanFM.Session.Text.parse text with
  | .error _ => false
  | .ok p =>
    p.roles == roles.map toString &&
    p.global.diagram p.roles == g.diagram roles &&
    p.global.issues p.roles == g.issues roles &&
    (p.roles.zip roles).all fun (s, r) =>
      ((p.global.project s).toOption.map Local.render) == ((g.project r).toOption.map Local.render)

open LeanFM.Session.SessionTests in
#guard agrees "protocol Purchase (Client, Shop, Bank) {
  o: Order from Client to Shop;
  choice {
    q: Quote from Shop to Client cause o;
    p: Pay   from Client to Bank cause q where p.amount = q.price;
       Paid  from Bank to Shop cause p;
       Shipped from Shop to Client;
  } or {
       SoldOut from Shop to Client cause o;
  }
}" LeanFM.Session.SessionTests.purchase roles3

open LeanFM.Session.SessionTests in
#guard agrees "-- the receiver decides whether the block repeats
protocol Transfer (Sender, Receiver) {
  rec Block {
    d: Data from Sender to Receiver;
    choice {
      Ack from Receiver to Sender cause d;
      continue Block;
    } or {
      LastAck from Receiver to Sender cause d;
    }
  }
}" transfer [.sender, .receiver]

open LeanFM.Session.SessionTests in
#guard agrees "protocol TransferWithTimer (Sender, Receiver) {
  rec Block {
    d: Data from Sender to Receiver;
    choice {
      Timeout at Sender;
      continue Block;
    } or {
      Ack from Receiver to Sender cause d;
      continue Block;
    }
  }
}" (TransferWithTimer Role.sender Role.receiver) [.sender, .receiver]

open LeanFM.Session.SessionTests in
#guard agrees "/-- Two of three replicas store the write. -/
protocol Replicate (P, A, B, C) {
  join 2 of {
    wa: Write from P to A; Stored from A to P cause wa;
  } and {
    wb: Write from P to B; Stored from B to P cause wb;
  } and {
    wc: Write from P to C; Stored from C to P cause wc;
  }
}
protocol ReplicatedOrder (Client, Primary, R1, R2, R3) {
  o: Order from Client to Primary;
  include Replicate Primary R1 R2 R3;
  Done from Primary to Client cause o;
}" replicatedOrder [.client, .primary, .r1, .r2, .r3]

open LeanFM.Session.SessionTests in
#guard agrees "protocol PurchaseHttp (Client, Shop, Bank) {
  o: Order from Client to Shop;
  choice {
    q: Quote   from Shop to Client cause o;
    p: Pay     from Client to Bank cause q where p.amount = q.price;
    r: Receipt from Bank to Client cause p;
    c: Confirm from Client to Shop cause r where c.amount = r.amount;
    v: Verify  from Shop to Bank cause c;
    w: Paid    from Bank to Shop cause v;
       Shipped from Shop to Client cause w;
  } or {
       SoldOut from Shop to Client cause o;
  }
}" (PurchaseHttp Role.client Role.shop Role.bank) roles3

open LeanFM.Session.SessionTests in
#guard agrees "protocol Serve (Client, Shop) {
  sessions {
    g: Get from Client to Shop;
       Page from Shop to Client cause g;
  }
}" (Serve Role.client Role.shop) [.client, .shop]

-- the reference's Lean example checks ok through the tool, and the answer echoes the text
def leanExample : String := ((reference.splitOn "```lean\n")[1]!.splitOn "\n```")[0]!
def leanArgs (t : String) : Json := Json.mkObj [("lean", Json.str t)]
def lo := check (leanArgs leanExample)
#guard verdict lo == "ok"
#guard (field lo "lean").getStr?.toOption == some leanExample
-- the Lean example and the JSON example are the same protocol
#guard (field lo "diagram").compress == (field po "diagram").compress
#guard (field lo "callsText").compress == (field po "callsText").compress
-- a JSON protocol is answered with the same protocol as text, which reads back to the same diagram
#guard match (field po "lean").getStr? with
  | .ok t => (field (check (leanArgs t)) "diagram").compress == (field po "diagram").compress
  | .error _ => false

-- errors give the line and column, and nothing is guessed
def leanRejects (t : String) (needle : String) : Bool :=
  let r := check (leanArgs t)
  verdict r == "rejected" && (reason r).contains needle
#guard leanRejects "protocol P (A, B) {\n  X from A to C;\n}" "C is not one of the roles"
#guard leanRejects "protocol P (A, B) {\n  X from A to B\n}" "line 3, column 1: expected ';' at the end of the message"
#guard leanRejects "protocol P (A, B) {\n  X from A to B;\n" "line 1, column 19: a '{' is never closed"
#guard leanRejects "/- never closed\nprotocol P (A) { }" "line 1, column 1: this comment is never closed"
#guard leanRejects "protocol P (A, B) { X from A to B route \"open; }" "this string is never closed"
#guard leanRejects "protocol P (A, B) { rec L { X from A to B; } continue L; }" "continue L is not inside rec L"
#guard leanRejects "protocol P (A, B) { rec L { continue L; X from A to B; } }" "must be the last statement"
#guard leanRejects "protocol P (A, B) { include Q A B; }" "no protocol Q is defined before this one"
#guard leanRejects "protocol Q (A) { X at A; }\nprotocol P (A, B) { include Q A B; }" "include Q needs 1 roles, not 2"
#guard leanRejects "protocol P (A, A) { }" "role names must be distinct"
#guard leanRejects "protocol P (A, B) { join 3 of { X from A to B; } and { Y from B to A; } }" "out of range"
-- text is never elaborated: Lean commands are not protocol syntax, so they are an error, not run
#guard leanRejects "#eval IO.Process.exit 1\nprotocol P (A) { X at A; }" "line 1, column 1: expected 'protocol'"
#guard leanRejects "protocol P (A, B) { X from A to B where (IO.Process.exit 1; }" "never ends with ';'"
-- a where condition is text, shown as written
#guard ((field (diagram (leanArgs "protocol P (A, B) { p: X from A to B where p.n <  3   && true; }")) "svg").getStr?.toOption.getD "").contains "[p.n &lt; 3 &amp;&amp; true]"
-- names with spaces, comments everywhere
#guard verdict (check (leanArgs "protocol «Two Words» («The Client», Shop) { -- hello\n  /- a /- nested -/ comment -/\n  «Place Order» from «The Client» to Shop; }")) == "ok"
-- the limits hold for text too
#guard leanRejects ("protocol P (A, B) {" ++ String.join ((List.range 201).map fun _ => " X from A to B;") ++ " }") "more than 200 steps"
#guard leanRejects ("protocol P (" ++ ", ".intercalate ((List.range 13).map fun i => s!"R{i}") ++ ") { }") "at most 12 roles"

/-! ## session_conform -/

-- session_simulate's events, fed back unchanged, conform; the PlaceOrder stream has 20 sessions
def simOut := (simulate ((leanArgs leanExample).setObjVal! "instances" (toJson 20) |>.setObjVal! "seed" (toJson 4))).toOption.get!
def simEvents : Json := simOut.getObjValD "events"
def conformArgs (evs : Json) : Json := (leanArgs leanExample).setObjVal! "events" evs
#guard verdict (conform (conformArgs simEvents)) == "conforms"
#guard ((field (conform (conformArgs simEvents)) "reading").getStr?.toOption.getD "").contains "in 20 sessions follow the protocol"
-- a log in the documented shape, with string ids and from/to
def goodLog : String := r#"[
  {"id": "e1", "session": "s1", "from": "Client", "to": "Shop", "label": "CreateOrder"},
  {"id": "e2", "session": "s1", "from": "Shop", "to": "Client", "label": "SoldOut", "cause": "e1"},
  {"id": "e3", "session": "s2", "from": "Client", "to": "Shop", "label": "CreateOrder"},
  {"id": "e4", "session": "s2", "from": "Shop", "to": "Client", "label": "Quote", "cause": "e3"}]"#
#guard verdict (conform (conformArgs (parse! goodLog))) == "violates"
#guard (strs (field (conform (conformArgs (parse! goodLog))) "issues")).head? ==
  some "session s2, event e4: the session stops early; the protocol still expects Pay from Client to Shop"
#guard verdict (conform ((conformArgs (parse! goodLog)).setObjVal! "allowIncomplete" (toJson true))) == "conforms"
-- a bug in the implementation: the shop charges the bank before the client pays
def badLog : String := r#"[
  {"id": "e1", "session": "s1", "from": "Client", "to": "Shop", "label": "CreateOrder"},
  {"id": "e2", "session": "s1", "from": "Shop", "to": "Client", "label": "Quote", "cause": "e1"},
  {"id": "e3", "session": "s1", "from": "Shop", "to": "Bank", "label": "Charge", "cause": "e2"}]"#
#guard (strs (field (conform (conformArgs (parse! badLog))) "issues")).head? ==
  some "session s1, event e3: Charge from Shop to Bank is not allowed here; the protocol allows Pay from Client to Shop"
-- malformed logs are rejected, not guessed
#guard (reason (conform (conformArgs (parse! r#"[{"id": "e1", "from": "Client", "to": "Shop"}]"#)))).contains "has no label"
#guard (reason (conform (conformArgs (Json.str "nope")))).contains "events must be an array"

/-! ## The worked example: examples/vibecode/lending

A protocol, the module session_skeleton generates from it (lending_protocol.py), a service built on
that module (lending.py), and two logs it wrote: the correct Desk conforms; the Desk with the bug
(it lends a returned copy on an approved hold, going around its typestate to do it) runs without
error on its own, and session_conform names the event where it breaks the protocol. Regenerate
with session_skeleton, then `python3 lending.py > log.json` and `--bug > bug-log.json`. -/

def lendingProtocol : String := include_str "../examples/vibecode/lending/Lending.protocol"
def lendingArgs (log : String) : Json := (leanArgs lendingProtocol).setObjVal! "events" (parse! log)
#guard verdict (check (leanArgs lendingProtocol)) == "ok"
-- the README's picture is the generated diagram of the current protocol, not a drawing. A copy may
-- carry a provenance manifest (C2PA content credentials, added when a file is delivered); that one
-- metadata element is set aside and everything drawn is compared exactly
def withoutProvenance (svg : String) : String :=
  let s := svg.replace " xmlns:c2pa=\"http://c2pa.org/manifest\"" ""
  match s.splitOn "<metadata>" with
  | [before, rest] => match rest.splitOn "</metadata>" with
    | [_, after] => before ++ after
    | _ => s
  | _ => s
#guard (field (diagram ((leanArgs lendingProtocol).setObjVal! "theme" (Json.str "dark"))) "svg").getStr?.toOption ==
  some (withoutProvenance (include_str "../examples/vibecode/lending/Lending.svg"))
-- negative: only the metadata goes; a change to the drawing still shows
#guard withoutProvenance "<svg xmlns:c2pa=\"http://c2pa.org/manifest\"><metadata>m</metadata><text>A</text></svg>" == "<svg><text>A</text></svg>"
#guard withoutProvenance "<svg><text>A</text></svg>" != "<svg><text>B</text></svg>"
#guard withoutProvenance "<svg><metadata>1</metadata><metadata>2</metadata></svg>" == "<svg><metadata>1</metadata><metadata>2</metadata></svg>"
#guard verdict (conform (lendingArgs (include_str "../examples/vibecode/lending/log.json"))) == "conforms"
#guard ((field (conform (lendingArgs (include_str "../examples/vibecode/lending/log.json"))) "reading").getStr?.toOption.getD "").contains
  "80 events in 20 sessions follow the protocol"
#guard verdict (conform (lendingArgs (include_str "../examples/vibecode/lending/bug-log.json"))) == "violates"
#guard strs (field (conform (lendingArgs (include_str "../examples/vibecode/lending/bug-log.json"))) "issues") ==
  [ "session 5, event 5.Desk.2: Lent from Desk to Member is not allowed here; the protocol allows Waitlisted from Desk to Member"
  , "session 12, event 12.Desk.2: Lent from Desk to Member is not allowed here; the protocol allows Waitlisted from Desk to Member" ]

-- the checked-in module is what session_skeleton generates from the current protocol
#guard (field (skeleton (leanArgs lendingProtocol)) "code").getStr?.toOption ==
  some (include_str "../examples/vibecode/lending/lending_protocol.py")

-- and the TypeScript module, which the example type-checks (npm run check)
#guard (field (skeleton ((leanArgs lendingProtocol).setObjVal! "language" (Json.str "typescript"))) "code").getStr?.toOption ==
  some (include_str "../examples/vibecode/lending/lending_protocol.ts")

/-! ## session_next -/

def walk (evs : String) : Except String Json := next ((leanArgs lendingProtocol).setObjVal! "events" (parse! evs))
def nextOf (r : Except String Json) : String := (field r "next").compress
-- from the start only the member may act
#guard verdict (next (leanArgs lendingProtocol)) == "running"
#guard nextOf (next (leanArgs lendingProtocol)) == "[{\"from\":\"Member\",\"label\":\"Borrow\",\"to\":\"Desk\"}]"
-- the steps are in the report, which goes into the text a model reads
#guard (field (next (leanArgs lendingProtocol)) "report").getStr?.toOption == some "- Borrow from Member to Desk"
-- after Borrow the Desk chooses, and both steps name the Borrow as their cause
#guard nextOf (walk r#"[{"id":"w1","from":"Member","to":"Desk","label":"Borrow"}]"#) ==
  "[{\"cause\":\"w1\",\"from\":\"Desk\",\"label\":\"Lent\",\"to\":\"Member\"},{\"cause\":\"w1\",\"from\":\"Desk\",\"label\":\"Hold\",\"to\":\"Librarian\"}]"
-- a whole session ends there
def fullWalk : String := r#"[{"id":"w1","from":"Member","to":"Desk","label":"Borrow"},
  {"id":"w2","from":"Desk","to":"Librarian","label":"Hold","cause":"w1"},
  {"id":"w3","from":"Librarian","to":"Desk","label":"Denied","cause":"w2"},
  {"id":"w4","from":"Desk","to":"Member","label":"Refused","cause":"w1"}]"#
#guard verdict (walk fullWalk) == "finished"
#guard (field (walk fullWalk) "canEnd") == Json.bool true
-- negative: a walk the protocol does not allow is reported, not extended; malformed events are rejected
#guard verdict (walk r#"[{"id":"w1","from":"Desk","to":"Member","label":"Lent"}]"#) == "violates"
#guard (strs (field (walk r#"[{"id":"w1","from":"Desk","to":"Member","label":"Lent"}]"#) "issues")).head? ==
  some "event w1: Lent from Desk to Member is not allowed here; the protocol allows Borrow from Member to Desk"
#guard (reason (walk r#"[{"id":"w1","from":"Member","to":"Desk"}]"#)).contains "has no label"
#guard (reason (next ((leanArgs lendingProtocol).setObjVal! "events" (Json.arr ((List.range 201).map fun i => parse! s!"\{\"id\":\"{i}\",\"from\":\"Member\",\"to\":\"Desk\",\"label\":\"Borrow\"}").toArray)))) ==
  "at most 200 events in a walk"
-- events and par: both branches are offered at once, and the event after them only when both end
#guard nextOf (next (leanArgs "protocol F (H, A, B) { par { x: Ping from H to A; } and { y: Ping from H to B; } Bye at H; }")) ==
  "[{\"from\":\"H\",\"label\":\"Ping\",\"to\":\"A\"},{\"from\":\"H\",\"label\":\"Ping\",\"to\":\"B\"}]"
#guard nextOf (next ((leanArgs "protocol F (H, A, B) { par { x: Ping from H to A; } and { y: Ping from H to B; } Bye at H; }").setObjVal! "events"
  (parse! r#"[{"id":"1","from":"H","to":"A","label":"Ping"},{"id":"2","from":"H","to":"B","label":"Ping"}]"#))) ==
  "[{\"act\":true,\"from\":\"H\",\"label\":\"Bye\"}]"

/-! ## HTTP: every request gets a response -/

def httpCheck (t : String) (pairs : String) (extra : List (String × Json) := []) : Except String Json :=
  check (extra.foldl (fun j (k, v) => j.setObjVal! k v) ((leanArgs t).setObjVal! "mayCall" (parse! pairs)))
-- the first draft of two-factor login: the code's answers are caused by the login request, so the
-- request carrying the code is never answered
def loginDraft : String := "protocol Login (User, App) { p: Password from User to App; e: EnterCode from User to App; Welcome from App to User cause p; }"
#guard strs (field (httpCheck loginDraft "[[\"User\",\"App\"]]") "httpCuts") == ["EnterCode (e) from User to App never gets a response"]
-- a request made before a loop and answered after it is not reported by a run that goes round again
#guard strs (field (httpCheck "protocol P (C, S) { o: Order from C to S; rec W { choice { Busy at S; continue W; } or { Ready at S; } } Done from S to C cause o; }" "[[\"C\",\"S\"]]") "httpCuts") == []
-- notHttp: a text message is not an HTTP request, so it needs no response and no permission
def withText : String := "protocol L (User, App, Sms) { p: Password from User to App; s: Send from App to Sms; Sent from Sms to App cause s; Text from Sms to User; Ok from App to User cause p; }"
#guard strs (field (httpCheck withText "[[\"User\",\"App\"],[\"App\",\"Sms\"]]") "httpCuts") ==
  ["Text is a request from Sms to User, which Sms may not call", "Text from Sms to User never gets a response"]
#guard strs (field (httpCheck withText "[[\"User\",\"App\"],[\"App\",\"Sms\"]]" [("notHttp", parse! "[[\"Sms\",\"User\"]]")]) "httpCuts") == []
#guard reason (httpCheck withText "[[\"User\",\"App\"]]" [("notHttp", parse! "[\"Sms\"]")]) == "notHttp must be an array of [role, role] pairs"

/-! ## Diagram layout found by using the tools: captions and label room -/

def loginLoop : String := "protocol Login (User, App, Auth, Sms) { p: Password from User to App; c: CheckPassword from App to Auth cause p route \"POST /auth/password\"; s: SendCode from Auth to Sms; Text from Sms to User; rec Try { e: EnterCode from User to App; v: VerifyCode from App to Auth cause e; choice { Valid from Auth to App cause v; Welcome from App to User cause e; } or { Invalid from Auth to App cause v; TryAgain from App to User cause e; continue Try; } } }"
def loginSvg : String := ((field (diagram (leanArgs loginLoop)) "svg").getStr?.toOption).getD ""
-- a choice is captioned with the role that decides
#guard loginSvg.contains "[Auth decides]"
-- "c: CheckPassword · POST /auth/password" is 38 characters: lifelines move apart to fit it
#guard loginSvg.startsWith "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1086\""
-- short labels keep the narrowest spacing
#guard ((field (diagram (leanArgs "protocol P (A, B) { Hi from A to B; }")) "svg").getStr?.toOption.getD "").startsWith "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"360\""

/-! ## Services: roles that take part only in nested sessions blocks -/

def loginProtocol : String := include_str "../examples/vibecode/login/Login.protocol"
def loginHttp : Except String Json := check ((leanArgs loginProtocol).setObjVal! "mayCall"
  (parse! "[[\"User\",\"App\"],[\"App\",\"Auth\"],[\"Auth\",\"Sms\"]]") |>.setObjVal! "notHttp" (parse! "[[\"Sms\",\"User\"]]"))
-- the two-factor login from the dogfooding session checks clean, HTTP included
#guard verdict loginHttp == "ok"
-- Sms serves its own sessions: it never sees the login's choices, so nothing asks it to tell them apart
def localOf (r : Except String Json) (role : String) : String :=
  (((field r "projections").getObjValD role).getObjValAs? String "local").toOption.getD ""
#guard localOf loginHttp "Sms" == "sessions {\n  receive SendCode from Auth;\n  send Queued to Auth;\n  send Text to User;\n}"
-- the roles of the login keep the sub-sessions where they happen
#guard (localOf loginHttp "Auth").contains "    sessions {\n      send SendCode to Sms;\n      receive Queued from Sms;\n    }"
-- without the nested blocks, the same Sms would have to follow the retry loop, and cannot
def loginInline : String := loginProtocol.replace "sessions { s: SendCode from Auth to Sms; Queued from Sms to Auth cause s status 202; Text from Sms to User; }" "s: SendCode from Auth to Sms; Queued from Sms to Auth cause s status 202; Text from Sms to User;"
#guard (strs (field (check (leanArgs loginInline)) "issues")).any (·.startsWith "Sms cannot tell which branch")
-- a service with two kinds of session tells them apart by the first message
def mailer : String := "protocol Accounts (User, App, Mail) { sessions { choice { Join from User to App; sessions { Welcome from App to Mail; } } or { Forgot from User to App; sessions { Reset from App to Mail; Link from Mail to User; } } } }"
#guard localOf (check (leanArgs mailer)) "Mail" == "sessions {\n  offer {\n    receive Welcome from App;\n  } or {\n    receive Reset from App;\n    send Link to User;\n  }\n}"
-- negative: two kinds that start alike cannot be told apart
#guard (strs (field (check (leanArgs (mailer.replace "Reset from App to Mail" "Welcome from App to Mail"))) "issues")).contains
  "Mail serves sessions that it cannot tell apart from their first message"
-- simulated logins with their text-message sessions conform, each sub-session checked against its block
def loginSim : Json := ((simulate ((leanArgs loginProtocol).setObjVal! "instances" (toJson 6) |>.setObjVal! "seed" (toJson 4))).toOption.get!).getObjValD "events"
#guard verdict (conform ((leanArgs loginProtocol).setObjVal! "events" loginSim)) == "conforms"
-- negative: a text-message session that skips the gateway's answer is reported
#guard verdict (conform ((leanArgs loginProtocol).setObjVal! "events" (parse! r#"[{"id":"t1","session":"sms1","from":"Auth","to":"Sms","label":"SendCode"},{"id":"t2","session":"sms1","from":"Sms","to":"User","label":"Text"}]"#))) == "violates"
-- a walk plays the text-message session in place: after CodeSent, Auth sends the code to Sms
def loginWalk : String := r#"[{"id":"w1","from":"User","to":"App","label":"Password"},
  {"id":"w2","from":"App","to":"Auth","label":"CheckPassword","cause":"w1"},
  {"id":"w3","from":"Auth","to":"App","label":"PasswordOk","cause":"w2"},
  {"id":"w4","from":"App","to":"User","label":"CodeSent","cause":"w1"}]"#
#guard (field (next ((leanArgs loginProtocol).setObjVal! "events" (parse! loginWalk))) "next").compress ==
  "[{\"from\":\"Auth\",\"label\":\"SendCode\",\"to\":\"Sms\"}]"
-- the generated service starts each of its sessions in the body's first state
#guard ((field (skeleton (leanArgs loginProtocol)) "code").getStr?.toOption.getD "").contains
  "def sms(session, transport, log=None, new_id=None):\n    \"\"\"Sms's start state in a new session.\"\"\"\n    return SmsS1("

/-! ## session_ctl: properties the structure does not show -/

def tripParallel : String := include_str "../examples/vibecode/trip/Trip-parallel.protocol"
def tripSequential : String := include_str "../examples/vibecode/trip/Trip.protocol"
def prop (t f : String) : Except String Json := ctl ((leanArgs t).setObjVal! "formula" (parse! f))
def neverChargeAfterNoSeat : String := r#"{"AG": {"implies": [{"after": "NoSeat"}, {"AG": {"not": {"after": "Charge"}}}]}}"#
def pathOf (r : Except String Json) : List String :=
  match (field r "evidence").getObjValD "path" with
  | .arr a => a.toList.filterMap fun n => (n.getObjValAs? String "message").toOption
  | _ => []
-- the parallel draft may charge after NoSeat: the counterexample runs to the Charge itself
#guard verdict (prop tripParallel neverChargeAfterNoSeat) == "disproved"
#guard pathOf (prop tripParallel neverChargeAfterNoSeat) == ["Book", "HoldSeat", "NoSeat", "HoldRoom", "RoomHeld", "Charge"]
-- and the same path is in the report, which goes into the text a model reads
#guard ((field (prop tripParallel neverChargeAfterNoSeat) "report").getStr?.toOption.getD "") ==
  "counterexample: Book → HoldSeat → NoSeat → HoldRoom → RoomHeld → Charge"
-- a path that ends where the session ended says it stays there
#guard ((field (prop tripSequential r#"{"AF": {"after": "Charge"}}"#) "report").getStr?.toOption.getD "").endsWith "(and stays there)"
-- holding in sequence fixes it, every hold is confirmed or released, and every session ends
#guard verdict (prop tripSequential neverChargeAfterNoSeat) == "proved"
#guard verdict (prop tripSequential r#"{"AG": {"implies": [{"after": "SeatHeld"}, {"AF": {"or": [{"after": "SeatConfirmed"}, {"after": "SeatReleased"}]}}]}}"#) == "proved"
#guard verdict (prop tripSequential r#"{"AF": "terminal"}"#) == "proved"
#guard verdict (check ((leanArgs tripSequential).setObjVal! "mayCall" (parse! "[[\"Traveler\",\"Agency\"],[\"Agency\",\"Flights\"],[\"Agency\",\"Hotels\"],[\"Agency\",\"Payments\"]]"))) == "ok"
-- negative: an unknown label and a missing formula are rejected, not answered
#guard (reason (prop tripSequential r#"{"never": {"after": "Teleport"}}"#)).contains "unknown message Teleport"
#guard (reason (ctl (leanArgs tripSequential))).startsWith "formula is required"

/-! ## session_openapi: a role's HTTP interface -/

def signIn : String := include_str "../examples/vibecode/signin/SignIn.protocol"
def api (t role : String) : Except String Json := openapi ((leanArgs t).setObjVal! "role" (Json.str role))
def opsOf (r : Except String Json) : List String :=
  match (field r "openapi").getObjValD "paths" with
  | .obj kvs => kvs.toList.flatMap fun (p, v) => match v with
    | .obj ms => ms.toList.map fun (m, _) => s!"{m} {p}"
    | _ => []
  | _ => []
-- the sign-in App serves two requests, start and callback, each its own session
#guard verdict (check ((leanArgs signIn).setObjVal! "mayCall" (parse! "[[\"Browser\",\"App\"],[\"Browser\",\"Idp\"],[\"App\",\"Idp\"]]"))) == "ok"
#guard opsOf (api signIn "App") == ["get /callback", "get /login"]
#guard (((((field (api signIn "App") "openapi").getObjValD "paths").getObjValD "/callback").getObjValD "get").getObjValD "responses").compress.contains "\"401\":{\"content\""
#guard ((field (api signIn "App") "openapi").getObjValAs? String "openapi").toOption == some "3.1.0"
-- a POST carries its request's label as its body; a request without a status gets a default response
#guard opsOf (api tripSequential "Flights") == ["post /seats/confirmations", "delete /seats/holds", "post /seats/holds"]
#guard ((((field (api tripSequential "Flights") "openapi").getObjValD "paths").getObjValD "/seats/holds").getObjValD "post").compress.contains "\"requestBody\""
-- negative: requests without a route are listed, not guessed; conflicting or malformed routes and
-- unknown roles are rejected
#guard strs (field (api "protocol P (A, B) { q: Ask from A to B; Answer from B to A cause q; }" "B") "unrouted") == ["Ask from A"]
#guard reason (api "protocol P (A, B) { Ask from A to B route \"GET /x\"; Tell from A to B route \"GET /x\"; }" "B") == "GET /x is both Ask and Tell"
#guard reason (api "protocol P (A, B) { Ask from A to B route \"FETCH /x\"; }" "B") == "route \"FETCH /x\": fetch is not an HTTP method"
#guard reason (api "protocol P (A, B) { Ask from A to B route \"GET x\"; }" "B") == "route \"GET x\": the path must start with /"
#guard reason (api signIn "Nobody") == "Nobody is not a role of SignIn; its roles are Browser, App, Idp"

/-! ## session_review: every check that applies, with an edit for each finding -/

def rev (t : String) : Except String Json := review (leanArgs t)
def kinds (r : Except String Json) : List String :=
  match field r "findings" with
  | .arr a => a.toList.filterMap (·.getObjValAs? String "kind" |>.toOption)
  | _ => []
def suggestions (r : Except String Json) : List String :=
  match field r "findings" with
  | .arr a => a.toList.filterMap (·.getObjValAs? String "suggestion" |>.toOption)
  | _ => []
-- every example reviews clean
#guard [lendingProtocol, loginProtocol, tripSequential, signIn].all (fun t => verdict (rev t) == "clean")
-- HTTP comes from routes, so the first login draft is caught with no flags, and the answer is written out
def draft : String := "protocol Login (User, App, Sms) { p: Password from User to App route \"POST /login\"; Text from Sms to User; e: EnterCode from User to App route \"POST /login/code\"; Welcome from App to User cause p status 200; }"
#guard strs (field (rev draft) "issues") ==
  ["EnterCode (e) from User to App never gets a response (try: Answer it: `EnterCodeDone from App to User cause e status 200;` (or the status it means).)"]
-- a routed request without an id gets one in the suggestion; a response without a status is named
#guard (suggestions (rev "protocol P (A, B) { Ask from A to B route \"GET /x\"; }")).head? ==
  some "Give Ask an id (`x: Ask from A to B ...`), then answer it: `AskDone from B to A cause x status 200;`."
#guard strs (field (rev "protocol P (A, B) { q: Ask from A to B route \"GET /x\"; Answer from B to A cause q; }") "issues") ==
  ["Answer answers Ask (GET /x) without a status (try: Add the status it means, such as `status 200`, to Answer.)"]
-- a loop with no way out, with the steps into it; a role that takes no part
#guard strs (field (rev "protocol P (A, B) { Hello from A to B; rec L { Ping from A to B; continue L; } }") "issues") ==
  ["the session can never end, whatever happens (try: Give the loop a branch that leaves it (one without continue), or end it.)"]
#guard strs (field (rev "protocol P (A, B) { choice { Quit from A to B; } or { Stay from A to B; rec L { Ping from A to B; continue L; } } }") "issues") ==
  ["after Stay, the session can never end (try: Give the loop a branch that leaves it (one without continue), or end it.)"]
#guard kinds (rev "protocol P (A, B, C) { Hi from A to B; }") == ["roles"]
-- the structural rules come with their usual fix
#guard (suggestions (rev "protocol P (A, B, C) { choice { X from A to B; } or { Y from B to C; } }")).any (·.startsWith "Let one role send the first message")
#guard (suggestions (rev (loginInline))).any (·.startsWith "Send Sms a message in each branch")

/-! ## session_compat -/

def compatOf (newer older : String) : Except String Json :=
  compat ((leanArgs newer).setObjVal! "old" (Json.str older))
def lendingV2 : String := include_str "../examples/vibecode/lending/Lending-v2.protocol"
-- renewing: the Desk and the Librarian can upgrade first; the Member must wait for the Desk
#guard verdict (compatOf lendingV2 lendingProtocol) == "incompatible"
#guard (field (compatOf lendingV2 lendingProtocol) "reading").getStr?.toOption == some "Lending → Lending: upgrade first: Desk, Librarian"
#guard (strs (field (compatOf lendingV2 lendingProtocol) "issues")) ==
  [ "Member cannot upgrade first: Member is stuck trying to send Renew to Desk; Desk waits to receive Return from Member (after Member → Desk: Borrow; Desk → Member: Lent; Member chooses to send Renew to Desk)"
  , "Desk cannot stay on the old version: Member is stuck trying to send Renew to Desk; Desk waits to receive Return from Member (after Member → Desk: Borrow; Desk → Member: Lent; Member chooses to send Renew to Desk)" ]
-- the same protocol is compatible with itself, and v1 after v2 is the mirror image
#guard verdict (compatOf lendingProtocol lendingProtocol) == "compatible"
#guard (field (compatOf lendingProtocol lendingV2) "reading").getStr?.toOption == some "Lending → Lending: upgrade first: Member, Librarian"
-- dropping holds: the Desk may answer Refused at once, which the old Member accepts there, so the
-- Desk can go first (a role-by-role subtyping check would refuse this); the Member cannot, because
-- the old Desk may still put it on hold and send Waitlisted
def noHolds : String := "protocol Lending (Member, Desk) { sessions { b: Borrow from Member to Desk; choice { l: Lent from Desk to Member cause b; r: Return from Member to Desk; Returned from Desk to Member cause r; } or { Refused from Desk to Member cause b; } } }"
#guard (field (compatOf noHolds lendingProtocol) "reading").getStr?.toOption == some "Lending → Lending: upgrade first: Desk"
#guard (strs (field (compatOf noHolds lendingProtocol) "notes")) == ["only in the old version: Librarian"]
#guard (strs (field (compatOf noHolds lendingProtocol) "issues")).head? ==
  some "Member cannot upgrade first: Member waits to receive Lent from Desk, receive Refused from Desk; Desk is stuck trying to send Waitlisted to Member (after Member → Desk: Borrow; Desk → Librarian: Hold; Librarian → Desk: Approved)"
-- negative: a message nobody sends any more leaves its receiver waiting
#guard (strs (field (compatOf "protocol P (A, B) { x: Ping from A to B; }" "protocol P (A, B) { x: Ping from A to B; Pong from B to A cause x; }") "issues")) ==
  [ "A cannot upgrade first: B is stuck trying to send Pong to A (after A → B: Ping)"
  , "A cannot stay on the old version: A waits to receive Pong from B (after A → B: Ping)"
  , "B cannot upgrade first: A waits to receive Pong from B (after A → B: Ping)"
  , "B cannot stay on the old version: B is stuck trying to send Pong to A (after A → B: Ping)" ]
-- par: branches interleave in the composed system, and a reordering inside a branch is found
#guard verdict (compatOf "protocol F (H, A, B) { par { Ping from H to A; } and { Ping from H to B; } }" "protocol F (H, A, B) { par { Ping from H to B; } and { Ping from H to A; } }") == "compatible"
#guard verdict (compatOf "protocol T (S, R) { x: Ask from S to R; y: Tell from S to R; }" "protocol T (S, R) { y: Tell from S to R; x: Ask from S to R; }") == "incompatible"
-- a version that drops the text gateway's answer cannot go first against the old Auth
#guard verdict (compatOf (loginProtocol.replace "Queued from Sms to Auth cause s status 202; " "") loginProtocol) == "incompatible"
#guard reason (compat (leanArgs lendingProtocol)) == "old is required: the previous version's LeanFM protocol text"
#guard (reason (compatOf lendingProtocol "protocol Broken (A) { oops }")).startsWith "the old version: line 1"

/-! ## session_skeleton -/

def skel (t : String) : Except String Json := skeleton (leanArgs t)
def code (t : String) : String := ((field (skel t) "code").getStr?.toOption).getD ""
-- each state's methods are exactly the typestate's
#guard (code lendingProtocol).contains "class DeskS2(State):\n    \"\"\"Desk at S2: send_lent → DeskS3; send_hold → DeskS5.\"\"\""
-- a send fills in the protocol's ids: Lent is l, caused by b
#guard (code lendingProtocol).contains "ep.send(\"Member\", \"Lent\", \"l\", \"b\", body)"
-- a role that only serves sessions starts each one in the body's first state
#guard (code lendingProtocol).contains "def desk(session, transport, log=None, new_id=None):\n    \"\"\"Desk's start state in a new session.\"\"\"\n    return DeskS1("
-- an empty branch for this role is skip; loops come back; par and join fork
#guard (code lendingProtocol).contains "    def skip(self):"
#guard (code "protocol T (S, R) { rec B { d: Data from S to R; choice { Ack from R to S cause d; continue B; } or { Done from R to S cause d; } } }").contains "return msg, SS0(ep)"
#guard (code "protocol F (H, A, B) { par { x: Ping from H to A; Pong from A to H cause x; } and { y: Ping from H to B; Pong from B to H cause y; } Bye at H; }").contains
  "return Fork([HS1(ep), HS3(ep)], lambda: HS5(ep))"
-- join k of: the generated fork joins on k ends
#guard (code "protocol R (P, A, B, C) { join 2 of { wa: W from P to A; S from A to P cause wa; } and { wb: W from P to B; S from B to P cause wb; } and { wc: W from P to C; S from C to P cause wc; } Done at P; }").contains
  "return Fork([PS1(ep), PS3(ep), PS5(ep)], lambda: PS7(ep), need=2)"
-- choices are captioned with the role that decides
#guard ((field (diagram (leanArgs lendingProtocol)) "svg").getStr?.toOption.getD "").contains "[Desk decides]"
#guard ((field (check (leanArgs lendingProtocol)) "projections").getObjValD "Member" |>.getObjValAs? String "local").toOption.map (·.contains "offer {") == some true
-- two messages alike with different ids or causes: the cause is passed, not guessed
#guard (code "protocol A (C, S) { a: Ask from C to S; Reply from S to C cause a; b: Ask from C to S; Reply from S to C cause b; }").contains
  "def send_reply(self, cause=None, body=None):"
-- TypeScript: the same states, so a step a state does not allow is a missing method, a type error
def tsCode (t : String) : String :=
  ((field (skeleton ((leanArgs t).setObjVal! "language" (Json.str "typescript"))) "code").getStr?.toOption).getD ""
def tsClass (t c : String) : String := (((tsCode t).splitOn s!"export class {c} extends State \{")[1]?.getD "").splitOn "\n}\n" |>.head!
#guard (tsClass lendingProtocol "DeskS2").contains "  sendLent(body?: unknown): DeskS3 {"
#guard (tsClass lendingProtocol "DeskS2").contains "  sendHold(body?: unknown): DeskS5 {"
-- the lending bug cannot be written: an approved hold's state has no sendLent
#guard (tsClass lendingProtocol "DeskS6").contains "sendWaitlisted" && !(tsClass lendingProtocol "DeskS6").contains "sendLent"
-- states with the same methods are still different types, and receive narrows by label
#guard (tsClass lendingProtocol "DeskS6").contains "  readonly state = \"DeskS6\" as const;"
#guard (tsClass lendingProtocol "MemberS2").contains "receive(msg: Message): { label: \"Lent\"; msg: Message; next: MemberS3 } | { label: \"Waitlisted\"; msg: Message; next: End }"
#guard (tsCode "protocol R (P, A, B, C) { join 2 of { wa: W from P to A; S from A to P cause wa; } and { wb: W from P to B; S from B to P cause wb; } and { wc: W from P to C; S from C to P cause wc; } Done at P; }").contains
  "return new Fork([new PS1(ep), new PS3(ep), new PS5(ep)] as [PS1, PS3, PS5], () => new PS7(ep), 2);"
#guard (tsCode "protocol A (C, S) { a: Ask from C to S; Reply from S to C cause a; b: Ask from C to S; Reply from S to C cause b; }").contains
  "sendReply(cause?: string, body?: unknown): "
#guard reason (skeleton ((leanArgs "protocol C (C, S) { q: Q from C to S; choice { SoldOut from S to C cause q; } or { soldOut from S to C cause q; } }").setObjVal! "language" (Json.str "typescript"))) ==
  "S: two methods of S1 would both be called sendSoldOut"
-- negative: two methods with one Python name, an unknown language
#guard reason (skel "protocol C (C, S) { q: Q from C to S; choice { SoldOut from S to C cause q; } or { Sold_out from S to C cause q; } }") ==
  "S: two methods of S1 would both be called send_sold_out"
#guard reason (skeleton ((leanArgs lendingProtocol).setObjVal! "language" (Json.str "cobol"))) ==
  "language cobol is not supported; use python or typescript"
-- negative: names reach the code only as identifiers and escaped literals, so a quote or a newline
-- in a «name» cannot end a string or start a statement
def hostile : String := "protocol I («a\"b», «x)\\nimport os») {\n  «Go\"\"\"!» from «a\"b» to «x)\\nimport os»;\n}"
-- a real line break inside «» never reaches the generator: the parser refuses it
#guard reason (skel "protocol I («x)\nimport os», B) { }") == "line 1, column 13: «name» is never closed"
#guard verdict (skel hostile) == "generated"
#guard !((code hostile).splitOn "\n").any (·.startsWith "import os")
#guard !((code hostile).splitOn "\n").any fun l => (l.dropWhile (· == ' ')).startsWith "import os"
#guard (code hostile).contains "class a_bS0(State):"
#guard (code hostile).contains "ep.send(\"x)\\\\nimport os\", \"Go\\\"\\\"\\\"!\""

#guard !((tsCode hostile).splitOn "\n").any fun l => (l.dropWhile (· == ' ')).startsWith "import os"
#guard (tsCode hostile).contains "ep.send(\"x)\\\\nimport os\", \"Go\\\"\\\"\\\"!\""

end LeanFM.SessionToolsTests
