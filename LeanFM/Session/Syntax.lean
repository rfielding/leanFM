import Lean
import LeanFM.Session.Global
import LeanFM.Session.Spec
import LeanFM.Session.Text
import LeanFM.Session.System
import LeanFM.Session.Versions
import LeanFM.Session.Deployment

/-- A field minted by the message that carries it: its value names a new session
(selfhost.session.identity.marks). It is the value itself; the mark is read from the text. -/
abbrev Fresh (α : Type) := α
/-- A field naming a session minted earlier, by a `Fresh` field of its name and type. -/
abbrev Link (α : Type) := α
/-- A field that travels in a header, visible without reading the body. -/
abbrev Header (α : Type) := α
/-- A field that travels as a URL path parameter. -/
abbrev PathParam (α : Type) := α
/-- A field that travels as a URL query parameter. -/
abbrev QueryParam (α : Type) := α

/-!
# The `protocol` command: a session-type file is Lean (clause selfhost.session.lean-syntax)

A `.leanfm` file is a Lean file. It starts with `import LeanFM.Session.Syntax`, declares its
message types as Lean structures, and writes its protocols with the `protocol` command;
`lake env lean File.leanfm` elaborates it.

```
import LeanFM.Session.Syntax

structure Quote where price : Nat
structure Pay where amount : Nat

protocol Purchase (Client, Shop, Bank) {
  o: Order from Client to Shop;
  choice {
    q: Quote from Shop to Client cause o;
    p: Pay   from Client to Bank cause q where p.amount = q.price;
    ...
  } or {
    SoldOut from Shop to Client cause o;
  }
}
```

There is one grammar and one reading of it. `Session.Grammar` defines the grammar with Lean's
parser combinators and registers `protocol` and `require` as Lean commands; `Session.Text` turns
the syntax into statements, with every check and limit, and unrolls bounded loops. The tools run
the same two steps on text a client sends, without elaborating it. This module elaborates the
statements of a Lean file into a `Global R` definition:

* a label is the name of a Lean type: one no structure declares is declared here as a structure
  that carries nothing, as the tools treat it;
