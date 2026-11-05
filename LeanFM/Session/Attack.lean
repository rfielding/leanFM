import LeanFM.Session.Knowledge
import Lean.Data.Json

/-!
# The attacker as a declaration

A security protocol is declared, not modelled by hand: each honest role is a short script of
choices, sends, receives and claims over message patterns, and the attacker is the network. Every
message an honest role sends goes to the attacker; every message an honest role receives is one
the attacker can build (`Knowledge.knows`) that matches the pattern it expects. That is the
Dolev–Yao channel, declared once for every channel of the protocol.

`Protocol.explore` generates the state space from the declaration: each thread's position and
bindings, the attacker's knowledge (kept broken apart and in one order), the claims made so far,
and the flags already tripped. Flags are requirements as state predicates over that world; a flag
trips once, as an event, when its predicate first holds. `Protocol.draft` writes the generated model
as a `check_ctl` draft, with every transition's term, every claim, and the attacker's knowledge
declared, so a formula may also use `knows` and `claimed` atoms directly; `Protocol.check`, in
`LeanFM.Logic`, asks it.

Sessions: a role may run several sessions at once (`Role.sessions`), each its own thread with its
own bindings, named `Alice`, `Alice#2`, …. A `fresh` step makes a value no other session and nothing
the attacker starts with has: `na` in the first session, `na#2` in the second. Attacks that play one
session of a role against another, such as reflection, need this.

An inline defender (`Inline`) may sit between the network and some roles: every message the
attacker delivers to a protected role passes through it first. It drops what matches a drop
pattern and rewrites what matches a rewrite rule, but it matches only what it can see: it opens a
ciphertext only with a key it can build from its own knowledge, and otherwise compares the whole
blob. That is the defender's version of `knows`: an encrypted payload goes past a filter that does
not hold the key. Without an `Inline`, every channel is the attacker's, as before.

Bounded on purpose: each thread runs once, the number of sessions is declared, a received pattern's
unbound variables range over a declared finite domain (names and nonces; a domain that holds a
fresh value also holds its copies in the other sessions), and a variable binds an atom, never a
whole ciphertext. Those bounds are where attacks on more sessions or on forwarded blobs would be
missed.
-/

namespace LeanFM.Session.Attack
open LeanFM.Session.Knowledge Lean

/-- A message pattern: a message with variables. `pk x` and `sk x` take an agent's name. -/
inductive Pat where
  | lit (m : Msg)
  | var (x : String)
  | pair (a b : Pat)
  | enc (key body : Pat)
  | hash (body : Pat)
  | pk (agent : Pat)
  | sk (agent : Pat)
  deriving Repr, Inhabited

/-- `[a, b, c]` as nested pairs, the way the literature writes tuples. -/
def Pat.tuple : List Pat → Pat
  | [] => .lit (.atom "")
  | [p] => p
  | p :: ps => .pair p (Pat.tuple ps)

abbrev Env := List (String × Msg)

def Pat.vars : Pat → List String
  | .lit _ => []
  | .var x => [x]
  | .pair a b | .enc a b => a.vars ++ b.vars
  | .hash b | .pk b | .sk b => b.vars

/-- The message a pattern stands for under some bindings; `none` while a variable is unbound. -/
def Pat.inst (env : Env) : Pat → Option Msg
  | .lit m => some m
  | .var x => env.lookup x
  | .pair a b => do pure (.pair (← a.inst env) (← b.inst env))
  | .enc k b => do pure (.enc (← k.inst env) (← b.inst env))
  | .hash b => do pure (.hash (← b.inst env))
  | .pk a => do match ← a.inst env with | .atom n => pure (.pk n) | _ => none
  | .sk a => do match ← a.inst env with | .atom n => pure (.sk n) | _ => none

inductive Step where
  /-- bind `x` to one of `values`: the role's own choice, such as whom to talk to -/
  | choose (x : String) (values : List Msg)
  /-- send to the intended recipient; it goes to the network, which is the attacker -/
  | send (to : Pat) (p : Pat)
  /-- receive any message the attacker can build that matches `p`, binding its free variables -/
  | recv (p : Pat)
  /-- a claim the role makes, such as "I have finished a run with X" -/
  | claim (name : String) (args : List Pat)
  /-- bind `x` to a value made new in this session: `x` in the first session, `x#k` in the k-th -/
  | fresh (x : String)
  deriving Repr, Inhabited

