import LeanFM.Session.Text
import LeanFM.Session.Events
import LeanFM.Session.Conform

/-!
selfhost.session.generative, .execution, .monitor.
Exact, bounded metadata interpretation; Global remains the conformance oracle.
No evaluation of user code, IO, hidden scheduler, or cross-session clock state.
-/
namespace LeanFM.Session.Generative
open Lean LeanFM.Overlay

abbrev Stmt := Text.Stmt

def parseValue (p : Text.P α) (s : String) : Except String α := do
  if s.length > 4096 then throw "annotation text is too long"
  let parser : Text.P α := do
    let v ← p
    Text.skip
    if (← Text.peek).isSome then Text.fail "unexpected trailing annotation text"
    return v
  let (v, _) ← (parser.run s.toList.toArray).run {}
  return v

def objKeys (j : Json) : List String := match j with
  | .obj o => o.toList.map (·.1)
  | _ => []

def onlyKeys (j : Json) (allowed : List String) : Except String Unit := do
  if !(match j with | .obj _ => true | _ => false) then throw "overlay entry must be an object"
  let extra := (objKeys j).filter (!allowed.contains ·)
  if !extra.isEmpty then throw s!"unknown overlay keys: {extra}"

def strField (j : Json) (k : String) : Except String String := do
  let s ← j.getObjValAs? String k
  if s.isEmpty || s.length > 200 || s.toList.any (fun c => c.toNat < 32) then
    throw s!"invalid overlay {k}"
  return s

def arrayField (j : Json) (k : String) : Except String (List Json) := do
  match j.getObjVal? k with
  | .error _ => return []
  | .ok (.arr a) =>
    if a.size > 200 then throw s!"at most 200 entries in {k}"
    return a.toList
  | _ => throw s!"{k} must be an array"

structure External where
  name : String := ""
  choices : List (String × List Q) := []
  timings : List (String × TimeExpr) := []

def external (j : Json) : Except String External := do
  onlyKeys j ["name", "choices", "timings"]
  let name ← strField j "name"
  let choices ← (← arrayField j "choices").mapM fun c => do
    onlyKeys c ["choice", "weights"]
    let key ← strField c "choice"
    let qs ← (← arrayField c "weights").mapM fun q => do
      parseValue Text.fraction (← q.getStr?)
    checkWeights qs
    return (key, qs)
  let timings ← (← arrayField j "timings").mapM fun t => do
    onlyKeys t ["message", "at"]
    let key ← strField t "message"
    let expression ← t.getObjValAs? String "at"
    return (key, ← parseValue Text.timeExpr expression)
  if (choices.map (·.1)).eraseDups.length != choices.length ||
     (timings.map (·.1)).eraseDups.length != timings.length then throw "duplicate overlay target"
  return { name, choices, timings }

structure ResolveState where
  choiceIndex : Nat := 0
  names : List String := []
  usedChoices : List String := []
  usedTimings : List String := []
  metadata : List Json := []
  active : Bool := false

abbrev ResolveM := StateT ResolveState (Except String)

def qJson (q : Q) : Json := Json.str q.text

def timeJson (t : TimeExpr) : Json := Json.mkObj
  [("clock", toJson t.clock), ("refs", toJson t.refs), ("relative", t.relative), ("periodMs", toJson t.period),
   ("offsets", toJson (t.offsets.map fun (d,q) => Json.mkObj [("delayMs", d), ("probability", qJson q)]))]

/-- The id (or label) of the message under any amount or time annotations. -/
partial def messageKey : Stmt → Option String
  | .msg id label .. => some (id.getD label)
  | .timed _ m | .valued _ m => messageKey m
  | _ => none

def record (j : Json) : ResolveM Unit := modify fun s => { s with metadata := s.metadata ++ [j], active := true }

