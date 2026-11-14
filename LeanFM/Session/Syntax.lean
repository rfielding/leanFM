import Lean
import LeanFM.Session.Global
import LeanFM.Session.Spec
import LeanFM.Session.Text
import LeanFM.Session.System

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
    | .msg i l a b cause route status guard =>
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
    | .incl p args =>
      let as := args.toArray.map fun a => (nm a : Term)
      `(LeanFM.Session.Global.box $(str p) ($(nm p) $as*) $(← gen scope rest))

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
  let value ← liftMacroM (gen [] d.body)
  let roles := d.roles.toArray.map nm
  let n := nm d.name
  elabCommand (← withRef body `($[$doc:docComment]? def $n {R : Type} ($roles* : R) : LeanFM.Session.Global R := $value))

/-- `require per q { ... }`: what each entry q must reach and by when (selfhost.session.sla). LeanFM's
tools check it against the protocol; elaborating it checks each clause. -/
@[command_elab LeanFM.Session.Grammar.requireCmd]
def elabRequire : CommandElab := fun stx => do
  let body := stx[0]
  let entry ← read (Text.name body[2] "a message id")
  for c in body[4].getArgs do
    discard <| withRef c (read (Text.requirement entry c))

/-- The roles of a protocol the `protocol` command defined: its explicit parameters, in order. -/
def protocolRoles (c : Name) : CommandElabM (List String) := do
  let info <- getConstInfo c
  let rec go : Expr -> List String
    | .forallE n _ b bi => (if bi == .default then [n.toString] else []) ++ go b
    | _ => []
  return go info.type

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

/-- A property atom naming a message by its vocabulary type, so a misspelt label is a type error:
`sent% Dup` elaborates only if `Dup` is a type. -/
syntax "sent% " ident : term
macro_rules
  | `(sent% $t:ident) => `((fun (_ : Option $t) => LeanFM.Session.Prop'.sent $(Syntax.mkStrLit t.getId.toString)) none)

end LeanFM.Session.Syntax
