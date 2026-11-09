import LeanFM.Session.Global
import LeanFM.Session.Syntax

/-!
# Projection through concurrency

Requirement: a role that has already taken part in a session, and waits on another role's
choice, can tell the branches apart when the first messages it can receive in them differ, even
when a branch runs concurrent work (`par`) first. Its projection is an `offer`.

Negative requirements, unchanged by that rule:

* never accept a choice that a role which has already taken part is left out of (the bank holding
  money in `PurchaseWithHold`);
* never accept a choice whose branches the role cannot tell apart because one of them sends it
  nothing at all.
-/

namespace LeanFM.Session.ProjectionTests
open LeanFM.Session

inductive Role | client | shop | bank | warehouse
  deriving DecidableEq, Repr, Inhabited

instance : ToString Role := ⟨fun
  | .client => "Client" | .shop => "Shop" | .bank => "Bank" | .warehouse => "Warehouse"⟩

structure Pay      where deriving TypeName
structure Charge   where deriving TypeName
structure Charged  where deriving TypeName
structure Declined where deriving TypeName
structure Ship     where deriving TypeName
structure Shipped  where deriving TypeName
structure Receipt  where deriving TypeName
structure Refused  where deriving TypeName
structure Hold     where deriving TypeName

def roles : List Role := [.client, .shop, .bank, .warehouse]

/-- The client paid, so it has taken part. The bank decides; the accepted branch ships and answers
the client concurrently. The client learns the branch from Receipt or Refused. -/
protocol ConcurrentAnswer (Client, Shop, Bank, Warehouse) {
  p: Pay from Client to Shop;
  c: Charge from Shop to Bank cause p;
  choice {
    d: Charged from Bank to Shop cause c;
    par {
      Receipt from Shop to Client cause d;
    } and {
      s: Ship from Shop to Warehouse cause d;
         Shipped from Warehouse to Shop cause s;
    }
  } or {
    x: Declined from Bank to Shop cause c;
       Refused from Shop to Client cause x;
  }
}

/-- The answer comes after the concurrent work; the client is in neither side of the `par`. -/
protocol FanOutThenAnswer (Client, Shop, Bank, Warehouse) {
  p: Pay from Client to Shop;
  c: Charge from Shop to Bank cause p;
  choice {
    d: Charged from Bank to Shop cause c;
    par {
      s: Ship from Shop to Warehouse cause d;
         Shipped from Warehouse to Shop cause s;
    } and {
      Hold from Shop to Bank cause d;
    }
       Receipt from Shop to Client cause d;
  } or {
    x: Declined from Bank to Shop cause c;
       Refused from Shop to Client cause x;
  }
}

/-- The declined branch tells the client nothing: still rejected. -/
protocol ConcurrentNoRefusal (Client, Shop, Bank, Warehouse) {
  p: Pay from Client to Shop;
  c: Charge from Shop to Bank cause p;
  choice {
    d: Charged from Bank to Shop cause c;
    par {
      Receipt from Shop to Client cause d;
    } and {
      s: Ship from Shop to Warehouse cause d;
         Shipped from Warehouse to Shop cause s;
    }
  } or {
    Declined from Bank to Shop cause c;
  }
}

def concurrent : Global Role := ConcurrentAnswer .client .shop .bank .warehouse
def fanOut : Global Role := FanOutThenAnswer .client .shop .bank .warehouse
def noRefusal : Global Role := ConcurrentNoRefusal .client .shop .bank .warehouse

#guard concurrent.issues roles == []
#guard (concurrent.project Role.client).toOption.map Local.render ==
  some "send Pay to Shop;\noffer & {\n  receive Receipt from Shop;\n} or {\n  receive Refused from Shop;\n}"
#guard fanOut.issues roles == []
#guard (fanOut.project Role.client).toOption.map Local.render ==
  some "send Pay to Shop;\noffer & {\n  receive Receipt from Shop;\n} or {\n  receive Refused from Shop;\n}"
#guard noRefusal.issues roles == ["Client cannot tell which branch Bank chose"]

end LeanFM.Session.ProjectionTests
