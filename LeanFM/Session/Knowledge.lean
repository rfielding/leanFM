/-!
# Knowledge: what an actor can derive from what it has seen

Symbolic (Dolev–Yao) messages. An actor that has seen some messages can take pairs apart and open
anything encrypted under a key it can build, and it can build new messages by pairing, encrypting
and hashing. It cannot guess: an atom it has not seen, or a private key nobody leaked, stays unknown,
and a hash hides its input.

`Derives K m` is that ability as a rule set (a Prop). `knows K m` decides it for one message: break
`K` apart to a finite set (`analz`), then ask whether `m` can be built from the pieces (`synth`).
Enumerating everything an actor could build would be infinite; breaking down and then checking one
value is finite. `knows_sound` proves that `knows` never claims more than `Derives` allows.

Knowledge is indexed at a state. An actor's knowledge at an event is what it had seen by then; in a
model it is part of the state, updated by `learn` when a message reaches the actor, so `knows` is an
ordinary label of that state and CTL can quantify over it.
-/

namespace LeanFM.Session.Knowledge

inductive Msg where
  /-- names, nonces, data -/
  | atom (name : String)
  /-- a symmetric key -/
  | key (name : String)
  /-- an actor's public key -/
  | pk (agent : String)
  /-- an actor's private key -/
  | sk (agent : String)
  | pair (a b : Msg)
  /-- `enc k b`: `b` encrypted under `k`; under a private key it is a signature -/
  | enc (key body : Msg)
  | hash (body : Msg)
  deriving DecidableEq, Repr, Inhabited

/-- The key that opens `enc k _`: a public key's private key, a private key's public key (anyone
can read a signature), otherwise the key itself. -/
def Msg.inverse : Msg → Msg
  | .pk a => .sk a
  | .sk a => .pk a
  | k => k

/-- How the security literature writes it: `{na, A}pk(B)`. -/
def Msg.render : Msg → String
  | .atom n | .key n => n
  | .pk a => s!"pk({a})"
  | .sk a => s!"sk({a})"
  | .pair a b => a.render ++ ", " ++ b.render
  | .enc k b => "{" ++ b.render ++ "}" ++ k.render
  | .hash b => "h(" ++ b.render ++ ")"

instance : ToString Msg := ⟨Msg.render⟩

def Msg.size : Msg → Nat
  | .pair a b => 1 + a.size + b.size
  | .enc k b => 1 + k.size + b.size
  | .hash b => 1 + b.size
  | _ => 1

/-- What can be derived from `K`: the rules themselves. -/
inductive Derives (K : List Msg) : Msg → Prop where
  | initial {m} : m ∈ K → Derives K m
  | pair {a b} : Derives K a → Derives K b → Derives K (.pair a b)
  | fst {a b} : Derives K (.pair a b) → Derives K a
  | snd {a b} : Derives K (.pair a b) → Derives K b
  | enc {k b} : Derives K k → Derives K b → Derives K (.enc k b)
  | dec {k b} : Derives K (.enc k b) → Derives K k.inverse → Derives K b
  | hash {b} : Derives K b → Derives K (.hash b)
  -- no rule recovers `b` from `.hash b`, and none produces an atom or key that is not in `K`

/-- Seeing more never makes anything underivable. -/
theorem Derives.mono {K K' : List Msg} (sub : ∀ m, m ∈ K → m ∈ K') {v : Msg} (h : Derives K v) :
    Derives K' v := by
  induction h with
  | initial hm => exact .initial (sub _ hm)
  | pair _ _ iha ihb => exact .pair iha ihb
  | fst _ ih => exact .fst ih
  | snd _ ih => exact .snd ih
  | enc _ _ ihk ihb => exact .enc ihk ihb
  | dec _ _ ihe ihk => exact .dec ihe ihk
  | hash _ ih => exact .hash ih

/-- Can `v` be built from the pieces in `S`? -/
def synth (S : List Msg) : Msg → Bool
  | .pair a b => S.contains (.pair a b) || (synth S a && synth S b)
  | .enc k b => S.contains (.enc k b) || (synth S k && synth S b)
  | .hash b => S.contains (.hash b) || synth S b
  | m => S.contains m

/-- What one message gives up: both halves of a pair; the body of a ciphertext whose opening key
can be built. -/
def parts (S : List Msg) : Msg → List Msg
  | .pair a b => [a, b]
  | .enc k b => if synth S k.inverse then [b] else []
  | _ => []

/-- Append what is not there yet. -/
def addNew (S : List Msg) (xs : List Msg) : List Msg :=
  xs.foldl (fun acc x => if acc.contains x then acc else acc ++ [x]) S

/-- One round of taking things apart. -/
def step (S : List Msg) : List Msg := addNew S (S.flatMap (parts S))

def analzN : Nat → List Msg → List Msg
  | 0, S => S
  | n + 1, S =>
    let S' := step S
    if S'.length == S.length then S else analzN n S'

/-- Break `K` apart until nothing new appears. Every new piece is a part of something in `K`, so
the total size of `K` is always enough rounds. -/
def analz (K : List Msg) : List Msg :=
  analzN (K.foldl (fun n m => n + m.size) 0 + 1) (addNew [] K)

/-- Can an actor that has seen `K` derive `v`? -/
def knows (K : List Msg) (v : Msg) : Bool := synth (analz K) v

/-- An actor's knowledge after one more message reaches it, kept broken apart. -/
def learn (K : List Msg) (m : Msg) : List Msg := analz (K ++ [m])

