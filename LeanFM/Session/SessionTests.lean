import LeanFM.Session.Global
import LeanFM.Session.Syntax
import LeanFM.Session.Physics
import LeanFM.Session.Spec
import LeanFM.Session.Topology
import LeanFM.Session.Http
import LeanFM.Session.Diagram
import LeanFM.Session.Calls
import LeanFM.Session.Events

/-!
# Session-type library tests (clauses selfhost.session.*)

Built with the library, so `lake build` runs every `#guard`. The protocols are the book's examples
(SessionExample.lean), repeated here so a broken rule fails the build rather than only the book.
Projection through `par` is tested in ProjectionTests.lean.
-/

namespace LeanFM.Session.SessionTests
open LeanFM.Session

inductive Role | client | shop | bank | sender | receiver | primary | r1 | r2 | r3
  deriving DecidableEq, Repr, Inhabited

instance : ToString Role := ⟨fun
  | .client => "Client" | .shop => "Shop" | .bank => "Bank" | .sender => "Sender"
  | .receiver => "Receiver" | .primary => "Primary" | .r1 => "R1" | .r2 => "R2" | .r3 => "R3"⟩

structure Order   where item : String deriving TypeName
structure Quote   where price : Nat   deriving TypeName
structure Pay     where amount : Nat  deriving TypeName
structure Paid    where               deriving TypeName
structure Shipped where               deriving TypeName
structure SoldOut where               deriving TypeName
structure Receipt where amount : Nat  deriving TypeName
structure Confirm where amount : Nat  deriving TypeName
structure Verify  where amount : Nat  deriving TypeName
structure Hold    where amount : Nat  deriving TypeName
structure Data    where n : Nat       deriving TypeName
structure Ack     where n : Nat       deriving TypeName
structure LastAck where n : Nat       deriving TypeName
structure Timeout where               deriving TypeName
structure Write   where key : String  deriving TypeName
structure Stored  where               deriving TypeName
structure Done    where               deriving TypeName
structure Bid     where amount : Nat  deriving TypeName
structure Get     where               deriving TypeName
structure Page    where               deriving TypeName
structure Declined where              deriving TypeName
structure Refused where               deriving TypeName

def roles3 : List Role := [.client, .shop, .bank]

/-! ## selfhost.session.syntax and selfhost.session.projection -/

protocol Purchase (Client, Shop, Bank) {
  o: Order from Client to Shop;
  choice {
    q: Quote from Shop to Client cause o;
    p: Pay   from Client to Bank cause q where p.amount = q.price;
       Paid  from Bank to Shop cause p;
       Shipped from Shop to Client;
  } or {
       SoldOut from Shop to Client cause o;
  }
}

def purchase : Global Role := Purchase .client .shop .bank

#guard purchase.issues roles3 == []
#guard purchase.labels == ["Order", "Quote", "Pay", "Paid", "Shipped", "SoldOut"]
-- a role that has not started is absent from a branch that never contacts it
#guard (purchase.project Role.bank).toOption.map Local.render ==
  some "offer {\n  receive Pay from Client;\n  send Paid to Shop;\n} or {\n}"
#guard (purchase.project Role.shop).toOption.map Local.render ==
  some "receive Order from Client;\nselect {\n  send Quote to Client;\n  receive Paid from Bank;\n  send Shipped to Client;\n} or {\n  send SoldOut to Client;\n}"

-- a where clause is typed Lean over decoded payloads
def payGuard : Guard := Id.run do
  match purchase with
  | .msg _ (.choice ((.msg _ (.msg p _)) :: _)) => p.guard.getD ⟨"", fun _ => none⟩
  | _ => ⟨"", fun _ => none⟩
#guard payGuard.text == "p.amount = q.price"
#guard payGuard.eval [("q", Dynamic.mk (Quote.mk 10)), ("p", Dynamic.mk (Pay.mk 10))] == some true
#guard payGuard.eval [("q", Dynamic.mk (Quote.mk 10)), ("p", Dynamic.mk (Pay.mk 12))] == some false