mutual
partial def resolveList (ext : External) (ss : List Stmt) : ResolveM (List Stmt) := ss.mapM (resolveStmt ext)
partial def resolveStmt (ext : External) (s : Stmt) : ResolveM Stmt := do
  match s with
  | .timed t (.event label role) =>
    record <| Json.mkObj [("kind", "timing"), ("event", label), ("role", role), ("at", timeJson t), ("origin", "inline")]
    return s
  | .timed t m => resolveMessage ext m (some t)
  | .accrue as =>
    for a in as do
      record <| Json.mkObj [("kind", "accrual"), ("payer", a.payer), ("payee", a.payee), ("unit", a.unit),
        ("quantity", a.quantity), ("periodMs", a.periodMs)]
    return s
  | .valued a m =>
    let key := (messageKey m).getD ""
    record <| Json.mkObj [("kind", "amount"), ("message", key), ("unit", a.unit), ("reverse", a.reverse),
      ("outcomes", toJson (a.outcomes.map fun (n,q) => Json.mkObj [("quantity", n), ("probability", qJson q)]))]
    return .valued a (← resolveStmt ext m)
  | .msg .. => resolveMessage ext s none
  | .clock name refs =>
    record <| Json.mkObj [("kind", "clock"), ("name", name), ("refs", toJson refs)]
    return s
  | .obligation o =>
    record <| Json.mkObj [("kind", "obligation"), ("name", o.name), ("actor", o.actor),
      ("trigger", o.clock), ("labels", toJson o.labels), ("withinMs", o.withinMs), ("breach", o.breach),
      ("penalty", match o.penalty with
        | some p => Json.mkObj [("quantity", p.quantity), ("unit", p.unit), ("payee", p.payee)]
        | none => Json.null)]
    return s
  | .choice bs => resolveChoice ext none "" [] bs
  | .weighted name actor qs bs => resolveChoice ext (some name) actor qs bs
  | .par bs => return .par (← bs.mapM (resolveList ext))
  | .join n bs => return .join n (← bs.mapM (resolveList ext))
  | .loop n b => return .loop n (← resolveList ext b)
  | .sessions b => return .sessions (← resolveList ext b)
  | _ => return s
partial def resolveChoice (ext : External) (named : Option String) (actor : String)
    (weights : List Q) (bs : List (List Stmt)) : ResolveM Stmt := do
  let state ← get
  let name := named.getD s!"choice:{state.choiceIndex}"
  if state.names.contains name then throw s!"duplicate choice name {name}"
  modify fun s => { s with choiceIndex := s.choiceIndex + 1, names := name :: s.names }
  let replacement := ext.choices.lookup name
  let qs := replacement.getD weights
  if !qs.isEmpty then
    checkWeights qs
    if qs.length != bs.length then throw s!"choice {name}: one probability is required per branch"
  if replacement.isSome then modify fun s => { s with usedChoices := name :: s.usedChoices }
  if !qs.isEmpty || named.isSome then
    record <| Json.mkObj [("kind", "choice"), ("name", name), ("actor", actor),
      ("weights", toJson (qs.map qJson)), ("origin", if replacement.isSome then ext.name else "inline")]
  let bodies ← bs.mapM (resolveList ext)
  -- Empty actor denotes a plain choice whose decider is still derived from Global.
  return .weighted name actor qs bodies
partial def resolveMessage (ext : External) (m : Stmt) (inlineTime : Option TimeExpr) : ResolveM Stmt := do
  let some key := messageKey m | throw "timeAt annotation requires a message"
  let replacement := ext.timings.lookup key
  if replacement.isSome then
    if (← get).usedTimings.contains key then throw s!"ambiguous timing target {key}; give messages unique ids"
    modify fun s => { s with usedTimings := key :: s.usedTimings }
  match replacement <|> inlineTime with
  | none => return m
  | some t =>
    record <| Json.mkObj [("kind", "timing"), ("message", key), ("at", timeJson t),
      ("origin", if replacement.isSome then ext.name else "inline")]
    return .timed t m
end

structure Resolved where
  body : List Stmt
  active : Bool
  metadata : Json
  deriving Inhabited

def resolve (body : List Stmt) (overlay : Option Json := none) : Except String Resolved := do
  let ext ← match overlay with | some j => external j | none => pure ({} : External)
  let (body, state) ← (resolveList ext body).run {}
  for (k, _) in ext.choices do
    if !state.usedChoices.contains k then throw s!"unknown choice overlay target {k}"
  for (k, _) in ext.timings do
    if !state.usedTimings.contains k then throw s!"unknown message overlay target {k}"
  return { body, active := state.active || overlay.isSome, metadata := Json.mkObj [("unit", "ms"), ("overlay", if overlay.isSome then ext.name else "inline"),
      ("annotations", toJson state.metadata), ("coreUnchanged", true)] }

