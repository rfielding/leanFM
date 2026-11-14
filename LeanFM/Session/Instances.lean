import Std.Data.HashMap
import LeanFM.Session.System
import LeanFM.Session.Text
import LeanFM.Session.SpecCheck
import LeanFM.Session.Actors

/-!
# Instances interleaved (clause selfhost.session.instances)

A `System` (`Session.System`) accepts protocols against shared instances. This module explores a
bounded number of accepted instances (1 to 4 in all) interleaved, as one state graph:

* a state is every instance's protocol state (the states conformance explores, `Conform.State`)
  and which session holds each `serial` shared instance;
* a step is one step some instance's protocol allows next, taken by that instance's actors: its
  fresh actors are `Role/s1`, `Role/s2`, ...; a shared instance `db : Db` is the actor `Db/db` in
  every instance it is given to;
* a step that involves a serial instance held by another session waits; a serial instance is held
  from its first step in a session until that session's protocol no longer mentions its role.

So two instances that take two serial instances in different orders deadlock, and the graph has
the path. The checks:

* deadlock: a state where nothing can happen and some instance cannot end, reported with the steps
  that reach it and what each instance waits for;
* isolation, over every reachable step: a step of instance s involves only s's own fresh actors and
  the shared instances s was given (a message of s never reaches t's thread; no instance uses a
  reference it was not given); session ids are distinct;
* per-instance properties: a property of one instance, checked for each instance, its messages
  `Label@s` and its `terminal` meaning that instance has finished; system properties: `sent X` is
  any instance's `X`, `terminal` that every instance can end. Both go to the logic tools' checker
  (`checkDraft`), the one `session_ctl` and `Spec.check` use, with its paths.

A log checked against a text that declares a system follows the system's actors (`checkActors`).
Negative requirements: more than 4 instances, or more than 2000 states, is refused rather than
explored in part; a property is never reported proved unless the checker proved it.
-/

namespace LeanFM.Session
namespace Instances
open Lean Conform

/-- Every system the text declares, each accepted protocol built as the text builds a protocol
(its includes inlined, its roles its own). -/
def systemsOf (text : String) : Except String (List System) := do
  let (defs, st) <- Text.readText text
  st.systems.toList.mapM fun sd => do
    let accepts <- sd.accepts.mapM fun (p, players) => do
      let some i := defs.findIdx? (fun x => x.name == p) | throw s!"system {sd.name}: no protocol {p}"
      let d := defs[i]!
      let ctx : Text.Ctx := { defs := defs.take i, rename := [], roles := d.roles, path := d.name, inside := [d.name] }
      let (g, _) <- (Text.build ctx d.body).run 0
      pure ({ protocolName := p, roles := d.roles, global := g,
              players := players.map fun (f, n) => if f then .fresh else .shared n } : Accept)
    pure ({ name := sd.name, accepts,
            shared := sd.shared.map fun (n, r, s) => { name := n, role := r, serial := s } } : System)

/-- Whether a role still occurs in what remains of a protocol. -/
partial def mentions (r : String) : Global String -> Bool
  | .msg i k => i.src == r || i.dst == r || mentions r k
  | .act a _ k => a == r || mentions r k
  | .choice bs => bs.any (mentions r)
  | .par bs k | .join _ bs k => bs.any (mentions r) || mentions r k
  | .loop _ b => mentions r b
  | .sessions b k | .box _ b k => mentions r b || mentions r k
  | .var _ | .done => false

/-- One accepted instance in the model. -/
structure Inst where
  id : String
  accept : Nat
  protocolName : String
  body : Global String
  /-- each role with its actor -/
  actors : List (Prod String String)
  /-- each role played by a shared instance, with that instance -/
  given : List (Prod String Shared)
  deriving Inhabited

def maxInstances : Nat := 4
def maxStates : Nat := 2000

/-- The instances explored: `n` of every accept, numbered s1, s2, ... in accept order. -/
def instancesOf (sys : System) (n : Nat) : Except String (List Inst) := do
  if n == 0 then throw "explore at least one instance"
  if n * sys.accepts.length > maxInstances then
    throw s!"{n} instance{if n == 1 then "" else "s"} of each of {sys.accepts.length} accepts is {n * sys.accepts.length} in all; at most {maxInstances} are explored"
  let mut out : Array Inst := #[]
  for (a, ai) in sys.accepts.zipIdx do
    for _ in [0:n] do
      let id := s!"s{out.size + 1}"
      let mut actors : List (Prod String String) := []
      let mut given : List (Prod String Shared) := []
      for (r, pl) in a.roles.zip a.players do
        match pl with
        | .fresh => actors := actors ++ [(r, s!"{r}/{id}")]
        | .shared x =>
          let some sh := sys.sharedNamed x | throw s!"system {sys.name}: {x} is not a shared instance"
          actors := actors ++ [(r, s!"{sh.role}/{sh.name}")]
          given := given ++ [(r, sh)]
      let body := Conform.inlineNested (match a.global with | .sessions b _ => b | g => g)
      out := out.push { id, accept := ai, protocolName := a.protocolName, body, actors, given }
  return out.toList

