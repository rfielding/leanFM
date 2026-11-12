import LeanFM.Session.Types

/-!
# Message types from a .proto file (clause selfhost.session.proto)

A protocol's message types may come from a proto3 file, the way an HTTP interface comes from an
OpenAPI file: it is a source of truth that implementations use directly, and LeanFM generates the
Lean payload types from it. `ofProto` reads the subset of proto3 that has an exact Lean type:

```
syntax = "proto3";
package shop;

// The shop's price for the order, in cents.
message Quote {
  uint64 price = 1;
}
```

`uint64`, `uint32`, `fixed64` and `fixed32` are `Nat`; `int64`, `int32`, `sint64`, `sint32`,
`sfixed64` and `sfixed32` are `Int`; `string` is `String`; `bool` is `Bool`; a message name is that
structure; `repeated` is `List` and `optional` is `Option`. The `//` comment lines just before a
message document it. Each field keeps its number.

Negative requirements: the file is read by this parser alone and nothing in it runs. `float`,
`double` (inexact) and `bytes` are refused with the reason; so are `import` (nothing outside the
text is read), nested messages, `enum`, `oneof` and `map`, which have no type here yet; a message
named `Event` (the envelope LeanFM writes); a field number outside 1 to 536870911 or in the
reserved 19000 to 19999; two fields with one number; a file that is not proto3; more than 65536
bytes; and everything `Types.check` refuses.
-/

namespace LeanFM.Session.Proto
open Types

def maxBytes : Nat := 65536

inductive Tok where
  | word (s : String) | num (n : Nat) | str (s : String) | sym (c : Char) | doc (s : String)
  deriving BEq, Repr, Inhabited