inductive Action where
  | decision (name actor : String) (branch : Nat) (weight : Q)
  | msg (interaction : Interaction String) (time : Option TimeExpr)
  | act (role label : String)
  | clock (name : String) (refs : List String)
  | obligation (o : Obligation)
  /-- An amount outcome moved by the message just before it (selfhost.session.amounts). -/
  | transfer (src dst unit : String) (quantity : Nat) (weight : Q)
  deriving Inhabited

structure Path where
  actions : List Action := []
  probability : Q := Q.one
  unknown : Bool := false
  deriving Inhabited

def maxPaths : Nat := 4096

def appendPaths (a b : List Path) : Except String (List Path) := do
  if a.length * b.length > maxPaths then throw "generative resource limit: more than 4096 paths"
  return a.flatMap fun x => b.map fun y =>
    { actions := x.actions ++ y.actions, probability := Q.mul x.probability y.probability,
      unknown := x.unknown || y.unknown }

mutual
partial def expand (ss : List Stmt) : Except String (List Path) := do
  match ss with
  | [] => return [{}]
  | s :: rest => appendPaths (← expandStmt s) (← expand rest)
partial def expandStmt (s : Stmt) : Except String (List Path) := do
  match s with
  | .msg id label src dst cause route status guard =>
    let i : Interaction String := { id, label, src, dst, cause, route, status, guard := guard.map (fun text => { text, eval := fun _ => none }) }
    return [{ actions := [.msg i none] }]
  | .timed _ (.event ..) => throw "after on an event is used by the chain view (view chain); the tree times messages only"
  | .accrue _ => throw "accrue needs the chain view: a rate accrues over time spent in states (view chain, or a session with rec)"
  | .timed t m =>
    checkWeights (t.offsets.map (·.2))
    let paths ← expandStmt m
    let mut result := []
    for p in paths do
      -- the message comes first; an amount's transfer may follow it
      let .msg i _ :: tail := p.actions | throw "timing must annotate one message"
      for (d,q) in t.offsets do
        if result.length ≥ maxPaths then throw "generative resource limit: more than 4096 paths"
        let timed : Action := .msg i (some { t with offsets := [(d,q)] })
        result := result ++ [{ p with actions := timed :: tail, probability := Q.mul p.probability q }]
    return result
  | .valued a m =>
    checkWeights (a.outcomes.map (·.2))
    let paths ← expandStmt m
    let mut result := []
    for p in paths do
      let some (.msg i _) := p.actions.head? | throw "an amount must annotate one message"
      for (n,q) in a.outcomes do
        if result.length ≥ maxPaths then throw "generative resource limit: more than 4096 paths"
        let moved : Action := if a.reverse then Action.transfer i.dst i.src a.unit n q else Action.transfer i.src i.dst a.unit n q
        result := result ++ [{ p with actions := p.actions ++ [moved], probability := Q.mul p.probability q }]
    return result
  | .event l r => return [{ actions := [.act r l] }]
  | .clock n refs => return [{ actions := [.clock n refs] }]
  | .obligation o => return [{ actions := [.obligation o] }]
  | .choice bs => expandStmt (.weighted "" "" [] bs)
  | .weighted name actor qs bs =>
    let mut result := []
    for (b,i) in bs.zipIdx do
      let paths ← expand b
      if result.length + paths.length > maxPaths then throw "generative resource limit: more than 4096 paths"
      result := result ++ paths.map fun p => { p with
        actions := .decision name actor i ((qs[i]?).getD Q.one) :: p.actions,
        probability := Q.mul p.probability ((qs[i]?).getD Q.one), unknown := p.unknown || qs.isEmpty }
    return result
  | _ => throw "timed generation/monitoring supports finite sequential choices only; par, join, rec, sessions and include need explicit scheduling semantics"
end

structure Pending where
  spec : Obligation
  start : Nat
  satisfied : Option Nat := none

structure Schedule where
  events : Array (Event String) := #[]
  obligations : List Pending := []
  now : Nat := 0
  notTriggered : List Obligation := []
  deriving Inhabited

structure Observation where
  src : String
  dst : String
  label : String
  time : Nat
  isAct : Bool := false
  deriving Inhabited

/-- Interpret clocks/obligations using generated times or actual observed prefix times.
    Sample support never restricts observed conformance. -/
