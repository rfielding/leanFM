import Std.Data.HashMap
import Std.Data.HashSet
import Lean.Data.Json
import LeanFM.Artifacts
import LeanFM.CallLimits
import LeanFM.LLMGenerated.SelfHosting
import LeanFM.Session.Knowledge
import LeanFM.Session.Attack
import LeanFM.Session.Reassembly

/-!
# LeanFM logic consultation (selfhost.mcp.logic.*)

Pure, path-free, deterministic logic tools for MCP agents. Formulas, tasks,
traces and predicate texts are parsed from JSON into closed data types; no
constructor carries code, a closure or a file path, so nothing submitted can
run (proof obligation: "Submitted logic never runs as code"). This module
defines no `IO` actions.

Requirement refs: clause:selfhost.mcp.logic.reference, .explain, .ctl, .trace,
.observability, .knows, .safety; property:Logic answers carry their evidence;
proof:Exhausted search never proves; proof:Hidden predicates never pass as observable.
-/

namespace LeanFM.Logic
open Lean

/-! ## Bounds -/

structure Bounds where
  maxFormulaNodes : Nat := 256
  maxDepth : Nat := 64
  maxString : Nat := 256
  maxArgumentBytes : Nat := 65536
  maxDraftStates : Nat := 8192
  maxDraftTransitions : Nat := 16384
  maxModelNodes : Nat := 4096
  maxEvents : Nat := 512
  maxConcurrentPairs : Nat := 64
  maxPredicates : Nat := 64
  /-- the truth-set bytes one evaluation may hold at once (selfhost.session.ctl-scale) -/
  maxTruthBytes : Nat := 1073741824
  /-- the bounds of a protocol's own state graph (session_ctl), whose limits have the session names -/
  session : Bool := false
deriving Repr

def bounds : Bounds := {}

/-- The sentence a refusal by bound `which` ends with: the per-call limit and how to raise it
(selfhost.mcp.limits). -/
def Bounds.hint (b : Bounds) (which : String) : String :=
  let (n, v) := match which, b.session with
    | "formula", true => ("formulaNodes", b.maxFormulaNodes)
    | "formula", false => ("ctlFormulaNodes", b.maxFormulaNodes)
    | "truth", _ => ("truthBytes", b.maxTruthBytes)
    | _, true => ("states", b.maxDraftStates)
    | "transitions", false => ("draftTransitions", b.maxDraftTransitions)
    | "model", false => ("modelNodes", b.maxModelNodes)
    | _, false => ("draftStates", b.maxDraftStates)
  "; " ++ LeanFM.CallLimits.raise n v

/-- check_ctl's bounds for one call: the defaults, changed by the call's `limits`. -/
def boundsOf (args : Json) : Bounds :=
  let g := LeanFM.CallLimits.get args
  { bounds with
    maxDraftStates := (g "draftStates")
    maxDraftTransitions := (g "draftTransitions")
    maxModelNodes := (g "modelNodes")
    maxFormulaNodes := (g "ctlFormulaNodes")
    maxTruthBytes := (g "truthBytes") }

def boundsJson (b : Bounds := bounds) : Json :=
  Json.mkObj
    [ ("maxFormulaNodes", toJson b.maxFormulaNodes), ("maxDepth", toJson b.maxDepth)
    , ("maxString", toJson b.maxString), ("maxArgumentBytes", toJson b.maxArgumentBytes)
    , ("maxDraftStates", toJson b.maxDraftStates), ("maxDraftTransitions", toJson b.maxDraftTransitions)
    , ("maxModelNodes", toJson b.maxModelNodes), ("maxEvents", toJson b.maxEvents)
    , ("maxConcurrentPairs", toJson b.maxConcurrentPairs), ("maxPredicates", toJson b.maxPredicates)
    , ("maxTruthBytes", toJson b.maxTruthBytes) ]

def terminalConvention : String :=
  "Terminal states, and non-terminal states with no outgoing transition (reported as deadlocks), " ++
  "repeat forever: they stutter on themselves, keeping the message that reached them, so every path is infinite. " ++
  "on(m), on delivery of m, holds in the state reached by delivering m, until the next message; stop holds where the conversation may stop; the initial state has no message."

/-- The words renamed to say what they mean, old to new, for every reference an agent reads
(selfhost.mcp.logic.on, selfhost.session.keywords). -/
def renamedWords : String := "## Renamed words

LeanFM's words were renamed to say what they mean. The old words are refused, each with an error
naming its replacement, so a formula or protocol written in them fails rather than meaning
something else.

| old | new | meaning |
|---|---|---|
| `par { ... } and { ... }` | `parallel { ... } and { ... }` | branches that run interleaved |
| `rec L { ... continue L; }` | `loop L { ... continue L; }` | a named loop (bounded: `loop L at most N { ... } otherwise { ... }`) |
| JSON steps `\"par\"`, `\"rec\"` | `\"parallel\"`, `\"loop\"` | the same, in the JSON protocol form |
| `(after M)`, `{\"after\": \"M\"}` | `(on M)`, `{\"on\": \"M\"}` | on delivery of M: true in the state that delivery reaches, until the next message |
| `terminal`, `\"terminal\"` | `stop`, `\"stop\"` | the conversation may stop here |
| diagram tabs `alt`, `par`, `ref` | `choice`, `parallel`, `include` | the language's own keywords |

Words that read as English stand for the CTL operators; each says whether it means some path or
every path: `possibly` (EF), `inevitably` (AF), `always` (AG), `never` (AG not), `someAlways` (EG),
`allNext`/`someNext` (AX/EX), and, infix, `allUntil`/`someUntil` (AU/EU) and `allUnless`/`someUnless`
(AW/EW). `explain_formula` answers any formula `unfolded` into the primitives."

/-! ## Formulas -/

/-- Words that read as English and unfold to one CTL primitive each (selfhost.mcp.logic.words); every
word says whether it speaks of some path or of every path. -/
inductive Word where
  | possibly | inevitably | always | someAlways | allNext | someNext | allUntil | someUntil | allUnless | someUnless
deriving Repr, Inhabited, BEq

namespace Word
def all : List Word := [.possibly, .inevitably, .always, .someAlways, .allNext, .someNext, .allUntil, .someUntil, .allUnless, .someUnless]
def name : Word → String
  | .possibly => "possibly" | .inevitably => "inevitably" | .always => "always" | .someAlways => "someAlways"
  | .allNext => "allNext" | .someNext => "someNext" | .allUntil => "allUntil" | .someUntil => "someUntil"
  | .allUnless => "allUnless" | .someUnless => "someUnless"
/-- The primitive's operator name. -/
def core : Word → String
  | .possibly => "EF" | .inevitably => "AF" | .always => "AG" | .someAlways => "EG"
  | .allNext => "AX" | .someNext => "EX" | .allUntil => "AU" | .someUntil => "EU"
  | .allUnless => "AW" | .someUnless => "EW"
def arity : Word → Nat
  | .allUntil | .someUntil | .allUnless | .someUnless => 2
  | _ => 1
def ofName? (n : String) : Option Word := all.find? (·.name == n)
/-- A word's primitive, for an operator name in the DAG (any other name is itself). -/
def coreOf (op : String) : String := ((ofName? op).map core).getD op
/-- The word LeanFM prints for a primitive operator (any other name is itself). -/
def ofCore (op : String) : String := ((all.find? (·.core == op)).map name).getD op
end Word

inductive Formula where
  | tt
  | ff
  | atState (state : String)
  | after (message : String)
  | terminal
  | field (message name value : String)
  | predicate (text : String)
  | derived (name : String)
  | unsupported (operator : String)
  /-- `actor` can derive `term` from the messages it has seen on the path to this state -/
  | knows (actor : String) (term : LeanFM.Session.Knowledge.Msg)
  /-- some role has made this claim, such as `commit(B, A)`, on the path to this state -/
  | claimed (claim : String)
  /-- the step just taken carried a secret field (a path ending in `_secr`), from `sender` to
  `receiver` and named `field` when they are given -/
  | secret (sender receiver field : Option String)
  | not (f : Formula)
  | and (fs : List Formula)
  | or (fs : List Formula)
  | implies (a b : Formula)
  | stronglyImplies (a b : Formula)
  /-- the outcomes of a choice: each can happen, and on every path one of them eventually happens -/
  | outcomes (fs : List Formula)
  /-- right after `a`, the next step is one of `bs`, each possible -/
  | follows (a : Formula) (bs : List Formula)
  /-- `a` can happen, and every `a` is eventually followed by `b` -/
  | leadsTo (a b : Formula)
  /-- `b` never happens before `a` (and need not happen) -/
  | precedes (a b : Formula)
  /-- a word that reads as English: `eventually f`, `a until b` (selfhost.mcp.logic.words) -/
  | word (w : Word) (fs : List Formula)
  | never (f : Formula)
  | ex (f : Formula)
  | ax (f : Formula)
  | ef (f : Formula)
  | af (f : Formula)
  | eg (f : Formula)
  | ag (f : Formula)
  | eu (a b : Formula)
  | au (a b : Formula)
  | ew (a b : Formula)
  | aw (a b : Formula)
deriving Repr, Inhabited, BEq

/-- The primitive a word unfolds to; a word given the wrong number of formulas (which the readers
refuse) is false. -/
def Word.apply : Word → List Formula → Formula
  | .possibly, [f] => .ef f | .inevitably, [f] => .af f | .always, [f] => .ag f | .someAlways, [f] => .eg f
  | .allNext, [f] => .ax f | .someNext, [f] => .ex f
  | .allUntil, [a, b] => .au a b | .someUntil, [a, b] => .eu a b
  | .allUnless, [a, b] => .aw a b | .someUnless, [a, b] => .ew a b
  | _, _ => .ff

namespace Formula

partial def size : Formula → Nat
  | not f | never f | ex f | ax f | ef f | af f | eg f | ag f => 1 + size f
  | and fs | or fs | outcomes fs => 1 + (fs.map size).foldl (· + ·) 0
  | follows a bs => 1 + size a + (bs.map size).foldl (· + ·) 0
  | leadsTo a b | precedes a b => 1 + size a + size b
  | word _ fs => 1 + (fs.map size).foldl (· + ·) 0
  | implies a b | stronglyImplies a b | eu a b | au a b | ew a b | aw a b => 1 + size a + size b
  | _ => 1