structure Role where
  name : String
  steps : List Step
  /-- which session of the declared role this thread runs, from 1 -/
  session : Nat := 1
  deriving Repr, Inhabited

/-- The value `fresh x` makes in session `k`. -/
def freshName (x : String) (k : Nat) : String := if k ≤ 1 then x else s!"{x}#{k}"

/-- `n` sessions of a role, as threads named `Alice`, `Alice#2`, …. -/
def Role.sessions (r : Role) (n : Nat) : List Role :=
  (List.range n).map fun k => { r with name := freshName r.name (k + 1), session := k + 1 }

def Role.freshVars (r : Role) : List String :=
  r.steps.filterMap fun | .fresh x => some x | _ => none

/-- Every fresh value the threads make, with the base name it copies. -/
def freshValues (threads : List Role) : List (String × Msg) :=
  threads.flatMap fun r => r.freshVars.map fun x => (x, .atom (freshName x r.session))

/-- Widen a domain so a value made fresh in one session is also there in the others. -/
def coverFresh (threads : List Role) (domain : List Msg) : List Msg :=
  domain ++ ((freshValues threads).filter fun (x, v) => domain.contains (.atom x) && !domain.contains v).map (·.2)

structure Thread where
  pc : Nat := 0
  env : Env := []
  deriving DecidableEq, Repr, Inhabited

structure World where
  threads : List Thread
  attacker : List Msg
  claims : List (String × List Msg) := []
  tripped : List String := []
  deriving DecidableEq, Repr, Inhabited

def World.knows (w : World) (m : Msg) : Bool := Knowledge.knows w.attacker m
def World.claimed (w : World) (name : String) (args : List Msg) : Bool := w.claims.contains (name, args)

/-- A rewrite rule of an inline defender: what it matches, and what it puts in its place. -/
structure Rewrite where
  pat : Pat
  replace : Pat
  deriving Repr, Inhabited

/-- A defender on the path to some roles: an IPS, a filtering proxy, an intercepting gateway. -/
structure Inline where
  name : String
  /-- the declared roles it protects; their later sessions (`Bob#2`) are protected too -/
  protects : List String
  /-- its keys: what it can open and read -/
  knows : List Msg := []
  drop : List Pat := []
  rewrite : List Rewrite := []
  deriving Repr, Inhabited

def Inline.guards (g : Inline) (thread : String) : Bool :=
  g.protects.any fun r => thread == r || thread.startsWith (r ++ "#")

/-- Match a pattern against a message, extending the bindings. -/
def Pat.matchMsg (env : Env) : Pat → Msg → Option Env
  | .lit l, m => if l == m then some env else none
  | .var x, m => match env.lookup x with
    | some v => if v == m then some env else none
    | none => some ((x, m) :: env)
  | .pair a b, .pair x y => do b.matchMsg (← a.matchMsg env x) y
  | .enc k b, .enc k' b' => do b.matchMsg (← k.matchMsg env k') b'
  | .hash b, .hash b' => b.matchMsg env b'
  | .pk a, .pk n => a.matchMsg env (.atom n)
  | .sk a, .sk n => a.matchMsg env (.atom n)
  | _, _ => none

/-- Match as an observer holding `S` sees it: it looks inside a ciphertext only when it can build
the opening key, and otherwise sees nothing it can match; a hash it can only compare whole with a
pattern that has no variables, since hashing is deterministic. -/
def Pat.matchSeen (S : List Msg) (env : Env) : Pat → Msg → Option Env
  | .pair a b, .pair x y => do Pat.matchSeen S (← Pat.matchSeen S env a x) b y
  | .enc k b, .enc k' b' =>
    -- encryption is randomised in practice, so a blob it cannot open matches nothing, not even itself
    if synth S k'.inverse then do Pat.matchSeen S (← k.matchMsg env k') b b' else none
  | .hash b, .hash b' =>
    if b.vars.isEmpty && b.inst [] == some b' then some env else none
  | .enc .., _ | .hash .., _ | .pair .., _ => none
  | p, m => p.matchMsg env m