-- a role that has taken part must be told which branch was chosen
protocol PurchaseWithHold (Client, Shop, Bank) {
  h: Hold from Client to Bank;
  o: Order from Client to Shop;
  choice {
    q: Quote from Shop to Client cause o;
    p: Pay   from Client to Bank cause q;
  } or {
       SoldOut from Shop to Client cause o;
  }
}
#guard (PurchaseWithHold Role.client Role.shop Role.bank).issues roles3 == ["Bank cannot tell which branch Shop chose"]

/-! ## selfhost.session.choice -/

protocol TransferWithTimer (Sender, Receiver) {
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
}
#guard (TransferWithTimer Role.sender Role.receiver).issues [.sender, .receiver] ==
  [ "no single role decides a choice, so it is a race: Sender starts Timeout; Receiver starts Ack" ]

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
}
def transfer : Global Role := Transfer .sender .receiver
#guard transfer.issues [.sender, .receiver] == []

/-! ## selfhost.session.causes -/

protocol BorrowedCause (Client, Shop, Bank) {
  o: Order from Client to Shop;
     Paid from Bank to Shop cause o;
}
#guard (BorrowedCause Role.client Role.shop Role.bank).causeIssues == ["Paid: Bank never saw o"]
#guard purchase.causeIssues == []

/-! ## selfhost.session.composition: include and threshold joins -/

protocol Replicate (P, A, B, C) {
  join 2 of {
    wa: Write from P to A; Stored from A to P cause wa;
  } and {
    wb: Write from P to B; Stored from B to P cause wb;
  } and {
    wc: Write from P to C; Stored from C to P cause wc;
  }
}
protocol ReplicatedOrder (Client, Primary, A, B, C) {
  o: Order from Client to Primary;
  include Replicate Primary A B C;
  Done from Primary to Client cause o;
}
def replicatedOrder : Global Role := ReplicatedOrder .client .primary .r1 .r2 .r3
#guard replicatedOrder.issues [.client, .primary, .r1, .r2, .r3] == []
#guard replicatedOrder.labels.length == 8

/-! ## selfhost.session.http -/

def allHttp (_ _ : Role) : Bool := true
def mayCall : Role → Role → Bool
  | .client, .shop | .client, .bank | .shop, .bank => true
  | _, _ => false

#guard purchase.httpCuts allHttp mayCall ==
  [ "Paid answers p, which Client sent to Bank, but goes to Shop"
  , "Shipped is a request from Shop to Client, which Shop may not call" ]

protocol PurchaseHttp (Client, Shop, Bank) {
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
}
#guard (PurchaseHttp Role.client Role.shop Role.bank).httpCuts allHttp mayCall == []

/-! ## selfhost.session.physics -/

def tftpPhysics : Physics Role :=
  { channels := [ (.sender, .receiver, { udp 2 with duplication := false })
                , (.receiver, .sender, { udp 2 with duplication := false }) ]
    timers := [{ role := .sender }] }

def tftp : Spec Role :=
  { global := transfer, roles := [.sender, .receiver], physics := tftpPhysics
    handles := [ (.sender, .receiver, [.loss, .reorder]), (.receiver, .sender, [.loss]) ] }

#guard tftp.issues == ["channel Receiver -> Sender surfaces reorder, which its protocol does not handle"]
-- with no physics declared every channel is reliable, so there is nothing to handle
#guard ({ global := transfer, roles := [.sender, .receiver] } : Spec Role).issues == []

/-! ## selfhost.session.topology -/

open Node in
def deployment : Topology Role :=
  { world := [
      outside [ .actor .client [] ],
      island "us" [ datacenter "dc1" [
        machine "m1" [ .actor .shop [ ingress "https" .ingressHttps, internal "api" .api ] ],
        replicated "ledger" [ .actor .bank [ internal "api" .api ] ] ] ] ] }

