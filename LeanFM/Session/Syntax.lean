import Lean
import LeanFM.Session.Global
import LeanFM.Session.Spec
import LeanFM.Session.Where

/-!
# Protocol syntax: a session-type file is Lean (clause selfhost.session.lean-syntax)

A `.leanfm` file is a Lean file. It starts with `import LeanFM.Session.Syntax`, declares its
message types as Lean structures, and writes its protocols with the `protocol` command defined
here; `lake env lean File.leanfm` elaborates it. LeanFM's tools read the same text without
elaborating it (`Session.Text`), and the two readings agree.

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

* A message label is the name of a Lean type. A label no structure declares is a message that
  carries nothing: the command declares `structure Label` for it before the protocol, as the text
  reading treats it. A protocol may not share its name with one of its labels (Lean would have two
  declarations with one name).
* `o:` names a message so that later ones can say `cause o` and conditions can read `o.item`.
* `route "POST /orders"` and `status 402` name the operation and the result; no rule reads them.
* `where c` is a condition in LeanFM's condition language (`and`, `or`, `not`, comparisons and
  arithmetic over the fields of named messages; `Session.Where`). The command type-checks it as a
  Lean proposition over the typed payloads, so `p.total` for a `Pay` without `total` is an error
  when the file is elaborated. Conformance runs the same text over logged fields with LeanFM's
  interpreter.
