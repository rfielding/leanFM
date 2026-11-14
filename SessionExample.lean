import LeanFM.Session

/-!
# Session types in LeanFM: worked examples

Every protocol in the book's session-types chapter, as a Lean module. `#guard` lines are checks
that run when the file is elaborated: `lake env lean SessionExample.lean`.

The three design rules show up as follows.

* Pay only for what you use: `Purchase` imports nothing but the core and the syntax; physics,
  topology and the HTTP discipline are separate modules, consulted only by the examples that need
  them.
* The default case is simple: a protocol with no physics is checked as if every channel were
  `reliable`; a channel declaration names only what differs from a preset.
* Exceptions live in libraries: presets, interface kinds and conditions are ordinary values, so a
  vendor library can add a `grpc` kind or a `quorumLost` condition without changing LeanFM.
-/

namespace SessionExample
open LeanFM.Session

/-! ## Roles and vocabulary -/

inductive Role | client | shop | bank | sender | receiver | primary | r1 | r2 | r3
  deriving DecidableEq, Repr, Inhabited

instance : ToString Role := ⟨fun
  | .client => "Client" | .shop => "Shop" | .bank => "Bank" | .sender => "Sender"
  | .receiver => "Receiver" | .primary => "Primary" | .r1 => "R1" | .r2 => "R2" | .r3 => "R3"⟩

-- Message labels are structures; guards are type-checked against their fields.
structure Order    where item : String  deriving TypeName
structure Quote    where price : Nat    deriving TypeName
structure Pay      where amount : Nat   deriving TypeName
structure Paid     where                deriving TypeName
structure Shipped  where                deriving TypeName
structure SoldOut  where                deriving TypeName
structure Receipt  where amount : Nat   deriving TypeName
structure Confirm  where amount : Nat   deriving TypeName
structure Verify   where amount : Nat   deriving TypeName

/-! ## The default case: a global type and nothing else -/

/-- The book's Purchase. The bank is never told about the `SoldOut` branch, and need not be: its
part of the session starts when `Pay` arrives, as a thread forked for that session, so a branch
that never contacts it asks nothing of it. -/
--@begin Purchase
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
--@end Purchase

def roles3 : List Role := [.client, .shop, .bank]
def purchase : Global Role := Purchase .client .shop .bank

#guard purchase.issues roles3 == []

structure Hold where amount : Nat deriving TypeName
structure Release where deriving TypeName

/-- Once the bank has taken part, it must be told. Here the client places a hold first, so the
bank's session has started, and the `SoldOut` branch leaves it holding money forever. -/
--@begin PurchaseWithHold
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
--@end PurchaseWithHold

#guard (PurchaseWithHold Role.client Role.shop Role.bank).issues roles3 == ["Bank cannot tell which branch Shop chose"]

-- Projection gives each role its local type; the shop's is a production of its own.
#guard (purchase.project Role.shop |>.toOption |>.isSome)

-- The guard is type-checked as Lean when the protocol is written; conformance runs its text over the
-- logged fields with LeanFM's interpreter: 10 = 10 holds, 10 = 12 does not.
def payGuard : Guard := Id.run do
  match purchase with
  | .msg _ (.choice ((.msg _ (.msg p _)) :: _)) => p.guard.getD ⟨""⟩
  | _ => ⟨""⟩

def paid (amount : Nat) : Where.Lookup := fun
  | "q" => some [("price", .num 10)]
  | "p" => some [("amount", .num amount)]
  | _ => none
#guard payGuard.text == "p.amount = q.price"
#guard Where.run payGuard.text (paid 10) == .yes
#guard Where.run payGuard.text (paid 12) == .no

/-! ## HTTP: cut and un-cut (pay for the HTTP module only here) -/

def allHttp (_ _ : Role) : Bool := true
/-- Who may start a call to whom: the client calls the shop and the bank, the shop calls the bank. -/
def mayCall : Role → Role → Bool
  | .client, .shop | .client, .bank | .shop, .bank => true
  | _, _ => false

#guard purchase.httpCuts allHttp mayCall ==
  [ "Paid answers p, which Client sent to Bank, but goes to Shop"
  , "Shipped is a request from Shop to Client, which Shop may not call"
  , "Pay (p) from Client to Bank never gets a response"
  , "Paid from Bank to Shop never gets a response"
  , "Shipped from Shop to Client never gets a response" ]