#guard (deployment.find "us.Shop.ingress.https").isSome
-- an internal interface is unreachable from outside, reachable from the same island
#guard ((deployment.find "us.Bank.internal.api").map (deployment.reachable .client ·)) == some false
#guard ((deployment.find "us.Bank.internal.api").map (deployment.reachable .shop ·)) == some true
-- placement adds conditions: a replicated group can reject
#guard ((deployment.find "us.Bank.internal.api").map (fun p => (deployment.channel .shop p).conditions.map (·.name)))
        == some ["duplicate", "reject", "close", "timeout"]
-- a library adds an interface kind by refining one; LeanFM itself does not change
def grpc : IfaceKind := IfaceKind.http.refine "grpc" (adds := [⟨"deadline exceeded"⟩])
#guard grpc.lineage == ["stream", "http"]

/-! ## selfhost.session.diagram -/

/-- How many times `pat` occurs in `s`. -/
def occurs (s pat : String) : Nat := (s.splitOn pat).length - 1

def purchaseSvg := purchase.diagram roles3
-- every message is one arrow, and nothing else is drawn as an arrow
#guard occurs purchaseSvg "class=\"msg" == purchase.labels.length
-- replies (the cause chain reaches a call from the receiver to the sender) are dashed: Quote and
-- SoldOut answer o; Pay is a new call made after a reply, and Paid answers Client's call to Bank
-- but goes to Shop, so both stay solid
#guard occurs purchaseSvg "class=\"msg reply\"" == 2
#guard occurs purchaseSvg "class=\"frame alt\"" == 1
#guard (purchaseSvg.splitOn "[Shop selects; others offer]").length == 2
#guard occurs purchaseSvg ">p: Pay<" == 1
#guard occurs purchaseSvg "class=\"guard\">[p.amount = q.price]" == 1

def replicatedSvg := replicatedOrder.diagram [.client, .primary, .r1, .r2, .r3]
#guard occurs replicatedSvg "class=\"msg" == 8
#guard occurs replicatedSvg "class=\"frame ref\"" == 1
#guard occurs replicatedSvg "[Replicate]" == 1
#guard occurs replicatedSvg "class=\"frame join\"" == 1
#guard occurs replicatedSvg "[any 2 of 3]" == 1

def transferSvg := transfer.diagram [.sender, .receiver]
#guard occurs transferSvg "class=\"frame loop\"" == 1
#guard occurs transferSvg "↻ continue Block" == 1
#guard occurs transferSvg "[Receiver selects; others offer]" == 1

-- an event is an action box; a race is drawn, and named as one, rather than hidden
def timerSvg := (TransferWithTimer Role.sender Role.receiver).diagram [.sender, .receiver]
#guard occurs timerSvg "class=\"act\"" == 1
#guard occurs timerSvg "[race: no single role selects]" == 1

-- a response that follows other calls is still the reply to the call that asked for it, and a
-- new call made after a reply is not a reply
protocol PayThenCharge (Client, Shop, Bank) {
  o: Order from Client to Shop;
  q: Quote from Shop to Client cause o;
  p: Pay from Client to Shop cause q;
  v: Verify from Shop to Bank cause p;
  h: Hold from Bank to Shop cause v;
     Receipt from Shop to Client cause h;
}
def payThenChargeSvg := (PayThenCharge Role.client Role.shop Role.bank).diagram roles3
#guard occurs payThenChargeSvg "class=\"msg reply\"" == 3  -- Quote, Hold, Receipt
#guard occurs payThenChargeSvg "class=\"msg\"" == 3        -- Order, Pay, Verify

protocol Serve (Client, Shop) {
  sessions {
    g: Get from Client to Shop;
       Page from Shop to Client cause g;
  }
}
def serveSvg := (Serve Role.client Role.shop).diagram [.client, .shop]
#guard occurs serveSvg "class=\"frame sessions\"" == 1
#guard occurs serveSvg "class=\"msg reply\"" == 1