/-- A state of the model: every instance's protocol state, and the serial instances held. -/
structure PState where
  sts : List Conform.State
  /-- serial shared instance, index of the instance holding it -/
  holders : List (Prod String Nat)
  deriving Inhabited

def stKey (st : Conform.State) : String := Conform.key st.g ++ "|" ++ toString (st.bind.map (fun x => x.1))
def pKey (p : PState) : String := " || ".intercalate (p.sts.map stKey) ++ " # " ++ toString p.holders

def finished (st : Conform.State) : Bool := Conform.nullable st.g && (Conform.nextOf st.bind 32 st.g).isEmpty

/-- One step of the model. -/
structure Edge where
  src : Nat
  dst : Nat
  /-- index of the instance that took it -/
  inst : Nat
  step : Conform.NextStep
  srcActor : String
  dstActor : String
  /-- the step after which its instance has finished -/
  finishes : Bool
  deriving Inhabited, BEq

/-- What blocks a session in a deadlocked state. -/
structure Waiting where
  inst : String
  /-- each step it could take, and the session holding the instance it needs -/
  waits : List (Prod String String)
  deriving Inhabited

structure Graph where
  insts : List Inst
  /-- the states' keys, `p0` is the start -/
  keys : Array String
  /-- whether every instance can end there -/
  terminal : Array Bool
  edges : Array Edge
  /-- for each state but the start: the state and edge it was first reached by -/
  parent : Array (Option (Prod Nat Nat))
  /-- deadlocked states and what each unfinished instance waits for there -/
  deadlocks : List (Prod Nat (List Waiting))
  deriving Inhabited

def stepText (insts : List Inst) (e : Edge) : String :=
  let sid := (insts[e.inst]?.map (fun x => x.id)).getD "?"
  if e.step.isAct then s!"{e.step.label}@{sid} at {e.srcActor}"
  else s!"{e.step.label}@{sid} from {e.srcActor} to {e.dstActor}"

/-- The serial shared instances a step of instance `i` involves. -/
def serialsOf (inst : Inst) (n : Conform.NextStep) : List Shared :=
  let roles := if n.isAct then [n.src] else [n.src, n.dst]
  (roles.filterMap fun r => inst.given.lookup r).filter (fun x => x.serial) |>.eraseDups