partial def toJson : Formula → Json
  | tt => Json.bool true
  | ff => Json.bool false
  | atState s => Json.mkObj [("at", s)]
  | after m => Json.mkObj [("on", m)]
  | terminal => "stop"
  | field m n v => Json.mkObj [("field", Json.mkObj [("message", m), ("name", n), ("value", v)])]
  | predicate t => Json.mkObj [("predicate", t)]
  | derived n => Json.mkObj [("derived", n)]
  | unsupported op => Json.mkObj [(op, Json.null)]
  | knows a t => Json.mkObj [("knows", Json.mkObj [("actor", Json.str a), ("term", LeanFM.Session.Attack.termJson t)])]
  | claimed c => Json.mkObj [("claimed", Json.str c)]
  | secret a b f => Json.mkObj [("secret", Json.mkObj ((a.toList.map (("from", Json.str ·))) ++ (b.toList.map (("to", Json.str ·))) ++ (f.toList.map (("field", Json.str ·)))))]
  | not f => Json.mkObj [("not", toJson f)]
  | and fs => Json.mkObj [("and", Json.arr (fs.map toJson).toArray)]
  | or fs => Json.mkObj [("or", Json.arr (fs.map toJson).toArray)]
  | implies a b => Json.mkObj [("implies", Json.arr #[toJson a, toJson b])]
  | stronglyImplies a b => Json.mkObj [("stronglyImplies", Json.arr #[toJson a, toJson b])]
  | outcomes fs => Json.mkObj [("outcomes", Json.arr (fs.map toJson).toArray)]
  | follows a bs => Json.mkObj [("follows", Json.arr ((a :: bs).map toJson).toArray)]
  | leadsTo a b => Json.mkObj [("leadsTo", Json.arr #[toJson a, toJson b])]
  | precedes a b => Json.mkObj [("precedes", Json.arr #[toJson a, toJson b])]
  | word w [f] => Json.mkObj [(w.name, toJson f)]
  | word w fs => Json.mkObj [(w.name, Json.arr (fs.map toJson).toArray)]
  | never f => Json.mkObj [("never", toJson f)]
  | ex f => Json.mkObj [("EX", toJson f)]
  | ax f => Json.mkObj [("AX", toJson f)]
  | ef f => Json.mkObj [("EF", toJson f)]
  | af f => Json.mkObj [("AF", toJson f)]
  | eg f => Json.mkObj [("EG", toJson f)]
  | ag f => Json.mkObj [("AG", toJson f)]
  | eu a b => Json.mkObj [("EU", Json.arr #[toJson a, toJson b])]
  | au a b => Json.mkObj [("AU", Json.arr #[toJson a, toJson b])]
  | ew a b => Json.mkObj [("EW", Json.arr #[toJson a, toJson b])]
  | aw a b => Json.mkObj [("AW", Json.arr #[toJson a, toJson b])]

def isAtomic : Formula → Bool
  | tt | ff | atState _ | after _ | terminal | field .. | predicate _ | derived _ | unsupported _ | knows .. | claimed _ | secret .. => true
  | _ => false

mutual
partial def reading : Formula → String
  | tt => "true"
  | ff => "false"
  | atState s => "the task is in state " ++ s
  | after m => m ++ " was just delivered"
  | terminal => "the conversation may stop"
  | field m n v => "the last message was " ++ m ++ " with " ++ n ++ " = " ++ v
  | predicate t => "\"" ++ t ++ "\" holds (a predicate text, not an observable event)"
  | derived n => "the derived predicate " ++ n ++ " holds"
  | unsupported op => "the " ++ op ++ " modality holds (not supported by these tools yet)"
  | knows a t => a ++ " can derive " ++ t.render
  | claimed c => "the claim " ++ c ++ " has been made"
  | secret a b f => "a secret" ++ (match f with | some x => " " ++ x | none => "") ++ " was just sent" ++
      (match a with | some x => " by " ++ x | none => "") ++ (match b with | some x => " to " ++ x | none => "")
  | not f => "it is not the case that " ++ paren f
  | and fs => " and ".intercalate (fs.map paren)
  | or fs => " or ".intercalate (fs.map paren)
  | implies a b => "if " ++ paren a ++ " then " ++ paren b
  | stronglyImplies a b => paren a ++ " can happen, and on every path, whenever " ++ paren a ++ " then " ++ paren b
  | outcomes fs => "each of these can happen, and on every path one of them eventually happens: " ++ "; ".intercalate (fs.map paren)
  | follows a bs => "on every path, whenever " ++ paren a ++ ", the next step is one of these, each possible: " ++ "; ".intercalate (bs.map paren)
  | leadsTo a b => "it is possible that eventually " ++ paren a ++ ", and on every path, whenever " ++ paren a ++ ", eventually " ++ paren b
  | precedes a b => "on every path, " ++ paren b ++ " never holds unless " ++ paren a ++ " has held at or before that point (" ++ paren b ++ " need not hold at all)"
  | word w fs => reading (w.apply fs)
  | never f => "on every path, never " ++ paren f
  | ex f => "on some path, at the next step " ++ paren f
  | ax f => "on every path, at the next step " ++ paren f
  | ef f => "it is possible that eventually " ++ paren f
  | af f => "on every path, eventually " ++ paren f
  | eg f => "on some path, always " ++ paren f
  | ag f => "on every path, always " ++ paren f
  | eu a b => "on some path, " ++ paren a ++ " holds until " ++ paren b ++ " (and " ++ paren b ++ " does happen)"
  | au a b => "on every path, " ++ paren a ++ " holds until " ++ paren b ++ " (and " ++ paren b ++ " does happen)"
  | ew a b => "on some path, " ++ paren a ++ " holds unless " ++ paren b ++ " (" ++ paren b ++ " need not happen)"
  | aw a b => "on every path, " ++ paren a ++ " holds unless " ++ paren b ++ " (" ++ paren b ++ " need not happen)"
partial def paren (f : Formula) : String :=
  if f.isAtomic then reading f else "(" ++ reading f ++ ")"
end

mutual
/-- The formula in CTL symbols, one line a person reads instead of the JSON: an after atom is its
message label, temporal operators are prefixes (AG, EF, ...) or infix (a EU b), and
parentheses appear only around a binary operand. -/
partial def symbols : Formula → String
  | tt => "true"
  | ff => "false"
  | atState s => "@" ++ s
  | after m => m
  | terminal => "stop"
  | field m n v => m ++ "." ++ n ++ " = " ++ v
  | predicate t => "\"" ++ t ++ "\""
  | derived n => n
  | unsupported op => op
  | knows a t => "K_" ++ a ++ " " ++ t.render
  | claimed c => c
  | secret a b f => "secret" ++ (match f with | some x => "(" ++ x ++ ")" | none => "") ++
      (if a.isNone && b.isNone then "" else " " ++ a.getD "" ++ "→" ++ b.getD "")
  | not f => "¬" ++ symbolsArg f
  | and fs => " ∧ ".intercalate (fs.map symbolsArg)
  | or fs => " ∨ ".intercalate (fs.map symbolsArg)
  | implies a b => symbolsArg a ++ " → " ++ symbolsArg b
  | stronglyImplies a b => symbolsArg a ++ " ⇒ " ++ symbolsArg b
  | outcomes fs => "outcomes(" ++ ", ".intercalate (fs.map symbols) ++ ")"
  | follows a bs => "follows(" ++ ", ".intercalate ((a :: bs).map symbols) ++ ")"
  | leadsTo a b => "leadsTo(" ++ symbols a ++ ", " ++ symbols b ++ ")"
  | precedes a b => "precedes(" ++ symbols a ++ ", " ++ symbols b ++ ")"
  | word w [f] => w.name ++ " " ++ symbolsArg f
  | word w [a, b] => symbolsArg a ++ " " ++ w.name ++ " " ++ symbolsArg b
  | word w fs => w.name ++ "(" ++ ", ".intercalate (fs.map symbols) ++ ")"
  | never f => "never " ++ symbolsArg f
  | ex f => "someNext " ++ symbolsArg f
  | ax f => "allNext " ++ symbolsArg f
  | ef f => "possibly " ++ symbolsArg f
  | af f => "inevitably " ++ symbolsArg f
  | eg f => "someAlways " ++ symbolsArg f
  | ag f => "always " ++ symbolsArg f
  | eu a b => symbolsArg a ++ " someUntil " ++ symbolsArg b
  | au a b => symbolsArg a ++ " allUntil " ++ symbolsArg b
  | ew a b => symbolsArg a ++ " someUnless " ++ symbolsArg b
  | aw a b => symbolsArg a ++ " allUnless " ++ symbolsArg b
/-- An operand: parenthesized only when it is a binary connective (and, or, implies). -/
partial def symbolsArg (f : Formula) : String :=
  match f with
  | and (_ :: _ :: _) | or (_ :: _ :: _) | implies .. | stronglyImplies .. | field .. | eu .. | au .. | ew .. | aw .. | word _ [_, _] => "(" ++ symbols f ++ ")"
  | _ => symbols f
end

/-- The primitives' notation, for `unfolded` only (selfhost.mcp.logic.words): an unfolded formula has
atoms, Boolean connectives and the ten CTL operators, written AG, AF, ..., a EU b. -/
partial def coreSymbols (f : Formula) : String :=
  let arg (g : Formula) : String := match g with
    | and (_ :: _ :: _) | or (_ :: _ :: _) | implies .. | eu .. | au .. | ew .. | aw .. => "(" ++ coreSymbols g ++ ")"
    | _ => coreSymbols g
  match f with
  | not g => "¬" ++ arg g
  | and fs => " ∧ ".intercalate (fs.map arg)
  | or fs => " ∨ ".intercalate (fs.map arg)
  | implies a b => arg a ++ " → " ++ arg b
  | ex g => "EX " ++ arg g | ax g => "AX " ++ arg g
  | ef g => "EF " ++ arg g | af g => "AF " ++ arg g
  | eg g => "EG " ++ arg g | ag g => "AG " ++ arg g
  | eu a b => arg a ++ " EU " ++ arg b | au a b => arg a ++ " AU " ++ arg b
  | ew a b => arg a ++ " EW " ++ arg b | aw a b => arg a ++ " AW " ++ arg b
  | g => g.symbols

/-- A function's meaning in the core operators (selfhost.mcp.logic.functions); any other formula is
itself. -/
def expand : Formula → Formula
  | outcomes fs => and (fs.map ef ++ [af (or fs)])
  | follows a bs => ag (implies a (and (bs.map ex ++ [ax (or bs)])))
  | leadsTo a b => stronglyImplies a (af b)
  | precedes a b => not (eu (not a) b)
  | word w fs => w.apply fs
  | f => f

/-- Negation pushed inward through the CTL dualities. -/
partial def negate : Formula → Formula
  | tt => ff
  | ff => tt
  | not f => f
  | and fs => or (fs.map negate)
  | or fs => and (fs.map negate)
  | implies a b => and [a, negate b]
  | stronglyImplies a b => or [ag (negate a), ef (and [a, negate b])]
  | outcomes fs => or (fs.map (fun a => ag (negate a)) ++ [eg (and (fs.map negate))])
  | f@(follows ..) | f@(leadsTo ..) | f@(precedes ..) | f@(word ..) => negate (expand f)
  | never f => ef f
  | ex f => ax (negate f)
  | ax f => ex (negate f)
  | ef f => ag (negate f)
  | af f => eg (negate f)
  | eg f => af (negate f)
  | ag f => ef (negate f)
  | au a b => ew (negate b) (and [negate a, negate b])
  | eu a b => aw (negate b) (and [negate a, negate b])
  | aw a b => eu (negate b) (and [negate a, negate b])
  | ew a b => au (negate b) (and [negate a, negate b])
  | f => not f

partial def mode : Formula → String
  | never _ => "never"
  | ag (not _) => "never"
  | ag _ => "always"
  | af _ => "eventually"
  | au .. => "eventually"
  | ef _ | ex _ | eu .. | eg _ | ew .. => "possibly"
  | stronglyImplies .. => "always (non-vacuous)"
  | outcomes _ => "eventually"
  | follows .. => "always"
  | leadsTo .. => "always (non-vacuous)"
  | precedes .. => "never"
  | word w fs => mode (w.apply fs)
  | _ => "compound"

partial def subformulas (f : Formula) : List Formula :=
  f :: match f with
    | not g | never g | ex g | ax g | ef g | af g | eg g | ag g => subformulas g
    | and fs | or fs | outcomes fs => fs.flatMap subformulas
    | follows a bs => subformulas a ++ bs.flatMap subformulas
    | leadsTo a b | precedes a b => subformulas a ++ subformulas b
    | word _ fs => fs.flatMap subformulas
    | implies a b | stronglyImplies a b | eu a b | au a b | ew a b | aw a b => subformulas a ++ subformulas b
    | _ => []

/-- Every word and function replaced by the CTL primitives it means, all the way down
(selfhost.mcp.logic.words): the plain CTL under any formula. -/
partial def unfold (f : Formula) : Formula :=
  match f.expand with
  | not g => not (unfold g)
  | and fs => and (fs.map unfold)
  | or fs => or (fs.map unfold)
  | implies a b => implies (unfold a) (unfold b)
  | stronglyImplies a b => let a' := unfold a; and [ef a', ag (implies a' (unfold b))]
  | never g => ag (not (unfold g))
  | ex g => ex (unfold g) | ax g => ax (unfold g)
  | ef g => ef (unfold g) | af g => af (unfold g)
  | eg g => eg (unfold g) | ag g => ag (unfold g)
  | eu a b => eu (unfold a) (unfold b) | au a b => au (unfold a) (unfold b)
  | ew a b => ew (unfold a) (unfold b) | aw a b => aw (unfold a) (unfold b)
  | g => g

end Formula

/-! ## Shared subformulas (selfhost.session.ctl-scale)

A formula as a DAG: each distinct subformula is one node, found through a hash table keyed by its
operator, its children's node numbers and, for an atom, the atom; the key is compared in full on a
hash match, so a collision costs a comparison and never merges two different subformulas. Node
numbers are given children first, so the node order is an evaluation order. -/

structure DagKey where
  op : String
  kids : Array Nat
  atom : String
deriving BEq, Hashable

structure Dag where
  ops : Array String := #[]
  kids : Array (Array Nat) := #[]
  atoms : Array (Option Formula) := #[]
  index : Std.HashMap DagKey Nat := {}
deriving Inhabited

namespace Dag

/-- A formula's operator, its children and, for an atom, the atom's identity. -/
def shape : Formula → String × List Formula × Option String
  | .tt => ("true", [], none)
  | .ff => ("false", [], none)
  | .not g => ("not", [g], none)
  | .never g => ("never", [g], none)
  | .ex g => ("EX", [g], none) | .ax g => ("AX", [g], none)
  | .ef g => ("EF", [g], none) | .af g => ("AF", [g], none)
  | .eg g => ("EG", [g], none) | .ag g => ("AG", [g], none)
  | .and fs => ("and", fs, none)
  | .or fs => ("or", fs, none)
  | .implies a b => ("implies", [a, b], none)
  | .stronglyImplies a b => ("stronglyImplies", [a, b], none)
  | .outcomes fs => ("outcomes", fs, none)
  | .follows a bs => ("follows", a :: bs, none)
  | .leadsTo a b => ("leadsTo", [a, b], none)
  | .precedes a b => ("precedes", [a, b], none)
  | .word w fs => (w.name, fs, none)
  | .eu a b => ("EU", [a, b], none) | .au a b => ("AU", [a, b], none)
  | .ew a b => ("EW", [a, b], none) | .aw a b => ("AW", [a, b], none)
  | f => ("atom", [], some (reprStr f))

def size (d : Dag) : Nat := d.ops.size

/-- The node for this operator over these children, made if new. -/
def intern (d : Dag) (op : String) (kids : Array Nat) (atom : Option String) (f : Option Formula) : Dag × Nat :=
  let key : DagKey := { op, kids, atom := atom.getD "" }
  match d.index.get? key with
  | some i => (d, i)
  | none =>
    let i := d.ops.size
    ({ ops := d.ops.push op, kids := d.kids.push kids, atoms := d.atoms.push (if atom.isSome then f else none),
       index := d.index.insert key i }, i)

/-- The plain definition: every path to a shared part walks it again (used only for its meaning). -/
partial def addRef (d : Dag) (f : Formula) : Dag × Nat :=
  let (op, ks, a) := shape f
  let (d, ids) := ks.foldl (fun (acc : Dag × Array Nat) k => let (d, i) := addRef acc.1 k; (d, acc.2.push i)) (d, #[])
  d.intern op ids a (some f)

/-- The same, walking each part shared in memory once: a part already seen at this address has its
node already. Equal addresses are equal formulas, so the answer is addRef's. -/
unsafe def addUnsafe (d : Dag) (f : Formula) : Dag × Nat :=
  let rec go (st : Dag × Std.HashMap USize Nat) (f : Formula) : (Dag × Std.HashMap USize Nat) × Nat :=
    let p := ptrAddrUnsafe f
    match st.2.get? p with
    | some i => (st, i)
    | none =>
      let (op, ks, a) := shape f
      let (st, ids) := ks.foldl (fun (acc : (Dag × Std.HashMap USize Nat) × Array Nat) k =>
        let (st, i) := go acc.1 k; (st, acc.2.push i)) (st, #[])
      let (d, i) := st.1.intern op ids a (some f)
      ((d, st.2.insert p i), i)
  let ((d, _), i) := go (d, {}) f
  (d, i)

@[implemented_by addUnsafe]
def add (d : Dag) (f : Formula) : Dag × Nat := addRef d f

/-- The DAG of a formula; its root is the last node. -/
def ofFormula (f : Formula) : Dag := (add {} f).1

/-- The atoms, each once. -/
def atomList (d : Dag) : List Formula := d.atoms.toList.filterMap id

/-- The longest path from the root to an atom. -/
def depth (d : Dag) : Nat := Id.run do
  let mut h : Array Nat := #[]
  for ks in d.kids do
    h := h.push (1 + ks.foldl (fun m k => max m (h[k]?.getD 0)) 0)
  return h.back?.getD 0

/-- How many nodes the formula has written out as a tree, counting no further than `cap`. -/
def treeSize (d : Dag) (cap : Nat) : Nat := Id.run do
  let mut t : Array Nat := #[]
  for ks in d.kids do
    t := t.push (min cap (1 + ks.foldl (fun m k => min cap (m + t[k]?.getD 0)) 0))
  return t.back?.getD 0

/-- A name as the s-expression reader reads it: bare when it is a plain run, quoted otherwise. -/
def nameText (s : String) : String :=
  let plain := !s.isEmpty && s.toList.all (fun c => c.isAlphanum || "_.:/@$-".toList.contains c)
    && !["stop", "true", "false"].contains s
  if plain then s else "\"" ++ (s.replace "\\" "\\\\" |>.replace "\"" "\\\"") ++ "\""

/-- The atoms' retired names, refused naming their replacements (selfhost.mcp.logic.on). -/
def retiredAfter : String := "after is now on: write (on M), read on delivery of M"
def retiredTerminal : String := "terminal is now stop: write stop, where the conversation may stop"

def atomText : Formula → String
  | .after m => s!"(on {nameText m})"
  | .atState x => s!"(at {nameText x})"
  | .claimed c => s!"(claimed {nameText c})"
  | .terminal => "stop"
  | .secret a b f => "(secret" ++ (a.map (" from " ++ nameText ·)).getD "" ++ (b.map (" to " ++ nameText ·)).getD "" ++
      (f.map (" field " ++ nameText ·)).getD "" ++ ")"
  | .unsupported op => s!"({op} stop)"
  | f => nameText (reprStr f)

/-- How many parents each node has. -/
def parentCounts (d : Dag) : Array Nat := Id.run do
  let mut parents : Array Nat := Array.replicate d.size 0
  for ks in d.kids do
    for k in ks do parents := parents.modify k (· + 1)
  return parents

/-- Node `i` on one line, threading the labels given so far (selfhost.session.ctl-sexpr). -/
partial def flatAt (d : Dag) (parents : Array Nat) (i : Nat) (labels : Std.HashMap Nat Nat) (core : Bool := false) :
    String × Std.HashMap Nat Nat :=
  match labels.get? i with
  | some n => (s!"#{n}#", labels)
  | none =>
    let op := d.ops[i]!
    let shared := (parents[i]?.getD 0) ≥ 2 && op != "atom" && op != "true" && op != "false"
    let (labels, pre) := if shared then (labels.insert i labels.size, s!"#{labels.size}=") else (labels, "")
    if op == "atom" then (pre ++ atomText (d.atoms[i]!.getD .tt), labels)
    else if op == "true" || op == "false" then (op, labels)
    else
      let (parts, labels) := (d.kids[i]!).foldl (fun (acc : Array String × Std.HashMap Nat Nat) k =>
        let (t, l) := flatAt d parents k acc.2 core; (acc.1.push t, l)) (#[], labels)
      -- every formula is written in words; the primitives only when asked for (unfolded)
      let head := if core then op else Word.ofCore op
      (pre ++ "(" ++ " ".intercalate (head :: parts.toList) ++ ")", labels)

/-- The formula as an s-expression, each part shared by two or more parents written once with a
label #n= and referred to as #n# after (selfhost.session.ctl-sexpr). -/
def toSexpr (d : Dag) (core : Bool := false) : String :=
  if d.size == 0 then "true" else (flatAt d (parentCounts d) (d.size - 1) {} core).1

/-- The column sexprPretty keeps a part within when it can (selfhost.mcp.logic.explain). -/
def sexprWidth : Nat := 72

/-- `toSexpr` laid out for reading: a part that fits in `width` columns at its indentation, with the
`close` parentheses that end its line, stays on one line; otherwise its label and operator open a line and each argument follows on its own line,
two spaces further in. The labels are threaded in the same order as `toSexpr`, so it reads back to
the same formula (selfhost.mcp.logic.explain). -/
partial def toSexprPretty (d : Dag) (width : Nat := sexprWidth) (core : Bool := false) : String :=
  if d.size == 0 then "true" else
  let parents := parentCounts d
  let rec go (i indent close : Nat) (labels : Std.HashMap Nat Nat) : String × Std.HashMap Nat Nat :=
    let (flat, after) := flatAt d parents i labels core
    let op := d.ops[i]!
    if indent + flat.length + close ≤ width || labels.contains i || op == "atom" || op == "true" || op == "false" then
      (flat, after)
    else
      let shared := (parents[i]?.getD 0) ≥ 2
      let (labels, pre) := if shared then (labels.insert i labels.size, s!"#{labels.size}=") else (labels, "")
      let pad := "".pushn ' ' (indent + 2)
      let kids := d.kids[i]!
      -- the last argument's line also carries this node's closing parenthesis and those after it
      let (body, labels) := (kids.zipIdx).foldl (fun (acc : String × Std.HashMap Nat Nat) (k, j) =>
        let (t, l) := go k (indent + 2) (if j + 1 == kids.size then close + 1 else 0) acc.2
        (acc.1 ++ "\n" ++ pad ++ t, l)) ("", labels)
      (pre ++ "(" ++ (if core then op else Word.ofCore op) ++ body ++ ")", labels)
  (go (d.size - 1) 0 0 {}).1

/-- An operator's English on one line, given its parts' texts (each parenthesized where it is not
atomic); the sentences of `Formula.reading`, with a repeated part said once ("whenever that holds"). -/
def readOp (op : String) (p : Array String) : String :=
  let part := fun (k : Nat) => p[k]?.getD "?"
  match Word.coreOf op with
  | "not" => "it is not the case that " ++ part 0
  | "never" => "on every path, never " ++ part 0
  | "EX" => "on some path, at the next step " ++ part 0
  | "AX" => "on every path, at the next step " ++ part 0
  | "EF" => "it is possible that eventually " ++ part 0
  | "AF" => "on every path, eventually " ++ part 0
  | "EG" => "on some path, always " ++ part 0
  | "AG" => "on every path, always " ++ part 0
  | "and" => " and ".intercalate p.toList
  | "or" => " or ".intercalate p.toList
  | "implies" => "if " ++ part 0 ++ " then " ++ part 1
  | "stronglyImplies" => "it is possible that eventually " ++ part 0 ++ ", and on every path, whenever that holds, " ++ part 1
  | "leadsTo" => "it is possible that eventually " ++ part 0 ++ ", and on every path, whenever that holds, eventually " ++ part 1
  | "EU" => "on some path, " ++ part 0 ++ " holds until " ++ part 1 ++ " (and it does happen)"
  | "AU" => "on every path, " ++ part 0 ++ " holds until " ++ part 1 ++ " (and it does happen)"
  | "EW" => "on some path, " ++ part 0 ++ " holds unless " ++ part 1 ++ " (which need not happen)"
  | "AW" => "on every path, " ++ part 0 ++ " holds unless " ++ part 1 ++ " (which need not happen)"
  | "outcomes" => "each of these can happen, and on every path one of them eventually happens: " ++ "; ".intercalate p.toList
  | "follows" => "on every path, whenever " ++ part 0 ++ ", the next step is one of these, each possible: " ++ "; ".intercalate (p.toList.drop 1)
  | "precedes" => "on every path, " ++ part 1 ++ " never holds unless " ++ part 0 ++ " has held at or before that point"
  | _ => op ++ "(" ++ ", ".intercalate p.toList ++ ")"

/-- An operator's clauses in the outline, one per line: the leading phrase, the parts read below it,
and whether they are a bulleted list. -/
def readClauses (op : String) (ks : Array Nat) : List (String × List Nat × Bool) :=
  let k := fun (i : Nat) => ks[i]?.toList
  match Word.coreOf op with
  | "not" => [("it is not the case that:", k 0, false)]
  | "never" => [("on every path, never:", k 0, false)]
  | "EX" => [("on some path, at the next step:", k 0, false)]
  | "AX" => [("on every path, at the next step:", k 0, false)]
  | "EF" => [("it is possible that eventually:", k 0, false)]
  | "AF" => [("on every path, eventually:", k 0, false)]
  | "EG" => [("on some path, always:", k 0, false)]
  | "AG" => [("on every path, always:", k 0, false)]
  | "and" => [("all of these:", ks.toList, true)]
  | "or" => [("at least one of these:", ks.toList, true)]
  | "implies" => [("if:", k 0, false), ("then:", k 1, false)]
  | "stronglyImplies" => [("it is possible that eventually:", k 0, false), ("and on every path, whenever that holds:", k 1, false)]
  | "leadsTo" => [("it is possible that eventually:", k 0, false), ("and on every path, whenever that holds, eventually:", k 1, false)]
  | "EU" => [("on some path, this holds:", k 0, false), ("until this does (and it does happen):", k 1, false)]
  | "AU" => [("on every path, this holds:", k 0, false), ("until this does (and it does happen):", k 1, false)]
  | "EW" => [("on some path, this holds:", k 0, false), ("unless this does (which need not happen):", k 1, false)]
  | "AW" => [("on every path, this holds:", k 0, false), ("unless this does (which need not happen):", k 1, false)]
  | "outcomes" => [("each of these can happen, and on every path one of them eventually happens:", ks.toList, true)]
  | "follows" => [("on every path, whenever:", k 0, false), ("the next step is one of these, each possible:", ks.toList.drop 1, true)]
  | "precedes" => [("on every path, this never holds:", k 1, false), ("unless this has held at or before that point:", k 0, false)]
  | _ => [(op ++ ":", ks.toList, true)]

/-- A one-part `and` or `or` says nothing its part does not: the reading goes to the part, unless the
wrapper is itself shared (reading through it twice could repeat its part). -/
partial def unwrap (d : Dag) (parents : Array Nat) (i : Nat) : Nat :=
  let o := d.ops[i]!
  if (o == "and" || o == "or") && (d.kids[i]!).size == 1 && (parents[i]?.getD 0) ≤ 1 then unwrap d parents (d.kids[i]!)[0]! else i

/-- Node `i`'s English on one line, threading labels as `flatAt` does: a part with two or more
parents is marked (#n) where it is first read, and is "the formula marked #n" after. -/
partial def readFlat (d : Dag) (parents : Array Nat) (i : Nat) (labels : Std.HashMap Nat Nat) :
    String × Std.HashMap Nat Nat :=
  match labels.get? i with
  | some n => (s!"the formula marked #{n}", labels)
  | none =>
    let op := d.ops[i]!
    if op == "atom" then ((d.atoms[i]!.getD .tt).reading, labels)
    else if op == "true" || op == "false" then (op, labels)
    else
      let (labels, pre) := if (parents[i]?.getD 0) ≥ 2 then (labels.insert i labels.size, s!"(#{labels.size}) ") else (labels, "")
      let (parts, labels) := (d.kids[i]!).foldl (fun (acc : Array String × Std.HashMap Nat Nat) k0 =>
        let k := unwrap d parents k0
        let o := d.ops[k]!
        let plain := o == "atom" || o == "true" || o == "false" || acc.2.contains k
        let (t, l) := readFlat d parents k acc.2
        (acc.1.push (if plain then t else "(" ++ t ++ ")"), l)) (#[], labels)
      (pre ++ readOp op parts, labels)

/-- The formula's English as an indented outline (readingIndented): a part whose English fits in
`width` columns at its indentation stays on one line; otherwise each clause of its operator opens
a line ending in a colon, its parts below, two spaces in, list parts bulleted. Labels as `readFlat`,
so the text grows with the distinct parts, never with the tree. -/
partial def toReadingIndented (d : Dag) (width : Nat := sexprWidth) : String :=
  if d.size == 0 then "true" else
  let parents := parentCounts d
  let rec go (i indent : Nat) (labels : Std.HashMap Nat Nat) : List String × Std.HashMap Nat Nat :=
    let (flat, after) := readFlat d parents i labels
    let op := d.ops[i]!
    if indent + flat.length ≤ width || labels.contains i || op == "atom" || op == "true" || op == "false" then
      ([flat], after)
    else
      let (labels, mark) := if (parents[i]?.getD 0) ≥ 2 then (labels.insert i labels.size, s!"(#{labels.size}) ") else (labels, "")
      let (lines, labels) := (readClauses op d.kids[i]!).foldl
        (fun (acc : List String × Std.HashMap Nat Nat) (lead, ks, bullet) =>
          let (ls, labels) := ks.foldl (fun (acc2 : List String × Std.HashMap Nat Nat) k =>
            let (kl, l) := go (unwrap d parents k) (indent + (if bullet then 4 else 2)) acc2.2
            let kl := if bullet then (match kl with | [] => [] | h :: t => ("  - " ++ h) :: t.map ("    " ++ ·))
              else kl.map ("  " ++ ·)
            (acc2.1 ++ kl, l)) ([], acc.2)
          (acc.1 ++ [lead] ++ ls, labels)) ([], labels)
      ((match lines with | [] => [] | h :: t => (mark ++ h) :: t), labels)
  "\n".intercalate (go (unwrap d parents (d.size - 1)) 0 {}).1

/-- The first atom kind the s-expression form refuses, if the formula has one. -/
def sexprBlocker (d : Dag) : Option String :=
  d.atomList.findSome? fun
    | .knows .. => some "knows" | .field .. => some "field"
    | .predicate _ => some "predicate" | .derived _ => some "derived" | _ => none

end Dag

namespace Formula
/-- The atoms of a formula, each once, walking each shared part once. -/
def atoms (f : Formula) : List Formula := (Dag.ofFormula f).atomList
end Formula

/-! ## Parsing (JSON data only) -/

def keyValues (j : Json) : List (String × Json) :=
  match j with
  | .obj kvs => kvs.toList
  | _ => []

def str? (j : Json) : Option String := (j.getStr?).toOption

def checkString (what s : String) : Except String String :=
  if s.length > bounds.maxString then .error s!"{what} is longer than {bounds.maxString} characters"
  else if s.isEmpty then .error s!"{what} is empty"
  else .ok s

/-! ### Symbolic terms (decision logic-knows) -/

section Terms
open LeanFM.Session.Knowledge

/-- A term from JSON: one key per object, within the formula bounds. -/
partial def parseTerm (depth : Nat) (j : Json) : Except String Msg := do
  if depth > bounds.maxDepth then throw s!"a term is nested deeper than {bounds.maxDepth}"
  match j with
  | .obj kvs =>
    match kvs.toList with
    | [(k, v)] =>
      let name := fun (what : String) => match str? v with
        | some n => checkString what n
        | none => .error s!"{what} names are strings"
      match k with
      | "atom" => return .atom (← name "atom")
      | "key" => return .key (← name "key")
      | "pk" => return .pk (← name "pk")
      | "sk" => return .sk (← name "sk")
      | "hash" => return .hash (← parseTerm (depth + 1) v)
      | "pair" => match v with
        | .arr #[a, b] => return .pair (← parseTerm (depth + 1) a) (← parseTerm (depth + 1) b)
        | _ => throw "pair takes exactly two terms"
      | "tuple" => match v with
        | .arr items =>
          if items.size < 2 then throw "tuple takes two or more terms"
          let ts ← items.toList.mapM (parseTerm (depth + 1))
          return (ts.dropLast.foldr (fun t acc => Msg.pair t acc) ts.getLast!)
        | _ => throw "tuple takes an array of terms"
      | "enc" =>
        let key ← match (v.getObjVal? "key").toOption with
          | some kj => parseTerm (depth + 1) kj
          | none => throw "enc needs a key"
        let body ← match (v.getObjVal? "body").toOption with
          | some bj => parseTerm (depth + 1) bj
          | none => throw "enc needs a body"
        return .enc key body
      | other => throw s!"unknown term constructor {other.take 40}; use atom, key, pk, sk, pair, tuple, enc or hash"
    | _ => throw "a term is an object with exactly one key"
  | _ => throw "a term is an object such as {\"atom\": \"na\"}"

def boundedTerm (j : Json) : Except String Msg := do
  let t ← parseTerm 0 j
  if t.size > bounds.maxFormulaNodes then throw s!"a term has {t.size} nodes; the bound is {bounds.maxFormulaNodes}"
  return t

end Terms

def pathOperatorHint (op : String) : Option String :=
  match op with
  | "F" | "eventually" | "<>" => some "F is a path operator; say which paths: inevitably (AF, on every path) or possibly (EF, on some path)"
  | "G" | "[]" => some "G is a path operator; say which paths: always (AG, on every path) or someAlways (EG, on some path)"
  | "X" | "next" => some "X is a path operator; say which paths: allNext (AX) or someNext (EX)"
  | "U" | "until" => some "U is a path operator; say which paths: allUntil (AU) or someUntil (EU), or allUnless/someUnless (AW/EW) when the right side need not happen"
  | "W" | "unless" => some "W is a path operator; say which paths: allUnless (AW) or someUnless (EW)"
  | _ => none

def unsupportedOperators : List String :=
  ["K", "O", "obliged", "obligatory", "P", "permitted", "B", "believes", "Pr", "probability", "C", "common"]

/-! ### S-expressions (selfhost.session.ctl-sexpr)

The reader is data only: there is no read-time evaluation and no # form but #n= and #n#. A label is
defined when its expression is complete, so a reference inside its own expression is to a label not
yet defined, refused: no cycle can be written. -/

inductive SexprTok | lp | rp | name (s : String) | define (n : Nat) | ref (n : Nat)
deriving Repr, BEq, Inhabited

def sexprTokens (s : String) : Except String (Array SexprTok) := do
  let cs := s.toList.toArray
  let mut out : Array SexprTok := #[]
  let mut i := 0
  let plain := fun (c : Char) => c.isAlphanum || "_.:/@$-".toList.contains c
  while i < cs.size do
    let c := cs[i]!
    if c.isWhitespace then i := i + 1
    else if c == '(' then out := out.push .lp; i := i + 1
    else if c == ')' then out := out.push .rp; i := i + 1
    else if c == '#' then
      let mut j := i + 1
      let mut n := 0
      while j < cs.size && cs[j]!.isDigit do
        n := n * 10 + (cs[j]!.toNat - '0'.toNat); j := j + 1
      if j == i + 1 || j >= cs.size || n > 1000000 then throw "a # form is #n= or #n#, with n a number"
      if cs[j]! == '=' then out := out.push (.define n)
      else if cs[j]! == '#' then out := out.push (.ref n)
      else throw "a # form is #n= or #n#; there is no other # syntax (nothing is evaluated when read)"
      i := j + 1
    else if c == '"' then
      let mut j := i + 1
      let mut acc := ""
      let mut closed := false
      while j < cs.size && !closed do
        let d := cs[j]!
        if d == '\\' then
          if j + 1 >= cs.size then throw "a quoted name ends inside an escape"
          acc := acc.push cs[j+1]!; j := j + 2
        else if d == '"' then closed := true; j := j + 1
        else acc := acc.push d; j := j + 1
      if !closed then throw "a quoted name is not closed"
      out := out.push (.name acc); i := j
    else if plain c then
      let mut j := i
      while j < cs.size && plain cs[j]! do j := j + 1
      out := out.push (.name (String.mk (cs.extract i j).toList)); i := j
    else throw s!"unexpected character {c.quote} in an s-expression formula"
  return out

structure SexprState where
  pos : Nat := 0
  labels : Std.HashMap Nat Formula := {}
  nodes : Nat := 0

/-- One formula from the tokens at `pos`; `depth` is the nesting so far. -/
partial def sexprFormula (ts : Array SexprTok) (b : Bounds) (depth : Nat) : StateT SexprState (Except String) Formula := do
  if depth > b.maxDepth then throw s!"formula nesting exceeds depth {b.maxDepth}"
  let st ← get
  let next := fun () => do let st ← get; set { st with pos := st.pos + 1 }; pure (ts[st.pos]?)
  -- reading is linear in the text, which is bounded; the size bounds are applied to the formula
  -- read (parseShared counts distinct subformulas, parseBounded tree nodes)
  let count := fun () => (pure () : StateT SexprState (Except String) Unit)
  match ts[st.pos]? with
  | some (.define n) =>
    let _ ← next ()
    if (← get).labels.contains n then throw s!"label #{n}= is defined twice"
    let f ← sexprFormula ts b depth
    modify fun st => { st with labels := st.labels.insert n f }
    return f
  | some (.ref n) =>
    let _ ← next ()
    match (← get).labels.get? n with
    | some f => return f
    | none => throw s!"#{n}# refers to a label not yet defined (a label is defined when its expression is complete)"
  | some (.name "stop") => let _ ← next (); count (); return .terminal
  | some (.name "terminal") => throw Dag.retiredTerminal
  | some (.name "true") => let _ ← next (); count (); return .tt
  | some (.name "false") => let _ ← next (); count (); return .ff
  | some (.name x) => throw s!"bare name {(x.take 40).toString} is not a formula; write (on {(x.take 40).toString}), (at {(x.take 40).toString}) or stop"
  | some .rp => throw "unexpected ) in an s-expression formula"
  | none => throw "the s-expression formula ends early"
  | some .lp =>
    let _ ← next ()
    count ()
    let op ← match ← next () with
      | some (.name o) => pure o
      | _ => throw "( must be followed by an operator name"
    let rec args (acc : Array Formula) : StateT SexprState (Except String) (Array Formula) := do
      match ts[(← get).pos]? with
      | some .rp => let _ ← next (); return acc
      | none => throw s!"({op} is not closed"
      | _ => args (acc.push (← sexprFormula ts b (depth + 1)))
    let nameArg := fun () => do
      let x ← match ← next () with
        | some (.name x) => checkString op x
        | _ => throw s!"{op} takes a name"
      match ← next () with
      | some .rp => pure x
      | _ => throw s!"{op} takes exactly one name"
    match op with
    | "on" => return .after (← nameArg ())
    | "after" => throw Dag.retiredAfter
    | "at" => return .atState (← nameArg ())
    | "claimed" => return .claimed (← nameArg ())
    | "secret" =>
      let rec kv (fr to fi : Option String) : StateT SexprState (Except String) Formula := do
        match ← next () with
        | some .rp => return .secret fr to fi
        | some (.name k) =>
          let v ← match ← next () with
            | some (.name v) => checkString ("secret." ++ k) v
            | _ => throw s!"secret {k} takes a name"
          match k with
          | "from" => kv (some v) to fi
          | "to" => kv fr (some v) fi
          | "field" => kv fr to (some v)
          | _ => throw s!"secret takes only from, to and field, not {(k.take 40).toString}"
        | _ => throw "secret takes from, to and field followed by names"
      kv none none none
    | "knows" | "field" | "predicate" | "derived" =>
      throw s!"{op} has structure the s-expression form does not carry; write it in the JSON form"
    | _ =>
      let xs ← args #[]
      let need := fun (k : Nat) => if xs.size == k then pure () else throw s!"{op} takes {k} formula{if k == 1 then "" else "s"}"
      match op with
      | "not" => need 1; return .not xs[0]!
      | "never" => need 1; return .never xs[0]!
      | "EX" => need 1; return .ex xs[0]! | "AX" => need 1; return .ax xs[0]!
      | "EF" => need 1; return .ef xs[0]! | "AF" => need 1; return .af xs[0]!
      | "EG" => need 1; return .eg xs[0]! | "AG" => need 1; return .ag xs[0]!
      | "and" => if xs.isEmpty then throw "and needs at least one formula" else return .and xs.toList
      | "or" => if xs.isEmpty then throw "or needs at least one formula" else return .or xs.toList
      | "implies" => need 2; return .implies xs[0]! xs[1]!
      | "stronglyImplies" => need 2; return .stronglyImplies xs[0]! xs[1]!
      | "outcomes" => if xs.size < 2 then throw "outcomes needs at least two formulas" else return .outcomes xs.toList
      | "follows" => if xs.size < 2 then throw "follows needs a formula and at least one next formula" else return .follows xs[0]! (xs.toList.drop 1)
      | "leadsTo" => need 2; return .leadsTo xs[0]! xs[1]!
      | "precedes" => need 2; return .precedes xs[0]! xs[1]!
      | "EU" => need 2; return .eu xs[0]! xs[1]! | "AU" => need 2; return .au xs[0]! xs[1]!
      | "EW" => need 2; return .ew xs[0]! xs[1]! | "AW" => need 2; return .aw xs[0]! xs[1]!
      | other =>
        if let some w := Word.ofName? other then
          need w.arity
          -- a word is its primitive; LeanFM writes every primitive as its word (selfhost.mcp.logic.words)
          return w.apply xs.toList
        if unsupportedOperators.contains other then return .unsupported other
        match pathOperatorHint other with
        | some hint => throw ("typing error: " ++ hint)
        | none => throw s!"unknown operator \"{(other.take 40).toString}\"; see leanfm://language/logic-reference"

/-- A formula written as an s-expression, with the caller's bounds. -/
def parseSexpr (s : String) (b : Bounds := bounds) : Except String Formula := do
  if s.length > b.maxArgumentBytes then throw s!"formula text exceeds {b.maxArgumentBytes} bytes"
  let ts ← sexprTokens s
  let (f, st) ← (sexprFormula ts b 0).run {}
  if st.pos != ts.size then throw "text follows the formula"
  return f

partial def parseFormula (j : Json) (depth : Nat := 0) (bnd : Bounds := bounds) : Except String Formula := do
  if depth > bnd.maxDepth then throw s!"formula nesting exceeds depth {bnd.maxDepth}"
  match j with
  | .bool true => return .tt
  | .bool false => return .ff
  | .str "stop" => return .terminal
  | .str "terminal" => throw Dag.retiredTerminal
  | .str "true" => return .tt
  | .str "false" => return .ff
  | .str s =>
    let t := s.trimAscii.toString
    if t.startsWith "(" || t.startsWith "#" then parseSexpr s bnd else
    throw ("bare string \"" ++ (s.take 40).toString ++ "\" is not a formula; write {\"at\": state}, {\"on\": message} or \"stop\"")
  | .obj _ =>
    match keyValues j with
    | [(op, arg)] =>
      let one := fun (k : Formula → Formula) => do return k (← parseFormula arg (depth + 1) bnd)
      let two := fun (k : Formula → Formula → Formula) => do
        match arg with
        | .arr #[a, b] => return k (← parseFormula a (depth + 1) bnd) (← parseFormula b (depth + 1) bnd)
        | _ => throw s!"{op} takes an array of exactly two formulas"
      let many := fun (k : List Formula → Formula) => do
        match arg with
        | .arr items =>
          if items.isEmpty then throw s!"{op} needs at least one formula"
          return k (← items.toList.mapM (parseFormula · (depth + 1) bnd))
        | _ => throw s!"{op} takes an array of formulas"
      let atomStr := fun (k : String → Formula) => do
        match str? arg with
        | some s => return k (← checkString op s)
        | none => throw s!"{op} takes a string"
      match op with
      | "at" => atomStr .atState
      | "on" => atomStr .after
      | "after" => throw Dag.retiredAfter
      | "predicate" => atomStr .predicate
      | "derived" => atomStr .derived
      | "claimed" => atomStr .claimed
      | "knows" =>
        let actor ← match (arg.getObjVal? "actor").toOption.bind str? with
          | some a => checkString "knows.actor" a
          | none => throw "knows needs a string actor"
        let term ← match (arg.getObjVal? "term").toOption with
          | some t => boundedTerm t
          | none => throw "knows needs a term"
        return .knows actor term
      | "secret" =>
        match arg with
        | .obj kvs =>
          if let some (k, _) := kvs.toList.find? (fun (k, _) => !["from", "to", "field"].contains k) then
            throw s!"secret takes only from, to and field, not {k.take 40}"
          let opt := fun (k : String) => do
            match (arg.getObjVal? k).toOption with
            | none => pure none
            | some v => match str? v with
              | some x => some <$> checkString ("secret." ++ k) x
              | none => throw s!"secret.{k} is a string"
          return .secret (← opt "from") (← opt "to") (← opt "field")
        | _ => throw "secret takes an object {from?, to?, field?}; {} means any secret"
      | "field" =>
        let get := fun (k : String) => match (arg.getObjVal? k).toOption.bind str? with
          | some v => checkString ("field." ++ k) v
          | none => .error s!"field needs a string {k}"
        return .field (← get "message") (← get "name") (← get "value")
      | "not" => one .not
      | "never" => one .never
      | "EX" => one .ex | "AX" => one .ax | "EF" => one .ef | "AF" => one .af
      | "EG" => one .eg | "AG" => one .ag
      | "and" => many .and
      | "or" => many .or
      | "implies" => two .implies
      | "stronglyImplies" => two .stronglyImplies
      | "outcomes" => do
        let f ← many .outcomes
        match f with
        | .outcomes (_ :: _ :: _) => return f
        | _ => throw "outcomes needs at least two formulas"
      | "follows" => do
        match ← many .and with
        | .and (a :: b :: bs) => return .follows a (b :: bs)
        | _ => throw "follows needs a formula and at least one next formula"
      | "leadsTo" => two .leadsTo
      | "precedes" => two .precedes
      | "EU" => two .eu | "AU" => two .au | "EW" => two .ew | "AW" => two .aw
      | other =>
        if let some w := Word.ofName? other then
          match w.arity with
          | 1 => return ← one (fun f => w.apply [f])
          | _ => return ← two (fun a b => w.apply [a, b])
        if unsupportedOperators.contains other then return .unsupported other
        match pathOperatorHint other with
        | some hint => throw ("typing error: " ++ hint)
        | none => throw s!"unknown operator \"{other.take 40}\"; see leanfm://language/logic-reference"
    | [] => throw "empty object is not a formula"
    | _ => throw "a formula object has exactly one operator key"
  | _ => throw "a formula is a JSON object, true, false or \"stop\""

/-- A formula a tool writes back out as a tree (explain_formula, classify_requirement and the other
logic tools): at most maxFormulaNodes nodes as a tree, with the caller's bounds. -/
def parseBounded (j : Json) (b : Bounds := bounds) : Except String Formula := do
  let f ← parseFormula j 0 b
  let n := (Dag.ofFormula f).treeSize (b.maxFormulaNodes + 1)
  if n > b.maxFormulaNodes then
    throw s!"formula has {if n > b.maxFormulaNodes then s!"more than {b.maxFormulaNodes}" else toString n} nodes; the bound is {b.maxFormulaNodes}{b.hint "formula"}"
  return f

/-- A formula check_ctl decides (and session_ctl through it): at most maxFormulaNodes distinct
subformulas, however large it would be as a tree (selfhost.session.ctl-scale). -/
def parseShared (j : Json) (b : Bounds := bounds) : Except String Formula := do
  let f ← parseFormula j 0 b
  let n := (Dag.ofFormula f).size
  if n > b.maxFormulaNodes then
    throw s!"formula has {n} distinct subformulas; the bound is {b.maxFormulaNodes}{b.hint "formula"}"
  return f

/-! ## Task models -/

structure Transition where
  src : String
  dst : String
  message : String
  sender : Option String := none
  receiver : Option String := none
  /-- the message as a symbolic term, for knowledge atoms -/
  term : Option LeanFM.Session.Knowledge.Msg := none
  /-- a claim this transition makes, for `claimed` atoms -/
  claim : Option String := none
  /-- the secret field paths its message carries, for `secret` atoms -/
  secrets : List String := []
deriving Repr, Inhabited

structure TaskModel where
  id : String
  states : List String
  initial : String
  terminals : List String
  transitions : List Transition
  canonical : Bool
  /-- actors whose knowledge the model tracks: name, initial terms, and whether they see every
  channel (a network attacker) rather than only transitions they send or receive -/
  knowers : List (String × List LeanFM.Session.Knowledge.Msg × Bool) := []
deriving Repr, Inhabited

def canonicalTasks : List TaskRequirement := LeanFM.LLMGenerated.SelfHosting.spec.tasks
def canonicalMessages : List MessageSchema := LeanFM.LLMGenerated.SelfHosting.spec.messages

def ofRequirement (t : TaskRequirement) : TaskModel :=
  { id := t.id, states := t.states.map (·.id), initial := t.initialState
  , terminals := (t.states.filter (·.terminal)).map (·.id)
  , transitions := t.transitions.map fun tr => { src := tr.src, dst := tr.dst, message := tr.message }
  , canonical := true }

def strings (j : Json) (what : String) (limit : Nat) : Except String (List String) := do
  match j with
  | .arr items =>
    if items.size > limit then throw s!"{what} has {items.size} entries; the bound is {limit}"
    items.toList.mapM fun item => match str? item with
      | some s => checkString what s
      | none => .error s!"{what} entries are strings"
  | _ => throw s!"{what} is an array of strings"

def parseDraft (j : Json) (b : Bounds := bounds) : Except String TaskModel := do
  let field := fun (k : String) => (j.getObjVal? k).toOption
  let states ← (strings ((field "states").getD (Json.arr #[])) "states" b.maxDraftStates).mapError (· ++ b.hint "states")
  if states.isEmpty then throw "a draft task needs states"
  let initial ← match (field "initial").bind str? with
    | some s => pure s
    | none => throw "a draft task needs a string initial state"
  let terminals ← strings ((field "terminals").getD (Json.arr #[])) "terminals" b.maxDraftStates
  let transitions ← match field "transitions" with
    | some (.arr items) =>
      if items.size > b.maxDraftTransitions then
        throw s!"draft has {items.size} transitions; the bound is {b.maxDraftTransitions}{b.hint "transitions"}"
      items.toList.mapM fun t => do
        let g := fun (k : String) => match (t.getObjVal? k).toOption.bind str? with
          | some v => checkString ("transition." ++ k) v
          | none => .error s!"each transition needs a string {k}"
        let opt := fun (k : String) => (t.getObjVal? k).toOption.bind str?
        let term ← match (t.getObjVal? "term").toOption with
          | some tj => some <$> boundedTerm tj
          | none => pure none
        let claim ← match opt "claim" with
          | some c => some <$> checkString "transition.claim" c
          | none => pure none
        let secrets ← match (t.getObjVal? "secrets").toOption with
          | some j => strings j "transition.secrets" b.maxPredicates
          | none => pure []
        let tr : Transition := { src := ← g "src", dst := ← g "dst", message := ← g "message"
                               , sender := opt "from", receiver := opt "to", term, claim, secrets }
        return tr
    | some _ => throw "transitions is an array"
    | none => pure []
  let declared : Std.HashSet String := states.foldl (·.insert ·) {}
  let unknown := ([initial] ++ terminals ++ transitions.flatMap (fun t => [t.src, t.dst])).filter (!declared.contains ·)
  if let some s := unknown.head? then throw s!"draft refers to undeclared state \"{s}\""
  let knowers ← match field "knowledge" with
    | some (.obj kvs) =>
      if kvs.size > b.maxPredicates then throw s!"knowledge declares {kvs.size} actors; the bound is {b.maxPredicates}"
      kvs.toList.mapM fun (actor, decl) => do
        let actor ← checkString "knowledge actor" actor
        let initial ← match (decl.getObjVal? "initial").toOption with
          | some (.arr items) =>
            if items.size > b.maxPredicates then throw s!"{actor}'s initial knowledge has {items.size} terms; the bound is {b.maxPredicates}"
            items.toList.mapM boundedTerm
          | some _ => throw "initial is an array of terms"
          | none => pure []
        let seesAll := match (decl.getObjVal? "seesAll").toOption with | some (.bool b) => b | _ => false
        return (actor, initial, seesAll)
    | some _ => throw "knowledge maps each actor to {initial, seesAll}"
    | none => pure []
  if (field "secrets").isSome then
    throw "a draft marks no secrets in a list: name each secret with _secr (nb_secr), and knows asks about it by that name"
  let id := ((field "id").bind str?).getD "draft"
  return { id, states, initial, terminals, transitions, canonical := false, knowers }

def resolveTask (j : Json) (b : Bounds := bounds) : Except String TaskModel :=
  match j with
  | .str id => match canonicalTasks.find? (·.id == id) with
    | some t => .ok (ofRequirement t)
    | none => .error s!"unknown canonical task \"{id.take 60}\"; known tasks: {", ".intercalate (canonicalTasks.map (·.id))}"
  | .obj _ => parseDraft j b
  | _ => .error "task is a canonical task id string or an inline draft object"

def TaskModel.messages (t : TaskModel) : List String := (t.transitions.map (·.message)).eraseDups

/-- A name ending in _secr, a session copy (`na_secr#2`) included. -/
def markedName (n : String) : Bool := ((n.splitOn "#").headD n).endsWith "_secr"

/-- Whether a knows atom may ask about `v`: it carries an atom or key whose name ends in _secr, the only
mark (selfhost.mcp.logic.secrets). -/
partial def termMarked (v : LeanFM.Session.Knowledge.Msg) : Bool :=
  let rec names : LeanFM.Session.Knowledge.Msg → List String
    | .atom n | .key n => [n]
    | .pk _ | .sk _ => []
    | .pair a b | .enc a b => names a ++ names b
    | .hash b => names b
  (names v).any markedName

/-- Whether a secret field path is the one a secret atom names: the whole path, or its last segment. -/
def secretPathNames (field path : String) : Bool :=
  path == field || path.endsWith ("." ++ field)

def unknownAtoms (t : TaskModel) (f : Formula) : List String :=
  (f.atoms.filterMap fun
    | .atState s => if t.states.contains s then none else some ("unknown state " ++ s)
    | .after m => if t.messages.contains m then none else some ("unknown message " ++ m ++ " for task " ++ t.id)
    | .field m _ _ => if t.messages.contains m then none else some ("unknown message " ++ m ++ " for task " ++ t.id)
    | .claimed c => if t.transitions.any (·.claim == some c) then none
        else some ("no transition of task " ++ t.id ++ " makes the claim " ++ c)
    | .knows a v => if !t.knowers.any (·.1 == a) then
          some ("actor " ++ a ++ " has no declared knowledge in task " ++ t.id ++ "; add it to the draft's knowledge field")
        -- asking whether an actor knows a term is a secrecy question; marking the term asks it
        else if termMarked v then none
        else some ("knows asks about " ++ v.render ++ ", which is not marked secret: name it with _secr (" ++
          (match v with | .atom n | .key n => n ++ "_secr" | _ => "a name inside it") ++ "), the only way to mark a secret, then ask")
    | .secret a b f =>
      let carrying := t.transitions.filter (!·.secrets.isEmpty)
      if carrying.isEmpty then some ("no transition of task " ++ t.id ++ " carries a secret field (a field path ending in _secr), so a secret atom would hold nowhere")
      else if let some x := f.filter (fun x => !carrying.any (·.secrets.any (secretPathNames x))) then
        some ("no transition of task " ++ t.id ++ " carries a secret field " ++ x)
      -- a role that exists but never handles a secret is a question the check answers, not an error
      else if let some x := (a.toList ++ b.toList).find? (fun x => !t.transitions.any (fun tr => tr.sender == some x || tr.receiver == some x)) then
        some ("task " ++ t.id ++ " has no role " ++ x ++ " (no transition sends or receives as " ++ x ++ ")")
      else none
    | _ => none).eraseDups

/-! ## Kripke structure -/

structure Node where
  state : String
  message : Option String
  /-- each declared knower's knowledge, taken apart and kept in one order, so that nodes reached
  with different knowledge stay different -/
  knowledge : List (List LeanFM.Session.Knowledge.Msg) := []
  /-- the claims made on the path here, in one order -/
  claims : List String := []
  /-- the step that reached this node: its sender, receiver and the secret paths it carried -/
  sender : Option String := none
  receiver : Option String := none
  secrets : List String := []
deriving Repr, BEq, Inhabited

def canonTerms (K : List LeanFM.Session.Knowledge.Msg) : List LeanFM.Session.Knowledge.Msg :=
  K.mergeSort (fun x y => decide (x.render ≤ y.render))

/-- What each knower holds after a transition: a term reaches an actor that sends or receives it,
or that sees every channel. -/
def TaskModel.learnOn (t : TaskModel) (tr : Transition) (ks : List (List LeanFM.Session.Knowledge.Msg)) :
    List (List LeanFM.Session.Knowledge.Msg) :=
  (t.knowers.zip ks).map fun ((actor, _, seesAll), K) =>
    match tr.term with
    | some m => if seesAll || tr.sender == some actor || tr.receiver == some actor
        then canonTerms (LeanFM.Session.Knowledge.learn K m) else K
    | none => K

structure Model where
  task : TaskModel
  nodes : Array Node
  succ : Array (Array Nat)
  deadlocks : List String
deriving Inhabited

/-- A node's identity as a string, for the index: equal exactly when the nodes are equal. -/
def nodeKey (n : Node) : String :=
  -- most models track no knowledge and no claims: then a node is its state and last message
  if n.knowledge.all (·.isEmpty) && n.claims.isEmpty && n.secrets.isEmpty then
    s!"{n.knowledge.length}\u0001{n.state}\u0001{n.message.getD "\u0002"}"
  else reprStr n

/-- Breadth-first construction; `none` when the node bound is exceeded. Transitions are indexed by
their source and nodes by their key, so building is linear in the model, not quadratic. -/
def buildModel (t : TaskModel) (b : Bounds := bounds) : Option Model := Id.run do
  let start := t.knowers.map fun (_, init, _) => canonTerms (LeanFM.Session.Knowledge.analz init)
  let first : Node := { state := t.initial, message := none, knowledge := start }
  let mut nodes : Array Node := #[first]
  let mut index : Std.HashMap String Nat := (({} : Std.HashMap String Nat).insert (nodeKey first) 0)
  let mut bySrc : Std.HashMap String (Array Transition) := {}
  for tr in t.transitions do
    bySrc := bySrc.insert tr.src ((bySrc.getD tr.src #[]).push tr)
  let terminals : Std.HashSet String := t.terminals.foldl (·.insert ·) {}
  let mut succ : Array (Array Nat) := #[]
  let mut deadlocks : List String := []
  let mut i := 0
  let mut fuel := b.maxModelNodes + 1
  while i < nodes.size && fuel > 0 do
    fuel := fuel - 1
    let n := nodes[i]!
    let outs := (bySrc.getD n.state #[]).toList
    let stutter := terminals.contains n.state || outs.isEmpty
    if outs.isEmpty && !terminals.contains n.state && !deadlocks.contains n.state then
      deadlocks := deadlocks ++ [n.state]
    let mut next : Array Nat := #[]
    if stutter then
      next := #[i]
    else
      for tr in outs do
        let claims := match tr.claim with
          | some c => if n.claims.contains c then n.claims else (c :: n.claims).mergeSort (· ≤ ·)
          | none => n.claims
        -- the sender and receiver distinguish nodes only for steps that carry a secret, so a
        -- model without secrets keeps its size
        let m : Node := { state := tr.dst, message := some tr.message, knowledge := t.learnOn tr n.knowledge, claims
                        , sender := if tr.secrets.isEmpty then none else tr.sender
                        , receiver := if tr.secrets.isEmpty then none else tr.receiver, secrets := tr.secrets }
        let k := nodeKey m
        match index.get? k with
        | some j => if !next.contains j then next := next.push j
        | none =>
          if nodes.size >= b.maxModelNodes then return none
          index := index.insert k nodes.size
          nodes := nodes.push m
          next := next.push (nodes.size - 1)
    succ := succ.push next
    i := i + 1
  return some { task := t, nodes, succ, deadlocks }

namespace Model

def size (m : Model) : Nat := m.nodes.size
def all (m : Model) (b : Bool) : Array Bool := Array.replicate m.size b
def mapI (m : Model) (f : Nat → Bool) : Array Bool := (Array.range m.size).map f
def get (a : Array Bool) (i : Nat) : Bool := a[i]?.getD false

def lfp (m : Model) (step : Array Bool → Array Bool) : Array Bool := Id.run do
  let mut z := m.all false
  for _ in [0:m.size + 2] do
    let z' := step z
    if z' == z then return z
    z := z'
  return z

def gfp (m : Model) (step : Array Bool → Array Bool) : Array Bool := Id.run do
  let mut z := m.all true
  for _ in [0:m.size + 2] do
    let z' := step z
    if z' == z then return z
    z := z'
  return z

def existsSucc (m : Model) (z : Array Bool) (i : Nat) : Bool := (m.succ[i]?.getD #[]).any (get z ·)
def allSucc (m : Model) (z : Array Bool) (i : Nat) : Bool := (m.succ[i]?.getD #[]).all (get z ·)

/-- Satisfaction sets by explicit fixpoint labelling, walking the formula as a tree: the meaning the
shared evaluation below must give (tested against it), and the atoms' meaning. -/
partial def satTree (m : Model) : Formula → Array Bool
  | .tt => m.all true
  | .ff => m.all false
  | .atState s => m.nodes.map (·.state == s)
  | .after msg => m.nodes.map (·.message == some msg)
  | .terminal => m.nodes.map (fun n => m.task.terminals.contains n.state)
  | .claimed c => m.nodes.map (·.claims.contains c)
  | .secret a b f => m.nodes.map fun n =>
      !n.secrets.isEmpty && (a.all (n.sender == some ·)) && (b.all (n.receiver == some ·)) &&
      (f.all fun x => n.secrets.any (secretPathNames x))
  | .knows a v =>
    match m.task.knowers.findIdx? (·.1 == a) with
    | some k => m.nodes.map fun n => LeanFM.Session.Knowledge.knows (n.knowledge[k]?.getD []) v
    | none => m.all false
  | .not f => (satTree m f).map (!·)
  | .and fs => fs.foldl (fun acc f => (acc.zip (satTree m f)).map fun (a, b) => a && b) (m.all true)
  | .or fs => fs.foldl (fun acc f => (acc.zip (satTree m f)).map fun (a, b) => a || b) (m.all false)
  | .implies a b => satTree m (.or [.not a, b])
  | .stronglyImplies a b => satTree m (.and [.ef a, .ag (.implies a b)])
  | .outcomes fs => satTree m (.and (fs.map .ef ++ [.af (.or fs)]))
  | f@(.follows ..) | f@(.leadsTo ..) | f@(.precedes ..) | f@(.word ..) => satTree m f.expand
  | .never f => satTree m (.ag (.not f))
  | .ex f => let s := satTree m f; m.mapI (m.existsSucc s)
  | .ax f => let s := satTree m f; m.mapI (m.allSucc s)
  | .ef f => satTree m (.eu .tt f)
  | .af f => satTree m (.au .tt f)
  | .eg f => let s := satTree m f; m.gfp fun z => m.mapI fun i => get s i && m.existsSucc z i
  | .ag f => (satTree m (.ef (.not f))).map (!·)
  | .eu a b =>
    let sa := satTree m a; let sb := satTree m b
    m.lfp fun z => m.mapI fun i => get sb i || (get sa i && m.existsSucc z i)
  | .au a b =>
    let sa := satTree m a; let sb := satTree m b
    m.lfp fun z => m.mapI fun i => get sb i || (get sa i && m.allSucc z i)
  | .ew a b => satTree m (.or [.eu a b, .eg a])
  | .aw a b => (satTree m (.eu (.not b) (.and [.not a, .not b]))).map (!·)
  | _ => m.all false


/-! ### Shared evaluation (selfhost.session.ctl-scale) -/

/-- The core operators every formula is rewritten into. -/
inductive COp | tt | ff | atom | not | and | or | ex | ax | eu | au | eg
deriving BEq, Hashable, Repr, Inhabited

structure CKey where
  op : COp
  kids : Array Nat
  atom : Nat
deriving BEq, Hashable

/-- The DAG over core operators: atoms point at the formula DAG's atom nodes. -/
structure Core where
  ops : Array COp := #[]
  kids : Array (Array Nat) := #[]
  atom : Array Nat := #[]
  index : Std.HashMap CKey Nat := {}

def Core.mk' (c : Core) (op : COp) (kids : Array Nat) (atom : Nat := 0) : Core × Nat :=
  let key : CKey := { op, kids, atom }
  match c.index.get? key with
  | some i => (c, i)
  | none => let i := c.ops.size
    ({ ops := c.ops.push op, kids := c.kids.push kids, atom := c.atom.push atom, index := c.index.insert key i }, i)

/-- The formula DAG rewritten into core operators, with the meanings satTree gives the derived ones;
the root is the last node. -/
def Core.ofDag (d : Dag) : Core × Nat := Id.run do
  let mut c : Core := {}
  let mut ids : Array Nat := #[]
  let mut root := 0
  for i in [0:d.size] do
    let ks := (d.kids[i]!).map (ids[·]!)
    let k0 := ks[0]?.getD 0
    let k1 := ks[1]?.getD 0
    let mk := fun (c : Core) (op : COp) (kids : Array Nat) => c.mk' op kids
    let (c', r) := match Word.coreOf d.ops[i]! with
      | "true" => mk c .tt #[]
      | "false" => mk c .ff #[]
      | "atom" => c.mk' .atom #[] i
      | "not" => mk c .not #[k0]
      | "and" => if ks.isEmpty then mk c .tt #[] else mk c .and ks
      | "or" => if ks.isEmpty then mk c .ff #[] else mk c .or ks
      | "EX" => mk c .ex #[k0]
      | "AX" => mk c .ax #[k0]
      | "EU" => mk c .eu #[k0, k1]
      | "AU" => mk c .au #[k0, k1]
      | "EG" => mk c .eg #[k0]
      | "EF" => let (c, t) := mk c .tt #[]; mk c .eu #[t, k0]
      | "AF" => let (c, t) := mk c .tt #[]; mk c .au #[t, k0]
      | "AG" => let (c, t) := mk c .tt #[]; let (c, n) := mk c .not #[k0]; let (c, e) := mk c .eu #[t, n]; mk c .not #[e]
      | "never" => let (c, t) := mk c .tt #[]; let (c, e) := mk c .eu #[t, k0]; mk c .not #[e]
      | "implies" => let (c, n) := mk c .not #[k0]; mk c .or #[n, k1]
      | "stronglyImplies" =>
        let (c, t) := mk c .tt #[]
        let (c, ef) := mk c .eu #[t, k0]
        let (c, na) := mk c .not #[k0]
        let (c, imp) := mk c .or #[na, k1]
        let (c, nimp) := mk c .not #[imp]
        let (c, e) := mk c .eu #[t, nimp]
        let (c, ag) := mk c .not #[e]
        mk c .and #[ef, ag]
      | "outcomes" =>
        let (c, t) := mk c .tt #[]
        let (c, efs) := ks.foldl (fun (acc : Core × Array Nat) k => let (c, e) := mk acc.1 .eu #[t, k]; (c, acc.2.push e)) (c, #[])
        let (c, any) := mk c .or ks
        let (c, af) := mk c .au #[t, any]
        mk c .and (efs.push af)
      | "follows" =>
        let rest := ks.extract 1 ks.size
        let (c, t) := mk c .tt #[]
        let (c, exs) := rest.foldl (fun (acc : Core × Array Nat) k => let (c, e) := mk acc.1 .ex #[k]; (c, acc.2.push e)) (c, #[])
        let (c, any) := mk c .or rest
        let (c, ax) := mk c .ax #[any]
        let (c, body) := mk c .and (exs.push ax)
        let (c, na) := mk c .not #[k0]
        let (c, imp) := mk c .or #[na, body]
        let (c, nimp) := mk c .not #[imp]
        let (c, e) := mk c .eu #[t, nimp]
        mk c .not #[e]
      | "leadsTo" =>
        let (c, t) := mk c .tt #[]
        let (c, ef) := mk c .eu #[t, k0]
        let (c, af) := mk c .au #[t, k1]
        let (c, na) := mk c .not #[k0]
        let (c, imp) := mk c .or #[na, af]
        let (c, nimp) := mk c .not #[imp]
        let (c, e) := mk c .eu #[t, nimp]
        let (c, ag) := mk c .not #[e]
        mk c .and #[ef, ag]
      | "precedes" =>
        let (c, na) := mk c .not #[k0]
        let (c, e) := mk c .eu #[na, k1]
        mk c .not #[e]
      | "EW" => let (c, u) := mk c .eu #[k0, k1]; let (c, g) := mk c .eg #[k0]; mk c .or #[u, g]
      | "AW" =>
        let (c, nb) := mk c .not #[k1]
        let (c, na) := mk c .not #[k0]
        let (c, both) := mk c .and #[na, nb]
        let (c, e) := mk c .eu #[nb, both]
        mk c .not #[e]
      | _ => mk c .ff #[]
    c := c'
    ids := ids.push r
    root := r
  return (c, root)

/-- A packed bitset over the model's nodes. -/
abbrev Bits := ByteArray

def bitsNew (n : Nat) (v : Bool) : Bits := Id.run do
  let nb := (n + 7) / 8
  let mut b := ByteArray.mk (Array.replicate nb (if v then 255 else 0))
  -- the bits past n stay clear, so complement and equality are exact
  if v && n % 8 != 0 then b := b.set! (nb - 1) ((1 <<< (n % 8).toUInt8) - 1)
  return b

@[inline] def bitGet (b : Bits) (i : Nat) : Bool := ((b.get! (i / 8)) >>> (i % 8).toUInt8) &&& 1 == 1
@[inline] def bitSet (b : Bits) (i : Nat) : Bits := b.set! (i / 8) (b.get! (i / 8) ||| (1 <<< (i % 8).toUInt8))

def bitsOf (a : Array Bool) : Bits := Id.run do
  let mut b := bitsNew a.size false
  for i in [0:a.size] do
    if a[i]! then b := bitSet b i
  return b

def bitsTo (b : Bits) (n : Nat) : Array Bool := (Array.range n).map (bitGet b ·)

def bitsNot (b : Bits) (n : Nat) : Bits := Id.run do
  let mut r := b
  for i in [0:r.size] do r := r.set! i (~~~ (r.get! i))
  if n % 8 != 0 && r.size > 0 then r := r.set! (r.size - 1) (r.get! (r.size - 1) &&& ((1 <<< (n % 8).toUInt8) - 1))
  return r

def bitsZip (a b : Bits) (f : UInt8 → UInt8 → UInt8) : Bits := Id.run do
  let mut r := a
  for i in [0:r.size] do r := r.set! i (f (r.get! i) (b.get! i))
  return r

/-- The model's steps as offset and target arrays, both ways. -/
structure Csr where
  off : Array Nat
  tgt : Array Nat

def Csr.ofSucc (succ : Array (Array Nat)) : Csr := Id.run do
  let mut off : Array Nat := #[0]
  let mut tgt : Array Nat := #[]
  for ss in succ do
    for j in ss do tgt := tgt.push j
    off := off.push tgt.size
  return { off, tgt }

def Csr.preds (succ : Array (Array Nat)) : Csr := Id.run do
  let n := succ.size
  let mut cnt : Array Nat := Array.replicate (n + 1) 0
  for ss in succ do
    for j in ss do cnt := cnt.modify (j + 1) (· + 1)
  for i in [0:n] do cnt := cnt.set! (i + 1) (cnt[i+1]! + cnt[i]!)
  let off := cnt
  let mut fill := cnt
  let mut tgt : Array Nat := Array.replicate (off[n]!) 0
  for i in [0:n] do
    for j in succ[i]! do
      tgt := tgt.set! (fill[j]!) i
      fill := fill.modify j (· + 1)
  return { off, tgt }

/-- Evaluate a formula once over the shared DAG: each distinct subformula once, EX and AX in one pass
over the steps, EU, AU and EG in one backward worklist pass each, every truth set freed once all
its readers are done, and at most `b.maxTruthBytes` held at once. -/
def satE (m : Model) (f : Formula) (b : Bounds := bounds) : Except String (Array Bool) := do
  let n := m.size
  let d := Dag.ofFormula f
  let (c, root) := Core.ofDag d
  let nb := (n + 7) / 8
  let fwd := Csr.ofSucc m.succ
  let bwd := Csr.preds m.succ
  -- readers left for each core node; the root is read by the caller
  let mut readers : Array Nat := Array.replicate c.ops.size 0
  for ks in c.kids do
    for k in ks do readers := readers.modify k (· + 1)
  readers := readers.modify root (· + 1)
  let mut sets : Array Bits := Array.replicate c.ops.size ByteArray.empty
  let mut live := 0
  for i in [0:c.ops.size] do
    let ks := c.kids[i]!
    let get := fun (k : Nat) => sets[k]!
    let r : Bits := match c.ops[i]! with
      | .tt => bitsNew n true
      | .ff => bitsNew n false
      | .atom => bitsOf (satTree m ((d.atoms[c.atom[i]!]!).getD .ff))
      | .not => bitsNot (get ks[0]!) n
      | .and => ks.foldl (fun acc k => bitsZip acc (get k) (· &&& ·)) (bitsNew n true)
      | .or => ks.foldl (fun acc k => bitsZip acc (get k) (· ||| ·)) (bitsNew n false)
      | .ex => Id.run do
        let s := get ks[0]!
        let mut r := bitsNew n false
        for v in [0:n] do
          let mut hit := false
          for e in [fwd.off[v]!:fwd.off[v+1]!] do
            if !hit && bitGet s (fwd.tgt[e]!) then hit := true
          if hit then r := bitSet r v
        return r
      | .ax => Id.run do
        let s := get ks[0]!
        let mut r := bitsNew n false
        for v in [0:n] do
          let mut all := true
          for e in [fwd.off[v]!:fwd.off[v+1]!] do
            if all && !bitGet s (fwd.tgt[e]!) then all := false
          if all then r := bitSet r v
        return r
      | .eu => Id.run do
        -- backward from the b-nodes through a-nodes
        let sa := get ks[0]!
        let mut r := get ks[1]!
        let mut work : Array Nat := (Array.range n).filter (bitGet r ·)
        while !work.isEmpty do
          let j := work.back!
          work := work.pop
          for e in [bwd.off[j]!:bwd.off[j+1]!] do
            let p := bwd.tgt[e]!
            if !bitGet r p && bitGet sa p then
              r := bitSet r p
              work := work.push p
        return r
      | .au => Id.run do
        -- a node joins once every successor has (each step counted), when a holds there
        let sa := get ks[0]!
        let mut r := get ks[1]!
        let mut left : Array Nat := (Array.range n).map fun v => fwd.off[v+1]! - fwd.off[v]!
        let mut work : Array Nat := (Array.range n).filter (bitGet r ·)
        while !work.isEmpty do
          let j := work.back!
          work := work.pop
          for e in [bwd.off[j]!:bwd.off[j+1]!] do
            let p := bwd.tgt[e]!
            if !bitGet r p then
              left := left.modify p (· - 1)
              if left[p]! == 0 && bitGet sa p then
                r := bitSet r p
                work := work.push p
        return r
      | .eg => Id.run do
        -- the a-nodes, removing each one left with no successor inside
        let mut r := get ks[0]!
        let mut inside : Array Nat := Array.replicate n 0
        for v in [0:n] do
          if bitGet r v then
            for e in [fwd.off[v]!:fwd.off[v+1]!] do
              if bitGet r (fwd.tgt[e]!) then inside := inside.modify v (· + 1)
        let mut work : Array Nat := (Array.range n).filter fun v => bitGet r v && inside[v]! == 0
        let mut gone := bitsNew n false
        for v in work do gone := bitSet gone v
        while !work.isEmpty do
          let j := work.back!
          work := work.pop
          for e in [bwd.off[j]!:bwd.off[j+1]!] do
            let p := bwd.tgt[e]!
            if bitGet r p && !bitGet gone p then
              inside := inside.modify p (· - 1)
              if inside[p]! == 0 then
                gone := bitSet gone p
                work := work.push p
        return bitsZip r gone (fun x g => x &&& ~~~ g)
    live := live + nb
    if live > b.maxTruthBytes then
      throw s!"the check would hold more than {b.maxTruthBytes} bytes of truth sets at once ({c.ops.size} distinct subformulas over {n} nodes); nothing was proved{b.hint "truth"}"
    sets := sets.set! i r
    for k in ks do
      readers := readers.modify k (· - 1)
      if readers[k]! == 0 then
        sets := sets.set! k ByteArray.empty
        live := live - nb
  return bitsTo (sets[root]!) n

/-- Satisfaction sets: the shared evaluation (satE). Past the truth-set bound it gives no node;
check_ctl calls satE and says the check stopped. -/
def sat (m : Model) (f : Formula) : Array Bool :=
  match satE m f with
  | .ok a => a
  | .error _ => m.all false

/-- Shortest path from `start` through `allowed` nodes to a `goal` node. -/
def bfs (m : Model) (start : Nat) (allowed goal : Nat → Bool) : Option (List Nat) := Id.run do
  if goal start then return some [start]
  if !allowed start then return none
  let mut parent : Array (Option Nat) := Array.replicate m.size none
  let mut seen : Array Bool := (Array.replicate m.size false).set! start true
  let mut queue : Array Nat := #[start]
  let mut head := 0
  while head < queue.size do
    let i := queue[head]!
    head := head + 1
    for j in m.succ[i]!.toList do
      if !seen[j]! then
        seen := seen.set! j true
        parent := parent.set! j (some i)
        if goal j then
          let mut path := [j]
          let mut cur := j
          for _ in [0:m.size] do
            match parent[cur]! with
            | some p => path := p :: path; cur := p
            | none => break
          return some path
        if allowed j then queue := queue.push j
  return none

/-- A lasso staying inside `region` (which must be closed under some successor). -/
def lasso (m : Model) (start : Nat) (region : Array Bool) : Option (List Nat × Nat) := Id.run do
  if !get region start then return none
  let mut path : Array Nat := #[start]
  let mut cur := start
  for _ in [0:m.size + 1] do
    match (m.succ[cur]?.getD #[]).find? (get region ·) with
    | none => return none
    | some j =>
      match path.findIdx? (· == j) with
      | some k => return some (path.toList, k)
      | none => path := path.push j; cur := j
  return none

end Model

/-! ## Evidence -/

structure Evidence where
  kind : String
  path : List Nat := []
  loopStart : Option Nat := none
  note : String := ""
deriving Inhabited

/-- A path followed by the evidence from its last state: the second path continues the first. -/
def extend (e : Evidence) (more : Option Evidence) : Evidence :=
  match more with
  | some e2 =>
    if e2.path.length ≤ 1 then e else
    { e with path := e.path ++ e2.path.drop 1,
             loopStart := e2.loopStart.map (· + e.path.length - 1) }
  | none => e

open Model in
/-- `holds = true`: explain why `f` holds at node `i`; `false`: why it fails. -/
partial def evidence (m : Model) (i : Nat) (holds : Bool) (f : Formula) : Option Evidence :=
  let sat := Model.sat m
  let reach := fun (goal : Formula) (kind : String) =>
    (m.bfs i (fun _ => true) (get (sat goal))).map fun p => { kind, path := p }
  let reachThrough := fun (a b : Formula) (kind : String) =>
    (m.bfs i (get (sat a)) (get (sat b))).map fun p => { kind, path := p }
  let loop := fun (region : Formula) (kind : String) =>
    (m.lasso i (sat (.eg region))).map fun (p, k) => { kind, path := p, loopStart := some k }
  let step := fun (goal : Formula) (kind : String) =>
    ((m.succ[i]?.getD #[]).find? (get (sat goal))).map fun j => { kind, path := [i, j] }
  match holds, f with
  | _, .not g => evidence m i (!holds) g
  | true, .ef g => reach g "witness"
  | true, .ex g => step g "witness"
  | true, .eu a b => reachThrough a b "witness"
  | true, .eg g => loop g "witness"
  | true, .ew a b => if get (sat (.eu a b)) i then reachThrough a b "witness" else loop a "witness"
  | true, .stronglyImplies a _ => reach a "witness"
  | true, .or fs => (fs.find? (fun g => get (sat g) i)).bind (evidence m i true)
  | true, .implies a b => if get (sat b) i then evidence m i true b else evidence m i false a
  -- reach the state where g fails (or, for never, holds), then show why with g's own evidence
  -- from there, so a nested AG(p -> AG q) ends at the step that breaks q, not at p
  | false, .ag g => (reach (.not g) "counterexample").map fun e => extend e (evidence m (e.path.getLastD i) false g)
  | false, .never g => (reach g "counterexample").map fun e => extend e (evidence m (e.path.getLastD i) true g)
  | false, .ax g => step (.not g) "counterexample"
  | false, .af g => loop (.not g) "counterexample"
  | false, .au a b =>
    match reachThrough (.and [a, .not b]) (.and [.not a, .not b]) "counterexample" with
    | some e => some e
    | none => loop (.and [a, .not b]) "counterexample"
  | false, .aw a b => reachThrough (.and [a, .not b]) (.and [.not a, .not b]) "counterexample"
  | false, .stronglyImplies a b =>
    if !get (sat (.ef a)) i then
      some { kind := "vacuous", path := [i], note := "the antecedent is unreachable, so the claim would hold vacuously; stronglyImplies rejects that" }
    else reach (.and [a, .not b]) "counterexample"
  | false, .outcomes fs =>
    match fs.find? (fun g => !get (sat (.ef g)) i) with
    | some g => some { kind := "unreachable", path := [i], note := s!"the outcome {g.symbols} can never happen" }
    | none => evidence m i false (.af (.or fs))
  | false, .and fs => (fs.find? (fun g => !get (sat g) i)).bind (evidence m i false)
  | h, f@(.follows ..) | h, f@(.leadsTo ..) | h, f@(.precedes ..) | h, f@(.word ..) => evidence m i h f.expand
  | false, .implies a b => (evidence m i true a).orElse fun _ => evidence m i false b
  | _, _ => none

def nodeJson (m : Model) (i : Nat) : Json :=
  let n := m.nodes[i]!
  let base := [("state", Json.str n.state), ("message", match n.message with | some s => Json.str s | none => Json.null)]
  let held := (m.task.knowers.zip n.knowledge).map fun ((actor, _, _), K) =>
    (actor, Json.arr (K.map (Json.str ·.render)).toArray)
  let base := if held.isEmpty then base else base ++ [("holds", Json.mkObj held)]
  Json.mkObj (if n.claims.isEmpty then base else base ++ [("claims", Json.arr (n.claims.map Json.str).toArray)])

def evidenceJson (m : Model) (e : Evidence) : Json :=
  Json.mkObj <|
    [("kind", Json.str e.kind), ("path", Json.arr (e.path.map (nodeJson m)).toArray)] ++
    (match e.loopStart with | some k => [("loopsBackTo", toJson k)] | none => []) ++
    (if e.note.isEmpty then [] else [("note", Json.str e.note)])

/-! ## Tool results -/

/-- `.error` is LogicInputRejected; `.ok` is a LogicVerdict body. -/
abbrev ToolOutcome := Except String Json

def verdictJson (tool verdict reading : String) (extra : List (String × Json)) : Json :=
  Json.mkObj ([("tool", Json.str tool), ("verdict", Json.str verdict), ("reading", Json.str reading), ("bounds", boundsJson)] ++ extra)

def lints (f : Formula) (sentence : Option String) : List String :=
  let subs := f.subformulas
  let vacuity := if subs.any (fun | .ag (.implies ..) => true | _ => false) then
      ["AG(implies(a, b)) also holds when a never happens. If a is meant to be possible, use stronglyImplies(a, b), which means EF a and AG(a -> b)."]
    else []
  let topImplies := match f with
    | .implies .. => ["A plain implication is checked only at the initial state. Did you mean AG(implies(a, b))?"]
    | _ => []
  let afag := if subs.any (fun | .af (.ag _) => true | _ => false) then
      ["AF AG p: on every path p eventually holds forever (it stabilizes). AG AF p is different: p recurs infinitely often."]
    else []
  let agaf := if subs.any (fun | .ag (.af _) => true | _ => false) then
      ["AG AF p: on every path p keeps coming back (infinitely often). AF AG p is different: p eventually holds forever."]
    else []
  let efag := if subs.any (fun | .ef (.ag _) => true | _ => false) then
      ["EF AG p: some path reaches a point after which p holds on every continuation. If you meant that p always holds, use AG p."]
    else []
  let nextOnTerminal := if subs.any (fun | .ex _ | .ax _ => true | _ => false) then
      ["EX/AX at a terminal state look at the same state again, because terminal states stutter."]
    else []
  let words := match sentence with
    | some s => (s.toLower.splitOn " ").map (fun (w : String) => String.ofList (w.toList.filter Char.isAlphanum))
    | none => []
  let universalWords := ["always", "never", "every", "all", "must", "cannot", "whenever", "only"]
  let existentialWords := ["can", "may", "possible", "possibly", "some", "might", "could"]
  let m := Formula.mode f
  let quantifier :=
    if words.any (universalWords.contains ·) && m == "possibly" then
      ["The sentence sounds universal (always/never/every/must) but the formula is existential (EF/EX/EU/EG). Did you mean AG or AF?"]
    else if words.any (existentialWords.contains ·) && (m == "always" || m == "never") then
      ["The sentence sounds existential (can/may/possible) but the formula is universal. Did you mean EF?"]
    else []
  vacuity ++ topImplies ++ afag ++ agaf ++ efag ++ nextOnTerminal ++ quantifier

def unsupportedIn (f : Formula) : List String :=
  (f.atoms.filterMap fun | .unsupported op => some op | _ => none).eraseDups

def unobservableIn (f : Formula) : List String :=
  (f.atoms.filterMap fun
    | .predicate t => some ("predicate \"" ++ t ++ "\"")
    | .derived n => some ("derived " ++ n)
    | .field m n _ => some ("field " ++ m ++ "." ++ n ++ " (field values are not in the task model; check them with check_trace)")
    | _ => none).eraseDups

def explainFormula (args : Json) : ToolOutcome := do
  let fj ← match (args.getObjVal? "formula").toOption with
    | some j => pure j
    | none => throw "explain_formula needs a formula"
  let f ← parseBounded fj
  let sentence := (args.getObjVal? "sentence").toOption.bind str?
  let unknown ← match (args.getObjVal? "task").toOption with
    | some tj => do let t ← resolveTask tj; pure (unknownAtoms t f)
    | none => pure []
  let neg := f.negate
  -- the formula written back as an s-expression, when every atom has that form
  let dag := Dag.ofFormula f
  let sx : List (String × Json) := match dag.sexprBlocker with
    | none => [("sexpr", Json.str dag.toSexpr), ("sexprPretty", Json.str dag.toSexprPretty)]
    | some k => [("sexpr", Json.null), ("sexprPretty", Json.null),
        ("sexprNote", Json.str s!"a {k} atom has no s-expression form; write this formula in the JSON form")]
  let u := f.unfold
  let ud := Dag.ofFormula u
  let unfolded := Json.mkObj [("sexpr", if ud.sexprBlocker.isNone then Json.str (ud.toSexprPretty (core := true)) else Json.null), ("notation", Json.str u.coreSymbols)]
  return verdictJson "explain_formula" "explained" f.reading <| sx ++ [("readingIndented", Json.str dag.toReadingIndented), ("unfolded", unfolded)] ++
    [ ("formula", f.toJson), ("notation", f.symbols), ("mode", Formula.mode f)
    , ("negation", Json.mkObj [("formula", neg.toJson), ("notation", neg.symbols), ("reading", neg.reading)])
    , ("typingErrors", Json.arr #[])
    , ("unknownAtoms", Json.arr (unknown.map Json.str).toArray)
    , ("unsupportedOperators", Json.arr ((unsupportedIn f).map Json.str).toArray)
    , ("unobservableAtoms", Json.arr ((unobservableIn f).map Json.str).toArray)
    , ("lints", Json.arr ((lints f sentence).map Json.str).toArray) ]

/-- The most nodes a formula may have, written out as a tree, for an answer to write it as one. -/
def treeLimit : Nat := 4096

def checkCtl (args : Json) (b : Bounds := bounds) : ToolOutcome := do
  let tj ← match (args.getObjVal? "task").toOption with
    | some j => pure j
    | none => throw "check_ctl needs a task (canonical id or inline draft)"
  let fj ← match (args.getObjVal? "formula").toOption with
    | some j => pure j
    | none => throw "check_ctl needs a formula"
  let t ← resolveTask tj b
  let f ← parseShared fj b
  let unknown := unknownAtoms t f
  if !unknown.isEmpty then
    throw ("formula names atoms the task does not declare: " ++ "; ".intercalate unknown)
  -- a formula too large to write out as a tree is given as an s-expression with its shared parts
  -- labelled, never expanded (selfhost.session.ctl-scale)
  let dag := Dag.ofFormula f
  let asTree := dag.treeSize (treeLimit + 1) ≤ treeLimit
  let reading := if asTree then f.reading else s!"a formula of {dag.size} distinct subformulas, too large to read out as a tree"
  let common : List (String × Json) :=
    [("task", t.id), ("formula", if asTree then f.toJson else Json.str dag.toSexpr),
     ("notation", if asTree then f.symbols else dag.toSexprPretty), ("mode", Formula.mode f), ("terminalConvention", terminalConvention),
     ("readingIndented", if dag.size ≤ treeLimit then Json.str dag.toReadingIndented else Json.null)]
  let unsupported := unsupportedIn f
  if !unsupported.isEmpty then
    return verdictJson "check_ctl" "unsupported" reading <| common ++
      [("unsupportedOperators", Json.arr (unsupported.map Json.str).toArray),
       ("evidence", Json.mkObj [("kind", "none"), ("note", "knowledge, obligation, permission and probability modalities are not evaluated by these tools yet")])]
  let unobservable := unobservableIn f
  if !unobservable.isEmpty then
    return verdictJson "check_ctl" "unknown" reading <| common ++
      [("unobservableAtoms", Json.arr (unobservable.map Json.str).toArray),
       ("evidence", Json.mkObj [("kind", "none"), ("note", "the task model cannot decide these atoms; run classify_requirement to restate them over events")])]
  match buildModel t b with
  | none =>
    return verdictJson "check_ctl" "resource-limit" reading <| common ++
      [("evidence", Json.mkObj [("kind", "none"), ("note", s!"the reachable model exceeds {b.maxModelNodes} nodes; nothing was proved{b.hint "model"}")])]
  | some m =>
    match Model.satE m f b with
    | .error e =>
      return verdictJson "check_ctl" "resource-limit" reading <| common ++
        [("evidence", Json.mkObj [("kind", "none"), ("note", e)])]
    | .ok sats =>
    let holds := Model.get sats 0
    let ev := evidence m 0 holds f
    let evJson := match ev with
      | some e => evidenceJson m e
      | none => Json.mkObj [("kind", "exhaustive"), ("note", s!"evaluated over all {m.size} reachable nodes")]
    return verdictJson "check_ctl" (if holds then "proved" else "disproved") reading <| common ++
      [ ("reachableNodes", toJson m.size)
      , ("deadlocks", Json.arr (m.deadlocks.map Json.str).toArray)
      , ("evidence", evJson) ]

/-! ## Traces -/

structure Event where
  id : String
  prevIds : List String
  causeIds : List String
  task : String
  src : String
  dst : String
  message : String
  /-- Optional timestamp (ms); when present, no prev/cause edge may run backwards in time. -/
  timeAt : Option Nat := none
deriving Repr, Inhabited

def parseEvent (j : Json) : Except String Event := do
  let g := fun (k : String) => match (j.getObjVal? k).toOption.bind str? with
    | some v => checkString ("event." ++ k) v
    | none => .error s!"each event needs a string {k}"
  let ids := fun (k : String) => match (j.getObjVal? k).toOption with
    | some a => strings a ("event." ++ k) bounds.maxEvents
    | none => .ok []
  return { id := ← g "id", prevIds := ← ids "prevIds", causeIds := ← ids "causeIds"
         , task := ← g "task", src := ← g "src", dst := ← g "dst", message := ← g "message"
         , timeAt := (j.getObjVal? "timeAt").toOption.bind (·.getNat?.toOption) }

def mermaidName (s : String) : String :=
  String.ofList (s.toList.map fun c => if c.isAlphanum || c == '_' then c else '_')

def mermaidLabel (s : String) : String :=
  String.ofList (s.toList.filter fun c => c != ';' && c != '#' && c != '"' && c != '\n' && c != '`')

def checkTrace (args : Json) : ToolOutcome := do
  let events ← match (args.getObjVal? "events").toOption with
    | some (.arr items) =>
      if items.size > bounds.maxEvents then throw s!"trace has {items.size} events; the bound is {bounds.maxEvents}"
      items.toList.mapM parseEvent
    | _ => throw "check_trace needs an events array"
  let drafts ← match (args.getObjVal? "drafts").toOption with
    | some (.arr items) => items.toList.mapM parseDraft
    | some _ => throw "drafts is an array of draft tasks"
    | none => pure []
  let ev := events.toArray
  let n := ev.size
  let index := fun (id : String) => ev.findIdx? (·.id == id)
  let mut issues : List String := []
  -- identifiers
  for i in [0:n] do
    if (ev.toList.take i).any (·.id == ev[i]!.id) then issues := issues ++ [s!"duplicate id {ev[i]!.id}"]
  -- references
  let mut edges : List (Nat × Nat × String) := []
  for i in [0:n] do
    let e := ev[i]!
    for (kind, refs) in [("prev", e.prevIds), ("cause", e.causeIds)] do
      for r in refs do
        match index r with
        | none => issues := issues ++ [s!"{e.id}: {kind} id {r} does not exist"]
        | some j =>
          edges := edges ++ [(j, i, kind)]
          if j >= i then issues := issues ++ [s!"{e.id}: {kind} {r} does not precede it in the trace"]
          match ev[j]!.timeAt, e.timeAt with
          | some before, some after =>
            if before > after then issues := issues ++ [s!"{e.id}: {kind} {r} has a later timeAt ({before} > {after})"]
          | _, _ => pure ()
  -- cycles (Kahn)
  let mut indeg := Array.replicate n 0
  for (_, b, _) in edges do indeg := indeg.modify b (· + 1)
  let mut ready := (List.range n).filter (indeg[·]! == 0)
  let mut done := 0
  for _ in [0:n + 1] do
    match ready with
    | [] => break
    | i :: rest =>
      ready := rest
      done := done + 1
      for (a, b, _) in edges do
        if a == i then
          indeg := indeg.modify b (· - 1)
          if indeg[b]! == 0 then ready := ready ++ [b]
  let acyclic := done == n
  if !acyclic then issues := issues ++ ["the prev/cause references form a cycle"]
  -- message schemas and task acceptance
  let taskFor : String → Option TaskModel := fun id =>
    match drafts.find? (·.id == id) with
    | some d => some d
    | none => (canonicalTasks.find? (·.id == id)).map ofRequirement
  for e in events do
    match canonicalMessages.find? (·.name == e.message) with
    | some s =>
      if s.src != e.src || s.dst != e.dst then
        issues := issues ++ [s!"{e.id}: {e.message} is declared {s.src} -> {s.dst}, not {e.src} -> {e.dst}"]
    | none =>
      match taskFor e.task with
      | some t =>
        match t.transitions.find? (·.message == e.message) with
        | some tr =>
          if (tr.sender.isSome && tr.sender != some e.src) || (tr.receiver.isSome && tr.receiver != some e.dst) then
            issues := issues ++ [s!"{e.id}: {e.message} is declared {tr.sender.getD "?"} -> {tr.receiver.getD "?"}, not {e.src} -> {e.dst}"]
        | none => pure ()
      | none => pure ()
  let taskIds := (events.map (·.task)).eraseDups
  let mut acceptance : Array Json := #[]
  for tid in taskIds do
    match taskFor tid with
    | none =>
      issues := issues ++ [s!"unknown task {tid}; pass an inline draft in drafts"]
      acceptance := acceptance.push (Json.mkObj [("task", tid), ("accepted", false), ("reason", "unknown task")])
    | some t =>
      let mut cur : List String := [t.initial]
      let mut rejected : Option Json := none
      for e in events.filter (·.task == tid) do
        if rejected.isNone then
          let next := ((t.transitions.filter fun tr => cur.contains tr.src && tr.message == e.message).map (·.dst)).eraseDups
          if next.isEmpty then
            let expected := ((t.transitions.filter fun tr => cur.contains tr.src).map (·.message)).eraseDups
            rejected := some (Json.mkObj [("event", e.id), ("message", e.message),
              ("expected", Json.arr (expected.map Json.str).toArray)])
          else cur := next
      let complete := cur.any (t.terminals.contains ·)
      acceptance := acceptance.push <| Json.mkObj <|
        [("task", Json.str tid), ("accepted", rejected.isNone), ("reachedTerminal", complete),
         ("states", Json.arr (cur.map Json.str).toArray)] ++
        (match rejected with | some r => [("firstRejected", r)] | none => [])
      if let some r := rejected then
        issues := issues ++ [s!"task {tid}: event {(r.getObjValD "event").getStr?.toOption.getD "?"} is not accepted by the task's transitions"]
  -- happens-before and concurrency
  let mut concurrent : Array Json := #[]
  let mut concurrentCount := 0
  if acyclic then
    let mut anc : Array (Array Bool) := Array.replicate n (Array.replicate n false)
    for i in [0:n] do
      let mut row := Array.replicate n false
      for (a, b, _) in edges do
        if b == i && a < i then
          row := row.set! a true
          row := (row.zip anc[a]!).map fun (x, y) => x || y
      anc := anc.set! i row
    for i in [0:n] do
      for j in [i+1:n] do
        if !anc[j]![i]! && !anc[i]![j]! then
          concurrentCount := concurrentCount + 1
          if concurrent.size < bounds.maxConcurrentPairs then
            concurrent := concurrent.push (Json.arr #[ev[i]!.id, ev[j]!.id])
  -- diagrams
  let participants := (events.flatMap fun e => [e.src, e.dst]).eraseDups
  let seqLines := ["sequenceDiagram"] ++
    participants.map (fun p => "    participant " ++ mermaidName p) ++
    events.map (fun e => "    " ++ mermaidName e.src ++ "->>" ++ mermaidName e.dst ++ ": " ++ mermaidLabel (e.id ++ " " ++ e.message))
  let causalLines := ["flowchart TD"] ++
    (List.range n).map (fun i => "    e" ++ toString i ++ "[\"" ++ mermaidLabel (ev[i]!.id ++ ": " ++ ev[i]!.message) ++ "\"]") ++
    edges.map (fun (a, b, kind) => "    e" ++ toString a ++ (if kind == "prev" then " --> " else " -.-> ") ++ "e" ++ toString b)
  let verdict := if issues.isEmpty then "admissible" else "inadmissible"
  return verdictJson "check_trace" verdict
    (s!"{n} events over {taskIds.length} task(s); {concurrentCount} concurrent pair(s)")
    [ ("issues", Json.arr (issues.map Json.str).toArray)
    , ("acceptance", Json.arr acceptance)
    , ("concurrent", Json.arr concurrent), ("concurrentCount", toJson concurrentCount)
    , ("sequenceDiagram", "\n".intercalate seqLines)
    , ("causalGraph", "\n".intercalate causalLines) ]

/-! ## Observability -/

def stopWords : List String :=
  ["the", "a", "an", "is", "are", "be", "of", "to", "in", "on", "and", "or", "that", "it", "its",
   "always", "never", "every", "all", "must", "should", "has", "have", "with", "by", "for", "not", "no"]

def camel (w : String) : String :=
  match w.toList with
  | c :: cs => String.ofList (c.toUpper :: cs)
  | [] => ""

def proposedEventName (text : String) : String :=
  let words := (text.splitOn " ").map (fun w => String.ofList (w.toList.filter Char.isAlphanum))
  let significant := (words.filter fun w => !w.isEmpty && !stopWords.contains w.toLower).take 3
  (String.join (significant.map (camel ·.toLower))) ++ "Observed"

def tokens (text : String) : List String :=
  ((text.splitOn " ").map fun w => String.ofList (w.toList.filter fun c => c.isAlphanum || c == '_')).filter (!·.isEmpty)

def classifyText (task : Option TaskModel) (text : String) : Json :=
  let names := match task with
    | some t => t.messages ++ t.states
    | none => canonicalMessages.map (fun (m : MessageSchema) => m.name)
  let mentioned := (tokens text).filter (names.contains ·) |>.eraseDups
  if !mentioned.isEmpty then
    Json.mkObj [("atom", text), ("class", "derived"),
      ("reason", "the text refers to declared events or states, but a predicate over them is computed, not observed"),
      ("needs", "a reducer declaration over " ++ ", ".intercalate mentioned ++ " (state it in Requirements.lean as a derived predicate), then use {\"derived\": name}")]
  else
    let ev := proposedEventName text
    Json.mkObj [("atom", text), ("class", "implementation-only"),
      ("reason", "no declared message or state reveals this; no event trace can test it"),
      ("advice", "move it to Implementation.lean as an internal invariant, or restate it over an event that exposes it"),
      ("proposedEvent", Json.mkObj [("message", ev), ("from", "the actor that owns this state"), ("to", "an observer that can check it"),
        ("fields", Json.arr #["subject", "holds", "observed_at"])]),
      ("restated", (Formula.ag (.implies (.after ev) (.field ev "holds" "true"))).toJson)]

def classifyAtom (task : Option TaskModel) : Formula → Json
  | .atState s =>
    let ok := task.map (·.states.contains s) |>.getD true
    Json.mkObj [("atom", "at " ++ s), ("class", if ok then "observable" else "unknown name"),
      ("reason", if ok then "a task state reached by delivered messages" else "the task does not declare this state")]
  | .after m =>
    let ok := task.map (·.messages.contains m) |>.getD true
    Json.mkObj [("atom", "on " ++ m), ("class", if ok then "observable" else "unknown name"),
      ("reason", if ok then "a delivered message" else "the task does not send this message")]
  | .terminal => Json.mkObj [("atom", "stop"), ("class", "observable"), ("reason", "a state where the conversation may stop")]
  | .field m n _ => Json.mkObj [("atom", m ++ "." ++ n), ("class", "observable"), ("reason", "a field of a delivered message")]
  | .derived n => Json.mkObj [("atom", "derived " ++ n), ("class", "derived"),
      ("needs", "a declared reducer, policy or knowledge rule named " ++ n ++ " in Requirements.lean")]
  | .predicate t => classifyText task t
  | .claimed c =>
    let ok := task.map (·.transitions.any (·.claim == some c)) |>.getD true
    Json.mkObj [("atom", "claimed " ++ c), ("class", if ok then "observable" else "unknown name"),
      ("reason", if ok then "a claim made by a transition on the path" else "no transition of the task makes this claim")]
  | .secret .. => Json.mkObj [("atom", "secret"), ("class", "observable"), ("reason", "a secret field (named _secr) on the message just delivered")]
  | .knows a v =>
    let declared := task.map (·.knowers.any (·.1 == a)) |>.getD false
    Json.mkObj [("atom", a ++ " knows " ++ v.render), ("class", if declared then "observable" else "derived"),
      ("reason", if declared then "computed from the terms delivered to " ++ a ++ " on the path, by the declared derivation rules"
        else "needs terms on the task's transitions and " ++ a ++ "'s initial knowledge in the draft's knowledge field")]
  | .unsupported op =>
    let kind := if ["K", "B", "believes", "C", "common"].contains op then "knowledge over indistinguishable histories"
      else if ["Pr", "probability"].contains op then "a probability over declared branch weights"
      else "an obligation or permission over a declared normative code"
    let tool := if ["K", "B", "believes", "C", "common"].contains op then "; for what an actor can derive, use the knows atom or the knows tool" else ""
    Json.mkObj [("atom", op), ("class", "derived"), ("needs", kind ++ tool)]
  | f => Json.mkObj [("atom", f.reading), ("class", "observable")]

def classifyRequirement (args : Json) : ToolOutcome := do
  let task ← match (args.getObjVal? "task").toOption with
    | some tj => some <$> resolveTask tj
    | none => pure none
  let items ← match (args.getObjVal? "formula").toOption, (args.getObjVal? "predicates").toOption with
    | some fj, _ => do
      let f ← parseBounded fj
      pure ((f.atoms.eraseDups).map (classifyAtom task))
    | none, some pj => do
      let texts ← strings pj "predicates" bounds.maxPredicates
      pure (texts.map (classifyText task))
    | none, none => throw "classify_requirement needs a formula or a predicates array"
  let classes := items.map fun j => (j.getObjValD "class").getStr?.toOption.getD ""
  let summary :=
    if classes.all (· == "observable") then "every atom is observable; check_ctl or check_trace can decide it"
    else if classes.any (· == "implementation-only") then "some atoms are implementation-only; restate them over proposed events before the requirements gate"
    else "some atoms are derived; declare their reducers before the requirements gate"
  return verdictJson "classify_requirement" "classified" summary [("atoms", Json.arr items.toArray)]

/-! ## knows (decision logic-knows)

What an actor can derive from the messages it has seen by an event. Terms are symbolic
(`LeanFM.Session.Knowledge.Msg`); the decision is `Knowledge.synth` over the pieces the actor
holds, proved sound by `Knowledge.knows_sound`. Every held piece carries the event that first gave
it, so an answer says not only that a value leaked but where. -/

section Knows
open LeanFM.Session.Knowledge

structure KEvent where
  id : String
  prevIds : List String
  causeIds : List String
  src : String
  dst : String
  term : Msg

def parseKEvent (j : Json) : Except String KEvent := do
  let g := fun (k : String) => match (j.getObjVal? k).toOption.bind str? with
    | some v => checkString ("event." ++ k) v
    | none => .error s!"each event needs a string {k}"
  let ids := fun (k : String) => match (j.getObjVal? k).toOption with
    | some a => strings a ("event." ++ k) bounds.maxEvents
    | none => .ok []
  let term ← match (j.getObjVal? "term").toOption with
    | some t => boundedTerm t
    | none => throw "each event needs a term"
  return { id := ← g "id", prevIds := ← ids "prevIds", causeIds := ← ids "causeIds",
           src := ← g "src", dst := ← g "dst", term }

/-- A piece the actor holds, the event that first gave it, and how it was obtained. -/
structure Held where
  term : Msg
  source : String
  how : String

def Held.json (h : Held) : Json :=
  Json.mkObj [("term", Json.str h.term.render), ("from", Json.str h.source), ("how", Json.str h.how)]

/-- The parts one held piece gives up, with how. -/
def partsWhy (S : List Msg) (h : Held) : List Held :=
  match h.term with
  | .pair a b =>
    [⟨a, h.source, s!"first part of {h.term.render}"⟩, ⟨b, h.source, s!"second part of {h.term.render}"⟩]
  | .enc k b =>
    if synth S k.inverse then [⟨b, h.source, s!"opened {h.term.render} with {k.inverse.render}"⟩] else []
  | _ => []

/-- Take everything apart until a round adds nothing. Each round adds at least one subterm of a
starting term, so their total size bounds the rounds. -/
def analyseHeld (start : List Held) : List Held := Id.run do
  let mut held : List Held := []
  for h in start do
    unless held.any (·.term == h.term) do held := held ++ [h]
  let fuel := start.foldl (fun n h => n + h.term.size) 1
  for _ in [0:fuel] do
    let S := held.map (·.term)
    let mut added := false
    for h in held do
      for p in partsWhy S h do
        unless held.any (·.term == p.term) do
          held := held ++ [p]; added := true
    if !added then break
  return held

/-- Why `v` can be built from the held pieces, as a tree; `none` when it cannot. Mirrors `synth`. -/
partial def derivation (held : List Held) : Msg → Option Json
  | v =>
    match held.find? (·.term == v) with
    | some h => some (Json.mkObj [("term", Json.str v.render), ("held", Json.str h.source), ("how", Json.str h.how)])
    | none =>
      let node := fun (op : String) (subs : List (Option Json)) =>
        if subs.all Option.isSome then
          some (Json.mkObj [("term", Json.str v.render), ("built", Json.str op),
            ("from", Json.arr (subs.filterMap id).toArray)])
        else none
      match v with
      | .pair a b => node "pair" [derivation held a, derivation held b]
      | .enc k b => node "encrypt" [derivation held k, derivation held b]
      | .hash b => node "hash" [derivation held b]
      | _ => none

end Knows

def knows (args : Json) : ToolOutcome := do
  let field := fun (k : String) => (args.getObjVal? k).toOption
  let events ← match field "events" with
    | some (.arr items) =>
      if items.size > bounds.maxEvents then throw s!"trace has {items.size} events; the bound is {bounds.maxEvents}"
      items.toList.mapM parseKEvent
    | _ => throw "knows needs an events array"
  let actor ← match (field "actor").bind str? with
    | some a => checkString "actor" a
    | none => throw "knows needs a string actor"
  let atId ← match (field "at").bind str? with
    | some a => checkString "at" a
    | none => throw "knows needs the id of the event to ask at"
  let initial ← match field "initial" with
    | some (.arr items) =>
      if items.size > bounds.maxPredicates then throw s!"initial has {items.size} terms; the bound is {bounds.maxPredicates}"
      items.toList.mapM boundedTerm
    | some _ => throw "initial is an array of terms"
    | none => pure []
  let query ← match field "query" with
    | some q => some <$> boundedTerm q
    | none => pure none
  let seesAll := match field "seesAll" with | some (.bool b) => b | _ => false
  -- ids are unique, references resolve, the asked-at event exists
  let ids := events.map (·.id)
  if ids.eraseDups.length != ids.length then throw "event ids must be unique"
  for e in events do
    for r in e.prevIds ++ e.causeIds do
      unless ids.contains r do throw s!"event {e.id} refers to unknown event {r}"
  unless ids.contains atId do throw s!"no event has id {atId}"
  -- the causal past of the asked-at event: everything reachable backwards through prev and cause
  let past := Id.run do
    let mut seen : List String := [atId]
    let mut frontier : List String := [atId]
    for _ in [0:events.length + 1] do
      let next := frontier.flatMap fun i =>
        match events.find? (·.id == i) with
        | some e => (e.prevIds ++ e.causeIds).filter (fun r => !seen.contains r)
        | none => []
      if next.isEmpty then break
      seen := seen ++ next.eraseDups
      frontier := next.eraseDups
    return seen
  let visible := events.filter fun e => past.contains e.id && (seesAll || e.src == actor || e.dst == actor)
  let start := initial.map (fun t => (⟨t, "initial", "known at the start"⟩ : Held)) ++
    visible.map (fun e => (⟨e.term, e.id, s!"delivered in {e.id} ({e.src} to {e.dst})"⟩ : Held))
  let held := analyseHeld start
  let common : List (String × Json) :=
    [ ("actor", Json.str actor), ("at", Json.str atId)
    , ("causalPast", Json.arr ((events.filter (past.contains ·.id)).map (Json.str ·.id)).toArray)
    , ("visible", Json.arr (visible.map (Json.str ·.id)).toArray)
    , ("holds", Json.arr (held.map Held.json).toArray) ]
  match query with
  | none =>
    return verdictJson "knows" "derived" s!"what {actor} holds at {atId}" <| common ++
      [("evidence", Json.mkObj [("kind", "analysis"),
        ("note", s!"{held.length} pieces from {visible.length} visible events and {initial.length} initial terms, taken apart until nothing new appeared")])]
  | some v =>
    let reading := fun (yes : Bool) => s!"{actor} {if yes then "can" else "cannot"} derive {v.render} at {atId}"
    match derivation held v with
    | some tree =>
      return verdictJson "knows" "proved" (reading true) <| common ++
        [("query", Json.str v.render), ("evidence", Json.mkObj [("kind", "derivation"), ("derivation", tree)])]
    | none =>
      return verdictJson "knows" "disproved" (reading false) <| common ++
        [("query", Json.str v.render), ("evidence", Json.mkObj [("kind", "exhaustive"),
          ("note", s!"no derivation from the {held.length} pieces held once analysis reached its fixpoint")])]

/-! ## check_protocol (decision logic-protocol)

A security protocol declared as data: honest roles as scripts over message patterns, an attacker
who is the network, and one formula. The state space is generated by `LeanFM.Session.Attack` and
decided by `check_ctl`, so the answer has the same verdicts and evidence, plus the messages that
crossed the wire on the returned path. -/

section ProtocolTool
open LeanFM.Session.Knowledge LeanFM.Session.Attack

/-- A pattern: a term, `{"var": x}`, or a constructor over patterns. `pk` and `sk` take a name or a
pattern for one. -/
partial def parsePat (depth : Nat) (j : Json) : Except String Pat := do
  if depth > bounds.maxDepth then throw s!"a pattern is nested deeper than {bounds.maxDepth}"
  let sub := parsePat (depth + 1)
  match j with
  | .obj kvs =>
    match kvs.toList with
    | [("var", v)] => match str? v with
      | some x => return .var (← checkString "var" x)
      | none => throw "var takes a variable name"
    | [("pk", v)] => match str? v with
      | some n => return .lit (.pk (← checkString "pk" n))
      | none => return .pk (← sub v)
    | [("sk", v)] => match str? v with
      | some n => return .lit (.sk (← checkString "sk" n))
      | none => return .sk (← sub v)
    | [("pair", v)] => match v with
      | .arr #[a, b] => return .pair (← sub a) (← sub b)
      | _ => throw "pair takes exactly two patterns"
    | [("tuple", v)] => match v with
      | .arr items =>
        if items.size < 2 then throw "tuple takes two or more patterns"
        return Pat.tuple (← items.toList.mapM sub)
      | _ => throw "tuple takes an array of patterns"
    | [("enc", v)] =>
      let key ← match (v.getObjVal? "key").toOption with | some k => sub k | none => throw "enc needs a key"
      let body ← match (v.getObjVal? "body").toOption with | some b => sub b | none => throw "enc needs a body"
      return .enc key body
    | [("hash", v)] => return .hash (← sub v)
    | _ => return .lit (← parseTerm depth j)
  | _ => throw "a pattern is an object such as {\"var\": \"x\"} or {\"atom\": \"na\"}"

def patNodes : Pat → Nat
  | .pair a b | .enc a b => 1 + patNodes a + patNodes b
  | .hash b | .pk b | .sk b => 1 + patNodes b
  | .lit m => m.size
  | .var _ => 1

def boundedPat (j : Json) : Except String Pat := do
  let p ← parsePat 0 j
  if patNodes p > bounds.maxFormulaNodes then throw s!"a pattern has {patNodes p} nodes; the bound is {bounds.maxFormulaNodes}"
  return p

def maxRoles : Nat := 8
/-- sessions of one role; every session is a thread, and all threads together stay within `maxRoles` -/
def maxSessions : Nat := 4
def maxSteps : Nat := 32

def parseStep (role : String) (i : Nat) (j : Json) : Except String Step := do
  let here := s!"{role}, step {i + 1}"
  match j with
  | .obj kvs =>
    match kvs.toList with
    | [("choose", v)] =>
      let x ← match (v.getObjVal? "var").toOption.bind str? with
        | some x => checkString "choose.var" x
        | none => throw s!"{here}: choose needs a var"
      let values ← match (v.getObjVal? "values").toOption with
        | some (.arr items) =>
          if items.isEmpty || items.size > bounds.maxPredicates then throw s!"{here}: choose takes 1 to {bounds.maxPredicates} values"
          items.toList.mapM boundedTerm
        | _ => throw s!"{here}: choose needs an array of values"
      return .choose x values
    | [("send", v)] =>
      let to ← match (v.getObjVal? "to").toOption with | some t => boundedPat t | none => throw s!"{here}: send needs to"
      let msg ← match (v.getObjVal? "message").toOption with | some m => boundedPat m | none => throw s!"{here}: send needs a message"
      return .send to msg
    | [("recv", v)] => return .recv (← boundedPat v)
    | [("claim", v)] =>
      let name ← match (v.getObjVal? "name").toOption.bind str? with
        | some n => checkString "claim.name" n
        | none => throw s!"{here}: claim needs a name"
      let args ← match (v.getObjVal? "args").toOption with
        | some (.arr items) =>
          if items.size > bounds.maxPredicates then throw s!"{here}: too many claim arguments"
          items.toList.mapM boundedPat
        | none => pure []
        | _ => throw s!"{here}: claim args is an array of patterns"
      return .claim name args
    | [("fresh", v)] => match v with
      | .str x =>
        let x ← checkString "fresh" x
        if x.contains '#' then throw s!"{here}: a fresh variable's name may not contain #"
        return .fresh x
      | _ => throw s!"{here}: fresh takes a variable name"
    | _ => throw s!"{here}: a step is one of choose, fresh, send, recv or claim"
  | _ => throw s!"{here}: a step is an object"

/-- A send or a claim may use only variables an earlier choose, fresh or recv of the same role bound. -/
def checkBindings (r : Role) : Except String Unit := do
  let mut bound : List String := []
  for (st, i) in r.steps.zipIdx do
    match st with
    | .choose x _ | .fresh x => bound := x :: bound
    | .recv p => bound := p.vars ++ bound
    | .send to p =>
      for x in to.vars ++ p.vars do
        unless bound.contains x do throw s!"{r.name}, step {i + 1}: sends {x} before anything binds it"
    | .claim _ args =>
      for x in args.flatMap Pat.vars do
        unless bound.contains x do throw s!"{r.name}, step {i + 1}: claims with {x} before anything binds it"

def parseProtocol (args : Json) : Except String Protocol := do
  let field := fun (k : String) => (args.getObjVal? k).toOption
  let roles ← match field "roles" with
    | some (.arr items) =>
      if items.isEmpty || items.size > maxRoles then throw s!"check_protocol takes 1 to {maxRoles} roles"
      items.toList.mapM fun rj => do
        let name ← match (rj.getObjVal? "name").toOption.bind str? with
          | some n => checkString "role.name" n
          | none => throw "each role needs a name"
        let steps ← match (rj.getObjVal? "steps").toOption with
          | some (.arr ss) =>
            if ss.size > maxSteps then throw s!"{name} has {ss.size} steps; the bound is {maxSteps}"
            ss.toList.zipIdx.mapM fun (sj, i) => parseStep name i sj
          | _ => throw s!"{name} needs an array of steps"
        if name.contains '#' then throw s!"role {name}: a role's name may not contain #; later sessions are named {name}#2, ..."
        let sessions ← match (rj.getObjVal? "sessions").toOption with
          | none => pure 1
          | some j => match j.getNat? with
            | .ok n => if n < 1 || n > maxSessions then throw s!"{name}: sessions is 1 to {maxSessions}" else pure n
            | .error _ => throw s!"{name}: sessions is a whole number"
        let r : Role := { name, steps }
        checkBindings r
        return (r, sessions)
    | _ => throw "check_protocol needs an array of roles"
  let declaredNames := roles.map (·.1.name)
  if declaredNames.eraseDups.length != declaredNames.length then throw "role names must be unique"
  let freshVars := roles.flatMap (·.1.freshVars)
  if freshVars.eraseDups.length != freshVars.length then
    throw "each fresh variable is made by one step of one role, so its values in different sessions stay distinct"
  let threadCount := (roles.map (·.2)).foldl (· + ·) 0
  if threadCount > maxRoles then throw s!"the roles' sessions add up to {threadCount} threads; the bound is {maxRoles}"
  let roles := roles.flatMap fun (r, n) => r.sessions n
  let names := roles.map (·.name)
  let (attacker, attackerKnows) ← match field "attacker" with
    | some aj => do
      let n ← match (aj.getObjVal? "name").toOption.bind str? with
        | some n => checkString "attacker.name" n
        | none => throw "the attacker needs a name"
      if names.contains n then throw "the attacker is not one of the honest roles"
      let ks ← match (aj.getObjVal? "knows").toOption with
        | some (.arr items) =>
          if items.size > bounds.maxPredicates then throw s!"the attacker's initial knowledge has {items.size} terms; the bound is {bounds.maxPredicates}"
          items.toList.mapM boundedTerm
        | none => pure []
        | _ => throw "attacker.knows is an array of terms"
      pure (n, ks)
    | none => throw "check_protocol needs an attacker {name, knows}"
  let terms := fun (what : String) (j : Json) => match j with
    | .arr items =>
      if items.size > bounds.maxPredicates then .error s!"{what} has {items.size} values; the bound is {bounds.maxPredicates}"
      else items.toList.mapM boundedTerm
    | _ => .error s!"{what} is an array of terms"
  let domain ← match field "domain" with | some j => terms "domain" j | none => pure []
  let domains ← match field "domains" with
    | some (.obj kvs) => kvs.toList.mapM fun (x, j) => do return (x, ← terms s!"domains.{x}" j)
    | some _ => throw "domains maps variable names to arrays of terms"
    | none => pure []
  for (x, v) in freshValues roles do
    if LeanFM.Session.Knowledge.knows attackerKnows v then
      throw s!"fresh {x} makes {v.render}, which the attacker already knows; a fresh value is new to everyone"
  let domain := coverFresh roles domain
  let domains := domains.map fun (x, vs) => (x, coverFresh roles vs)
  let defender ← match field "defender" with
    | none => pure none
    | some dj => do
      let n ← match (dj.getObjVal? "name").toOption.bind str? with
        | some n => checkString "defender.name" n
        | none => throw "the defender needs a name"
      if declaredNames.contains n || n == attacker then throw "the defender is neither an honest role nor the attacker"
      let protects ← match (dj.getObjVal? "protects").toOption with
        | some (.arr items) =>
          if items.isEmpty then throw "defender.protects names at least one role"
          items.toList.mapM fun j => match str? j with
            | some r => if declaredNames.contains r then pure r else throw s!"the defender protects {r}, which is not a declared role"
            | none => throw "defender.protects is an array of role names"
        | _ => throw "the defender needs protects: an array of role names"
      let items := fun (k : String) => match (dj.getObjVal? k).toOption with
        | none => pure []
        | some (.arr xs) =>
          if xs.size > bounds.maxPredicates then .error s!"defender.{k} has {xs.size} entries; the bound is {bounds.maxPredicates}"
          else pure xs.toList
        | some _ => .error s!"defender.{k} is an array"
      let knows ← (← items "knows").mapM boundedTerm
      let drop ← (← items "drop").mapM boundedPat
      let rewrite ← (← items "rewrite").mapM fun rj => do
        let pat ← match (rj.getObjVal? "match").toOption with | some j => boundedPat j | none => throw "a rewrite needs match"
        let replace ← match (rj.getObjVal? "replace").toOption with | some j => boundedPat j | none => throw "a rewrite needs replace"
        for x in replace.vars do
          unless pat.vars.contains x do throw s!"a rewrite's replacement uses {x}, which its match does not bind"
        return ({ pat, replace } : Rewrite)
      pure (some ({ name := n, protects, knows, drop, rewrite } : Inline))
  return { attacker, attackerKnows, domain, domains, roles, flags := [], defender }

/-! ### Secrets (selfhost.mcp.logic.secrets)

Marking a secret is asking a question: the attacker never derives it. A secret is marked by name
(an atom or symmetric key whose name ends in `_secr`) or listed in the `secrets` argument. -/

def maxSecrets : Nat := 16

/-- A name without its session suffix: `na_secr#2` is a copy of `na_secr`. -/
def baseName (n : String) : String := (n.splitOn "#").headD n

def secretName (n : String) : Bool := (baseName n).endsWith "_secr"

/-- Every atom, key and agent name inside a term. -/
def msgNames : Msg → List String
  | .atom n | .key n | .pk n | .sk n => [n]
  | .pair a b | .enc a b => msgNames a ++ msgNames b
  | .hash b => msgNames b

/-- The atoms and symmetric keys inside a term. -/
def msgLeaves : Msg → List Msg
  | .atom n => [.atom n]
  | .key n => [.key n]
  | .pk _ | .sk _ => []
  | .pair a b | .enc a b => msgLeaves a ++ msgLeaves b
  | .hash b => msgLeaves b

/-- Is `s` the term `m` or inside it? -/
def msgHas (m s : Msg) : Bool :=
  m == s || match m with
    | .pair a b | .enc a b => msgHas a s || msgHas b s
    | .hash b => msgHas b s
    | _ => false

def patLits : Pat → List Msg
  | .lit m => [m]
  | .var _ => []
  | .pair a b | .enc a b => patLits a ++ patLits b
  | .hash b | .pk b | .sk b => patLits b

def patText : Pat → String
  | .lit m => m.render
  | .var x => x
  | .pair a b => patText a ++ ", " ++ patText b
  | .enc k b => "{" ++ patText b ++ "}" ++ patText k
  | .hash b => s!"h({patText b})"
  | .pk a => s!"pk({patText a})"
  | .sk a => s!"sk({patText a})"

/-- The key that opens a ciphertext sealed under this key pattern. -/
def openerText : Pat → String
  | .lit m => m.inverse.render
  | .pk a => s!"sk({patText a})"
  | .sk a => s!"pk({patText a})"
  | k => patText k

/-- Every term the protocol itself mentions: step literals, choices, fresh values and domains. -/
def protocolTerms (p : Protocol) : List Msg :=
  p.roles.flatMap (fun r => r.steps.flatMap fun
    | .choose _ vs => vs
    | .send to m => patLits to ++ patLits m
    | .recv m => patLits m
    | .claim _ args => args.flatMap patLits
    | .fresh _ => []) ++
  (freshValues p.roles).map (·.2) ++ p.domain ++ p.domains.flatMap (·.2)

/-- Secrets marked by name: atoms and symmetric keys whose name ends in `_secr`. -/
def namedSecrets (p : Protocol) : List Msg :=
  ((protocolTerms p).flatMap msgLeaves |>.filter fun
    | .atom n | .key n => secretName n
    | _ => false).eraseDups

/-- The secrets a pattern carries: secret terms inside it (a pattern without variables is matched as
the whole term it builds, so a marked hash is found), and variables holding secrets. -/
def patSecrets (secrets : List Msg) (secretVars : List String) (q : Pat) : List String :=
  match q.vars, q.inst [] with
  | [], some m => (secrets.filter (msgHas m ·)).map Msg.render
  | _, _ => match q with
    | .lit m => (secrets.filter (msgHas m ·)).map Msg.render
    | .var x => if secretVars.contains x then [x] else []
    | .pair a b | .enc a b => patSecrets secrets secretVars a ++ patSecrets secrets secretVars b
    | .hash b | .pk b | .sk b => patSecrets secrets secretVars b

/-- Every ciphertext inside a pattern, as (key pattern, body pattern). -/
def patSealed : Pat → List (Pat × Pat)
  | .enc k b => (k, b) :: (patSealed k ++ patSealed b)
  | .pair a b => patSealed a ++ patSealed b
  | .hash b | .pk b | .sk b => patSealed b
  | _ => []

/-- What protects each secret: the opening key of every ciphertext a role sends with a secret
inside, with the role and step that sends it. -/
def protectors (p : Protocol) (secrets : List Msg) : List Json := Id.run do
  let mut out : List Json := []
  for r in p.roles.filter (·.session == 1) do
    let secretVars := r.steps.flatMap fun
      | .choose x vs => if secretName x || vs.any (fun v => secrets.any (msgHas v ·)) then [x] else []
      | .fresh x => if secretName x then [x] else []
      | .recv pat => pat.vars.filter secretName
      | _ => []
    for (st, i) in r.steps.zipIdx do
      if let .send _ msg := st then
        for (k, b) in patSealed msg do
          let carried := (patSecrets secrets secretVars b).eraseDups
          unless carried.isEmpty do
            out := out ++ [Json.mkObj [("protector", Json.str (openerText k)),
              ("protects", toJson carried), ("sentBy", Json.str s!"{r.name}, step {i + 1}"),
              ("message", Json.str (patText msg))]]
  return out

/-- Names that look secret but are not marked: a forgotten marker is reported, never silently unchecked. -/
def secretLint (p : Protocol) (secrets : List Msg) : List String :=
  let looks := fun (n : String) =>
    let l := n.toLower
    ["passw", "secret", "token", "priv", "cred"].any fun w => (l.splitOn w).length > 1
  let listedLeaves := secrets.filterMap fun | .atom n | .key n => some n | _ => none
  let leafNames := (protocolTerms p).flatMap msgLeaves |>.filterMap fun | .atom n | .key n => some n | _ => none
  let varNames := p.roles.flatMap fun r => r.steps.flatMap fun
    | .choose x _ | .fresh x => [x]
    | .send to m => to.vars ++ m.vars
    | .recv m => m.vars
    | .claim _ args => args.flatMap Pat.vars
  ((leafNames ++ varNames).map baseName).eraseDups.filter fun n =>
    looks n && !secretName n && !listedLeaves.contains n

end ProtocolTool

/-- Ask `check_ctl` a formula over a generated protocol model. -/
def _root_.LeanFM.Session.Attack.Protocol.check (p : LeanFM.Session.Attack.Protocol)
    (m : LeanFM.Session.Attack.Model) (id : String) (formula : Json) : Json :=
  match checkCtl (Json.mkObj [("task", p.draft m id), ("formula", formula)]) with
  | .ok j => j
  | .error e => Json.mkObj [("verdict", "error"), ("reason", e)]

/-- check_protocol with the model's state bound as a parameter, so the cut-off answer can be tested on a
small model; the tool always uses `bounds.maxModelNodes`. -/
def checkProtocolWith (limit : Nat) (args : Json) : ToolOutcome := do
  let p ← parseProtocol args
  -- secrets: marked by name (_secr), the only mark; each is a question (selfhost.mcp.logic.secrets)
  if (args.getObjVal? "secrets").toOption.isSome then
    throw "secrets is not an argument: name each secret with _secr (passwd_secr; a hash a server accepts in place of the password as hpasswd_secr)"
  let secrets := namedSecrets p
  if secrets.length > maxSecrets then
    throw s!"the protocol marks {secrets.length} secrets; the bound is {maxSecrets}"
  let f? ← match (args.getObjVal? "formula").toOption with
    | some fj => some <$> parseBounded fj
    | none => pure none
  if f?.isNone && secrets.isEmpty then
    throw "check_protocol needs a formula or a secret (a name ending in _secr)"
  let m := p.explore limit
  let size : List (String × Json) := [("states", toJson m.states.size), ("transitions", toJson m.edges.length)]
  let draft := p.draft m "protocol"
  let wireOf := fun (r : Json) =>
    let path := match (r.getObjValD "evidence").getObjValD "path" with
      | .arr ps => ps.toList.filterMap fun s => (s.getObjValD "message").getStr?.toOption
      | _ => []
    (p.replayWire path).map LeanFM.Session.Attack.Hop.toJson
  let secretResults : List (String × Json) := secrets.map fun s =>
    let base := [("term", Json.str s.render), ("json", LeanFM.Session.Attack.termJson s),
      ("marked", Json.str "by name")]
    if m.truncated then ("resource-limit", Json.mkObj (base ++ [("verdict", Json.str "resource-limit")]))
    else
      let q := Json.mkObj [("AG", Json.mkObj [("not", Json.mkObj [("knows", Json.mkObj [("actor", Json.str p.attacker), ("term", LeanFM.Session.Attack.termJson s)])])])]
      match checkCtl (Json.mkObj [("task", draft), ("formula", q)]) with
      | .ok r =>
        match (r.getObjValD "verdict").getStr?.toOption with
        | some "proved" => ("kept", Json.mkObj (base ++ [("verdict", Json.str "kept")]))
        | some "disproved" => ("leaked", Json.mkObj (base ++ [("verdict", Json.str "leaked"), ("evidence", r.getObjValD "evidence"),
            ("wire", Json.arr (wireOf r).toArray)]))
        | _ => ("resource-limit", Json.mkObj (base ++ [("verdict", Json.str "resource-limit")]))
      | .error e => ("resource-limit", Json.mkObj (base ++ [("verdict", Json.str "resource-limit"), ("reason", Json.str e)]))
  let warnings := (secretLint p secrets).map fun n =>
    s!"{n} looks secret but is not marked: name it {n}_secr, or it is not checked"
  let extras : List (String × Json) :=
    (if secrets.isEmpty then [] else
      [("secrets", Json.arr (secretResults.map (·.2)).toArray),
       ("protectors", Json.arr (protectors p secrets).toArray)]) ++
    (if warnings.isEmpty then [] else [("warnings", toJson warnings)])
  let note := ("note", Json.str ("bounded: each session runs once, with the declared number of sessions per role; variables bind values from the declared domains; every channel is the attacker's" ++
        (match p.defender with
         | some g => s!", except {g.name}'s links to the roles it protects; {g.name} sees inside a ciphertext only with a key it holds"
         | none => "")))
  match f? with
  | none =>
    let leaked := secretResults.filter (·.1 == "leaked")
    let cut := secretResults.any (·.1 == "resource-limit")
    let verdict := if !leaked.isEmpty then "disproved" else if cut then "resource-limit" else "proved"
    let reading := s!"{(secretResults.filter (·.1 == "kept")).length} of {secrets.length} secrets kept from {p.attacker}" ++
      (if leaked.isEmpty then "" else ": " ++ ", ".intercalate (leaked.map fun (_, j) => ((j.getObjValD "term").getStr?.toOption.getD "?") ++ " leaked"))
    return Json.mkObj ([("tool", Json.str "check_protocol"), ("bounds", boundsJson), ("verdict", Json.str verdict), ("reading", Json.str reading)] ++
      size ++ extras ++ [note])
  | some f =>
  if m.truncated then
    return verdictJson "check_protocol" "resource-limit" f.reading <| size ++
      [("evidence", Json.mkObj [("kind", "none"), ("note", s!"the generated model exceeds {limit} states; nothing was proved")])] ++ extras
  let r ← checkCtl (Json.mkObj [("task", draft), ("formula", f.toJson)])
  let wire := wireOf r
  let keep := ["verdict", "reading", "mode", "evidence", "deadlocks"]
  let body := match r with
    | .obj kvs => kvs.toList.filter (fun (k, _) => keep.contains k)
    | _ => []
  return Json.mkObj ([("tool", Json.str "check_protocol"), ("bounds", boundsJson)] ++ body ++ size ++
    [("wire", Json.arr wire.toArray)] ++ extras ++ [note])

def checkProtocol (args : Json) : ToolOutcome := checkProtocolWith bounds.maxModelNodes args

/-! ## check_reassembly (decision logic-reassembly)

A defender and the host behind it reassemble the same attacker-segmented stream, each with its own
overlap policy. The model is `LeanFM.Session.Reassembly`; `check_ctl` decides the formula over it. -/

def maxSignature : Nat := 4

def parsePolicy (what : String) : Option Json → Except String LeanFM.Session.Reassembly.Policy
  | none => throw s!"internal: no default for {what}"
  | some (.str "first") => pure .first
  | some (.str "last") => pure .last
  | some _ => throw s!"{what} is \"first\" (old bytes win an overlap) or \"last\" (new bytes win)"

def checkReassembly (args : Json) : ToolOutcome := do
  let field := fun (k : String) => (args.getObjVal? k).toOption
  let signature ← match field "signature" with
    | none => pure "EVIL"
    | some (.str sig) =>
      if sig.isEmpty || sig.length > maxSignature then throw s!"the signature is 1 to {maxSignature} characters"
      if sig.contains '.' then throw "the signature may not contain . (it marks a byte that is not the signature's)"
      checkString "signature" sig
    | some _ => throw "signature is a string"
  let box ← parsePolicy "box" (some ((field "box").getD (Json.str "first")))
  let host ← parsePolicy "host" (some ((field "host").getD (Json.str "last")))
  let blocking ← match field "mode" with
    | none | some (.str "blocking") => pure true
    | some (.str "passive") => pure false
    | some _ => throw "mode is \"blocking\" (an IPS resets the stream on a match) or \"passive\" (an IDS alerts)"
  let c : LeanFM.Session.Reassembly.Config := { signature, box, host, blocking }
  let fj := (field "formula").getD c.defaultFormula
  let f ← parseBounded fj
  let m := c.explore bounds.maxModelNodes
  let size : List (String × Json) := [("states", toJson m.states.size), ("transitions", toJson m.edges.length)]
  if m.truncated then
    return verdictJson "check_reassembly" "resource-limit" f.reading <| size ++
      [("evidence", Json.mkObj [("kind", "none"), ("note", s!"the model exceeds {bounds.maxModelNodes} states; nothing was proved")])]
  let r ← checkCtl (Json.mkObj [("task", c.draft m), ("formula", f.toJson)])
  let path : List String := match (r.getObjValD "evidence").getObjValD "path" with
    | .arr ps => ps.toList.filterMap fun (s : Json) => (s.getObjValD "message").getStr?.toOption
    | _ => []
  let segments := (path.filter (fun (l : String) => l.startsWith "segment" && !l.endsWith "(host)")).map fun (l : String) =>
    match (l.drop "segment @".length).toString.splitOn ": " with
    | [off, data] => Json.mkObj [("offset", Json.str off), ("data", Json.str data)]
    | _ => Json.str l
  let keep := ["verdict", "reading", "mode", "evidence", "deadlocks"]
  let body := match r with
    | .obj kvs => kvs.toList.filter (fun (k, _) => keep.contains k)
    | _ => []
  return Json.mkObj ([("tool", Json.str "check_reassembly"), ("bounds", boundsJson)] ++ body ++ size ++
    [("segments", Json.arr segments.toArray),
     ("defender", Json.mkObj [("policy", Json.str box.name), ("mode", Json.str (if blocking then "blocking" else "passive"))]),
     ("host", Json.mkObj [("policy", Json.str host.name)]),
     ("note", Json.str s!"every segmentation of a {signature.length}-byte stream: any offset and length, each byte the signature's or another, sent any number of times; '.' is a byte that is not the signature's")])

/-! ## Reference -/

def reference : String := String.intercalate "\n"
  [ "# LeanFM logic reference (MCP)"
  , ""
  , renamedWords
  , ""
  , "Formulas, tasks and traces are JSON data. They are parsed into closed types and never executed."
  , ""
  , "## Formula grammar"
  , ""
  , "| JSON | Meaning |"
  , "|---|---|"
  , "| `true`, `false` | constants |"
  , "| `{\"at\": \"s\"}` | the task is in state s (observable) |"
  , "| `{\"on\": \"M\"}` | on delivery of M: true in the state that delivery reaches, until the next message (observable); after, the old name, is refused |"
  , "| `\"stop\"` | the conversation may stop here (observable); terminal, the old name, is refused |"
  , "| `{\"field\": {\"message\": \"M\", \"name\": \"f\", \"value\": \"v\"}}` | last message M had f = v (observable in traces; not in task models) |"
  , "| `{\"derived\": \"name\"}` | a declared reducer, policy or knowledge predicate |"
  , "| `{\"claimed\": \"commit(B, A)\"}` | some transition on the path made this claim (drafts with claims, and check_protocol) |"
  , "| `{\"secret\": {\"from\": \"A\", \"to\": \"B\", \"field\": \"card_secr\"}}` | the step just taken carried a secret field (a path ending in _secr), from A to B and named card_secr; each key is optional and `{}` is any secret (drafts whose transitions carry secrets, and session_ctl, which reads them from the message types). Secrecy is a question a protocol test asks, not a rule: `{\"AG\": {\"not\": {\"secret\": {\"to\": \"Log\"}}}}` |"
  , "| `{\"knows\": {\"actor\": \"Ivo\", \"term\": t}}` | the actor can derive term t from what reached it on the path (observable when the draft declares the actor's knowledge; terms as in the knows tool). t must carry a name ending in _secr, the only way to mark a secret: knows(Ivo, nb) is refused, knows(Ivo, nb_secr) is the question |"
  , "| `{\"predicate\": \"text\"}` | free text: never observable; classify it first |"
  , "| `{\"not\": f}`, `{\"and\": [..]}`, `{\"or\": [..]}`, `{\"implies\": [a, b]}` | Boolean |"
  , "| `{\"stronglyImplies\": [a, b]}` | EF a and AG(a -> b): non-vacuous always |"
  , "| `{\"outcomes\": [a, b, ...]}` | EF a and EF b and ... and AF (a or b or ...): the outcomes of a choice, each possible and one inevitable (not AF a or AF b, which says one particular outcome is inevitable); two or more |"
  , "| `{\"follows\": [a, b, ...]}` | AG(a -> (EX b and ... and AX (b or ...))): right after a, the next step is one of b, ..., each possible; a and one or more |"
  , "| `{\"leadsTo\": [a, b]}` | stronglyImplies(a, AF b): a can happen, and every a is eventually followed by b (never vacuous, unlike AG(a -> AF b)) |"
  , "| `{\"precedes\": [a, b]}` | not (not a EU b): b never happens before a, and need not happen |"
  , "| `{\"never\": f}` | AG not f |"
  , "| `{\"possibly\": f}` `{\"inevitably\": f}` `{\"always\": f}` `{\"someAlways\": f}` `{\"allNext\": f}` `{\"someNext\": f}` | words for EF, AF, AG, EG, AX, EX: written back as written, decided as the primitive |"
  , "| `{\"allUntil\": [a, b]}` `{\"someUntil\": [a, b]}` `{\"allUnless\": [a, b]}` `{\"someUnless\": [a, b]}` | words for a AU b, a EU b, a AW b, a EW b; the notation writes them infix, a allUntil b |"
  , "| `{\"AG\": f}` `{\"AF\": f}` `{\"EG\": f}` `{\"EF\": f}` `{\"AX\": f}` `{\"EX\": f}` | CTL unary |"
  , "| `{\"AU\": [a, b]}` `{\"EU\": [a, b]}` | a until b, and b happens |"
  , "| `{\"AW\": [a, b]}` `{\"EW\": [a, b]}` | a unless b, b need not happen |"
  , ""
  , "Bare F, G, X, U and W are typing errors: quantify them with A (every path) or E (some path)."
  , ""
  , "## S-expressions"
  , ""
  , "Wherever a formula is read, a JSON string beginning with ( or # is an s-expression over the same operators: `(AG (implies (on Ping) (AX (or (on Pong) (on SlowPong)))))`. `(outcomes a b ...)` and `(follows a b ...)` take two or more formulas and `(leadsTo a b)` and `(precedes a b)` two; `(on M)`, `(at s)` and `(claimed c)` take a name; `stop`, `true` and `false` are bare; `(secret from A to B field f)` with each pair optional. A name is letters, digits and `_ . : / @ $ -`, or a double-quoted string. A part written once may be labelled `#1=` and reused as `#1#`, so a formula with shared parts is written with each part once. The reader is data only: no other # form and nothing evaluated; a label must be defined before it is used, which rules out cycles. knows, field, predicate and derived have structure the string form does not carry: write them in JSON."
  , ""
  , "To parse or format one, call explain_formula with the formula alone (no task): besides its reading it answers `formula` (the JSON tree), `sexpr` (the canonical one-line s-expression: single spaces, names quoted only where needed, a part shared by two or more parents written once with a label) and `sexprPretty` (the same, indented: every line within 72 columns where it can be: a part that fits there, closing parentheses included, stays on one line, otherwise each argument goes on its own line two spaces in). Both read back to the same formula. A formula with a knows, field, predicate or derived atom gets null for both, with `sexprNote` saying why. Every formula also gets `readingIndented`: its English as an indented outline (a part that fits in 72 columns on one line, otherwise its leading phrase ending in a colon and its parts below, lists bulleted, a shared part read once as (#n)); check_ctl and session_ctl answers carry it too."
  , ""
  , "check_ctl evaluates a formula as its DAG: each distinct subformula once, so its size bound counts distinct subformulas, and an answer writes a formula too large to write as a tree as an s-expression with its shared parts labelled."
  , "K, O, P, B and Pr are parsed and reported as unsupported inside formulas; the knows tool decides what an actor can derive at an event of a trace."
  , ""
  , "## knows"
  , ""
  , "Arguments: events (envelopes {id, prevIds, causeIds, src, dst, term}), actor, at (an event id), initial (terms the actor starts with), query (optional term), seesAll (optional: the actor sees every channel)."
  , ""
  , "Terms: `{\"atom\": n}`, `{\"key\": n}`, `{\"pk\": a}`, `{\"sk\": a}`, `{\"pair\": [x, y]}`, `{\"tuple\": [x, y, ...]}`, `{\"enc\": {\"key\": k, \"body\": b}}`, `{\"hash\": x}`."
  , ""
  , "Only events in the causal past of at count. Pairs split; a ciphertext opens with the private key for pk, the public key for sk (a signature), the key itself otherwise; nothing recovers a hash input. Without a query the verdict is derived and holds lists every piece with the event that gave it; with one, proved carries the derivation and disproved an exhaustive note."
  , ""
  , "## check_protocol"
  , ""
  , "Arguments: roles ([{name, steps, sessions?}]; sessions 1 to 4, default 1, every session a thread named name, name#2, ...; at most 8 threads in all), attacker ({name, knows: [terms]}), domain ([terms] for received variables), domains ({var: [terms]}), formula. A name ending in _secr is the only way to mark a secret: each is the question never knows(attacker, secret), answered kept, leaked or resource-limit, with the keys that protect it and warnings for names that look secret but are unmarked; with secrets the formula is optional. A hash hides its input, so a hash a server accepts in place of the password is its own secret, named so (hpasswd_secr)."
  , ""
  , "Steps: `{\"choose\": {\"var\": x, \"values\": [terms]}}`, `{\"send\": {\"to\": p, \"message\": p}}`, `{\"recv\": p}`, `{\"claim\": {\"name\": n, \"args\": [p]}}`, `{\"fresh\": x}` (binds x to a value new in this session: x in the first, x#2 in the second; no two roles make the same fresh variable, and the attacker may not already know it). A domain that holds a fresh value also holds its copies in other sessions. Patterns are terms with `{\"var\": x}` anywhere; `pk` and `sk` take a name or a pattern."
  , ""
  , "Every channel is the attacker's: honest sends go to the attacker, honest receives accept any matching message the attacker can build. An optional defender ({name, protects, knows, drop, rewrite: [{match, replace}]}) stands between the attacker and the roles it protects: it drops a message when a drop pattern matches any part it can see, opening ciphertexts only with keys it can build from its knows, rewrites a whole message that matches a rewrite (the replacement uses only variables its match binds), and otherwise forwards it; the link from the defender to a protected role is not the attacker's. The formula may use claimed and knows atoms. Bounded: each session runs once, with as many sessions as declared; variables bind values from the domains; a model over 4096 states answers resource-limit."
  , ""
  , "## check_reassembly"
  , ""
  , "Arguments, all optional: signature (1 to 4 characters, default EVIL), box and host (first or last: which bytes win an overlap; defaults first and last), mode (blocking or passive), formula."
  , ""
  , "The attacker sends any segments of the stream, any number of times; each byte is the signature's or another, shown as . in the answer. The claims alerted(sig) and delivered(sig) mark the defender's copy and the host's copy first holding the signature. The search covers every segmentation; the answer lists the segments of an evasion."
  , ""
  , "## Requirement modes"
  , ""
  , "always = AG p; never = AG not p; eventually = AF p; possibly = EF p."
  , "AG(implies(a, b)) is vacuous when a is unreachable; prefer stronglyImplies(a, b)."
  , ""
  , "## Tasks"
  , ""
  , "A task is a canonical id string, or a draft: `{\"id\", \"states\": [..], \"initial\", \"terminals\": [..], \"transitions\": [{\"src\", \"dst\", \"message\", \"from\"?, \"to\"?, \"term\"?}], \"knowledge\"?: {actor: {\"initial\": [terms], \"seesAll\": bool}}}`."
  , ""
  , "With knowledge declared, a state of the model is a task state together with what each declared actor holds; a transition's term reaches its from and to actors and every actor that sees all channels."
  , ""
  , "## Terminal convention"
  , ""
  , terminalConvention
  , ""
  , "## Verdicts"
  , ""
  , "- proved: holds on every reachable node; existential claims carry a witness path."
  , "- disproved: fails; universal claims carry a counterexample path (a lasso with loopsBackTo for AF and EG)."
  , "- unknown: a derived, predicate or field atom cannot be decided from the task model."
  , "- unsupported: a modality outside the implemented logic."
  , "- resource-limit: the model exceeded the node bound; nothing was proved."
  , "- Malformed or oversized input is rejected with a reason (isError)."
  , ""
  , "## Traces"
  , ""
  , "check_trace takes `{\"events\": [{\"id\", \"prevIds\", \"causeIds\", \"task\", \"src\", \"dst\", \"message\"}], \"drafts\"?: [task]}`."
  , "prevIds orders events within an actor or task; causeIds names the events that caused it (for example the HTTP request a response answers)."
  , "References must point to earlier events. Events unordered by the transitive closure of both are concurrent."
  , ""
  , "## Observability"
  , ""
  , "observable: decided by the event trace. derived: computed from it by a declared reducer. implementation-only: no event reveals it."
  , "classify_requirement proposes an event for each implementation-only atom so it can be restated and tested."
  , ""
  , "## Example"
  , ""
  , "```json"
  , "{\"task\": \"mcp_logic_consult\", \"formula\": {\"AG\": {\"implies\": [{\"on\": \"LogicConsultRequested\"}, {\"AF\": \"stop\"}]}}}"
  , "```" ]

/-! ## Dispatch -/

def toolNames : List String := ["explain_formula", "check_ctl", "check_trace", "classify_requirement", "knows", "check_protocol", "check_reassembly"]

def run (name : String) (args : Json) : Option ToolOutcome :=
  if args.compress.length > bounds.maxArgumentBytes then
    some (.error s!"arguments exceed {bounds.maxArgumentBytes} bytes")
  else match name with
    | "explain_formula" => some (explainFormula args)
    | "check_ctl" => some (checkCtl args (boundsOf args))
    | "check_trace" => some (checkTrace args)
    | "classify_requirement" => some (classifyRequirement args)
    | "knows" => some (knows args)
    | "check_protocol" => some (checkProtocol args)
    | "check_reassembly" => some (checkReassembly args)
    | _ => none

end LeanFM.Logic