* `Timeout at Sender;` is an event at one role only; `after d` or `at next d` times it.
* `choice { } or { }`; `choice at R using declared("name") { probability 9/10: ... } or { ... }`.
* `par { } and { }`, `join 2 of { } and { }`, `rec B { ... continue B; }`, and
  `rec B at most 3 { ... continue B; } otherwise { ... }`, which is unrolled into copies exactly
  as the text reading unrolls it (copy k's ids end in `_k`).
* `sessions { ... }` and `sessions by x.field { ... }`: concurrent instances, each its own session.
* `include P A B;` stacks another protocol, written as if it were the whole thing.
* The annotations of the generative and money models (`amount ...`, `at ...`, `after ...`,
  `clock`, `obligation`, `accrue`, and the `require per q { ... }` command) are parsed here and
  read by LeanFM's tools from the text; they do not change the global type.

The words are non-reserved where Lean allows it, so importing this module takes almost no
identifiers away from Lean code; `require` is a keyword because a command must start with one.
-/

namespace LeanFM.Session.Syntax
open Lean

declare_syntax_cat sess_stmt (behavior := both)
declare_syntax_cat sess_cond (behavior := both)

syntax sess_binder := ident " : " ident
/-- A message or event label: the name of a Lean type. -/
syntax sess_label := ident

/-! ## Annotations: parsed, read from the text by LeanFM's tools -/

syntax sess_frac := num ("/" num)?
syntax sess_dur := num ident
syntax sess_dur_weight := sess_dur " : " sess_frac ";"
syntax sess_delay := (&"sample" " { " sess_dur_weight* " }") <|> sess_dur
-- `time(` is one token (the tokenizer reads it whole once any syntax names it)
syntax sess_timeref := ("time(" ident ")") <|> (&"max" "(" "time(" ident ")" ", " "time(" ident ")" ")")
syntax sess_texpr := (&"next" sess_dur) <|> ((sess_timeref <|> ident) (" + " sess_delay)?)
syntax sess_qty := ("-")? num ident
syntax sess_qty_weight := sess_qty " : " sess_frac ";"
syntax sess_amount := &"amount" ((&"sample" " { " sess_qty_weight* " }") <|> (" { " (sess_qty ";")* " }") <|> sess_qty)
syntax sess_timing := (" at " sess_texpr) <|> (&"after" sess_delay)
syntax sess_event_timing := (&"after" sess_delay) <|> (" at " &"next" sess_dur)
syntax sess_rate := ("-")? num ident &"per" (sess_dur <|> ident)

/-! ## Conditions: LeanFM's condition language, typed as Lean -/

-- `and` and `or` as words join operands at their own two levels, loosest; the symbols are operators.
-- A condition's grouping does not change its type, which is all elaboration checks.
syntax:20 sess_cond:20 " || " sess_cond:21 : sess_cond
syntax:20 sess_cond:20 " ∨ " sess_cond:21 : sess_cond
syntax:30 sess_cond:30 " && " sess_cond:31 : sess_cond
syntax:30 sess_cond:30 " ∧ " sess_cond:31 : sess_cond
syntax:40 &"not " sess_cond:40 : sess_cond
syntax:40 "!" sess_cond:40 : sess_cond
syntax:40 "¬" sess_cond:40 : sess_cond
syntax:50 sess_cond:51 " = " sess_cond:51 : sess_cond
syntax:50 sess_cond:51 " == " sess_cond:51 : sess_cond
syntax:50 sess_cond:51 " != " sess_cond:51 : sess_cond
syntax:50 sess_cond:51 " ≠ " sess_cond:51 : sess_cond
syntax:50 sess_cond:51 " < " sess_cond:51 : sess_cond
syntax:50 sess_cond:51 " <= " sess_cond:51 : sess_cond
syntax:50 sess_cond:51 " ≤ " sess_cond:51 : sess_cond
syntax:50 sess_cond:51 " > " sess_cond:51 : sess_cond
syntax:50 sess_cond:51 " >= " sess_cond:51 : sess_cond
syntax:50 sess_cond:51 " ≥ " sess_cond:51 : sess_cond
syntax:65 sess_cond:65 " + " sess_cond:66 : sess_cond
syntax:65 sess_cond:65 " - " sess_cond:66 : sess_cond
syntax:70 sess_cond:70 " * " sess_cond:71 : sess_cond
syntax:70 sess_cond:70 " / " sess_cond:71 : sess_cond
syntax:75 "-" sess_cond:75 : sess_cond
syntax ident : sess_cond
syntax num : sess_cond
syntax str : sess_cond
syntax sess_conj := sess_cond (&" and " sess_cond)*
/-- A `where` condition. -/
syntax sess_where := sess_conj (&" or " sess_conj)*
syntax "(" sess_where ")" : sess_cond

mutual
/-- A condition as a Lean proposition, for type-checking only. ASCII constant names are used so the
expansion reads the same in every font. -/
partial def condTerm (c : TSyntax `sess_cond) : MacroM Term := do
  let bin (f : Term → Term → MacroM Term) (a b : TSyntax `sess_cond) : MacroM Term := do
    f (← condTerm a) (← condTerm b)
  match c with
  | `(sess_cond| $a || $b) | `(sess_cond| $a ∨ $b) => bin (fun x y => `(Or $x $y)) a b
  | `(sess_cond| $a && $b) | `(sess_cond| $a ∧ $b) => bin (fun x y => `(And $x $y)) a b
  | `(sess_cond| not $a) | `(sess_cond| ! $a) | `(sess_cond| ¬ $a) => do `(Not $(← condTerm a))
  | `(sess_cond| $a = $b) | `(sess_cond| $a == $b) => bin (fun x y => `(Eq $x $y)) a b
  | `(sess_cond| $a != $b) | `(sess_cond| $a ≠ $b) => bin (fun x y => `(Ne $x $y)) a b
  | `(sess_cond| $a < $b) => bin (fun x y => `(LT.lt $x $y)) a b
  | `(sess_cond| $a <= $b) | `(sess_cond| $a ≤ $b) => bin (fun x y => `(LE.le $x $y)) a b
  | `(sess_cond| $a > $b) => bin (fun x y => `(GT.gt $x $y)) a b
  | `(sess_cond| $a >= $b) | `(sess_cond| $a ≥ $b) => bin (fun x y => `(GE.ge $x $y)) a b
  | `(sess_cond| $a + $b) => bin (fun x y => `(HAdd.hAdd $x $y)) a b
  | `(sess_cond| $a - $b) => bin (fun x y => `(HSub.hSub $x $y)) a b
  | `(sess_cond| $a * $b) => bin (fun x y => `(HMul.hMul $x $y)) a b
  | `(sess_cond| $a / $b) => bin (fun x y => `(HDiv.hDiv $x $y)) a b
  | `(sess_cond| - $a) => do `(Neg.neg $(← condTerm a))
  | `(sess_cond| $x:ident) => pure x
  | `(sess_cond| $n:num) => pure n
  | `(sess_cond| $s:str) => pure s
  | _ =>
    if c.raw.getNumArgs == 3 && c.raw[0].isToken "(" then whereTerm c.raw[1]
    else Macro.throwErrorAt c "not in LeanFM's condition language"

/-- `a and b or c`: the operands joined by the words. -/
partial def whereTerm (w : Syntax) : MacroM Term := do
  let conj (k : Syntax) : MacroM Term := do
    let first ← condTerm ⟨k[0]⟩
    k[1].getArgs.foldlM (fun acc p => do let t ← condTerm ⟨p[1]⟩; `(And $acc $t)) first
  let first ← conj w[0]
  w[1].getArgs.foldlM (fun acc p => do let t ← conj p[1]; `(Or $acc $t)) first
end

/-! ## Statements -/

syntax (name := sessMsg) (atomic(ident " : "))? sess_label &" from " ident &" to " ident (&" cause " ident)?
  (&" route " str)? (&" status " num)? (sess_amount)? (sess_timing)? (" where " sess_where)? ";" : sess_stmt
syntax (name := sessEvent) sess_label " at " ident (sess_event_timing)? ";" : sess_stmt
syntax (name := sessChoice) &"choice " " { " sess_stmt* " }" (&" or " " { " sess_stmt* " }")* : sess_stmt
syntax sess_wbranch := " { " (&"probability" sess_frac " : ")? sess_stmt* " }"
syntax (name := sessDeclared) &"choice " " at " ident &" using " &"declared" "(" str ")" sess_wbranch (&" or " sess_wbranch)* : sess_stmt
syntax (name := sessPar) &"par " " { " sess_stmt* " }" (&" and " " { " sess_stmt* " }")* : sess_stmt
syntax (name := sessJoin) &"join " num &" of " " { " sess_stmt* " }" (&" and " " { " sess_stmt* " }")* : sess_stmt
syntax (name := sessRec) &"rec " ident " { " sess_stmt* " }" : sess_stmt
syntax (name := sessBounded) &"rec " ident " at " &"most" num " { " sess_stmt* " }" (&" otherwise " " { " sess_stmt* " }")? : sess_stmt
syntax (name := sessSessions) &"sessions " " { " sess_stmt* " }" : sess_stmt
syntax (name := sessKeyed) &"sessions " &"by" ident " { " sess_stmt* " }" : sess_stmt
syntax (name := sessCont) " continue " ident ";" : sess_stmt
syntax (name := sessInclude) &"include " term ";" : sess_stmt
syntax (name := sessClock) &"clock " ident " = " sess_timeref ";" : sess_stmt
syntax (name := sessObligation) &"obligation " ident &" on " ident " { " &"trigger" ident ";"
  "require " ident (&" or " ident)* &" within " sess_dur ";"
  &"on" &"breach" &"record" ident (&" pays " sess_qty &" to " ident)? ";" " }" : sess_stmt
syntax (name := sessAccrue) &"accrue " ((" { " (sess_rate ";")* " }") <|> sess_rate) &" from " ident &" to " ident ";" : sess_stmt

/-- Identifiers mentioned in a condition whose first component is a bound message id. -/
partial def mentioned (ids : List Name) (s : Syntax) : List Name :=
  match s with
  | .ident _ _ n _ =>
    match n.components.head? with
    | some r => if ids.contains r then [r] else []
    | none => []
  | .node _ _ args => args.toList.flatMap (mentioned ids)
  | _ => []

def str (n : Name) : Term := Syntax.mkStrLit n.toString

/-- The source of `s` with each identifier written as its current name (a copy of an unrolled loop
renames its ids; the source positions are the original's). -/
partial def reprintNames (s : Syntax) : String :=
  match s with
  | .ident info _ n _ =>
    let (l, t) := match info with
      | .original l _ t _ => (l.toString, t.toString)
      | _ => ("", " ")
    l ++ n.toString ++ t
  | .node _ _ args => String.join (args.toList.map reprintNames)
  | other => other.reprint.getD ""

/-- The text of a condition as the text reading keeps it: whitespace runs made single spaces; in a
copy of an unrolled loop, the renamed condition as `Where` writes it (as `Text.renameIds` does). -/
def condText (c : Syntax) : String :=
  let words (t : String) : String :=
    " ".intercalate ((t.split Char.isWhitespace).toList.map (·.toString) |>.filter (· != ""))
  let original := words (c.reprint.getD "")
  let named := words (reprintNames c)
  if named == original then original
  else match Where.parse named with
    | .ok e => e.render
    | .error _ => named

/-! ## Bounded loops, unrolled on the syntax exactly as `Text.unroll` unrolls the text -/

/-- The statement kinds, to tell a block (a null node of statements) from other nodes. -/
def stmtKinds : List SyntaxNodeKind :=
  [``sessMsg, ``sessEvent, ``sessChoice, ``sessDeclared, ``sessPar, ``sessJoin, ``sessRec, ``sessBounded,
   ``sessSessions, ``sessKeyed, ``sessCont, ``sessInclude, ``sessClock, ``sessObligation, ``sessAccrue]

def isBlock (s : Syntax) : Bool :=
  s.isOfKind nullKind && s.getArgs.size > 0 && s.getArgs.all fun a => stmtKinds.contains a.getKind

/-- Apply `f` to every block inside `s`, innermost first is up to `f`. -/
partial def mapBlocks (f : Array Syntax → MacroM (Array Syntax)) (s : Syntax) : MacroM Syntax := do
  if isBlock s then return s.setArgs (← f s.getArgs)
  match s with
  | .node info k args => return .node info k (← args.mapM (mapBlocks f))
  | other => return other

/-- The ids a body declares, in any branch. -/
partial def declaredIds (s : Syntax) : List Name :=
  if s.isOfKind ``sessMsg then
    match s[0].getArgs[0]? with
    | some (Syntax.ident _ _ n _) => [n]
    | _ => []
  else match s with
    | .node _ _ args => args.toList.flatMap declaredIds
    | _ => []

/-- Rename every identifier whose first component is in `ids`. -/
partial def renameAll (ids : List Name) (sfx : String) (s : Syntax) : Syntax :=
  match s with
  | .ident info raw n pre =>
    match n.components with
    | r :: rest => if ids.contains r then
        let n' := rest.foldl Name.append (Name.mkSimple (r.toString ++ sfx))
        .ident info raw n' pre
      else s
    | [] => s
  | .node info k args => .node info k (args.map (renameAll ids sfx))
  | other => other

/-- Rename message ids, causes, conditions and time references (as `Text.renameIds`). -/
partial def renameIds (ids : List Name) (sfx : String) (s : Syntax) : Syntax :=
  if s.isOfKind ``sessMsg then
    let args := s.getArgs
    let args := args.set! 0 (renameAll ids sfx args[0]!) |>.set! 6 (renameAll ids sfx args[6]!)
      |>.set! 10 (renameIds ids sfx args[10]!) |>.set! 11 (renameAll ids sfx args[11]!)
    s.setArgs args
  else if s.isOfKind ``sess_timeref then renameAll ids sfx s
  else match s with
    | .node info k args => .node info k (args.map (renameIds ids sfx))
    | other => other

/-- Replace `continue name;` (the last statement of its block; not inside a loop of the same name)
by the statements `next`. -/
partial def splice (name : Name) (next : Array Syntax) (ss : Array Syntax) : Array Syntax :=
  ss.flatMap fun s =>
    if s.isOfKind ``sessCont && s[1].getId == name then next
    else if (s.isOfKind ``sessRec || s.isOfKind ``sessBounded) && s[1].getId == name then #[s]
    else #[inner s]
where
  inner (s : Syntax) : Syntax :=
    if isBlock s then s.setArgs (splice name next s.getArgs)
    else match s with
      | .node info k args => .node info k (args.map inner)
      | other => other

/-- Expand every bounded loop into explicit copies: copy k continues into copy k+1, and copy N
continues into the otherwise block. -/
partial def unroll (ss : Array Syntax) : MacroM (Array Syntax) := do
  let mut out := #[]
  for s in ss do
    if s.isOfKind ``sessBounded then
      let name := s[1].getId
      let n := s[4].isNatLit?.getD 1
      let body0 := s[6].getArgs
      let ids := body0.toList.flatMap declaredIds
      let body ← unroll body0
      let other ← match s[8].getArgs[2]? with
        | some b => unroll b.getArgs
        | none => pure #[]
      let rec copy (k : Nat) (fuel : Nat) : MacroM (Array Syntax) := do
        let mine := if k == 1 then body else body.map (renameIds ids s!"_{k}")
        let next ← match fuel with
          | 0 => pure other
          | f + 1 => if k ≥ n then pure other else copy (k + 1) f
        pure (splice name next mine)
      out := out ++ (← copy 1 n)
    else out := out.push (← mapBlocks unroll s)
  return out

/-! ## Elaboration to `Global` -/

/-- A declared choice is an ordinary choice; the actor it names is checked by LeanFM's tools
against the decider (`Text`), as the text reading does. -/
def declaredChoice {R : Type} (_who : R) (branches : List (LeanFM.Session.Global R)) : LeanFM.Session.Global R :=
  .choice branches

/-- Internal: statements, with the typed message ids bound so far. -/
syntax "sess% " "[" sess_binder,* "]" " { " sess_stmt* " }" : term

macro_rules
  | `(sess% [$_bs,*] { }) => `(LeanFM.Session.Global.done)

  | `(sess% [$bs,*] { $[$i:ident :]? $l:sess_label from $a:ident to $b:ident $[cause $c:ident]? $[route $rt:str]? $[status $st:num]? $[$_am:sess_amount]? $[$_tm:sess_timing]? $[where $e:sess_where]? ; $rest* }) => do
    let l : Ident := ⟨l.raw[0]⟩
    let binders : Array (Ident × Ident) := bs.getElems.map fun b => (⟨b.raw[0]⟩, ⟨b.raw[2]⟩)
    let idT ← match i with | some i => `(some $(str i.getId)) | none => `(none)
    let causeT ← match c with | some c => `(some $(str c.getId)) | none => `(none)
    let statusT ← match st with | some n => `(some $n) | none => `(none)
    let routeT ← match rt with | some r => `(some $r) | none => `(none)
    -- the condition is typed over the payloads of earlier named messages and of this one
    let scope := match i with | some i => binders.push (i, l) | none => binders
    let guardT ← match e with
      | none => `(none)
      | some e =>
        let used := (mentioned (scope.toList.map (·.1.getId)) e.raw).eraseDups
        let uses := scope.filter (fun (x, _) => used.contains x.getId)
        let prop ← whereTerm e.raw
        let check ← uses.foldrM (fun (x, ty) acc => `(fun ($x : $ty) => $acc)) (← `(decide ($prop : Prop)))
        `(let _typed := $check; some ({ text := $(Syntax.mkStrLit (condText e.raw)) } : LeanFM.Session.Guard))
    let bs' ← match i with
      | some i => pure (bs.getElems.push (← `(sess_binder| $i:ident : $l:ident)))
      | none => pure bs.getElems
    `(LeanFM.Session.Global.msg
        { id := $idT, label := (fun (_ : Option $l) => $(str l.getId)) none, src := $a, dst := $b, cause := $causeT, status := $statusT, route := $routeT, guard := $guardT }
        (sess% [$bs',*] { $rest* }))

  | `(sess% [$bs,*] { $l:sess_label at $r:ident $[$_t:sess_event_timing]? ; $rest* }) => do
    let l : Ident := ⟨l.raw[0]⟩
    `(LeanFM.Session.Global.act $r ((fun (_ : Option $l) => $(str l.getId)) none) (sess% [$bs,*] { $rest* }))

  | `(sess% [$bs,*] { choice { $s0* } $[or { $ss* }]* $rest* }) => do
    let branches ← (#[s0] ++ ss).mapM fun s => `(sess% [$bs,*] { $s* })
    `(LeanFM.Session.Global.andThen (LeanFM.Session.Global.choice [$branches,*]) (sess% [$bs,*] { $rest* }))

  | `(sess% [$bs,*] { choice at $who:ident using declared($_n:str) $b0:sess_wbranch $[or $bs'':sess_wbranch]* $rest* }) => do
    let branches ← (#[b0] ++ bs'').mapM fun b => do
      let body : TSyntaxArray `sess_stmt := b.raw[2].getArgs.map (⟨·⟩)
      `(sess% [$bs,*] { $body* })
    -- the declared actor is the one that decides
    `(LeanFM.Session.Global.andThen
        (LeanFM.Session.Syntax.declaredChoice $who [$branches,*]) (sess% [$bs,*] { $rest* }))

  | `(sess% [$bs,*] { par { $s0* } $[and { $ss* }]* $rest* }) => do
    let branches ← (#[s0] ++ ss).mapM fun s => `(sess% [$bs,*] { $s* })
    `(LeanFM.Session.Global.par [$branches,*] (sess% [$bs,*] { $rest* }))

  | `(sess% [$bs,*] { join $n:num of { $s0* } $[and { $ss* }]* $rest* }) => do
    let branches ← (#[s0] ++ ss).mapM fun s => `(sess% [$bs,*] { $s* })
    `(LeanFM.Session.Global.join $n [$branches,*] (sess% [$bs,*] { $rest* }))

  | `(sess% [$bs,*] { rec $n:ident { $body* } $rest* }) =>
    `(LeanFM.Session.Global.andThen (LeanFM.Session.Global.loop $(str n.getId) (sess% [$bs,*] { $body* }))
        (sess% [$bs,*] { $rest* }))


  | `(sess% [$bs,*] { sessions { $body* } $rest* }) =>
    `(LeanFM.Session.Global.sessions (sess% [$bs,*] { $body* }) (sess% [$bs,*] { $rest* }))

  | `(sess% [$bs,*] { sessions by $_k:ident { $body* } $rest* }) =>
    `(LeanFM.Session.Global.sessions (sess% [$bs,*] { $body* }) (sess% [$bs,*] { $rest* }))

  | `(sess% [$bs,*] { continue $n:ident ; $_rest* }) =>
    `(LeanFM.Session.Global.var $(str n.getId))

  | `(sess% [$bs,*] { include $t:term ; $rest* }) => do
    -- the included protocol becomes a named box: the name of the protocol it applies
    let name := match t with
      | `($f:ident $_*) => f.getId.toString
      | `($f:ident) => f.getId.toString
      | _ => "include"
    `(LeanFM.Session.Global.box $(Lean.quote name) $t (sess% [$bs,*] { $rest* }))

macro_rules
  | `(sess% [$bs,*] { $s:sess_stmt $rest* }) => do
    if s.raw.isOfKind ``sessBounded then
      let copies : TSyntaxArray `sess_stmt := (← unroll #[s.raw]).map (⟨·⟩)
      `(sess% [$bs,*] { $copies* $rest* })
    else if s.raw.isOfKind ``sessClock || s.raw.isOfKind ``sessObligation || s.raw.isOfKind ``sessAccrue then
      -- annotations of the generative and money models: read from the text, no change to the type
      `(sess% [$bs,*] { $rest* })
    else Macro.throwUnsupported

/-! ## The commands -/

/-- `protocol Name (Role, ...) { statements }` defines `Name : (roles) → Global R` for any role
type `R`, so the same protocol can be instantiated and stacked with different roles. -/
syntax (name := protocolCmd) (docComment)? "protocol " ident " (" ident,* ") " " { " sess_stmt* " }" : command

/-- Every label in the statements, in order. -/
partial def labels (s : Syntax) : Array Ident :=
  if s.isOfKind ``sess_label then #[⟨s[0]⟩]
  else match s with
    | .node _ _ args => args.flatMap labels
    | _ => #[]

open Elab Command in
elab_rules : command
  | `($[$doc:docComment]? protocol $n:ident ($rs,*) { $ss* }) => do
    let roles := rs.getElems
    -- distinct roles: a repeated name would silently shadow the earlier one
    for r in roles do
      if (roles.filter (·.getId == r.getId)).size > 1 then
        throwErrorAt r "role names must be distinct; {r.getId} is given twice"
    -- a label no structure declares is a message that carries nothing
    let mut seen : List Name := []
    for l in ss.flatMap (fun s => labels s.raw) do
      if seen.contains l.getId then continue
      seen := l.getId :: seen
      if l.getId == n.getId then
        throwErrorAt l "protocol {n.getId} has a message {l.getId}; in Lean they would be two declarations with one name, so rename one of them"
      let known ← (do let cs ← resolveGlobalName l.getId; pure (cs.any (·.2.isEmpty)))
      if !known then elabCommand (← `(structure $l:ident))
    elabCommand (← `($[$doc:docComment]? def $n {R : Type} ($roles* : R) : LeanFM.Session.Global R := sess% [] { $ss* }))

/-- `require per q { ... }`: what each entry q must reach and by when (selfhost.session.sla). LeanFM's
tools read it from the text; elaborating it checks only its form. -/
syntax sess_reqopt := (&"within" sess_dur) <|> (&"over" num ident) <|> (&"confidence" sess_frac) <|> (&"expecting" num &"per" ident)
syntax sess_req := ((&"every" ident &"reaches") <|> (" at " (&"least" <|> &"most") sess_frac &"of" ident &"reach")) ident,+ sess_reqopt* ";"
elab (name := requireCmd) "require " &"per" ident " { " sess_req* " }" : command => pure ()

/-- A property atom naming a message by its vocabulary type, so a misspelt label is a type error:
`sent% Dup` elaborates only if `Dup` is a type. -/
syntax "sent% " ident : term
macro_rules
  | `(sent% $t:ident) => `((fun (_ : Option $t) => LeanFM.Session.Prop'.sent $(str t.getId)) none)

end LeanFM.Session.Syntax