def schedule (p : Path) (roles : List String) (observed : Option (List Observation) := none) : Except String Schedule := do
  let mut env : List (String × Nat) := []
  let mut clocks : List (String × Nat) := []
  let mut pending : List Pending := []
  let mut sim : Sim.St String := { seed := 0 }
  let mut obs := observed.getD []
  let mut now := 0
  let mut stopped := false
  for action in p.actions do
    if !stopped then
      match action with
      | .decision .. | .transfer .. => pure ()
      | .clock name refs =>
        if (clocks.lookup name).isSome then throw s!"duplicate clock {name}"
        let times ← refs.mapM fun r => match env.lookup r with
          | some t => pure t | none => throw s!"clock {name} references unknown or future message {r}"
        clocks := (name, times.foldl max 0) :: clocks
      | .obligation o =>
        if pending.any (fun x => x.spec.name == o.name) then throw s!"duplicate obligation {o.name}"
        if !roles.contains o.actor then throw s!"obligation {o.name}: unknown actor {o.actor}"
        let some start := clocks.lookup o.clock | throw s!"obligation {o.name}: unknown clock {o.clock}"
        if start + o.withinMs > 9007199254740991 then throw "deadline exceeds the safe integer limit"
        pending := pending ++ [{ spec := o, start }]
      | .msg i timing =>
        if observed.isSome && obs.isEmpty then stopped := true
        else
          let mut timeAt := now
          if let some t := timing then
            let base ← if let some d := t.period then pure ((now / d + 1) * d - ((t.offsets.head?).map (·.1)).getD 0)
              else if t.relative then pure now else match t.clock with
              | some c => match clocks.lookup c with
                | some v => pure v | none => throw s!"unknown or forward clock {c}"
              | none =>
                let ts ← t.refs.mapM fun r => match env.lookup r with
                  | some v => pure v | none => throw s!"unknown or future message {r}"
                pure (ts.foldl max 0)
            timeAt := base + ((t.offsets.head?).map (·.1)).getD 0
          if observed.isSome then
            let e := obs.head!
            if e.isAct || e.src != i.src || e.dst != i.dst || e.label != i.label then throw "observed path does not match"
            timeAt := e.time; obs := obs.tail
          if timeAt < now then throw s!"{i.label}: time moves backwards before its causal prefix"
          if timeAt > 9007199254740991 then throw "timestamp exceeds the safe integer limit"
          now := timeAt
          if let some id := i.id then
            if (env.lookup id).isSome then throw s!"duplicate message id {id} in one path"
            env := (id, timeAt) :: env
          sim := { sim with clock := timeAt }
          let (_, next) := (Sim.emit 0 [] i.src i.dst i.label i.id i.cause i.route i.status false).run sim
          sim := next
          pending := pending.map fun o =>
            if o.satisfied.isNone && i.src == o.spec.actor && o.spec.labels.contains i.label && timeAt ≥ o.start then
              { o with satisfied := some timeAt } else o
      | .act role label =>
        if observed.isSome && obs.isEmpty then stopped := true
        else
          if observed.isSome then
            let e := obs.head!
            if !e.isAct || e.src != role || e.label != label then throw "observed path does not match"
            if e.time < now then throw "event time moves backwards"
            now := e.time; obs := obs.tail
          sim := { sim with clock := now }
          let (_, next) := (Sim.emit 0 [] role role label none none none none true).run sim
          sim := next
  if !obs.isEmpty then throw "extra observed events"
  let notTriggered := p.actions.filterMap fun
    | .obligation o => if pending.any (fun x => x.spec.name == o.name) then none else some o
    | _ => none
  return { events := sim.events, obligations := pending, now, notTriggered }

def reports (s : Schedule) (horizon : Nat) : List Json :=
  (s.obligations.map fun o =>
    let deadline : Nat := o.start + o.spec.withinMs
    let status := match o.satisfied with
      | some t => if t ≤ deadline then "fulfilled" else "violated"
      | none => if horizon > deadline then "violated" else "pending"
    Json.mkObj [("name", o.spec.name), ("actor", o.spec.actor), ("triggerMs", o.start),
      ("deadlineMs", deadline), ("observedUntilMs", horizon), ("satisfiedAtMs", toJson o.satisfied),
      ("status", status), ("record", if status == "violated" then Json.str o.spec.breach else Json.null),
      ("penalty", match o.spec.penalty with
        | some p => if status == "violated"
            then Json.mkObj [("quantity", p.quantity), ("unit", p.unit), ("from", o.spec.actor), ("to", p.payee)]
            else Json.null
        | none => Json.null)]) ++ s.notTriggered.map (fun o => Json.mkObj
      [("name", o.name), ("actor", o.actor), ("status", "not-triggered")])