/-- The same purchase un-cut for HTTP: every response goes back to the role that asked. -/
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

def purchaseHttp : Global Role := PurchaseHttp .client .shop .bank
#guard purchaseHttp.httpCuts allHttp mayCall == []
#guard purchaseHttp.causeIssues == []

/-! ## Physics: TFTP over UDP (pay for the physics module only here) -/

structure Data    where n : Nat deriving TypeName
structure Ack     where n : Nat deriving TypeName
structure LastAck where n : Nat deriving TypeName
structure Timeout where         deriving TypeName

/-- A first attempt puts the sender's timer in the global type, as a branch beside the
acknowledgement. No single role decides that choice: the sender's timer starts one branch and the
receiver's `Ack` the other, and both can happen at once. The checker reports the race. -/
--@begin TransferWithTimer
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
--@end TransferWithTimer

#guard (TransferWithTimer Role.sender Role.receiver).issues [.sender, .receiver] ==
  [ "no single role decides a choice, so it is a race: Sender starts Timeout; Receiver starts Ack" ]

/-- The lock step itself. The receiver decides between `Ack` and `LastAck`. Loss, reordering and
the sender's retransmission timer are physics, declared below, not branches of the type. -/
--@begin Transfer
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
--@end Transfer

def transfer : Global Role := Transfer .sender .receiver
#guard transfer.issues [.sender, .receiver] == []

/-- The channels, from presets. Only the differences are written. -/
--@begin tftpPhysics
def tftpPhysics : Physics Role :=
  { channels := [ (.sender, .receiver, { udp 2 with duplication := false })
                , (.receiver, .sender, { udp 2 with duplication := false }) ]
    timers := [{ role := .sender }] }
--@end tftpPhysics

/-- Requirements: what each channel's protocol handles, the properties the protocol promises, and
the assumptions about the channels. -/
def tftp : Spec Role :=
  { global := transfer, roles := [.sender, .receiver], physics := tftpPhysics
    handles := [ (.sender, .receiver, [.loss, .reorder])
               , (.receiver, .sender, [.loss]) ]
    properties := [ .AG (.EF .terminal)
                  , .someUntil (.not (sent% Ack)) (sent% LastAck) ]
    assumptions := [.fairDelivery .sender .receiver, .fairDelivery .receiver .sender] }

-- The ACK channel can reorder, and the protocol does not say it handles that: one finding.
#guard tftp.issues == ["channel Receiver -> Sender surfaces reorder, which its protocol does not handle"]

-- The properties are proved, over the protocol's state graph, when this file compiles: from every
-- state the transfer can still finish, and a one-block transfer exists.
#guard (tftp.verdicts "Transfer").map (·.2.1) == ["proved", "proved"]

-- The protocol does not promise that every transfer ends: the receiver decides when the last block
-- has come, and may acknowledge forever. Stated as a property, it is disproved with that path.
#guard ({ tftp with properties := [.AF .terminal] }.check "Transfer").getLast? ==
  some "property disproved: Transfer: on every path, eventually the task has ended; counterexample: Data -> Ack (then repeats from Ack)"

-- With no physics at all, the same protocol has nothing to handle: the default is reliable.
#guard ({ global := transfer, roles := [.sender, .receiver] } : Spec Role).issues == []

/-! ## Stacking and joins -/

structure Write where key : String deriving TypeName
structure Stored where              deriving TypeName
structure Done   where              deriving TypeName

/-- Write to three replicas; continue after any two acknowledge. -/
--@begin Replicate
protocol Replicate (P, A, B, C) {
  join 2 of {
    wa: Write from P to A; Stored from A to P cause wa;
  } and {
    wb: Write from P to B; Stored from B to P cause wb;
  } and {
    wc: Write from P to C; Stored from C to P cause wc;
  }
}

/-- A production that includes another, each written as if it were the whole protocol. -/
protocol ReplicatedOrder (Client, Primary, A, B, C) {
  o: Order from Client to Primary;
  include Replicate Primary A B C;
  Done from Primary to Client cause o;
}
--@end Replicate