/-- The pieces of a message an observer holding `S` can look at: the message, the halves of every
pair, and the body of every ciphertext it can open. -/
def visibleParts (S : List Msg) : Msg → List Msg
  | m@(.pair a b) => m :: (visibleParts S a ++ visibleParts S b)
  | m@(.enc k b) => if synth S k.inverse then m :: visibleParts S b else [m]
  | m => [m]

/-- What the defender does with a message: it drops it when a drop pattern matches any piece it can
look at, like a signature scan; it rewrites the whole message when a rewrite rule matches it.
`none` drops it; otherwise the message it forwards,
and the original when it rewrote it. -/
def Inline.pass (g : Inline) (m : Msg) : Option (Msg × Option Msg) :=
  let S := analz g.knows
  if g.drop.any (fun p => (visibleParts S m).any fun v => (p.matchSeen S [] v).isSome) then none
  else match g.rewrite.findSome? (fun r => (r.pat.matchSeen S [] m).bind r.replace.inst) with
    | some m' => some (m', some m)
    | none => some (m, none)

/-- A requirement as a state predicate; it trips once, as the event `name`, when it first holds. -/
structure Flag where
  name : String
  holds : World → Bool

structure Protocol where
  attacker : String
  /-- what the attacker knows before the run: names, public keys, its own keys and nonces -/
  attackerKnows : List Msg
  /-- the values an unbound variable of a received pattern may take -/
  domain : List Msg
  /-- narrower domains for named variables, such as agents or nonces -/
  domains : List (String × List Msg) := []
  roles : List Role
  flags : List Flag
  /-- a defender between the network and some roles; none means every channel is the attacker's -/
  defender : Option Inline := none

def canon (K : List Msg) : List Msg := K.mergeSort (fun x y => decide (x.render ≤ y.render))

/-- A message on the wire. `src` and `dst` are who physically handed it over and took it, so one of
them is always the attacker, who is the network; `addressee` is whom an honest sender addressed. -/
structure Hop where
  /-- `send` (an honest role hands a message to the network) or `recv` (the network delivers one) -/
  event : String
  src : String
  dst : String
  addressee : Option String := none
  term : Msg

/-- One transition: the event that names it, the world after it, and the message it put on the
wire, if any. -/
structure Move where
  label : String
  next : World
  wire : Option Hop := none
  /-- the claim this move makes, as `commit(B, A)` -/
  claim : Option String := none

def assignments (domain : List Msg) : List String → List Env
  | [] => [[]]
  | x :: xs => (assignments domain xs).flatMap fun env => domain.map fun v => (x, v) :: env