protocol Bidding (Client, Shop) {
  q: Quote from Shop to Client;
  b: Bid from Client to Shop cause q where b.amount < q.price && b.amount > 0;
}
def biddingSvg := (Bidding Role.client Role.shop).diagram [.client, .shop]
#guard occurs biddingSvg "[b.amount &lt; q.price &amp;&amp; b.amount &gt; 0]" == 1
#guard occurs biddingSvg "b.amount <" == 0

/-! ## selfhost.session.calls -/

protocol Checkout (Client, Shop, Bank) {
  o: Order from Client to Shop route "POST /orders";
  choice {
    q: Quote from Shop to Client cause o status 201;
    p: Pay from Client to Shop cause q route "POST /orders/{id}/payment" where p.amount = q.price;
    v: Verify from Shop to Bank cause p route "POST /charges";
    choice {
      h: Hold from Bank to Shop cause v;
         Receipt from Shop to Client cause h status 200;
    } or {
      x: Declined from Bank to Shop cause v;
         Refused from Shop to Client cause x status 402;
    }
  } or {
    SoldOut from Shop to Client cause o status 409;
  }
}
def checkout : Global Role := Checkout .client .shop .bank

#guard checkout.issues roles3 == []
-- a call is a request with the responses its cause chain ties to it; the bank's charge is part of
-- the payment's detail, nested under it; responses are never calls of their own
#guard checkout.callsText ==
  "o: Order  Client → Shop  POST /orders\n" ++
  "  returns Quote 201 | SoldOut 409\n" ++
  "p: Pay  Client → Shop  POST /orders/{id}/payment\n" ++
  "  returns Receipt 200 | Refused 402\n" ++
  "    v: Verify  Shop → Bank  POST /charges\n" ++
  "      returns Hold | Declined"
-- a one-way message is a call with no reply
#guard purchase.callsText ==
  "o: Order  Client → Shop\n  returns Quote | SoldOut\n" ++
  "p: Pay  Client → Bank\n  returns no reply\n" ++
  "    Paid  Bank → Shop\n      returns no reply\n" ++
  "Shipped  Shop → Client\n  returns no reply"

-- each role's projection read as a typestate API
#guard ((checkout.typestates roles3).lookup Role.client).bind (·.toOption) == some ((
  "start : S0\n" ++
  "S0.sendOrder(m : Order) : S1    -- to Shop\n" ++
  "S1.receive() : Quote × S2 (from Shop) | SoldOut × End (from Shop)\n" ++
  "S2.sendPay(m : Pay) : S3    -- to Shop\n" ++
  "S3.receive() : Receipt × End (from Shop) | Refused × End (from Shop)"))
#guard ((checkout.typestates roles3).lookup Role.bank).bind (·.toOption) == some ((
  "start : S0\n" ++
  "S0.receive() : Verify × S1 (from Shop) | nothing × End\n" ++
  "S1.sendHold(m : Hold) : End    -- to Shop\n" ++
  "S1.sendDeclined(m : Declined) : End    -- to Shop"))
-- a loop's continue returns to the loop's state
#guard ((transfer.typestates [.sender, .receiver]).lookup Role.sender).bind (·.toOption) == some ((
  "start : S0\n" ++
  "S0.sendData(m : Data) : S1    -- to Receiver\n" ++
  "S1.receive() : Ack × S0 (from Receiver) | LastAck × End (from Receiver)"))

-- the diagram shows routes and statuses, and each call as an activation bar on the callee; a
-- response in another branch gets a bar of its own from where that branch begins
def checkoutSvg := checkout.diagram roles3
#guard occurs checkoutSvg "o: Order · POST /orders<" == 1
#guard occurs checkoutSvg "q: Quote · 201<" == 1
#guard occurs checkoutSvg "Refused · 402<" == 1
#guard occurs checkoutSvg "class=\"activation\"" == 6

