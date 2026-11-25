import Lean.Data.Json

/-!
# Lean as a programming language: the parts LeanFM uses

The code the tutorial video (video/lean-tutorial) shows, one region per scene, from `--@scene name`
to `--@end`. Every `#eval` result on screen is what Lean printed for this file (fetch.py runs
`lake env lean --json` on it), every `#guard` is checked when the file compiles, and every theorem
is proved. `make video-check` compiles it, so the tutorial stays true as Lean and LeanFM change.

Run from the LeanFM root: `lake env lean video/lean-tutorial/Tour.lean`
-/

namespace Tour

--@scene def
-- a function: its arguments and result have types
def double (n : Nat) : Nat := n * 2
#eval double 21

def greet (name : String) : String := s!"hello, {name}"
#eval greet "Lean"

-- a function is a value: `twice` takes one as its argument
def twice (f : Nat → Nat) (x : Nat) : Nat := f (f x)
#eval twice double 5
#eval twice (fun n => n + 1) 5
#eval twice (· + 1) 5
--@end

--@scene structure
-- a record type; `currency` has a default
structure Pay where
  amount : Nat
  currency : String := "USD"
  deriving Repr, BEq

def p : Pay := { amount := 10 }
#eval p
#eval p.amount
#eval { p with amount := 12 }
#eval p == { amount := 10, currency := "USD" }
--@end

--@scene inductive
-- a type with a fixed set of cases, each carrying its own data
inductive Pointer where
  | protocol (name : String)
  | formula (name : String) (sexpr : String)
  | sorry_ (note : String)
  deriving Repr

-- one equation per case; Lean refuses a match that forgets one
def Pointer.describe : Pointer → String
  | .protocol n => s!"the faithful rules of {n}"
  | .formula n φ => s!"{φ}, decided over {n}"
  | .sorry_ note => s!"nothing yet: {note}"

#eval (Pointer.formula "Orders" "(AF (after Receipt))").describe
#eval [Pointer.protocol "Orders", .sorry_ "no Refund"].map (·.describe)
--@end

--@scene option
-- no null: a value that may be missing has type Option
def prices : List (String × Nat) := [("tea", 3), ("cake", 5)]

def priceOf (item : String) : Option Nat :=
  (prices.find? (·.1 == item)).map (·.2)

#eval priceOf "tea"
#eval priceOf "soup"
#eval (priceOf "soup").getD 0

def describePrice (item : String) : String :=
  match priceOf item with
  | some n => s!"{item} costs {n}"
  | none => s!"no {item} here"
#eval describePrice "soup"
--@end

--@scene except
-- no exceptions in pure code: a result or an error, in the type
def parseQty (s : String) : Except String Nat :=
  match s.toNat? with
  | some 0 => throw "a quantity is positive"
  | some n => pure n
  | none => throw s!"{s} is not a number"

-- `←` unwraps a result; the first error stops the whole block
def order (item qty : String) : Except String Nat := do
  let n ← parseQty qty
  let price ← match priceOf item with
    | some x => pure x
    | none => throw s!"no {item} here"
  return n * price

#eval order "tea" "2"
#eval order "tea" "two"
#eval order "soup" "2"
--@end

--@scene collections
def amounts : List Nat := [3, 5, 12, 7]
#eval amounts.map (· * 2)
#eval amounts.filter (· > 4)
#eval amounts.foldl (· + ·) 0
-- `|>` passes the value on, left to right
#eval amounts |>.filter (· > 4) |>.map (· * 2)

-- an Array grows at the end; `[i]?` may miss, `[i]!` may not
def arr : Array Nat := #[3, 5]
#eval arr.push 12
#eval arr[0]!
#eval arr[7]?
--@end

--@scene loops
-- looks imperative, is pure: `let mut` names a new value each step
def total (xs : List Nat) : Nat := Id.run do
  let mut sum := 0
  for x in xs do
    if x > 10 then continue
    sum := sum + x
  return sum
#eval total [3, 5, 12, 7]
--@end