* each `where` condition (LeanFM's condition language, `Session.Where`) is type-checked as a Lean
  proposition over the payload types of the message ids it reads, so `p.total` for a `Pay` without
  `total` is an error when the file is elaborated; conformance runs the same text over logged fields;
* the annotations of the generative and money models (amounts, times, clocks, obligations,
  accruals, `require`) are checked by the reading and do not change the global type.
-/

namespace LeanFM.Session.Syntax
open Lean Elab Command

def str (s : String) : Term := Syntax.mkStrLit s
def nm (s : String) : Ident := mkIdent (Name.mkSimple s)

/-- A condition as a Lean proposition, for type-checking only: ASCII constant names, the message
ids and their field paths as identifiers. -/
partial def condTerm : Where.Expr → MacroM Term
  | .lit (.num q) =>
    if q.den == 1 then
      if q.num < 0 then do `(Neg.neg $(Syntax.mkNumLit (toString q.num.natAbs)))
      else pure (Syntax.mkNumLit (toString q.num.natAbs))
    else `(HDiv.hDiv $(Syntax.mkNumLit (toString q.num.natAbs)) $(Syntax.mkNumLit (toString q.den)))
  | .lit (.str s) => pure (Syntax.mkStrLit s)
  | .lit (.bool b) => if b then `(true) else `(false)
  | .path x f => pure (mkIdent ((x :: f).foldl (fun n c => Name.mkStr n c) .anonymous))
  | .neg e => do `(Neg.neg $(← condTerm e))
  | .not e => do `(Not $(← condTerm e))
  | .bin op a b => do
    let x ← condTerm a
    let y ← condTerm b
    match op with
    | "or" => `(Or $x $y)
    | "and" => `(And $x $y)
    | "=" => `(Eq $x $y)
    | "!=" => `(Ne $x $y)
    | "<" => `(LT.lt $x $y)
    | "<=" => `(LE.le $x $y)
    | ">" => `(GT.gt $x $y)
    | ">=" => `(GE.ge $x $y)
    | "+" => `(HAdd.hAdd $x $y)
    | "-" => `(HSub.hSub $x $y)
    | "*" => `(HMul.hMul $x $y)
    | _ => `(HDiv.hDiv $x $y)

/-- A label as a term of type String that only elaborates if the label is a type. -/
def labelTerm (l : String) : MacroM Term := `((fun (_ : Option $(nm l)) => $(str l)) none)

/-- The global type of statements, with the message ids bound so far and their labels. -/
partial def gen (scope : List (String × String)) : List Text.Stmt → MacroM Term
  | [] => `(LeanFM.Session.Global.done)
  | s :: rest => do
    match s with
    | .timed _ m | .valued _ m => gen scope (m :: rest)
    | .accrue _ | .clock .. | .obligation _ => gen scope rest
    | .bounded .. => Macro.throwError "a bounded loop is unrolled when it is read"
    | .msg i l a b cause route status _media guard =>
      let scope' := match i with | some x => scope ++ [(x, l)] | none => scope
      let idT ← match i with | some x => `(some $(str x)) | none => `(none)
      let causeT ← match cause with | some c => `(some $(str c)) | none => `(none)
      let routeT ← match route with | some r => `(some $(str r)) | none => `(none)
      let statusT ← match status with | some n => `(some $(Syntax.mkNumLit (toString n))) | none => `(none)
      let guardT ← match guard with
        | none => `(none)
        | some text =>
          let e ← match Where.parse text with
            | .ok e => pure e
            | .error err => Macro.throwError s!"where {text}: {err}"
          -- typed over the payloads of the ids it reads, in the order they were bound
          let reads := (e.paths.map (·.1)).eraseDups
          let unknown := reads.filter fun x => !scope'.any (·.1 == x)
          if let some x := unknown.head? then
            Macro.throwError s!"where {text}: {x} is not the id of this message or an earlier one"
          let binders := scope'.filter fun (x, _) => reads.contains x
          let prop ← condTerm e
          let check ← binders.foldrM (fun (x, l) acc => `(fun ($(nm x) : $(nm l)) => $acc)) (← `(decide ($prop : Prop)))
          `(let _typed := $check; some ({ text := $(str text) } : LeanFM.Session.Guard))
      `(LeanFM.Session.Global.msg
          { id := $idT, label := $(← labelTerm l), src := $(nm a), dst := $(nm b), cause := $causeT,
            status := $statusT, route := $routeT, guard := $guardT }
          $(← gen scope' rest))
    | .event l r => `(LeanFM.Session.Global.act $(nm r) $(← labelTerm l) $(← gen scope rest))
    | .choice bs | .weighted _ _ _ bs =>
      let gs ← bs.toArray.mapM (gen scope)
      `(LeanFM.Session.Global.andThen (LeanFM.Session.Global.choice [$gs,*]) $(← gen scope rest))
    | .par bs =>
      let gs ← bs.toArray.mapM (gen scope)
      `(LeanFM.Session.Global.par [$gs,*] $(← gen scope rest))
    | .join k bs =>
      let gs ← bs.toArray.mapM (gen scope)
      `(LeanFM.Session.Global.join $(Syntax.mkNumLit (toString k)) [$gs,*] $(← gen scope rest))
    | .loop n b =>
      `(LeanFM.Session.Global.andThen (LeanFM.Session.Global.loop $(str n) $(← gen scope b)) $(← gen scope rest))
    | .cont n => `(LeanFM.Session.Global.var $(str n))
    | .sessions b => `(LeanFM.Session.Global.sessions $(← gen scope b) $(← gen scope rest))
    | .incl p args bs =>
      let as := args.toArray.map fun a => (nm a : Term)
      -- a versioned protocol is included by its newest version, Name.vN (selfhost.session.versions);
      -- the box shows the include's bindings (selfhost.session.identity.scopes)
      let shown := Global.boxName ((p.splitOn ".").headD p) bs
      `(LeanFM.Session.Global.box $(str shown) ($(mkIdent p.toName) $as*) $(<- gen scope rest))

/-- Read one command's syntax with `Session.Text`, against this file's source. -/
def read (f : Text.R α) : CommandElabM α := do
  match (f.run (← getFileMap).source).run {} with
  | .ok (v, _) => pure v
  -- Lean reports the position itself, so the reading's line and column are left out
  | .error e =>
    let msg := match e.splitOn ": " with
      | pos :: rest => if pos.startsWith "line " && (pos.splitOn ", column ").length == 2 then ": ".intercalate rest else e
      | [] => e
    throwError msg

/-- The roles of a protocol the `protocol` command defined: its explicit parameters, in order. -/
def protocolRoles (c : Name) : CommandElabM (List String) := do
  let info <- getConstInfo c
  let rec go : Expr -> List String
    | .forallE n _ b bi => (if bi == .default then [n.toString] else []) ++ go b
    | _ => []
  return go info.type

/-- The protocols a body includes, by name. -/
partial def includesOf : List Text.Stmt -> List String
  | [] => []
  | s :: rest => (match s with
      | .incl p _ _ => [p]
      | .timed _ m | .valued _ m => includesOf [m]
      | .weighted _ _ _ bs | .choice bs | .par bs | .join _ bs => bs.flatMap includesOf
      | .loop _ b | .sessions b => includesOf b
      | .bounded _ _ b o => includesOf b ++ includesOf o
      | _ => []) ++ includesOf rest

/-- The body with each include of `p` naming `target` instead. -/
partial def retarget (targets : List (Prod String String)) : List Text.Stmt -> List Text.Stmt
  | [] => []
  | s :: rest => (match s with
      | .incl p args bs => .incl ((targets.lookup p).getD p) args bs
      | .timed t m => .timed t ((retarget targets [m]).headD m)
      | .valued a m => .valued a ((retarget targets [m]).headD m)
      | .weighted n a qs bs => .weighted n a qs (bs.map (retarget targets))
      | .choice bs => .choice (bs.map (retarget targets))
      | .par bs => .par (bs.map (retarget targets))
      | .join k bs => .join k (bs.map (retarget targets))
      | .loop n b => .loop n (retarget targets b)
      | .sessions b => .sessions (retarget targets b)
      | .bounded n k b o => .bounded n k (retarget targets b) (retarget targets o)
      | other => other) :: retarget targets rest

/-- Includes look this far back for a versioned protocol's newest version. -/
def maxVersionSearched : Nat := Text.maxVersion

/-- The newest version at most `upTo` of protocol `p` defined so far, with its constant. -/
def newestVersion (p : String) (upTo : Nat) : CommandElabM (Option (Prod Nat Name)) := do
  let env <- getEnv
  let ns <- getCurrNamespace
  let mut k := upTo
  while k > 0 do
    let c := ns ++ s!"{p}.v{k}".toName
    if env.contains c then return some (k, c)
    -- a version declared in an enclosing namespace or another module, by its plain name
    let rs <- resolveGlobalName s!"{p}.v{k}".toName
    if let some (c', _) := rs.find? (fun x => x.2.isEmpty) then return some (k, c')
    k := k - 1
  return none

/-- A protocol constant applied to its own role names, evaluated: its roles and global type. -/
unsafe def evalProtocolUnsafe (c : Name) : CommandElabM (Prod (List String) (Global String)) := do
  let roles <- protocolRoles c
  let args := roles.toArray.map fun r => (str r : Term)
  let g <- liftTermElabM do
    let t <- `($(mkIdent c) $args*)
    Term.evalTerm (Global String) (mkApp (mkConst ``LeanFM.Session.Global) (mkConst ``String)) t
  return (roles, g)

@[implemented_by evalProtocolUnsafe]
opaque evalProtocol (c : Name) : CommandElabM (Prod (List String) (Global String))

/-- `protocol Name (Role, ...) { statements }` defines `Name : (roles) -> Global R` for any role
type `R`, so the same protocol can be instantiated and stacked with different roles. -/
@[command_elab LeanFM.Session.Grammar.protocolCmd]
def elabProtocol : CommandElab := fun stx => do
  let doc : Option (TSyntax ``Lean.Parser.Command.docComment) := stx[0].getOptional?.map (⟨·⟩)
  let body := stx[1]
  let d ← withRef body (read (Text.protocolDef body))
  -- a label no structure declares is a message that carries nothing
  for l in (Text.labelsOf d.body).eraseDups do
    let known ← (do let cs ← resolveGlobalName (Name.mkSimple l); pure (cs.any (·.2.isEmpty)))
    if !known then elabCommand (← `(structure $(nm l):ident))
  -- an include of a versioned protocol means its newest version
  let mut targets : List (Prod String String) := []
  for p in includesOf d.body do
    if (<- resolveGlobalName (Name.mkSimple p)).any (fun x => x.2.isEmpty) then continue
    if let some (k, _) <- newestVersion p maxVersionSearched then targets := targets ++ [(p, s!"{p}.v{k}")]
  let value <- liftMacroM (gen [] (retarget targets d.body))
  let roles := d.roles.toArray.map nm
  if d.version == 0 then
    let n := nm d.name
    elabCommand (<- withRef body `($[$doc:docComment]? def $n {R : Type} ($roles* : R) : LeanFM.Session.Global R := $value))
    return
  -- version N is Name.vN, checked against the version before it (selfhost.session.versions)
  if (<- resolveGlobalName (Name.mkSimple d.name)).any (fun x => x.2.isEmpty) then
    throwErrorAt body "protocol {d.name} is defined without a version; give every version of it a number"
  if let some (k, _) <- newestVersion d.name Text.maxVersion then
    if k >= d.version then
      throwErrorAt body "protocol {d.name} version {d.version} follows version {k}; versions go oldest first, each higher than the one before"
  let n := mkIdent s!"{d.name}.v{d.version}".toName
  let defn <- withRef body `($[$doc:docComment]? def $n {R : Type} ($roles* : R) : LeanFM.Session.Global R := $value)
  if let some (k, c) <- newestVersion d.name (d.version - 1) then
    -- the candidate is defined and evaluated in a throwaway environment; only a version with a clean
    -- upgrade path is defined, so nothing can include a refused one
    let answer <- withoutModifyingEnv do
      elabCommand defn
      let old <- evalProtocol c
      let new <- evalProtocol ((<- getCurrNamespace) ++ s!"{d.name}.v{d.version}".toName)
      pure (Versions.search old.2 new.2 old.1 new.1)
    match answer with
    | .ok (.clean _) => pure ()
    | .ok (.none why) => throwErrorAt body (Versions.refusal d.name k d.version why)
    | .error e => throwErrorAt body "{d.name} version {d.version}: the upgrade path from version {k} could not be searched: {e}"
  elabCommand defn

/-- `require per q { ... }`: what each entry q must reach and by when (selfhost.session.sla). LeanFM's
tools check it against the protocol; elaborating it checks each clause. -/
@[command_elab LeanFM.Session.Grammar.requireCmd]
def elabRequire : CommandElab := fun stx => do
  let body := stx[0]
  let entry ← read (Text.name body[2] "a message id")
  for c in body[4].getArgs do
    discard <| withRef c (read (Text.requirement entry c))

/-- `system Name { instance x : Role [serial]; accept P (fresh Role, x, ...); }` defines
`Name : LeanFM.Session.System` (selfhost.session.instances): each accept applies protocol `P` to
its own role names, so an unknown protocol is a Lean error, and the players are checked against the
roles `P` was declared with. -/
@[command_elab LeanFM.Session.Grammar.systemCmd]
def elabSystem : CommandElab := fun stx => do
  let doc : Option (TSyntax ``Lean.Parser.Command.docComment) := stx[0].getOptional?.map (⟨·⟩)
  let body := stx[1]
  -- the protocols accepted, with the roles their protocol commands declared
  let mut defs : List Text.Def := []
  let mut consts : List (Prod String Name) := []
  for a in Text.ofKind `LeanFM.Session.Grammar.acceptDecl body do
    let pid := a[1]
    let c <- withRef pid do
      let cs <- resolveGlobalName pid.getId
      match cs.find? (fun x => x.2.isEmpty) with
      | some (c, _) => pure c
      | none => throwError "accept {pid.getId}: no protocol {pid.getId} is defined"
    let p := pid.getId.toString
    if !defs.any (fun x => x.name == p) then
      defs := defs ++ [{ name := p, roles := <- protocolRoles c, body := [] }]
      consts := consts ++ [(p, c)]
  let sd <- withRef body (read (Text.systemDecl defs body))
  let shared <- sd.shared.toArray.mapM fun (n, r, s) =>
    `(({ name := $(str n), role := $(str r), serial := $(quote s) } : LeanFM.Session.Shared))
  let accepts <- sd.accepts.toArray.mapM fun (p, players) => do
    let roles := ((defs.find? (fun x => x.name == p)).map (fun x => x.roles)).getD []
    let c := (consts.lookup p).getD (Name.mkSimple p)
    let ps <- players.toArray.mapM fun (f, n) =>
      if f then `(LeanFM.Session.Player.fresh) else `(LeanFM.Session.Player.shared $(str n))
    let args := roles.toArray.map fun r => (str r : Term)
    `(({ protocolName := $(str p), roles := [$(roles.toArray.map str),*], players := [$ps,*],
         global := ($(mkIdent c) $args*) } : LeanFM.Session.Accept))
  let n := nm sd.name
  elabCommand (<- withRef body `($[$doc:docComment]? def $n : LeanFM.Session.System :=
    { name := $(str sd.name), shared := [$shared,*], accepts := [$accepts,*] }))

/-- `deployment Name of P { ... }` (selfhost.session.deployment): elaborating it checks the tree
against protocol `P` (an unknown protocol is a Lean error) and defines nothing. Every issue of
`Deployment.check` is an error at the first identifier of the block naming the role it is about: a
role unplaced or placed twice, a name that is not a role, a link no interface lets through. -/
@[command_elab LeanFM.Session.Grammar.deploymentCmd]
def elabDeployment : CommandElab := fun stx => do
  let body := stx[1]
  let pid := body[3]
  let c <- withRef pid do
    let cs <- resolveGlobalName pid.getId
    match cs.find? (fun x => x.2.isEmpty) with
    | some (c, _) => pure c
    | none => throwError "deployment {body[1].getId}: no protocol {pid.getId} is defined"
  -- a reading error names its line and column: report it there, not at the whole block
  let d <- match ((Text.deploymentDecl body).run (← getFileMap).source).run {} with
    | .ok (v, _) => pure v
    | .error e =>
      match e.splitOn ": " with
      | pos :: rest =>
        match (pos.dropPrefix? "line ").map (fun p => p.toString.splitOn ", column ") with
        | some [l, col] =>
          let here := (← getFileMap).ofPosition ⟨l.toNat!, col.toNat! - 1⟩
          throwErrorAt (Syntax.atom (SourceInfo.synthetic here here) "") (": ".intercalate rest)
        | _ => throwErrorAt body e
      | [] => throwErrorAt body e
  let (roles, g) <- evalProtocol c
  let r := Deployment.check { d with protocolName := pid.getId.toString } roles g
  let idents := Text.identsIn body[5]
  for (who, msg) in r.issues do
    logErrorAt ((idents.find? (·.getId.toString == who)).getD body[1]) msg

/-- `requirements { "name" => pointer; ... }` (selfhost.requirements.map): elaborating it checks
every name once and every protocol a pointer names, which must be defined; nothing is defined, so
the protocols mean what they meant. LeanFM's tools transform each entry into CTL and decide it. -/
@[command_elab LeanFM.Session.Grammar.requirementsCmd]
def elabRequirements : CommandElab := fun stx => do
  let body := stx[0]
  let mut seen : List String := []
  for e in body[2].getArgs do
    let n ← withRef e[0] (read (Text.reqName e[0]))
    if seen.contains n then throwErrorAt e[0] "requirement \"{n}\" is in the map twice"
    seen := n :: seen
    let a := e[2][0]
    if a.isIdent then
      withRef a do
        let cs <- resolveGlobalName a.getId
        unless cs.any (fun x => x.2.isEmpty) do throwError "requirement \"{n}\": no protocol {a.getId} is defined"
  if seen.length > Text.maxMapEntries then throwErrorAt body "a requirements map has at most {Text.maxMapEntries} entries"

/-- `implementation Name of Module { ... }` (selfhost.implementations.map): elaborating it checks its
own shape; what it names in the imported requirements is checked where a project's files are read. -/
@[command_elab LeanFM.Session.Grammar.implementationCmd]
def elabImplementation : CommandElab := fun stx => do
  discard <| withRef stx[1] (read (Text.implementationDecl stx[1]))

/-- A property atom naming a message by its vocabulary type, so a misspelt label is a type error:
`sent% Dup` elaborates only if `Dup` is a type. -/
syntax "sent% " ident : term
macro_rules
  | `(sent% $t:ident) => `((fun (_ : Option $t) => LeanFM.Session.Prop'.sent $(Syntax.mkStrLit t.getId.toString)) none)

end LeanFM.Session.Syntax