/-- Tokens with line numbers. A `//` comment becomes a doc token, for the message that follows. -/
partial def lex (cs : List Char) (line : Nat := 1) (acc : Array (Tok × Nat) := #[]) : Except String (Array (Tok × Nat)) :=
  match cs with
  | [] => .ok acc
  | '\n' :: rest => lex rest (line + 1) acc
  | c :: rest =>
    if c.isWhitespace then lex rest line acc
    else if c == '/' && rest.head? == some '/' then
      let body := (rest.drop 1).takeWhile (· != '\n')
      lex ((rest.drop 1).dropWhile (· != '\n')) line (acc.push (.doc (String.ofList body).trimAscii.toString, line))
    else if c == '/' && rest.head? == some '*' then
      let rec block (xs : List Char) (l : Nat) : Except String (List Char × Nat) :=
        match xs with
        | '*' :: '/' :: r => .ok (r, l)
        | '\n' :: r => block r (l + 1)
        | _ :: r => block r l
        | [] => .error s!"line {line}: a /* comment is never closed"
      match block (rest.drop 1) line with
      | .ok (r, l) => lex r l acc
      | .error e => .error e
    else if c.isAlpha || c == '_' then
      let w := cs.takeWhile fun d => d.isAlphanum || d == '_' || d == '.'
      lex (cs.drop w.length) line (acc.push (.word (String.ofList w), line))
    else if c.isDigit then
      let d := cs.takeWhile Char.isDigit
      if d.length > 10 then .error s!"line {line}: a number is too long" else
      lex (cs.drop d.length) line (acc.push (.num (String.ofList d).toNat!, line))
    else if c == '"' then
      let body := rest.takeWhile (· != '"')
      if body.length == rest.length then .error s!"line {line}: a string is never closed" else
      lex (rest.drop (body.length + 1)) line (acc.push (.str (String.ofList body), line))
    else if "{}=;[]<>,()".contains c then lex rest line (acc.push (.sym c, line))
    else .error s!"line {line}: unexpected character {c}"

def scalar (t : String) : Option Ty :=
  if ["uint64", "uint32", "fixed64", "fixed32"].contains t then some .nat
  else if ["int64", "int32", "sint64", "sint32", "sfixed64", "sfixed32"].contains t then some .int
  else if t == "string" then some .str
  else if t == "bool" then some .bool
  else none

/-- The messages of a proto3 file, as message types. -/
def ofProto (text : String) : Except String Env := do
  if text.utf8ByteSize > maxBytes then throw s!"the .proto is over {maxBytes} bytes"
  let toks := (← lex text.toList).toList
  let mut rest := toks
  let mut docs : List String := []
  let mut out : Array Message := #[]
  let mut proto3 := false
  let fail (l : Nat) (m : String) : Except String Unit := throw s!".proto line {l}: {m}"
  while !rest.isEmpty do
    match rest with
    | (.doc d, _) :: r => docs := docs ++ [d]; rest := r
    | (.word "syntax", l) :: (.sym '=', _) :: (.str v, _) :: (.sym ';', _) :: r =>
      if v != "proto3" then fail l s!"syntax is {v}; LeanFM reads proto3"
      proto3 := true; docs := []; rest := r
    | (.word "package", _) :: (.word _, _) :: (.sym ';', _) :: r => docs := []; rest := r
    | (.word "option", _) :: r => docs := []; rest := (r.dropWhile (fun (p : Tok × Nat) => p.1 != Tok.sym ';')).drop 1
    | (.word "import", l) :: _ => fail l "imports are not followed: LeanFM reads only the text it is given, so put every message in one file"
    | (.word "enum", l) :: _ | (.word "service", l) :: _ => fail l "enum and service are not read yet; declare messages only"
    | (.word "message", l) :: (.word name, _) :: (.sym '{', _) :: r =>
      if !proto3 then fail l "the file must start with syntax = \"proto3\";"
      if name == "Event" then fail l "Event is the envelope LeanFM writes around every message; rename this message"
      let doc := " ".intercalate docs
      docs := []
      let mut body := r
      let mut fields : Array Field := #[]
      let mut closed := false
      while !closed do
        match body with
        | (.sym '}', _) :: r2 => closed := true; body := r2
        | (.doc _, _) :: r2 => body := r2
        | (.word "reserved", _) :: r2 => body := (r2.dropWhile (fun (p : Tok × Nat) => p.1 != Tok.sym ';')).drop 1
        | (.word w, l2) :: r2 =>
          if ["message", "enum", "oneof", "map"].contains w || w.startsWith "map<" then
            fail l2 s!"{name}: {w} inside a message is not read yet; use a message of its own"
          let (wrap, t, r3) : String × String × List (Tok × Nat) := match w, r2 with
            | "repeated", (.word t, _) :: r3 => ("list", t, r3)
            | "optional", (.word t, _) :: r3 => ("opt", t, r3)
            | _, _ => ("", w, r2)
          if ["float", "double"].contains t then fail l2 s!"{name}: {t} is not exact; use an integer of the smallest unit (cents, ms)"
          if t == "bytes" then fail l2 s!"{name}: bytes have no type here yet; use a string"
          if t == "map" then fail l2 s!"{name}: map is not read yet"
          let base := (scalar t).getD (.msg t)
          match r3 with
          | (.word f, _) :: (.sym '=', _) :: (.num n, _) :: r4 =>
            if n == 0 || n > 536870911 || (19000 ≤ n && n ≤ 19999) then
              fail l2 s!"{name}.{f}: field number {n} is outside 1 to 536870911 or in the reserved 19000 to 19999"
            if fields.any (·.number == n) then fail l2 s!"{name}: two fields have number {n}"
            -- field options [ ... ] are skipped
            let r5 : List (Tok × Nat) := match r4 with
              | (.sym '[', _) :: r6 => (r6.dropWhile (fun (p : Tok × Nat) => p.1 != Tok.sym ']')).drop 1
              | _ => r4
            match r5 with
            | (.sym ';', _) :: r6 =>
              let ty := if wrap == "list" then Ty.list base else if wrap == "opt" then Ty.opt base else base
              fields := fields.push { name := f, ty, number := n }
              body := r6
            | _ => fail l2 s!"{name}.{f}: expected ';'"
          | _ => fail l2 s!"{name}: expected a field, such as uint64 price = 1;"
        | (_, l2) :: _ => fail l2 s!"{name}: expected a field or '}'"
        | [] => fail l s!"message {name} is never closed"
      out := out.push { name, fields := fields.toList, doc }
      rest := body
    | (t, l) :: _ => fail l s!"unexpected {repr t}"
    | [] => pure ()
  if !proto3 then throw ".proto: the file must start with syntax = \"proto3\";"
  let env := out.toList
  Types.check env
  return env

end LeanFM.Session.Proto