def compile (r : Resolved) (roles : List String) : Except String (List (Path × Schedule)) := do
  let paths ← expand r.body
  let vocabulary := paths.flatMap fun p => p.actions.filterMap fun
    | .msg i _ => some (i.src, i.label)
    | _ => none
  for p in paths do
    for a in p.actions do
      if let .obligation o := a then
        if !roles.contains o.actor then throw s!"obligation {o.name}: unknown actor {o.actor}"
        if o.labels.isEmpty || o.labels.any (fun l => !vocabulary.contains (o.actor,l)) then
          throw s!"obligation {o.name}: unknown message label for actor {o.actor}"
        if let some pen := o.penalty then
          if !roles.contains pen.payee then throw s!"obligation {o.name}: the penalty goes to unknown role {pen.payee}"
  paths.mapM fun p => return (p, ← schedule p roles)

/-- Integer tickets on exact rational masses, using the same seeded LCG family as Sim. -/
def choose (qs : List Q) (seed : Nat) : Except String (Nat × Nat) := do
  let den := qs.foldl (fun d q => Nat.lcm d q.den) 1
  let mut state := seed
  for _ in [0:64] do
    let mut ticket := 0
    let mut range := 1
    while range < den do
      state := (state * 6364136223846793005 + 1442695040888963407) % 18446744073709551616
      ticket := ticket * 18446744073709551616 + state
      range := range * 18446744073709551616
    let usable := range - range % den
    if ticket < usable then
      ticket := ticket % den
      let mut cumulative := 0
      for (q,i) in qs.zipIdx do
        cumulative := cumulative + q.num * (den / q.den)
        if ticket < cumulative then return (i,state)
      throw "invalid probability mass"
  throw "weighted sampler rejection limit reached"

structure Generated where
  events : Array (Event String)
  reports : List Json

/-- Finite sessions use relative clocks; inter-session ordering is not claimed as a scheduler. -/
def generate (r : Resolved) (roles : List String) (seed instances maxEvents : Nat) : Except String Generated := do
  let paths ← compile r roles
  if paths.any (fun (p,_) => p.unknown) then throw "generative choice has no probabilities; supply an inline or external layer"
  let total := paths.foldl (fun q (p,_) => Q.add q p.probability) Q.zero
  if total != Q.one then throw "generative path mass is not 1"
  let mut rng := seed
  let mut events := #[]
  let mut out := []
  for session in [0:instances] do
    let (ix,next) ← choose (paths.map fun (p,_) => p.probability) rng
    rng := next
    let some (_,s) := paths[ix]? | throw "no generative path"
    let shift := events.size
    if shift + s.events.size > maxEvents then throw "generative event limit exceeded; reduce instances or increase maxEvents"
    events := events ++ s.events.map fun e => { e with session, id := e.id + shift, prior := e.prior.map (· + shift), cause := e.cause.map (· + shift), answers := e.answers.map (· + shift) }
    out := out ++ [Json.mkObj [("session", session), ("observedUntilMs", s.now), ("obligations", toJson (reports s s.now))]]
  return { events, reports := out }

/-- Replay one observed session, considering every structural alternative regardless of weight. -/
def monitor (r : Resolved) (roles : List String) (observed : List Observation) (horizon : Option Nat) : Except String Json := do
  let paths ← expand r.body
  let mut matching : List Schedule := []
  let mut errors := []
  for p in paths do
    match schedule p roles (some observed) with
    | .ok s => matching := matching ++ [s]
    | .error e => errors := errors ++ [e]
  let some first := matching.head? | throw (errors.headD "no matching timed path")
  let horizonAt := horizon.getD first.now
  if horizonAt < first.now then throw "observation horizon precedes the last event"
  let choices := matching.map (fun s => toJson (reports s horizonAt)) |>.eraseDups
  if choices.length > 1 then throw "observed prefix has ambiguous obligation state"
  return Json.mkObj [("observedUntilMs", horizonAt), ("obligations", choices.headD (toJson ([] : List Json)))]

end LeanFM.Session.Generative
