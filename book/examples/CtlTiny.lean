/-! CTL in a page of Lean (the book's Chapter 4): the quantifier is the reducer, `and` for ∀ and
`or` for ∃, over the finite list of next states; one recursive `until` under either reducer; and
every other word defined from it. Plain Lean, no LeanFM: `lean book/examples/CtlTiny.lean`, which
`make check` runs, so every `#guard` below stays true. The book prints the part between the markers.

The example is a tiny tree of futures:

    s0 (a) ---> s1 (a)            then stops: no b ever
      \-------> s2 (not a) ---> s3 (b)

A state that stops repeats itself forever, so every path goes on. -/

def States : List String := ["s0", "s1", "s2", "s3"]

def next : String → List String
  | "s0" => ["s1", "s2"]
  | "s1" => ["s1"]
  | "s2" => ["s3"]
  | _    => ["s3"]

-- @book begin
/-- A formula, read at a state. -/
abbrev Pred := String → Bool

/-- Over a finite list, ∀ is `and` of the mapped list, and ∃ is `or`. -/
abbrev Reduce := List Bool → Bool
def andR : Reduce := fun bs => bs.all id      -- ∀
def orR  : Reduce := fun bs => bs.any id      -- ∃

/-- R next p: p mapped over the next states, then reduced. -/
def nextR (R : Reduce) (p : Pred) : Pred := fun s => R ((next s).map p)

/-- until(R, a, b): b here, or a here and the same claim reduced over the next states. Coming
back to a state already on the path means b was never reached on that future: false. -/
partial def untilR (R : Reduce) (a b : Pred) (s : String) (path : List String := []) : Bool :=
  b s || (a s && !path.contains s && R ((next s).map (untilR R a b · (s :: path))))

def tt : Pred := fun _ => true
def neg (p : Pred) : Pred := fun s => !p s

def allNext   : Pred → Pred := nextR andR
def someNext  : Pred → Pred := nextR orR
def allUntil  (a b : Pred) : Pred := untilR andR a b
def someUntil (a b : Pred) : Pred := untilR orR a b

def possibly   (p : Pred) : Pred := someUntil tt p
def inevitably (p : Pred) : Pred := allUntil tt p
def always     (p : Pred) : Pred := neg (possibly (neg p))
def someAlways (p : Pred) : Pred := neg (inevitably (neg p))

/-- a until b, or a forever: on no path (or not on every path) does a fail before b has come. -/
def allUnless  (a b : Pred) : Pred := neg (someUntil (neg b) (fun s => !a s && !b s))
def someUnless (a b : Pred) : Pred := neg (allUntil (neg b) (fun s => !a s && !b s))

/-- map/reduce over a list of claims: and (map f xs), or (map f xs). -/
def allOf (f : α → Pred) (xs : List α) : Pred := fun s => andR (xs.map (f · s))
def anyOf (f : α → Pred) (xs : List α) : Pred := fun s => orR (xs.map (f · s))
-- @book end

def a : Pred := fun s => s == "s0" || s == "s1"
def b : Pred := fun s => s == "s3"
def holdsAt (p : Pred) : List String := States.filter p

-- only s3 has "a until b": from s0 no single future keeps a until b arrives
#guard holdsAt (someUntil a b) == ["s3"]
#guard holdsAt (allUntil a b) == ["s3"]
#guard possibly b "s0" && !inevitably b "s0"
#guard always a "s1" && someAlways a "s0" && !always a "s0"
#guard someNext b "s2" && !allNext a "s0" && someNext a "s0"
-- unless: from s0, the future through s1 keeps a forever, the one through s2 loses a before b
#guard someUnless a b "s0" && !allUnless a b "s0"
#guard allUnless a b "s1" && allUnless a b "s3" && !someUnless a b "s2"
-- map/reduce: every one of s1, s3 is reachable from s0; s1 is not reachable from s2
#guard allOf (fun t => possibly (· == t)) ["s1", "s3"] "s0"
#guard !allOf (fun t => possibly (· == t)) ["s1", "s3"] "s2" && anyOf (fun t => possibly (· == t)) ["s1", "s3"] "s2"
