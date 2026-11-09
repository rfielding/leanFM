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
#guard ((field po "diagram").getObjValD "shapes").compress.contains "⊕ Shop selects · & "
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
  , "Shipped is a request from Shop to Client, which Shop may not call" ]
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
-- the README's picture is the generated diagram of the current protocol, not a drawing
#guard (field (diagram ((leanArgs lendingProtocol).setObjVal! "theme" (Json.str "dark"))) "svg").getStr?.toOption ==
  some (include_str "../examples/vibecode/lending/Lending.svg")
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
-- choices are captioned in session-type notation: ⊕ the decider, & the roles that offer
#guard ((field (diagram (leanArgs lendingProtocol)) "svg").getStr?.toOption.getD "").contains "[⊕ Desk selects · &amp; Member, Librarian offer]"
#guard ((field (check (leanArgs lendingProtocol)) "projections").getObjValD "Member" |>.getObjValAs? String "local").toOption.map (·.contains "offer & {") == some true
-- two messages alike with different ids or causes: the cause is passed, not guessed
#guard (code "protocol A (C, S) { a: Ask from C to S; Reply from S to C cause a; b: Ask from C to S; Reply from S to C cause b; }").contains
  "def send_reply(self, cause=None, body=None):"
-- negative: two methods with one Python name, an unknown language
#guard reason (skel "protocol C (C, S) { q: Q from C to S; choice { SoldOut from S to C cause q; } or { Sold_out from S to C cause q; } }") ==
  "S: two methods of S1 would both be called send_sold_out"
#guard reason (skeleton ((leanArgs lendingProtocol).setObjVal! "language" (Json.str "cobol"))) ==
  "language cobol is not supported; use python"
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

end LeanFM.SessionToolsTests