/-! ## Soundness: `knows` claims nothing that `Derives` does not allow -/

theorem synth_sound {K S : List Msg} (hS : ∀ m, m ∈ S → Derives K m) :
    ∀ v, synth S v = true → Derives K v := by
  intro v
  induction v with
  | pair a b iha ihb =>
    intro h
    simp only [synth, Bool.or_eq_true, Bool.and_eq_true, List.contains_iff_mem] at h
    rcases h with h | ⟨ha, hb⟩
    · exact hS _ h
    · exact .pair (iha ha) (ihb hb)
  | enc k b ihk ihb =>
    intro h
    simp only [synth, Bool.or_eq_true, Bool.and_eq_true, List.contains_iff_mem] at h
    rcases h with h | ⟨hk, hb⟩
    · exact hS _ h
    · exact .enc (ihk hk) (ihb hb)
  | hash b ih =>
    intro h
    simp only [synth, Bool.or_eq_true, List.contains_iff_mem] at h
    rcases h with h | h
    · exact hS _ h
    · exact .hash (ih h)
  | atom n => intro h; simp only [synth, List.contains_iff_mem] at h; exact hS _ h
  | key n => intro h; simp only [synth, List.contains_iff_mem] at h; exact hS _ h
  | pk a => intro h; simp only [synth, List.contains_iff_mem] at h; exact hS _ h
  | sk a => intro h; simp only [synth, List.contains_iff_mem] at h; exact hS _ h

theorem parts_sound {K S : List Msg} (hS : ∀ m, m ∈ S → Derives K m) {m : Msg} (hm : m ∈ S) :
    ∀ x, x ∈ parts S m → Derives K x := by
  intro x hx
  have dm := hS _ hm
  cases m with
  | pair a b =>
    simp only [parts, List.mem_cons, List.mem_nil_iff, or_false] at hx
    rcases hx with rfl | rfl
    · exact .fst dm
    · exact .snd dm
  | enc k b =>
    simp only [parts] at hx
    split at hx
    · next hk =>
      simp only [List.mem_cons, List.mem_nil_iff, or_false] at hx
      subst hx
      exact .dec dm (synth_sound hS _ hk)
    · simp at hx
  | _ => simp [parts] at hx

theorem addNew_mem {S xs : List Msg} : ∀ x, x ∈ addNew S xs → x ∈ S ∨ x ∈ xs := by
  induction xs generalizing S with
  | nil => intro x hx; exact .inl hx
  | cons y ys ih =>
    intro x hx
    simp only [addNew, List.foldl_cons] at hx
    rcases ih (S := if S.contains y then S else S ++ [y]) x hx with h | h
    · split at h
      · exact .inl h
      · simp only [List.mem_append, List.mem_cons, List.mem_nil_iff, or_false] at h
        rcases h with h | rfl
        · exact .inl h
        · exact .inr (List.mem_cons_self ..)
    · exact .inr (List.mem_cons_of_mem _ h)

theorem step_sound {K S : List Msg} (hS : ∀ m, m ∈ S → Derives K m) :
    ∀ x, x ∈ step S → Derives K x := by
  intro x hx
  rcases addNew_mem x hx with h | h
  · exact hS _ h
  · simp only [List.mem_flatMap] at h
    obtain ⟨m, hm, hp⟩ := h
    exact parts_sound hS hm x hp

theorem analzN_sound {K : List Msg} :
    ∀ n S, (∀ m, m ∈ S → Derives K m) → ∀ x, x ∈ analzN n S → Derives K x := by
  intro n
  induction n with
  | zero => intro S hS; exact hS
  | succ n ih =>
    intro S hS x hx
    simp only [analzN] at hx
    split at hx
    · exact hS _ hx
    · exact ih _ (step_sound hS) x hx

theorem analz_sound (K : List Msg) : ∀ x, x ∈ analz K → Derives K x := by
  apply analzN_sound
  intro m hm
  rcases addNew_mem m hm with h | h
  · simp at h
  · exact .initial h

/-- Whatever `knows` says an actor can derive, it can. -/
theorem knows_sound {K : List Msg} {v : Msg} (h : knows K v = true) : Derives K v :=
  synth_sound (analz_sound K) v h

/-! ## Examples -/

private def kAB := Msg.key "kAB"
private def sealed := Msg.enc kAB (.pair (.atom "na") (.atom "A"))

-- A ciphertext alone gives nothing away; once its key leaks, the old message opens.
#guard !knows [sealed] (.atom "na")
#guard knows [sealed, kAB] (.atom "na")
#guard knows (learn [sealed] kAB) (.pair (.atom "na") (.atom "na"))
-- A signature hides nothing from someone with the signer's public key.
#guard knows [.pk "B", .enc (.sk "B") (.atom "nb")] (.atom "nb")
-- A public-key ciphertext opens only with the private key.
#guard !knows [.pk "B", .enc (.pk "B") (.atom "nb")] (.atom "nb")
#guard knows [.sk "B", .enc (.pk "B") (.atom "nb")] (.atom "nb")
-- A hash hides its input, but can be recomputed from it.
#guard !knows [.hash (.atom "pw")] (.atom "pw")
#guard knows [.atom "pw"] (.hash (.atom "pw"))
-- Keys can be built: a key that is itself a hash of known parts opens what it sealed.
#guard knows [.atom "s", .enc (.hash (.atom "s")) (.atom "m")] (.atom "m")

end LeanFM.Session.Knowledge