--@scene strings
#eval "Client,Shop,Bank".splitOn ","
#eval " -> ".intercalate ["Client", "Shop", "Bank"]
#eval s!"{2 + 3} items"
#eval "Receipt".startsWith "Rec"

-- include_str reads a file when this file compiles
def ordersText : String :=
  include_str "../../examples/orders/Requirements.leanfm"
#eval (ordersText.splitOn "\n").find? (·.startsWith "protocol")
--@end

--@scene io
-- effects show in the type: IO Unit may read files and print
def main : IO Unit := do
  let text ← IO.FS.readFile "examples/orders/Requirements.leanfm"
  let lines := text.splitOn "\n"
  IO.println s!"{lines.length} lines; the requirements:"
  for line in lines.filter (·.startsWith "  \"") do
    IO.println line.trimAscii
#eval main
--@end

--@scene names
namespace Shop
def tax (n : Nat) : Nat := n / 10
end Shop
#eval Shop.tax 50
open Shop in
#eval tax 50

-- a function in Pay's namespace is called with a dot on any Pay
def Pay.total (q : Pay) : Nat := q.amount + Shop.tax q.amount
#eval p.total

-- «» makes a keyword usable as a name: messages have from and to
structure Envelope where
  «from» : String
  to : String
  deriving Repr
#eval ({ «from» := "Client", to := "Shop" } : Envelope).«from»
--@end

--@scene classes
inductive Role | client | shop | bank
  deriving Repr, BEq

-- an instance teaches a type a shared interface: here, ToString
instance : ToString Role where
  toString
    | .client => "Client" | .shop => "Shop" | .bank => "Bank"
#eval s!"{Role.shop} answers {Role.client}"

-- deriving writes instances for you: JSON both ways
structure Quote where
  price : Nat
  deriving Lean.ToJson, Lean.FromJson, Repr
#eval Lean.toJson ({ price := 10 } : Quote)
def parsed : Except String Quote :=
  Lean.Json.parse "{\"price\": 12}" >>= Lean.fromJson?
#eval parsed
--@end

--@scene partial
-- Lean must see that recursion ends: here n shrinks every call
def countdown : Nat → List Nat
  | 0 => [0]
  | n + 1 => (n + 1) :: countdown n
#eval countdown 3

-- when it cannot see that, `partial` runs it anyway,
-- and nothing can be proved about it
partial def collatz (n : Nat) (steps : Nat := 0) : Nat :=
  if n ≤ 1 then steps
  else
    let next := if n % 2 == 0 then n / 2
                else 3 * n + 1
    collatz next (steps + 1)
#eval collatz 27
--@end

--@scene guard
-- a test that runs while the file compiles;
-- a false one is a compile error
#guard double 21 == 42
#guard priceOf "cake" == some 5
#guard (order "tea" "two").toOption == none
#guard total [3, 5, 12, 7] == 15
--@end

--@scene proofs
-- true by computing
example : double 21 = 42 := rfl
example : [3, 5, 12, 7].length = 4 := by decide

-- true for every a and b: a tactic does the algebra
theorem double_add (a b : Nat) :
    double (a + b) = double a + double b := by
  unfold double; omega
--@end

--@scene carry
-- a field can be a proof: no Price exists unless it holds
structure Price where
  private mk ::
  cents : Nat
  positive : 0 < cents

-- the only way to make one outside this file: check first
def Price.make (n : Nat) : Except String Price :=
  if h : 0 < n then .ok ⟨n, h⟩ else .error "a price is positive"

def show? : Except String Price → String
  | .ok q => s!"{q.cents} cents"
  | .error e => e
#eval show? (Price.make 250)
#eval show? (Price.make 0)

-- and every Price ever made obeys it, with no runtime check
theorem Price.never_zero (q : Price) : q.cents ≠ 0 := by
  have := q.positive; omega
--@end

--@scene sorry
-- a hole: Lean accepts the file, and warns
theorem refunds_within_30_days : 1 + 1 = 2 := sorry
--@end

--@scene syntax
-- Lean's grammar is extensible: a new term, and what it means
syntax "twice! " term : term
macro_rules
  | `(twice! $x) => `($x + $x)
#eval twice! 21
--@end

end Tour