/-- Explore `n` instances of every accept, interleaved. -/
def explore (sys : System) (n : Nat) : Except String Graph := do
  let insts <- instancesOf sys n
  let ids := insts.map (fun x => x.id)
  if ids.eraseDups.length != ids.length then throw "two instances have one id"
  let start : PState := { sts := insts.map fun i => { g := i.body, bind := [] }, holders := [] }
  let mut index : Std.HashMap String Nat := Std.HashMap.emptyWithCapacity 256
  index := index.insert (pKey start) 0
  let mut states : Array PState := #[start]
  let mut keys : Array String := #[pKey start]
  let mut parent : Array (Option (Prod Nat Nat)) := #[none]
  let mut edges : Array Edge := #[]
  let mut deadlocks : List (Prod Nat (List Waiting)) := []
  let mut fresh := 0
  let mut head := 0
  while head < states.size do
    let p := states[head]!
    let src := head
    head := head + 1
    let mut moved := false
    let mut waiting : List Waiting := []
    for (inst, i) in insts.zipIdx do
      let st := p.sts[i]!
      let mut waits : List (Prod String String) := []
      for nx in (Conform.nextOf st.bind 32 st.g).eraseDups do
        let actorOf (r : String) : String := (inst.actors.lookup r).getD r
        let serials := serialsOf inst nx
        match serials.find? (fun sh => match p.holders.lookup sh.name with | some j => j != i | none => false) with
        | some sh =>
          let holder := (p.holders.lookup sh.name).bind (fun j => insts[j]?) |>.map (fun x => x.id) |>.getD "?"
          let what := if nx.isAct then s!"{nx.label} at {actorOf nx.src}" else s!"{nx.label} from {actorOf nx.src} to {actorOf nx.dst}"
          waits := waits ++ [(what, s!"{sh.role}/{sh.name}, which {holder} holds")]
        | none =>
          fresh := fresh + 1
          let e : LogEvent := { id := s!"g{fresh}", src := nx.src, dst := nx.dst, label := nx.label, cause := nx.cause, isAct := nx.isAct }
          for st' in Conform.step e 64 false st do
            moved := true
            -- take the serial instances it involves; give back every one this instance no longer needs
            let taken := serials.foldl (fun hs sh => if hs.any (fun h => h.1 == sh.name) then hs else hs ++ [(sh.name, i)]) p.holders
            let holders := taken.filter fun (x, j) =>
              j != i || match sys.sharedNamed x with
                | some sh => (inst.given.filter (fun rs => rs.2.name == sh.name)).any fun (r, _) => mentions r st'.g
                | none => false
            -- one order for the holders, so one state has one key
            let holders := holders.toArray.qsort (fun a b => a.1 < b.1) |>.toList
            let q : PState := { sts := p.sts.set i st', holders }
            let k := pKey q
            let dst <- match index.get? k with
              | some d => pure d
              | none =>
                if states.size >= maxStates then
                  throw s!"more than {maxStates} states with {insts.length} instances; nothing was proved, so explore fewer instances"
                let d := states.size
                index := index.insert k d
                states := states.push q
                keys := keys.push k
                parent := parent.push (some (src, edges.size))
                pure d
            let edge : Edge := { src, dst, inst := i, step := nx, srcActor := actorOf nx.src,
                                 dstActor := if nx.isAct then actorOf nx.src else actorOf nx.dst,
                                 finishes := !finished st && finished st' }
            if !edges.any (fun x => x == edge) then edges := edges.push edge
      if !finished st then waiting := waiting ++ [{ inst := inst.id, waits }]
    let terminal := p.sts.all (fun st => Conform.nullable st.g)
    if !moved && !terminal then deadlocks := deadlocks ++ [(src, waiting)]
  let terminal := states.map fun p => p.sts.all (fun st => Conform.nullable st.g)
  return { insts, keys, terminal, edges, parent, deadlocks }

/-- The steps from the start to a state. -/
def Graph.pathTo (g : Graph) (s : Nat) : List Edge := Id.run do
  let mut out : List Edge := []
  let mut cur := s
  for _ in [0:g.keys.size] do
    match g.parent[cur]?.getD none with
    | some (p, e) => out := g.edges[e]! :: out; cur := p
    | none => break
  return out

/-- At most this many deadlocks are described, the nearest first; the rest are counted. -/
def maxDescribed : Nat := 4

/-- Each deadlock in words, the nearest first: the steps that reach it, and what each instance
waits for. -/
def Graph.deadlockTexts (g : Graph) : List String :=
  (g.deadlocks.take maxDescribed).map fun (s, ws) =>
    let path := (g.pathTo s).map (stepText g.insts)
    let why := ws.map fun w =>
      if w.waits.isEmpty then s!"{w.inst} can do nothing and cannot end"
      else s!"{w.inst} waits to " ++ " or ".intercalate (w.waits.map fun (what, on) => s!"send {what} (needs {on})")
    s!"deadlock after {" -> ".intercalate path}: {"; ".intercalate why}"

/-- Isolation over steps: each step of instance s involves only s's own actors, its fresh ones and
the shared instances it was given. A pure function of the steps, so a step built by hand is judged
by the same rule as the explored ones. -/
def isolationProblems (sys : System) (insts : List Inst) (edges : List Edge) : List String :=
  edges.flatMap fun e =>
    match insts[e.inst]? with
    | none => [s!"a step names instance {e.inst + 1}, which does not exist"]
    | some inst =>
      let own := inst.actors.map (fun x => x.2)
      ([e.srcActor, e.dstActor].eraseDups.filter (fun a => !own.contains a)).map fun a =>
        match sys.shared.find? (fun sh => s!"{sh.role}/{sh.name}" == a) with
        | some sh => s!"{stepText insts e}: {inst.id} uses {sh.name}, which it was not given"
        | none => s!"{stepText insts e}: a message of {inst.id} reaches {a}, which is not one of its actors"

/-- The model as the logic tools' inline task: messages `Label@s`, and a claim `finished@s` on the
step after which instance s has finished (claims stay true along the path). -/
def Graph.draft (g : Graph) (name : String) : Json :=
  let st (i : Nat) := s!"p{i}"
  let transition (e : Edge) : Json :=
    let sid := (g.insts[e.inst]?.map (fun x => x.id)).getD "?"
    Json.mkObj ([("src", Json.str (st e.src)), ("dst", Json.str (st e.dst)), ("message", Json.str s!"{e.step.label}@{sid}"),
      ("from", Json.str e.srcActor)] ++ (if e.step.isAct then [] else [("to", Json.str e.dstActor)]) ++
      (if e.finishes then [("claim", Json.str s!"finished@{sid}")] else []))
  Json.mkObj [("id", Json.str name), ("states", Json.arr ((List.range g.keys.size).map (fun i => Json.str (st i))).toArray),
    ("initial", "p0"), ("terminals", Json.arr (((List.range g.keys.size).filter (fun i => g.terminal[i]!)).map (fun i => Json.str (st i))).toArray),
    ("transitions", Json.arr (g.edges.map transition))]

def Graph.messages (g : Graph) : List String :=
  (g.edges.toList.map fun e => s!"{e.step.label}@{(g.insts[e.inst]?.map (fun x => x.id)).getD "?"}").eraseDups

/-- A formula about one instance: `{"after": X}` is that instance's X, `"terminal"` that it has
finished. An atom the model never shows (a message that instance never sends) is false. -/
partial def localize (g : Graph) (sid : String) : Json -> Json
  | .str "terminal" =>
    if g.edges.any (fun e => e.finishes && (g.insts[e.inst]?.map (fun x => x.id)) == some sid)
    then Json.mkObj [("claimed", Json.str s!"finished@{sid}")] else Json.bool false
  | .obj kvs =>
    match kvs.toList with
    | [("after", .str l)] =>
      let t := s!"{l}@{sid}"
      if g.messages.contains t then Json.mkObj [("after", Json.str t)] else Json.bool false
    | items => Json.mkObj (items.map fun (k, v) => (k, localize g sid v))
  | .arr a => Json.arr (a.map (localize g sid))
  | j => j

/-- A formula about the whole system: `{"after": X}` is any instance's X, `"terminal"` that every
instance can end. -/
partial def globalize (g : Graph) : Json -> Json
  | .obj kvs =>
    match kvs.toList with
    | [("after", .str l)] =>
      let present := (g.insts.map fun i => s!"{l}@{i.id}").filter g.messages.contains
      if present.isEmpty then Json.bool false
      else if present.length == 1 then Json.mkObj [("after", Json.str present.head!)]
      else Json.mkObj [("or", Json.arr (present.map fun t => Json.mkObj [("after", Json.str t)]).toArray)]
    | items => Json.mkObj (items.map fun (k, v) => (k, globalize g v))
  | .arr a => Json.arr (a.map (globalize g))
  | j => j

/-- One property's verdict: the formula as written, where it was checked (an instance id or
`system`), the verdict, and the reading with the path. -/
structure Verdict where
  formula : Json
  scope : String
  verdict : String
  why : String
  deriving Inhabited

/-- The labels a formula names with `{"after": X}`. -/
partial def afterLabels : Json -> List String
  | .obj kvs => match kvs.toList with
    | [("after", .str l)] => [l]
    | items => items.flatMap (fun kv => afterLabels kv.2)
  | .arr a => a.toList.flatMap afterLabels
  | _ => []

def verdictOf (name : String) (draft formula : Json) (shown : Json) (scope : String) (never : List String := []) : Verdict :=
  -- labels the model never shows in this scope were read as false: say so
  let note := if never.isEmpty then "" else
    s!" ({if scope == "system" then "no instance" else scope} never sends {", ".intercalate never}, so {if never.length == 1 then "it reads" else "they read"} as false)"
  match checkDraft name draft formula with
  | .ok a =>
    let verdict := (a.getObjValAs? String "verdict").toOption.getD "unknown"
    let reading := (a.getObjValAs? String "reading").toOption.getD ""
    let report := (a.getObjValAs? String "report").toOption.getD ""
    { formula := shown, scope, verdict, why := (if report.isEmpty then reading else s!"{reading}; {report}") ++ note }
  | .error e => { formula := shown, scope, verdict := "not checked", why := e }

/-- Everything the check found. -/
structure Report where
  graph : Graph
  deadlocks : List String
  isolation : List String
  verdicts : List Verdict
  deriving Inhabited

/-- Explore `n` instances of every accept and decide everything: deadlocks, isolation, each
per-instance formula for every instance and each system formula. -/
def run (sys : System) (n : Nat) (perInstance properties : List Json) : Except String Report := do
  let g <- explore sys n
  let draft := g.draft sys.name
  let msgs := g.messages
  let per := perInstance.flatMap fun f => g.insts.map fun i =>
    let never := (afterLabels f).eraseDups.filter fun l => !msgs.contains s!"{l}@{i.id}"
    verdictOf s!"{sys.name} {i.id}" draft (localize g i.id f) f i.id never
  let whole := properties.map fun f =>
    let never := (afterLabels f).eraseDups.filter fun l => !g.insts.any fun i => msgs.contains s!"{l}@{i.id}"
    verdictOf sys.name draft (globalize g f) f "system" never
  let more := g.deadlocks.length - maxDescribed
  let deadlocks := g.deadlockTexts ++
    (if g.deadlocks.length > maxDescribed then [s!"{more} more deadlocked state{if more == 1 then "" else "s"}, each reached by a longer path"] else [])
  return { graph := g, deadlocks, isolation := isolationProblems sys g.insts g.edges.toList,
           verdicts := per ++ whole }

/-- The findings: deadlocks, isolation problems, and every property not proved. -/
def Report.problems (r : Report) : List String :=
  r.deadlocks ++ r.isolation ++ r.verdicts.filterMap fun v =>
    if v.verdict == "proved" then none
    else if v.verdict == "disproved" then some s!"property {v.formula.compress} disproved for {v.scope}: {v.why}"
    else some s!"property {v.formula.compress} not checked for {v.scope} ({v.verdict}): {v.why}"

/-! ## Systems in Lean -/

/-- A system with the properties stated about it, as a `Spec` is for one protocol. -/
structure SystemSpec where
  sys : System
  /-- instances of each accept to explore -/
  instances : Nat := 2
  /-- properties of one instance, checked for every instance -/
  perInstance : List Prop' := []
  /-- properties of the whole system -/
  properties : List Prop' := []

/-- Everything wrong with the system: deadlocks, isolation, properties not proved, or why it could
not be explored. -/
def SystemSpec.check (s : SystemSpec) : List String :=
  match run s.sys s.instances (s.perInstance.map Prop'.toJson) (s.properties.map Prop'.toJson) with
  | .ok r => r.problems
  | .error e => [e]

/-! ## Logs of a system -/

/-- The actor rules a log of a system follows, each problem with its event: every actor names an
instance (`Role/instance`); a shared instance plays its own role and is given to some accept; a
fresh actor plays a role some accept marks fresh and belongs to one session only (a message of
one instance never reaches another's thread). -/
def checkActors (sys : System) (evs : List LogEvent) : List (Prod String String) := Id.run do
  let freshRoles := (sys.accepts.flatMap fun a => (a.roles.zip a.players).filterMap fun (r, p) =>
    if p == .fresh then some r else none).eraseDups
  let givenNames := (sys.accepts.flatMap fun a => a.players.filterMap fun | .shared x => some x | .fresh => none).eraseDups
  let mut owner : List (Prod String String) := []
  let mut out : List (Prod String String) := []
  for e in evs do
    let sides := [(e.src, e.srcActor)] ++ (if e.isAct then [] else [(e.dst, e.dstActor)])
    for (role, actor) in sides do
      if actor.isEmpty then
        out := out ++ [(e.id, s!"{role} names no instance; system {sys.name} declares its instances, so every actor is Role/instance")]
      else
        let inst := (actor.splitOn "/").getLastD ""
        match sys.sharedNamed inst with
        | some sh =>
          if sh.role != role then out := out ++ [(e.id, s!"{actor}: {inst} plays {sh.role}, not {role}")]
          else if !givenNames.contains inst then out := out ++ [(e.id, s!"{actor}: {inst} is given to no accept of system {sys.name}")]
        | none =>
          if !freshRoles.contains role then
            let by_ := (sys.shared.filter (fun x => x.role == role)).map (fun x => x.name)
            out := out ++ [(e.id, s!"{actor}: {role} is never fresh in system {sys.name}" ++
              (if by_.isEmpty then "" else s!"; it is played by {", ".intercalate by_}"))]
          else match owner.lookup actor with
            | some s =>
              if s != e.session && !out.any (fun (_, w) => w.startsWith s!"{actor} belongs to session {s}") then
                out := out ++ [(e.id, s!"{actor} belongs to session {s}; a fresh actor is in one instance only, but it also appears in session {e.session}")]
            | none => owner := owner ++ [(actor, e.session)]
  return out

end Instances
end LeanFM.Session