protocol Lookup (Client, Shop) {
  g: Get from Client to Shop route "GET /pages?q=<a&b>";
     Page from Shop to Client cause g status 200;
}
def lookupSvg := (Lookup Role.client Role.shop).diagram [.client, .shop]
#guard occurs lookupSvg "GET /pages?q=&lt;a&amp;b&gt;" == 1
#guard occurs lookupSvg "<a&b>" == 0

/-! ## selfhost.session.events -/

/-- Every link of every event points to an earlier event of the same session. -/
def linksBackward (evs : Array (Event Role)) : Bool :=
  evs.toList.all fun e =>
    (e.prior ++ e.cause.toList ++ e.answers.toList).all fun p =>
      p < e.id && (evs[p]?.map (·.session)) == some e.session

/-- The events a given event reaches backwards through prior. -/
partial def before (evs : Array (Event Role)) (id : Nat) : List Nat :=
  match evs[id]? with
  | some e => e.prior ++ e.prior.flatMap (before evs)
  | none => []

def sorted (xs : List String) : List String := xs.mergeSort (· ≤ ·)
def sessionLabels (evs : Array (Event Role)) (s : Nat) : List String :=
  (evs.toList.filter (·.session == s)).map (·.label)

-- each session of a served protocol is one instance of it; the response answers its request
def serveEvents := (Serve Role.client Role.shop).simulate (seed := 3) (instances := 5)
#guard serveEvents.size == 10
#guard linksBackward serveEvents
#guard (List.range 5).all fun i => sessionLabels serveEvents (i + 1) == ["Get", "Page"]
#guard serveEvents.toList.all fun e => e.label != "Page" || (e.answers.bind (serveEvents[·]?)).map (·.label) == some "Get"

-- whatever branches the seed picks, a run contains exactly the messages of one run of the protocol
#guard (List.range 20).all fun seed =>
  let evs := checkout.simulate (seed := seed)
  linksBackward evs &&
  (checkout.runs.map fun r => sorted (r.map Step.label)).contains (sorted (sessionLabels evs 0))
-- the same seed gives the same stream
#guard eventsJson (checkout.simulate (seed := 9)) == eventsJson (checkout.simulate (seed := 9))

-- par branches are concurrent: neither reaches the other through prior; what follows the par
-- reaches both, even the branch whose actors it does not involve
-- (on different actors: one actor handles one message at a time, so its own events are ordered)
protocol Fan (Client, Shop, Bank, Ledger) {
  o: Order from Client to Shop;
  v: Verify from Shop to Bank cause o;
  par {
    Receipt from Shop to Client cause o;
  } and {
    Hold from Bank to Ledger cause v;
  }
  Done from Shop to Client cause o;
}
def fanEvents := (Fan Role.client Role.shop Role.bank Role.r1).simulate (seed := 5)
def idOf (evs : Array (Event Role)) (l : String) : Nat := ((evs.toList.find? (·.label == l)).map (·.id)).getD 0
#guard linksBackward fanEvents
#guard !(before fanEvents (idOf fanEvents "Receipt")).contains (idOf fanEvents "Hold")
#guard !(before fanEvents (idOf fanEvents "Hold")).contains (idOf fanEvents "Receipt")
#guard (before fanEvents (idOf fanEvents "Done")).contains (idOf fanEvents "Receipt")
#guard (before fanEvents (idOf fanEvents "Done")).contains (idOf fanEvents "Hold")

-- a loop repeats at most its fuel, then ends
#guard ((transfer.simulate (seed := 1) (loops := 2)).toList.filter (·.label == "Data")).length ≤ 3

-- strings are escaped in the JSON
#guard jsonString "a\"b\\c\n" == "\"a\\\"b\\\\c\\n\""

end LeanFM.Session.SessionTests