def replicatedOrder : Global Role := ReplicatedOrder .client .primary .r1 .r2 .r3
#guard replicatedOrder.issues [.client, .primary, .r1, .r2, .r3] == []
#guard replicatedOrder.labels.length == 8

/-! ## The deployment tree (pay for the topology module only here) -/

open Node in
def deployment : Topology Role :=
  { world := [
      outside [ .actor .client [] ],
      island "us" [ datacenter "dc1" [
        machine "m1" [ .actor .shop [ ingress "https" .ingressHttps, internal "api" .api ] ],
        replicated "ledger" [ .actor .bank [ internal "api" .api ] ] ] ] ] }

#guard (deployment.find "us.Shop.ingress.https").isSome
#guard ((deployment.find "us.Bank.internal.api").map (deployment.reachable .client ·)) == some false
#guard ((deployment.find "us.Bank.internal.api").map (fun p => (deployment.channel .shop p).conditions.map (·.name)))
        == some ["duplicate", "reject", "close", "timeout"]

-- A library adds an interface kind by refining an existing one; nothing in LeanFM changes.
def grpc : IfaceKind := IfaceKind.http.refine "grpc" (adds := [⟨"deadline exceeded"⟩])
#guard grpc.lineage == ["stream", "http"]

/-! ## Bridge to the existing artifact format -/

#guard match purchase.toGrammarExpr "purchase" with
  | .seq (.event a) _ => a.message == "Order" && a.src == "Client"
  | _ => false

/-! ## Listings for the book

`lake env lean --run SessionExample.lean` writes the chapters' listings from this file and from the
checker, so the book shows exactly what is checked: protocol source between `--@begin`/`--@end`
markers, every role's projection, and the checker's findings. -/

def block (src name : String) : String :=
  match (src.splitOn s!"--@begin {name}\n")[1]? with
  | some rest => ((rest.splitOn s!"--@end {name}").headD "").trimAsciiEnd.toString
  | none => panic! s!"no block {name}"

def listing (body : String) : String :=
  "\\begin{lstlisting}[language={}]\n" ++ body ++ "\n\\end{lstlisting}\n"

def localsTeX (g : Global Role) (roles : List Role) : String :=
  "\n".intercalate (roles.map fun r =>
    match g.project r with
    | .ok l => "\\noindent\\textbf{" ++ toString r ++ "}\n" ++ listing (l.render)
    | .error e => "\\noindent\\textbf{" ++ toString r ++ "}: rejected, ``" ++ e ++ "''\n")

def issuesTeX (xs : List String) : String :=
  if xs.isEmpty then listing "(no issues)" else listing ("\n".intercalate xs)

def main : IO Unit := do
  let src ← IO.FS.readFile "SessionExample.lean"
  let out := "book/generated/"
  IO.FS.writeFile (out ++ "session-purchase.tex") (listing (block src "Purchase"))
  IO.FS.writeFile (out ++ "session-purchase-locals.tex") (localsTeX purchase roles3)
  IO.FS.writeFile (out ++ "session-purchase-shop.tex")
    (listing ((purchase.project Role.shop).toOption.map Local.render |>.getD ""))
  IO.FS.writeFile (out ++ "session-hold.tex") (listing (block src "PurchaseWithHold"))
  IO.FS.writeFile (out ++ "session-hold-issues.tex")
    (issuesTeX ((PurchaseWithHold Role.client Role.shop Role.bank).issues roles3))
  IO.FS.writeFile (out ++ "session-timer.tex") (listing (block src "TransferWithTimer"))
  IO.FS.writeFile (out ++ "session-timer-issues.tex")
    (issuesTeX ((TransferWithTimer Role.sender Role.receiver).issues [.sender, .receiver]))
  IO.FS.writeFile (out ++ "session-transfer.tex")
    (listing (block src "Transfer" ++ "\n\n" ++ block src "tftpPhysics"))
  IO.FS.writeFile (out ++ "session-tftp-issues.tex") (issuesTeX tftp.issues)
  IO.FS.writeFile (out ++ "session-replicate.tex") (listing (block src "Replicate"))
  IO.FS.writeFile (out ++ "session-provenance.txt")
    s!"generated by lake env lean --run SessionExample.lean\npurchase issues: {purchase.issues roles3}\n"

end SessionExample

def main : IO Unit := SessionExample.main
