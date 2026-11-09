/-!
# A philosophy calculator: what exists among the numbers

Positions on the existence of large numbers (Zeilberger's largest number, Hamkins's potentialism,
actualism) disagree about which sentences are true. This module makes the disagreement concrete:
it evaluates a ladder of sentences on finite worlds and on growth frames, proves which
combinations no finite world can satisfy, and classifies a set of answers.

## Requirements

Positive (always):

* every ladder sentence is evaluated by computation on every catalogued finite world, so each
  verdict can be rerun, and on the standard model ℕ by a Lean theorem;
* the three ways a finite successor can behave at its top (undefined, wrap to zero, stay put) each
  give up exactly one of the Peano properties *total*, *zero is no successor*, *injective*;
* no finite world has all three of those properties (`no_finite_dedekind`, proved for every size);
* on every catalogued frame, the convergence and connectedness conditions agree with the
  validity of the .2 and .3 axioms, checked over every valuation;
* the calculator names every world and frame that fits a set of answers, and when none does it
  reports a smallest set of answers that no world in the catalogue or ℕ satisfies.

Negative (never):

* a closed-form shortcut that disagrees with iterating the successor;
* a verdict for an infinite world produced by enumerating it (ℕ's verdicts are theorems);
* a conflict reported as impossible outright when it is only absent from the catalogue: the
  report says which, and only theorem-backed conflicts are called impossible.
-/

namespace LeanFM.Philosophy

/-! ## Finite worlds -/

/-- What the successor of the largest element is. -/
inductive Top where
  /-- there is none: the successor is partial (Zeilberger's largest number) -/
  | undefined
  /-- it wraps to zero, as two's-complement counters do; order is only local -/
  | wrap
  /-- it is the top again, as a saturating counter is -/
  | saturate
  deriving DecidableEq, Repr

def Top.name : Top → String
  | .undefined => "undefined top" | .wrap => "wraparound" | .saturate => "saturating"

/-- The numbers 0, ..., size - 1 with a successor and an order. -/
structure World where
  size : Nat
  top  : Top
  deriving DecidableEq, Repr

namespace World

def elems (w : World) : List Nat := List.range w.size

def succ (w : World) (n : Nat) : Option Nat :=
  if n + 1 < w.size then some (n + 1)
  else match w.top with
    | .undefined => none
    | .wrap => some 0
    | .saturate => some n

/-- Order. A wraparound world compares within half the circle, as `time_after` does for jiffies:
`a < b` when b is ahead of a by more than 0 and less than half the size. -/
def lt (w : World) (a b : Nat) : Bool :=
  match w.top with
  | .wrap => let d := (b + w.size - a) % w.size; 0 < d && 2 * d < w.size
  | _ => a < b

/-- The successor applied k times to 0, by iteration. -/
def iterate (w : World) : Nat → Option Nat
  | 0 => some 0
  | k + 1 => (w.iterate k).bind w.succ

/-- The same, in closed form, so 2^n steps cost nothing. Tests check it agrees with `iterate`. -/
def reach (w : World) (k : Nat) : Option Nat :=
  if k < w.size then some k
  else match w.top with
    | .undefined => none
    | .wrap => some (k % w.size)
    | .saturate => some (w.size - 1)

def name (w : World) : String := s!"{w.top.name}, {w.size} numbers"

end World

/-! ## The ladder -/

/-- What a sentence says about ℕ, stated as a Lean proposition and proved below. -/
structure Sentence where
  id    : String
  text  : String
  gloss : String
  eval  : World → Bool
  /-- its truth value in the standard model ℕ, backed by a theorem in this file -/
  inNat : Bool

open World in
def ladder : List Sentence :=
  [ { id := "succ-total", text := "∀n ∃m. m = n+1", gloss := "every number has a successor"
      eval := fun w => w.elems.all fun n => (w.succ n).isSome, inNat := true }
  , { id := "succ-injective", text := "∀a b. a+1 = b+1 → a = b"
      gloss := "different numbers have different successors"
      eval := fun w => w.elems.all fun a => w.elems.all fun b =>
        a == b || w.succ a != w.succ b || (w.succ a).isNone
      inNat := true }
  , { id := "zero-first", text := "∀n. n+1 ≠ 0", gloss := "zero is no number's successor"
      eval := fun w => w.elems.all fun n => w.succ n != some 0, inNat := true }
  , { id := "succ-above", text := "∀n m. m = n+1 → n < m", gloss := "a successor is larger"
      eval := fun w => w.elems.all fun n => match w.succ n with
        | some m => w.lt n m | none => true
      inNat := true }
  , { id := "order-transitive", text := "∀a b c. a < b ∧ b < c → a < c", gloss := "order is transitive"
      eval := fun w => w.elems.all fun a => w.elems.all fun b => w.elems.all fun c =>
        !(w.lt a b && w.lt b c) || w.lt a c
      inNat := true }
  , { id := "largest", text := "∃N ∀n. ¬ N < n", gloss := "there is a largest number"
      eval := fun w => w.elems.any fun m => w.elems.all fun n => !w.lt m n, inNat := false }
  , { id := "exp-total", text := "∀n ∃m. m = 2ⁿ", gloss := "every power of two exists"
      eval := fun w => w.elems.all fun n => (w.reach (2 ^ n)).isSome, inNat := true }
  ]

def sentence? (id : String) : Option Sentence := ladder.find? (·.id == id)

/-! ## ℕ: the verdicts above are theorems, not enumerations -/

theorem nat_succ_total : ∀ n : Nat, ∃ m, m = n + 1 := fun n => ⟨n + 1, rfl⟩
theorem nat_succ_injective : ∀ a b : Nat, a + 1 = b + 1 → a = b := fun _ _ h => by omega
theorem nat_zero_first : ∀ n : Nat, n + 1 ≠ 0 := fun _ => by omega
theorem nat_succ_above : ∀ n : Nat, n < n + 1 := fun _ => by omega
theorem nat_order_transitive : ∀ a b c : Nat, a < b → b < c → a < c := fun _ _ _ h1 h2 => by omega
theorem nat_no_largest : ¬ ∃ N : Nat, ∀ n, ¬ N < n := fun ⟨N, h⟩ => h (N + 1) (by omega)
theorem nat_exp_total : ∀ n : Nat, ∃ m, m = 2 ^ n := fun n => ⟨2 ^ n, rfl⟩

/-! ## No finite world is Dedekind-infinite -/

/-- Pigeonhole: an injective map from {0..n-1} into {0..m-1} needs n ≤ m. -/
theorem pigeonhole : ∀ (n m : Nat) (f : Nat → Nat), (∀ i, i < n → f i < m) →
    (∀ i j, i < n → j < n → f i = f j → i = j) → n ≤ m
  | 0, _, _, _, _ => Nat.zero_le _
  | n + 1, m, f, hmap, hinj => by
    have ht : f n < m := hmap n (by omega)
    have hne : ∀ i, i < n → f i ≠ f n := fun i hi h => by
      have := hinj i n (by omega) (by omega) h; omega
    have ih := pigeonhole n (m - 1) (fun i => if f i < f n then f i else f i - 1)
      (by
        intro i hi
        have h1 := hmap i (by omega); have h2 := hne i hi
        show (if f i < f n then f i else f i - 1) < m - 1
        split <;> omega)
      (by
        intro i j hi hj h
        have h1 := hne i hi; have h2 := hne j hj
        apply hinj i j (by omega) (by omega)
        split at h <;> split at h <;> omega)
    omega

/-- A successor on {0..n-1} that is total, injective and never 0 exists only for n = 0. -/
theorem no_finite_dedekind (n : Nat) (s : Nat → Nat) (total : ∀ i, i < n → s i < n)
    (inj : ∀ i j, i < n → j < n → s i = s j → i = j) (zero_first : ∀ i, i < n → s i ≠ 0) :
    n = 0 := by
  have := pigeonhole n (n - 1) (fun i => s i - 1)
    (fun i hi => by have := total i hi; have := zero_first i hi; omega)
    (fun i j hi hj h => by
      have := zero_first i hi; have := zero_first j hj
      exact inj i j hi hj (by omega))
  omega

/-- In any structure, a largest element, a total successor and "a successor is larger" cannot
all hold: the successor of the largest element would be larger than it. -/
theorem no_largest_with_larger_successor {α : Type} (lt : α → α → Prop) (succ : α → α)
    (above : ∀ n, lt n (succ n)) : ¬ ∃ N, ∀ n, ¬ lt N n :=
  fun ⟨N, h⟩ => h (succ N) (above N)

/-- In a finite world, every power of two existing forces the successor to be total: 2^(size-1)
lies past the top, so reaching it needs a successor at the top. -/
theorem exp_total_needs_successor (w : World) (hpos : 0 < w.size)
    (hexp : (w.reach (2 ^ (w.size - 1))).isSome) : ∀ n, n < w.size → (w.succ n).isSome := by
  have hbig : w.size ≤ 2 ^ (w.size - 1) := by
    have := Nat.lt_two_pow_self (n := w.size - 1); omega
  intro n hn
  unfold World.reach at hexp
  unfold World.succ
  split
  · rfl
  · cases ht : w.top <;> simp_all <;> omega

/-- The theorem-backed impossibilities the calculator may cite, by the sentences they forbid
holding together. -/
def impossible : List (List String × String) :=
  [ (["succ-total", "succ-injective", "zero-first"],
      "no finite world has these three (no_finite_dedekind); only an infinite one does")
  , (["largest", "succ-total", "succ-above"],
      "no world of any size has these three (no_largest_with_larger_successor)") ]

/-- Combinations of accepted and rejected sentences that no finite world of this kind satisfies
and ℕ does not either, with the theorem. -/
def impossibleMixed : List (List (String × Bool) × String) :=
  [ ([("exp-total", true), ("succ-total", false)],
      "every power of two existing forces a total successor in a finite world (exp_total_needs_successor), and ℕ's successor is total") ]

/-! ## Growth frames -/

/-- Stages of construction. World 0 is the start; `edges` are immediate extensions; `dom w` is the
numbers available at stage w. -/
structure Frame where
  name   : String
  worlds : Nat
  edges  : List (Nat × Nat)
  dom    : Nat → List Nat

namespace Frame

def ws (f : Frame) : List Nat := List.range f.worlds

/-- Reflexive, transitive reachability. -/
def reach (f : Frame) (u v : Nat) : Bool :=
  let step (s : List Nat) := (s ++ (f.edges.filter (fun e => s.contains e.1)).map (·.2)).eraseDups
  let rec go : Nat → List Nat → List Nat
    | 0, s => s
    | k + 1, s => go k (step s)
  (go f.worlds [u]).contains v

def box (f : Frame) (p : Nat → Bool) (w : Nat) : Bool := f.ws.all fun v => !f.reach w v || p v
def dia (f : Frame) (p : Nat → Bool) (w : Nat) : Bool := f.ws.any fun v => f.reach w v && p v

/-- Any two extensions of a stage have a common extension. -/
def convergent (f : Frame) : Bool :=
  f.ws.all fun w => f.ws.all fun u => f.ws.all fun v =>
    !(f.reach w u && f.reach w v) || f.ws.any fun z => f.reach u z && f.reach v z

/-- Any two extensions of a stage are comparable. -/
def connected (f : Frame) : Bool :=
  f.ws.all fun w => f.ws.all fun u => f.ws.all fun v =>
    !(f.reach w u && f.reach w v) || f.reach u v || f.reach v u

/-- Domains only grow along extensions. -/
def growing (f : Frame) : Bool :=
  f.ws.all fun w => f.ws.all fun v => !f.reach w v || (f.dom w).all (f.dom v).contains

/-- Some stage can still grow. -/
def grows (f : Frame) : Bool :=
  f.ws.any fun w => f.ws.any fun v => f.reach w v && (f.dom v).any (!(f.dom w).contains ·)

def valuations (n : Nat) : List (Nat → Bool) :=
  (List.range (2 ^ n)).map fun bits => fun w => (bits >>> w) % 2 == 1

/-- ◇□p → □◇p at every stage, for every valuation of p. -/
def axiom2 (f : Frame) : Bool :=
  (valuations f.worlds).all fun p => f.ws.all fun w =>
    !(f.dia (f.box p) w) || f.box (f.dia p) w

/-- □(□p → q) ∨ □(□q → p) at every stage, for every valuation of p and q. -/
def axiom3 (f : Frame) : Bool :=
  (valuations f.worlds).all fun p => (valuations f.worlds).all fun q => f.ws.all fun w =>
    f.box (fun v => !(f.box p v) || q v) w || f.box (fun v => !(f.box q v) || p v) w

/-- The Barcan formula ◇∃x φ(x) → ∃x ◇φ(x) at every stage, for every rigid predicate φ on the
numbers that ever appear. It fails when a later stage has a number no current one becomes. -/
def barcan (f : Frame) : Bool :=
  let all := (f.ws.flatMap f.dom).eraseDups
  (valuations all.length).all fun bits =>
    let φ := fun x => match all.idxOf? x with | some i => bits i | none => false
    f.ws.all fun w =>
      !(f.dia (fun v => (f.dom v).any φ) w) || (f.dom w).any fun x => f.dia (fun _ => φ x) w

/-- Stages at which every available number can be exceeded later: □∀x ◇∃y. y > x. -/
def unbounded (f : Frame) (w : Nat) : Bool :=
  (f.dom w).all fun x => f.dia (fun v => (f.dom v).any (· > x)) w

end Frame

def linear (k : Nat) : Frame :=
  { name := s!"linear, {k + 1} stages", worlds := k + 1
    edges := (List.range k).map fun i => (i, i + 1), dom := fun i => List.range (i + 1) }

def convergent : Frame :=
  { name := "convergent (two extensions meet)", worlds := 4
    edges := [(0, 1), (0, 2), (1, 3), (2, 3)]
    dom := fun | 0 => [0] | 1 => [0, 1] | 2 => [0, 2] | _ => [0, 1, 2, 3] }

def branching : Frame :=
  { name := "branching (two extensions never meet)", worlds := 3
    edges := [(0, 1), (0, 2)]
    dom := fun | 0 => [0] | 1 => [0, 1] | _ => [0, 2] }

def single (k : Nat) : Frame :=
  { name := s!"one completed stage of {k} numbers", worlds := 1, edges := [], dom := fun _ => List.range k }

def frames : List Frame := [linear 4, convergent, branching, single 5]

/-- Answers about frames, by name. Each is checked on the frame itself. -/
def modalProps : List (String × String × (Frame → Bool)) :=
  [ ("grows", "some stage has a later stage with new numbers", Frame.grows)
  , ("convergent", "◇□p → □◇p (.2): extensions always meet again", Frame.axiom2)
  , ("connected", "□(□p → q) ∨ □(□q → p) (.3): extensions form a line", Frame.axiom3)
  , ("barcan", "◇∃x φ(x) → ∃x ◇φ(x): whatever may exist already exists", Frame.barcan) ]

def modal? (id : String) : Option (Frame → Bool) := (modalProps.find? (·.1 == id)).map (·.2.2)

/-! ## Positions -/

structure Position where
  name    : String
  holder  : String
  /-- the sentences the position accepts (true) and rejects (false) -/
  answers : List (String × Bool)
  /-- the kind of world or frame it lives in -/
  setting : String

def positions : List Position :=
  [ { name := "Largest number, successor undefined", holder := "Zeilberger"
      answers := [("succ-total", false), ("largest", true), ("exp-total", false), ("zero-first", true),
                 ("grows", false), ("barcan", true)]
      setting := "one finite world with an undefined top: a completed finite totality, so the Barcan formula holds" }
  , { name := "Wraparound finitism", holder := "two's-complement arithmetic; jiffies"
      answers := [("succ-total", true), ("zero-first", false), ("order-transitive", false), ("largest", false),
                 ("grows", false)]
      setting := "one finite world that wraps; order is local, within half the circle" }
  , { name := "Linear potentialism", holder := "Hamkins and Linnebo: S4.3"
      answers := [("succ-total", true), ("succ-injective", true), ("zero-first", true), ("largest", false),
                  ("grows", true), ("connected", true), ("barcan", false)]
      setting := "stages in a line; no finite stage satisfies the Peano sentences, the open-ended sequence does; .3 holds, Barcan fails" }
  , { name := "Convergent potentialism", holder := "Hamkins and Linnebo: S4.2"
      answers := [("succ-total", true), ("succ-injective", true), ("zero-first", true), ("largest", false),
                  ("grows", true), ("convergent", true), ("connected", false), ("barcan", false)]
      setting := "branching stages that always meet again; .2 holds, .3 and Barcan fail" }
  , { name := "Actualism", holder := "classical set theory"
      answers := [("succ-total", true), ("succ-injective", true), ("zero-first", true), ("largest", false),
                  ("grows", false), ("barcan", true)]
      setting := "one completed infinite world, ℕ; the Barcan formula holds" } ]

/-! ## The calculator -/

def worlds (maxSize : Nat := 12) : List World :=
  ((List.range (maxSize + 1)).filter (· ≥ 3)).flatMap fun n =>
    [Top.undefined, .wrap, .saturate].map fun t => { size := n, top := t }

/-- The answers about the ladder, and the answers about frames. Unknown ids are reported. -/
def firstOrder (answers : List (String × Bool)) := answers.filter fun a => (sentence? a.1).isSome
def modalAnswers (answers : List (String × Bool)) := answers.filter fun a => (modal? a.1).isSome
def unknownIds (answers : List (String × Bool)) : List String :=
  (answers.filter fun a => (sentence? a.1).isNone && (modal? a.1).isNone).map (·.1)

def World.fits (w : World) (answers : List (String × Bool)) : Bool :=
  (firstOrder answers).all fun (id, v) => match sentence? id with | some s => s.eval w == v | none => false

def natFits (answers : List (String × Bool)) : Bool :=
  (firstOrder answers).all fun (id, v) => match sentence? id with | some s => s.inNat == v | none => false

def Frame.fits (f : Frame) (answers : List (String × Bool)) : Bool :=
  (modalAnswers answers).all fun (id, v) => match modal? id with | some p => p f == v | none => false

/-- Every sublist of a list, shortest first. -/
def sublists : List α → List (List α)
  | [] => [[]]
  | x :: xs => let r := sublists xs; r ++ r.map (x :: ·)

structure Report where
  finiteWorlds : List String
  nat          : Bool
  frames       : List String
  unknown      : List String
  /-- a smallest set of answers that nothing in the catalogue or ℕ satisfies, with the theorem
  that makes it impossible everywhere, if there is one -/
  conflict     : Option (List (String × Bool) × Option String)
  /-- the theorem-backed infinitude, when the answers need an infinite world -/
  infinite     : Option String
  deriving Repr

def classify (answers : List (String × Bool)) (maxSize : Nat := 12) : Report :=
  let fo := firstOrder answers
  let fit := (worlds maxSize).filter (·.fits fo)
  let nat := natFits fo
  let accepted := (fo.filter (·.2)).map (·.1)
  let why (c : List (String × Bool)) : Option String :=
    let acc := (c.filter (·.2)).map (·.1)
    match (impossible.find? fun (ids, _) => ids.all acc.contains) with
    | some (_, t) => some t
    | none => (impossibleMixed.find? fun (req, _) => req.all c.contains).map (·.2)
  let conflict :=
    if !fit.isEmpty || nat then none
    else
      let subs := ((sublists fo).filter fun c =>
        !c.isEmpty && !natFits c && (worlds maxSize).all (!·.fits c)).mergeSort
          (fun a b => a.length ≤ b.length)
      subs.head?.map fun c => (c, why c)
  let infinite :=
    if fit.isEmpty && nat && ["succ-total", "succ-injective", "zero-first"].all accepted.contains
    then some "only an infinite domain satisfies these answers (no_finite_dedekind)" else none
  { finiteWorlds := fit.map World.name, nat, conflict, infinite
    frames := ((frames.filter (·.fits answers)).map (·.name))
    unknown := unknownIds answers }

def Report.text (r : Report) : String :=
  let worldsLine := if r.finiteWorlds.isEmpty then "no finite world in the catalogue"
    else s!"{r.finiteWorlds.length} finite worlds, e.g. {", ".intercalate (r.finiteWorlds.take 3)}"
  let natLine := if r.nat then "ℕ satisfies them" else "ℕ does not"
  let conflictLine := match r.conflict with
    | none => ""
    | some (c, why) =>
      let cs := ", ".intercalate (c.map fun (p : String × Bool) => (if p.2 then "" else "not ") ++ p.1)
      match why with
      | some t => s!"\nconflict: {cs}: impossible: {t}"
      | none => s!"\nconflict: {cs}: no world in the catalogue or ℕ satisfies these (not proved impossible)"
  let infLine := match r.infinite with | some t => s!"\n{t}" | none => ""
  let frameLine := if r.frames.isEmpty then "\nno frame in the catalogue fits the answers about stages"
    else s!"\nframes: {"; ".intercalate r.frames}"
  let unknownLine := if r.unknown.isEmpty then "" else s!"\nunknown sentences: {", ".intercalate r.unknown}"
  s!"{worldsLine}; {natLine}{conflictLine}{infLine}{frameLine}{unknownLine}"

/-! ## Tables -/

def mark (b : Bool) : String := if b then "yes" else "no"

/-- The ladder against one world of each top policy and ℕ. -/
def ladderTable (size : Nat := 8) : String :=
  let ws : List World := [Top.undefined, .wrap, .saturate].map fun t => { size, top := t }
  let header := s!"| sentence | {" | ".intercalate (ws.map (·.top.name))} | ℕ |"
  let sep := "|---|" ++ String.join (ws.map fun _ => "---|") ++ "---|"
  let rows := ladder.map fun s =>
    s!"| {s.gloss} | {" | ".intercalate (ws.map fun w => mark (s.eval w))} | {mark s.inNat} |"
  "\n".intercalate (header :: sep :: rows)

def frameTable : String :=
  let header := "| frame | grows | convergent (.2) | connected (.3) | Barcan | every number exceedable | modal logic |"
  let sep := "|---|---|---|---|---|---|---|"
  let rows := frames.map fun f =>
    let logic := if !f.grows then "Triv (no growth: actualist)"
      else if f.connected then "S4.3 (linear potentialism)"
      else if f.convergent then "S4.2 (convergent potentialism)" else "S4 (branching potentialism)"
    let ex := (f.ws.filter f.unbounded).length
    s!"| {f.name} | {mark f.grows} | {mark f.axiom2} | {mark f.axiom3} | {mark f.barcan} | {ex} of {f.worlds} stages | {logic} |"
  "\n".intercalate (header :: sep :: rows)

end LeanFM.Philosophy
