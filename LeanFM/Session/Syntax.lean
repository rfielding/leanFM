import Lean
import LeanFM.Session.Global
import LeanFM.Session.Spec

/-!
# Protocol syntax

Scribble-style statements that elaborate to ordinary `Global` values:

```
protocol Purchase (Client, Shop, Bank) {
  o: Order from Client to Shop;
  choice at Shop {
    q: Quote from Shop to Client cause o;
    p: Pay   from Client to Bank cause q where p.amount = q.price;
    ...
  } or {
    SoldOut from Shop to Client cause o;
  }
}
```

* A message label is the name of a Lean type, the protocol's vocabulary; a misspelt label is
  an unknown identifier, not a new message.
* `o:` names a message so that later ones can say `cause o` and guards can read `o.item`.
* `where e` is a Lean `Bool`-valued condition over the payloads of named earlier messages; it is
  type-checked when the protocol is written and evaluated over decoded payloads at check time.
* `Timeout at Sender;` is an event at one role only.
* `choice at R { } or { }`, `par { } and { }`, `join 2 of { } and { }`, `rec B { ... continue B; }`.
* `include P A B;` stacks another protocol, written as if it were the whole thing.

The words are non-reserved, so importing this module takes no identifiers away from Lean code.
-/

namespace LeanFM.Session.Syntax
open Lean

declare_syntax_cat sess_stmt (behavior := both)
syntax sess_binder := ident " : " ident

syntax (atomic(ident " : "))? ident &" from " ident &" to " ident (&" cause " ident)? (" where " term)? ";" : sess_stmt
syntax ident " at " ident ";" : sess_stmt
syntax &"choice " " at " ident " { " sess_stmt* " }" (&" or " " { " sess_stmt* " }")* : sess_stmt
syntax &"par " " { " sess_stmt* " }" (&" and " " { " sess_stmt* " }")* : sess_stmt
syntax &"join " num &" of " " { " sess_stmt* " }" (&" and " " { " sess_stmt* " }")* : sess_stmt
syntax &"rec " ident " { " sess_stmt* " }" : sess_stmt
syntax " continue " ident ";" : sess_stmt
syntax &"include " term ";" : sess_stmt

/-- Internal: statements, with the typed message ids bound so far. -/
syntax "sess% " "[" sess_binder,* "]" " { " sess_stmt* " }" : term

/-- Identifiers mentioned in a guard whose first component is a bound message id. -/
partial def mentioned (ids : List Name) (s : Syntax) : List Name :=
  match s with
  | .ident _ _ n _ =>
    match n.components.head? with
    | some r => if ids.contains r then [r] else []
    | none => []
  | .node _ _ args => args.toList.flatMap (mentioned ids)
  | _ => []

def str (n : Name) : Term := Syntax.mkStrLit n.toString

macro_rules
  | `(sess% [$_bs,*] { }) => `(LeanFM.Session.Global.done)

  | `(sess% [$bs,*] { $[$i:ident :]? $l:ident from $a:ident to $b:ident $[cause $c:ident]? $[where $e:term]? ; $rest* }) => do
    let binders : Array (Ident × Ident) := bs.getElems.map fun b => (⟨b.raw[0]⟩, ⟨b.raw[2]⟩)
    let idT ← match i with | some i => `(some $(str i.getId)) | none => `(none)
    let causeT ← match c with | some c => `(some $(str c.getId)) | none => `(none)
    -- the guard sees the payloads of earlier named messages and of this one
    let scope := match i with | some i => binders.push (i, l) | none => binders
    let guardT ← match e with
      | none => `(none)
      | some e =>
        let used := (mentioned (scope.toList.map (·.1.getId)) e.raw).eraseDups
        let uses := scope.filter (fun (x, _) => used.contains x.getId)
        let body ← uses.foldrM (fun (x, ty) acc => `(Option.bind (Env.find env $(str x.getId) $ty) (fun $x => $acc)))
          (← `(some (decide ($e : Prop))))
        `(some { text := $(Syntax.mkStrLit ((e.raw.reprint.getD "").trimAscii.toString)),
                 eval := fun env => $body })
    let bs' ← match i with
      | some i => pure (bs.getElems.push (← `(sess_binder| $i:ident : $l:ident)))
      | none => pure bs.getElems
    `(LeanFM.Session.Global.msg
        { id := $idT, label := (fun (_ : Option $l) => $(str l.getId)) none, src := $a, dst := $b, cause := $causeT, guard := $guardT }
        (sess% [$bs',*] { $rest* }))

  | `(sess% [$bs,*] { $l:ident at $r:ident ; $rest* }) =>
    `(LeanFM.Session.Global.act $r ((fun (_ : Option $l) => $(str l.getId)) none) (sess% [$bs,*] { $rest* }))

  | `(sess% [$bs,*] { choice at $r:ident { $s0* } $[or { $ss* }]* $rest* }) => do
    let branches ← (#[s0] ++ ss).mapM fun s => `(sess% [$bs,*] { $s* })
    `(LeanFM.Session.Global.andThen (LeanFM.Session.Global.choice $r [$branches,*]) (sess% [$bs,*] { $rest* }))

  | `(sess% [$bs,*] { par { $s0* } $[and { $ss* }]* $rest* }) => do
    let branches ← (#[s0] ++ ss).mapM fun s => `(sess% [$bs,*] { $s* })
    `(LeanFM.Session.Global.par [$branches,*] (sess% [$bs,*] { $rest* }))

  | `(sess% [$bs,*] { join $n:num of { $s0* } $[and { $ss* }]* $rest* }) => do
    let branches ← (#[s0] ++ ss).mapM fun s => `(sess% [$bs,*] { $s* })
    `(LeanFM.Session.Global.join $n [$branches,*] (sess% [$bs,*] { $rest* }))

  | `(sess% [$bs,*] { rec $n:ident { $body* } $rest* }) =>
    `(LeanFM.Session.Global.andThen (LeanFM.Session.Global.loop $(str n.getId) (sess% [$bs,*] { $body* }))
        (sess% [$bs,*] { $rest* }))

  | `(sess% [$bs,*] { continue $n:ident ; $_rest* }) =>
    `(LeanFM.Session.Global.var $(str n.getId))

  | `(sess% [$bs,*] { include $t:term ; $rest* }) =>
    `(LeanFM.Session.Global.andThen $t (sess% [$bs,*] { $rest* }))

/-- `protocol Name (Role, ...) { statements }` defines `Name : (roles) → Global R` for any role
type `R`, so the same protocol can be instantiated and stacked with different roles. -/
syntax (docComment)? "protocol " ident " (" ident,* ") " " { " sess_stmt* " }" : command

macro_rules
  | `($[$doc:docComment]? protocol $n:ident ($rs,*) { $ss* }) => do
    let roles := rs.getElems
    `($[$doc:docComment]? def $n {R : Type} ($roles* : R) : LeanFM.Session.Global R := sess% [] { $ss* })

/-- A property atom naming a message by its vocabulary type, so a misspelt label is a type error:
`sent% Dup` elaborates only if `Dup` is a type. -/
syntax "sent% " ident : term
macro_rules
  | `(sent% $t:ident) => `((fun (_ : Option $t) => LeanFM.Session.Prop'.sent $(str t.getId)) none)

end LeanFM.Session.Syntax
