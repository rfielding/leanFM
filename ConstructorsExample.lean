import LeanFM.Session
import LeanFM.SessionTools

/-! Constructors that carry proofs (clause selfhost.session.constructors).

A message is not a mere record. Its structure can name its constructor private, so the only way
to make one is a smart constructor that checks first; and it can hold constraint fields,
propositions about its own fields, so no value exists unless they hold. Lean proves facts about
these types that no `where` clause states: an encoding that decodes back to what was encoded, a
payment that can never exceed a bound because the quote it was made from could not.

The region from `--@begin Checkout` to `--@end Checkout` is also what LeanFM's tools read: they
check the constraints they can read on every logged message, fill them in simulated ones, give them
to OpenAPI as bounds and to generated code as checks, and carry the theorems through unread.

Run from the LeanFM root: `lake env lean ConstructorsExample.lean`. Every `theorem` is checked and
every `#guard` runs when the file is elaborated. -/

namespace ConstructorsExample
open LeanFM.Session

inductive Role | client | shop | bank
  deriving DecidableEq, Repr, Inhabited

instance : ToString Role := ⟨fun | .client => "Client" | .shop => "Shop" | .bank => "Bank"⟩

--@begin Checkout
/-- Four bytes of an unsigned 32-bit integer, least significant first. -/
structure LE32 where
  private mk ::
  b0 : Nat
  b1 : Nat
  b2 : Nat
  b3 : Nat
  bytes : b0 < 256 /\ b1 < 256 /\ b2 < 256 /\ b3 < 256
  deriving TypeName

/-- A C string: bytes ending in a single zero byte, with no zero before it. -/
structure CString where
  private mk ::
  bytes : List Nat
  terminated : bytes.getLast? = some 0
  noInnerZero : bytes.dropLast.contains 0 = false
  deriving TypeName

structure CreateOrder where
  item : String
  quantity : Nat
  someItems : 0 < quantity /\ quantity <= 100
  deriving TypeName

structure Quote where
  private mk ::
  price : Nat
  priced : 0 < price /\ price <= 10000
  deriving TypeName

structure Pay where
  private mk ::
  amount : Nat
  card_secr : String
  bounded : 0 < amount /\ amount <= 10000
  deriving TypeName

structure Receipt where
  total : LE32
  deriving TypeName

structure SoldOut where
  deriving TypeName

/-- The only way to make an LE32: split a number below 2^32 into its four bytes. -/
def LE32.ofNat (n : Nat) (_h : n < 4294967296) : LE32 :=
  ⟨n % 256, n / 256 % 256, n / 65536 % 256, n / 16777216 % 256, by omega⟩

def LE32.toNat (x : LE32) : Nat :=
  x.b0 + 256 * x.b1 + 65536 * x.b2 + 16777216 * x.b3

/-- Decoding what was encoded gives the number back: proved for every number, not tested on some. -/
theorem LE32.roundtrip (n : Nat) (h : n < 4294967296) : (LE32.ofNat n h).toNat = n := by
  simp only [LE32.ofNat, LE32.toNat]
  omega

/-- Every LE32 holds a number below 2^32, whoever made it: the constructor's proof is enough. -/
theorem LE32.toNat_lt (x : LE32) : x.toNat < 4294967296 := by
  obtain ⟨h0, h1, h2, h3⟩ := x.bytes
  simp only [LE32.toNat]
  omega

/-- A C string from bytes that hold no zero: the terminator is added, and both proofs come from
the bytes' own proof. -/
def CString.ofBytes (bs : List Nat) (h : bs.contains 0 = false) : CString :=
  ⟨bs ++ [0], by simp, by simpa using h⟩

/-- The smart constructor for a quote: it checks the price, and only then builds. -/
def Quote.make (price : Nat) : Except String Quote :=
  if h : 0 < price /\ price <= 10000 then .ok ⟨price, h⟩
  else .error s!"no Quote can have price {price}: it must be from 1 to 10000"

/-- A payment for a quote needs no check at all: the quote's proof is the payment's proof. -/
def Pay.forQuote (q : Quote) (card_secr : String) : Pay :=
  ⟨q.price, card_secr, q.priced⟩

/-- A payment made for a quote pays exactly its price, so the protocol's `where p.amount = q.price`
holds by construction. -/
theorem Pay.forQuote_amount (q : Quote) (c : String) : (Pay.forQuote q c).amount = q.price := rfl