def assignments' (p : Protocol) : List String → List Env
  | [] => [[]]
  | x :: xs => (assignments' p xs).flatMap fun env =>
      ((p.domains.lookup x).getD p.domain).map fun v => (x, v) :: env

def agentName : Msg → String
  | .atom n => n
  | m => m.render

/-- A receive straight from the network: any message of the expected shape the attacker can build. -/
def Protocol.unguardedRecv (p : Protocol) (w : World) (role : Role) (t : Thread)
    (setT : Thread → List Thread) (pat : Pat) : List Move :=
  let free := (pat.vars.filter (fun x => (t.env.lookup x).isNone)).eraseDups
  (assignments' p free).filterMap fun binding =>
    let env := binding ++ t.env
    match pat.inst env with
    | some m => if w.knows m then
        some { label := s!"{role.name} ⇐ {m}", next := { w with threads := setT { pc := t.pc + 1, env } },
               wire := some { event := "recv", src := p.attacker, dst := role.name, term := m } }
      else none
    | none => none

def Protocol.moves (p : Protocol) (w : World) : List Move :=
  let stepMoves := (p.roles.zip (List.range p.roles.length)).flatMap fun (role, i) =>
    let t := w.threads[i]!
    let setT := fun (t' : Thread) => w.threads.set i t'
    match role.steps[t.pc]? with
    | none => []
    | some (.choose x values) => values.map fun v =>
        { label := s!"{role.name} chooses {x} = {v}", next := { w with threads := setT { pc := t.pc + 1, env := (x, v) :: t.env } } }
    | some (.send to pat) =>
        match pat.inst t.env, to.inst t.env with
        | some m, some dst =>
          [{ label := s!"{role.name} → {agentName dst}: {m}",
             next := { w with threads := setT { t with pc := t.pc + 1 }, attacker := canon (learn w.attacker m) },
             wire := some { event := "send", src := role.name, dst := p.attacker, addressee := some (agentName dst), term := m } }]
        | _, _ => []
    | some (.recv pat) =>
      match p.defender with
      | some (g : Inline) =>
        if g.guards role.name then
          -- what the attacker could try: anything of the expected shape, and anything a rewrite turns into it
          let shapes : List Pat := pat :: g.rewrite.map (·.pat)
          let tries := (shapes.flatMap fun (sp : Pat) =>
            let free := (sp.vars.filter (fun x => (t.env.lookup x).isNone)).eraseDups
            (assignments' p free).filterMap fun b => sp.inst (b ++ t.env)).eraseDups
          tries.filterMap fun m =>
            if !w.knows m then none else
            match g.pass m with
            | none => none
            | some (m', orig) =>
              match pat.matchMsg t.env m' with
              | none => none
              | some env =>
                let how := match orig with
                  | some o => s!" ({g.name} rewrote {o})"
                  | none => s!" via {g.name}"
                some { label := s!"{role.name} ⇐ {m'}{how}", next := { w with threads := setT { pc := t.pc + 1, env } },
                       wire := some { event := "recv", src := g.name, dst := role.name, term := m' } }
        else p.unguardedRecv w role t setT pat
      | none => p.unguardedRecv w role t setT pat
    | some (.fresh x) =>
        let v := Msg.atom (freshName x role.session)
        [{ label := s!"{role.name} makes {v}", next := { w with threads := setT { pc := t.pc + 1, env := (x, v) :: t.env } } }]
    | some (.claim name args) =>
        match args.mapM (·.inst t.env) with
        | some vs =>
          let c := s!"{name}({", ".intercalate (vs.map agentName)})"
          [{ label := s!"{role.name} claims {c}", claim := some c,
             next := { w with threads := setT { t with pc := t.pc + 1 }, claims := (name, vs) :: w.claims } }]
        | none => []
  let flags := p.flags.filterMap fun f =>
    if f.holds w && !w.tripped.contains f.name then
      some { label := f.name, next := { w with tripped := f.name :: w.tripped } }
    else none
  stepMoves ++ flags

structure Model where
  states : Array World
  edges : List (Nat × Nat × Move)
  /-- the exploration stopped at its state limit: verdicts over this model prove nothing -/
  truncated : Bool := false

/-- Breadth-first over the declared protocol; stops adding states at `limit`. -/
def Protocol.explore (p : Protocol) (limit : Nat := 4096) : Model := Id.run do
  let init : World := { threads := p.roles.map (fun _ => {}), attacker := canon (analz p.attackerKnows) }
  let mut states : Array World := #[init]
  let mut edges : List (Nat × Nat × Move) := []
  let mut truncated := false
  let mut i := 0
  while i < states.size do
    for mv in p.moves states[i]! do
      match states.findIdx? (· == mv.next) with
      | some j => edges := (i, j, mv) :: edges
      | none =>
        if states.size < limit then
          states := states.push mv.next
          edges := (i, states.size - 1, mv) :: edges
        else truncated := true
    i := i + 1
  return { states, edges := edges.reverse, truncated }

def termJson : Msg → Json
  | .atom n => Json.mkObj [("atom", n)]
  | .key n => Json.mkObj [("key", n)]
  | .pk a => Json.mkObj [("pk", a)]
  | .sk a => Json.mkObj [("sk", a)]
  | .pair a b => Json.mkObj [("pair", Json.arr #[termJson a, termJson b])]
  | .enc k b => Json.mkObj [("enc", Json.mkObj [("key", termJson k), ("body", termJson b)])]
  | .hash b => Json.mkObj [("hash", termJson b)]

/-- Every claim some thread could make: each claim step's arguments over the values its variables
could take (choices, fresh values, receive domains), at most 256 per step. The draft declares them
on an unreachable state, so a formula may name a claim that never happens, and a claim no thread
could make stays an unknown name. -/
def Protocol.possibleClaims (p : Protocol) : List String := Id.run do
  let mut out : List String := []
  for r in p.roles do
    let candidates := fun (x : String) => r.steps.flatMap fun
      | .choose y vs => if y == x then vs else []
      | .fresh y => if y == x then [Msg.atom (freshName y r.session)] else []
      | .recv pat => if pat.vars.contains x then (p.domains.lookup x).getD p.domain else []
      | _ => []
    for st in r.steps do
      if let .claim name args := st then
        let vars := (args.flatMap Pat.vars).eraseDups
        let envs := vars.foldl (fun (envs : List Env) x =>
          (envs.flatMap fun e => (candidates x).eraseDups.map fun v => (x, v) :: e).take 256) [[]]
        for e in envs do
          if let some vs := args.mapM (·.inst e) then
            let c := s!"{name}({", ".intercalate (vs.map agentName)})"
            unless out.contains c do out := out ++ [c]
  return out

/-- The generated model as a `check_ctl` draft: every message transition carries its term, the
attacker sees every channel, and every flag is declared on an unreachable extra state so a formula
may name a flag that never trips. -/
def Protocol.draft (p : Protocol) (m : Model) (id : String) : Json :=
  let name := fun (i : Nat) => s!"s{i}"
  let outs := m.edges.map (·.1)
  let terminals := (List.range m.states.size).filter (fun i => !outs.contains i)
  let tr := fun ((a, b, mv) : Nat × Nat × Move) =>
    Json.mkObj ([("src", Json.str (name a)), ("dst", Json.str (name b)), ("message", Json.str mv.label)] ++
      (match mv.wire with
      | some h =>
        -- the defender's link to the role it protects is not the attacker's: no term, so nothing is learnt
        if (match p.defender with | some g => g.name == h.src | none => false) then [("from", Json.str h.src), ("to", Json.str h.dst)]
        else [("from", Json.str h.src), ("to", Json.str h.dst), ("term", termJson h.term)]
      | none => []) ++
      (match mv.claim with | some c => [("claim", Json.str c)] | none => []))
  Json.mkObj
    [ ("id", Json.str id)
    , ("states", Json.arr (((List.range m.states.size).map (Json.str ∘ name)) ++ [Json.str "flags"]).toArray)
    , ("initial", "s0")
    , ("terminals", Json.arr (terminals.map (Json.str ∘ name)).toArray)
    , ("transitions", Json.arr ((m.edges.map tr) ++ p.flags.map (fun f =>
        Json.mkObj [("src", "flags"), ("dst", "flags"), ("message", Json.str f.name)]) ++
        p.possibleClaims.map (fun c =>
        Json.mkObj [("src", "flags"), ("dst", "flags"), ("message", Json.str s!"possible {c}"), ("claim", Json.str c)])).toArray)
    , ("knowledge", Json.mkObj [(p.attacker, Json.mkObj
        [("initial", Json.arr (p.attackerKnows.map termJson).toArray), ("seesAll", Json.bool true)])]) ]

def verdict (j : Json) : String := (j.getObjValD "verdict").getStr?.toOption.getD "?"

/-- The events of a returned path, in order. -/
def walk (j : Json) : List String :=
  match (j.getObjValD "evidence").getObjValD "path" with
  | .arr ps => ps.toList.filterMap fun s => (s.getObjValD "message").getStr?.toOption
  | _ => []

/-- What crossed the wire along a returned path, replayed through the model. -/
def Protocol.replayWire (p : Protocol) (path : List String) : List Hop := Id.run do
  let mut w : World := { threads := p.roles.map (fun _ => {}), attacker := canon (analz p.attackerKnows) }
  let mut out := []
  for label in path do
    match (p.moves w).find? (·.label == label) with
    | some mv =>
      if let some hop := mv.wire then out := out ++ [hop]
      w := mv.next
    | none => pure ()
  return out

end LeanFM.Session.Attack

namespace LeanFM.Session.Attack
open Lean

/-- A hop as people read it: a send names its sender, the addressee, and the attacker it went via;
a delivery names the attacker it came from and the role that took it. -/
def Hop.toJson (h : Hop) : Json :=
  match h.event, h.addressee with
  | "send", some a => Json.mkObj [("event", "send"), ("from", Json.str h.src), ("to", Json.str a),
      ("via", Json.str h.dst), ("term", Json.str h.term.render)]
  | e, _ => Json.mkObj [("event", Json.str e), ("from", Json.str h.src), ("to", Json.str h.dst),
      ("term", Json.str h.term.render)]

end LeanFM.Session.Attack
