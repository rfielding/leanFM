import LeanFM.Session.Global
import LeanFM.Session.Syntax
import LeanFM.Session.Physics
import LeanFM.Session.Spec
import LeanFM.Session.Topology
import LeanFM.Session.Http

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

end LeanFM.Session.SessionTests