/-- No `where` clause says this: whenever a payment matches a quote, the quote was at most 10000.
The clause and Pay's constructor prove it together. -/
theorem quote_bounded_by_pay (q : Quote) (p : Pay) (h : p.amount = q.price) : q.price <= 10000 :=
  h ▸ p.bounded.2

protocol Checkout (Client, Shop, Bank) {
  o: CreateOrder from Client to Shop route "POST /orders";
  choice {
    q: Quote from Shop to Client cause o status 200;
    p: Pay from Client to Bank cause q route "POST /pay" where p.amount = q.price;
    r: Receipt from Bank to Client cause p status 200;
  } or {
    SoldOut from Shop to Client cause o status 409;
  }
}
--@end Checkout

def checkout : Global Role := Checkout .client .shop .bank
#guard checkout.issues [.client, .shop, .bank] == []

/-! ## What the tools make of it -/

open Lean LeanFM.SessionTools

def text : String := include_str "ConstructorsExample.lean"

/-- The region the tools read, as a protocol file. -/
def spec : String :=
  let after := ((text.splitOn "--@begin Checkout\n")[1]?).getD ""
  "import LeanFM.Session.Syntax\n\n" ++ ((after.splitOn "--@end Checkout")[0]?).getD ""

def args (extra : List (String × Json) := []) : Json := Json.mkObj ([("lean", Json.str spec)] ++ extra)
def field (r : Except String Json) (k : String) : Json := match r with | .ok j => j.getObjValD k | .error _ => Json.null
def str (r : Except String Json) (k : String) : String := ((field r k).getStr?).toOption.getD ""
def has (s sub : String) : Bool := (s.splitOn sub).length > 1

-- the tools read the constraint fields, the private constructors, and carry the theorems unread
#guard match parseProtocol (args) with
  | .ok p => match p.types.find? (·.name == "Pay") with
    | some m => m.privateCtor && m.constraints.map (·.name) == ["bounded"] && m.constraints.all (·.checkable)
    | none => false
  | .error _ => false
-- a constraint outside the condition language is Lean's alone: CString's are proved, not run
#guard match parseProtocol (args) with
  | .ok p => match p.types.find? (·.name == "CString") with
    | some m => m.constraints.map (·.name) == ["terminated", "noInnerZero"] && m.constraints.all (!·.checkable)
    | none => false
  | .error _ => false

def ev (id label src dst : String) (cause : Option String) (fields : Json) : Json :=
  Json.mkObj ([("id", Json.str id), ("ts", Json.str (toString (id.drop 1).toString.toNat!)), ("label", Json.str label),
    ("from", Json.str src), ("to", Json.str dst), ("session", "s1"), ("fields", fields)] ++
    (match cause with | some c => [("cause", Json.str c)] | none => []))

def payLog (amount : Nat) : Json := Json.arr #[
  ev "e1" "CreateOrder" "Client" "Shop" none (Json.mkObj [("item", "tea"), ("quantity", "2")]),
  ev "e2" "Quote" "Shop" "Client" (some "e1") (Json.mkObj [("price", Json.str (toString amount))]),
  ev "e3" "Pay" "Client" "Bank" (some "e2") (Json.mkObj [("amount", Json.str (toString amount)), ("card_secr", "4242")])]

-- a logged Pay its constructor could never have made is a violation, and says which constraint
#guard str (conform (args [("events", payLog 20000), ("allowIncomplete", Json.bool true)])) "verdict" == "violates"
#guard has (field (conform (args [("events", payLog 20000), ("allowIncomplete", Json.bool true)])) "issues").compress "Quote.priced does not hold"
#guard str (conform (args [("events", payLog 250), ("allowIncomplete", Json.bool true)])) "verdict" == "conforms"
-- simulated streams carry contents every constructor accepts
#guard match simulate (args [("seed", toJson (3 : Nat))]) with
  | .ok j => (j.getObjValD "events").compress.length > 0 && !has (j.getObjValD "reading").compress "no example fields"
  | .error _ => false
-- OpenAPI gets the bounds the constraints put on single fields
#guard match openapi (args [("role", "Bank")]) with
  | .ok j => let c := (j.getObjValD "code").getStr?.toOption.getD ""
    has c "maximum: 10000" && has c "exclusiveMinimum: 0" && has c "bounded: 0 < amount"
  | .error _ => false

end ConstructorsExample
