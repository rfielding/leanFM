import Lean

/-!
# The session-type grammar (clause selfhost.session.lean-syntax)

One grammar, written with Lean's own parser combinators, read two ways:

* in a Lean file, `protocol` and `require` are Lean commands (`Session.Syntax` registers them), so
  `lake env lean File.leanfm` parses a session type with exactly these parsers;
* LeanFM's tools run the same parsers over text a client sends (`parseFile`), with Lean's parser and
  token rules but no elaboration: nothing in the text is compiled or run.

`Session.Text` turns the syntax tree into statements, checking every limit; both readings go
through it.

The construct words are non-reserved: a word such as `choice` is a construct only when followed by
its shape, so it can still be a label. A `where` condition is taken as raw text up to the `;` that
ends the statement (outside brackets and strings), as LeanFM's condition language
(`Session.Where`) reads it. Only the parsers reachable from the two commands carry formatters;
the statement parser hides its alternatives behind one, so Lean's pretty printer never has to
print a session type.
-/

namespace LeanFM.Session.Grammar
open Lean Parser PrettyPrinter

/-- A word that is a construct only here: an identifier, or a keyword Lean already reserves. -/
local macro "W" s:str : term => `(nonReservedSymbol $s)

/-! ## Raw condition text -/

/-- The text of a `where` condition: up to the `;` that ends the statement, outside brackets and
strings. It becomes an atom whose value is the text, with its source position. -/
def condFn : ParserFn := fun c s => Id.run do
  let input := c.inputString
  let start := s.pos
  let mut i := start
  let mut depth : Nat := 0
  let mut inStr := false
  while !input.atEnd i do
    let ch := String.Pos.Raw.get input i
    if inStr then
      if ch == '\\' then
        i := String.Pos.Raw.next input i
        if input.atEnd i then break
      else if ch == '"' then inStr := false
    else if ch == '"' then inStr := true
    else if ch == ';' && depth == 0 then break
    else if ch == '(' || ch == '[' || ch == '{' then depth := depth + 1
    else if ch == ')' || ch == ']' || ch == '}' then
      if depth == 0 then return s.mkErrorAt "a balanced condition (this bracket is never opened)" i
      depth := depth - 1
    i := String.Pos.Raw.next input i
  if input.atEnd i then return s.mkErrorAt "a where condition ending with ';'" start
  let text := String.Pos.Raw.extract input start i
  if text.trimAscii.isEmpty then return s.mkErrorAt "a condition after where" start
  let info := SourceInfo.original "".toRawSubstring start "".toRawSubstring i
  return s.setPos i |>.pushSyntax (Syntax.atom info text)

def cond : Parser := { fn := condFn }
@[combinator_formatter cond] def cond.formatter : Formatter := pure ()
@[combinator_parenthesizer cond] def cond.parenthesizer : Parenthesizer := pure ()

/-! ## Annotations: numbers, durations, amounts and times -/

def frac : Parser := node `LeanFM.Session.Grammar.frac (numLit >> optional ("/" >> numLit))
def dur : Parser := node `LeanFM.Session.Grammar.dur (numLit >> ident)
def durWeight : Parser := node `LeanFM.Session.Grammar.durWeight (dur >> ":" >> frac >> ";")
def delay : Parser := node `LeanFM.Session.Grammar.delay
  ((atomic (W "sample" >> lookahead "{") >> "{" >> many durWeight >> "}") <|> dur)
/-- `time(x)` (the tokenizer reads `time(` whole where some syntax names it) or `max(time(a), time(b))`. -/
def timeRef1 : Parser := node `LeanFM.Session.Grammar.timeRef1
  (("time(" <|> atomic (W "time" >> "(")) >> ident >> ")")
def timeRef : Parser := node `LeanFM.Session.Grammar.timeRef
  (timeRef1 <|> (atomic (W "max" >> "(") >> timeRef1 >> "," >> timeRef1 >> ")"))
def timeExpr : Parser := node `LeanFM.Session.Grammar.timeExpr
  ((W "next" >> dur) <|> ((timeRef <|> ident) >> optional ("+" >> delay)))
def qty : Parser := node `LeanFM.Session.Grammar.qty (optional "-" >> numLit >> ident)
def qtyWeight : Parser := node `LeanFM.Session.Grammar.qtyWeight (qty >> ":" >> frac >> ";")
def amount : Parser := node `LeanFM.Session.Grammar.amount
  (W "amount" >> ((atomic (W "sample" >> lookahead "{") >> "{" >> many qtyWeight >> "}") <|>
    ("{" >> many (qty >> ";") >> "}") <|> qty))
def timing : Parser := node `LeanFM.Session.Grammar.timing ((W "at" >> timeExpr) <|> (W "after" >> delay))
def eventTiming : Parser := node `LeanFM.Session.Grammar.eventTiming
  ((W "after" >> delay) <|> (W "at" >> W "next" >> dur))
def rate : Parser := node `LeanFM.Session.Grammar.rate
  (optional "-" >> numLit >> ident >> W "per" >> (dur <|> ident))

/-! ## Statements -/

def block (st : Parser) : Parser := node `LeanFM.Session.Grammar.block ("{" >> many st >> "}")

def msg : Parser := node `LeanFM.Session.Grammar.msg
  (optional (atomic (ident >> ":")) >> ident >> W "from" >> ident >> W "to" >> ident >>
    optional (W "cause" >> ident) >> optional (W "route" >> strLit) >> optional (W "status" >> numLit) >>
    optional amount >> optional timing >> optional (W "where" >> cond) >> ";")
def event : Parser := node `LeanFM.Session.Grammar.event
  (atomic (ident >> W "at") >> ident >> optional eventTiming >> ";")
def choice (st : Parser) : Parser := node `LeanFM.Session.Grammar.choice
  (atomic (W "choice" >> lookahead "{") >> block st >> many (W "or" >> block st))
def wbranch (st : Parser) : Parser := node `LeanFM.Session.Grammar.wbranch
  ("{" >> optional (atomic (W "probability" >> lookahead numLit) >> frac >> ":") >> many st >> "}")
def declared (st : Parser) : Parser := node `LeanFM.Session.Grammar.declared
  (atomic (W "choice" >> W "at") >> ident >> W "using" >> W "declared" >> "(" >> strLit >> ")" >>
    wbranch st >> many (W "or" >> wbranch st))
def par (st : Parser) : Parser := node `LeanFM.Session.Grammar.par
  (atomic (W "par" >> lookahead "{") >> block st >> many (W "and" >> block st))
def join (st : Parser) : Parser := node `LeanFM.Session.Grammar.join
  (atomic (W "join" >> lookahead numLit) >> numLit >> W "of" >> block st >> many (W "and" >> block st))
def recP (st : Parser) : Parser := node `LeanFM.Session.Grammar.rec
  (atomic (W "rec" >> ident >> lookahead "{") >> block st)
def bounded (st : Parser) : Parser := node `LeanFM.Session.Grammar.bounded
  (atomic (W "rec" >> ident >> W "at") >> W "most" >> numLit >> block st >> optional (W "otherwise" >> block st))
def sessions (st : Parser) : Parser := node `LeanFM.Session.Grammar.sessions
  (atomic (W "sessions" >> lookahead "{") >> block st)
def keyed (st : Parser) : Parser := node `LeanFM.Session.Grammar.keyed
  (atomic (W "sessions" >> W "by") >> ident >> block st)
def cont : Parser := node `LeanFM.Session.Grammar.cont (atomic (W "continue" >> ident >> ";"))
def incl : Parser := node `LeanFM.Session.Grammar.incl (atomic (W "include" >> ident) >> many ident >> ";")
def clock : Parser := node `LeanFM.Session.Grammar.clock (atomic (W "clock" >> ident >> "=") >> timeRef >> ";")
def obligation : Parser := node `LeanFM.Session.Grammar.obligation
  (atomic (W "obligation" >> ident >> W "on") >> ident >> "{" >> W "trigger" >> ident >> ";" >>
    W "require" >> ident >> many (W "or" >> ident) >> W "within" >> dur >> ";" >>
    W "on" >> W "breach" >> W "record" >> ident >> optional (W "pays" >> qty >> W "to" >> ident) >> ";" >> "}")
def accrue : Parser := node `LeanFM.Session.Grammar.accrue
  (atomic (W "accrue" >> lookahead (numLit <|> "{" <|> "-")) >>
    (("{" >> many (rate >> ";") >> "}") <|> rate) >> W "from" >> ident >> W "to" >> ident >> ";")

/-- Every statement form, the recursive ones over `st`; keyword forms first, messages last. -/
def alternatives (st : Parser) : Parser :=
  clock <|> obligation <|> accrue <|> declared st <|> choice st <|> par st <|> keyed st <|> sessions st <|>
  join st <|> bounded st <|> recP st <|> cont <|> incl <|> event <|> msg

/-- One statement. -/
partial def stmtFn : ParserFn := fun c s => (alternatives { fn := stmtFn }).fn c s

def stmt : Parser := { fn := stmtFn, info := (alternatives skip).info }
@[combinator_formatter stmt] def stmt.formatter : Formatter := pure ()
@[combinator_parenthesizer stmt] def stmt.parenthesizer : Parenthesizer := pure ()

/-! ## Protocols, requirements, structures, files -/

def protocolBody : Parser := node `LeanFM.Session.Grammar.protocolBody
  ("protocol " >> ident >> "(" >> sepBy ident "," >> ")" >> block stmt)

def reqOpt : Parser := node `LeanFM.Session.Grammar.reqOpt
  ((W "within" >> dur) <|> (W "over" >> numLit >> ident) <|> (W "confidence" >> frac) <|>
    (W "expecting" >> numLit >> W "per" >> ident))
def reqClause : Parser := node `LeanFM.Session.Grammar.reqClause
  (((W "every" >> ident >> W "reaches") <|> (W "at" >> (W "least" <|> W "most") >> frac >> W "of" >> ident >> W "reach")) >>
    sepBy1 ident "," >> many reqOpt >> ";")
def requireBody : Parser := node `LeanFM.Session.Grammar.requireBody
  ("require " >> W "per" >> ident >> "{" >> many reqClause >> "}")

/-- `instance db : Db serial;`: a shared instance named `db` playing role `Db`. -/
def instDecl : Parser := node `LeanFM.Session.Grammar.instDecl
  ("instance " >> ident >> " : " >> ident >> optional (W "serial") >> ";")
/-- One player of an accept: `fresh Role` or the name of a shared instance. -/
def acceptArg : Parser := node `LeanFM.Session.Grammar.acceptArg (optional (W "fresh") >> ident)
/-- `accept Order (fresh Client, db, cache);`: one instance of `Order` per accept. -/
def acceptDecl : Parser := node `LeanFM.Session.Grammar.acceptDecl
  (W "accept" >> ident >> "(" >> sepBy1 acceptArg "," >> ")" >> ";")
def systemBody : Parser := node `LeanFM.Session.Grammar.systemBody
  ("system " >> ident >> "{" >> many (instDecl <|> acceptDecl) >> "}")

/-- `protocol Name (Roles) { ... }` as a Lean command (`Session.Syntax` elaborates it). -/
@[command_parser] def protocolCmd : Parser := leading_parser optional Command.docComment >> protocolBody

/-- `system Name { instance ...; accept ...; }` as a Lean command (selfhost.session.instances). -/
@[command_parser] def systemCmd : Parser := leading_parser optional Command.docComment >> systemBody

/-- `require per q { ... }` as a Lean command. -/
@[command_parser] def requireCmd : Parser := leading_parser requireBody

/-- A field's type: a name, or `List`, `Array` or `Option` of one plain name. -/
def fieldTypeFn : ParserFn := fun c s =>
  let iniSz := s.stackSize
  let s := identFn c s
  if s.hasError then s else
  match s.stxStack.back.getId.toString with
  | "List" | "Array" | "Option" =>
    let n := s.stxStack.back.getId.toString
    let s := whitespace c s
    if String.Pos.Raw.get c.inputString s.pos == '(' then
      s.mkUnexpectedError s!"'('; {n} holds one plain type, such as {n} Nat (protobuf has no {n} of a List or Option)"
    else
    let s := identFn c s
    if s.hasError then s.mkNode `LeanFM.Session.Grammar.fieldType iniSz
    else (s.pushSyntax mkNullNode).mkNode `LeanFM.Session.Grammar.fieldType iniSz
  | _ => (s.pushSyntax mkNullNode |>.pushSyntax mkNullNode).mkNode `LeanFM.Session.Grammar.fieldType iniSz
def fieldType : Parser := { fn := fieldTypeFn }

def field : Parser := node `LeanFM.Session.Grammar.field
  (many1 ident >> ":" >> fieldType >> notFollowedBy ":=" "default values (:=); they are not part of a message type")
def structureBody : Parser := node `LeanFM.Session.Grammar.structureBody
  ("structure " >> ident >> optional ("where" >> many field) >> optional ("deriving" >> sepBy1 ident ","))

/-- A file as the tools read it: the Lean header, then structures, protocols and requirements. -/
def file : Parser := node `LeanFM.Session.Grammar.file
  (many (node `LeanFM.Session.Grammar.import ("import " >> ident)) >>
    many (node `LeanFM.Session.Grammar.item (optional Command.docComment >>
      (structureBody <|> protocolBody <|> requireBody <|> systemBody))) >>
    notFollowedBy (Command.moduleDoc) "module doc comment (/-! -/); use -- comments")

/-! ## Running the grammar on text -/

/-- The tokens the grammar needs beyond Lean's built-in ones. -/
def tokens : TokenTable :=
  (file.info.collectTokens []).foldl (fun t tk => t.insert tk tk) {}

/-- Nesting deeper than this is refused before parsing, so no input can exhaust the stack. -/
def maxBraceDepth : Nat := 64

/-- The deepest `{` nesting outside strings and comments (an over-approximation is fine). -/
def braceDepth (text : String) : Nat := Id.run do
  let mut depth := 0
  let mut deepest := 0
  let mut inStr := false
  let mut prev := ' '
  for ch in text.toList do
    if inStr then
      if ch == '"' && prev != '\\' then inStr := false
    else if ch == '"' then inStr := true
    else if ch == '{' then depth := depth + 1; deepest := max deepest depth
    else if ch == '}' then depth := depth - 1
    prev := if prev == '\\' && ch == '\\' then ' ' else ch
  return deepest

/-- Run parser `p` over all of `text` with the given token table and the grammar's own tokens.
`env` is only carried in the parser context: none of the grammar's parsers reads it. -/
def runWith (env : Environment) (base : TokenTable) (p : Parser) (what : String) (text : String) : Except String Syntax := do
  if braceDepth text > maxBraceDepth then throw s!"statements are nested more than {maxBraceDepth} deep"
  let ictx := mkInputContext text "<protocol>"
  let tokens := (file.info.collectTokens []).foldl (fun t tk => t.insert tk tk) base
  let s := (whitespace >> p.fn).run ictx { env, options := {} } tokens (mkParserState text)
  let pos := ictx.fileMap.toPosition s.pos
  match s.errorMsg with
  | some e => throw s!"line {pos.line}, column {pos.column + 1}: {e}"
  | none =>
    if !text.atEnd s.pos then throw s!"line {pos.line}, column {pos.column + 1}: expected {what}"
    return s.stxStack.back

/- The tools parse with Lean's built-in token table and no environment at all. An environment
cannot be created while a program initializes, and a compiled program computes some constants then
(a `def` holding a parsed example, in any module it links); none of the grammar's parsers is a
category parser, the only kind that reads the environment, so the context carries a placeholder
that is never read. -/
private unsafe def runImpl (p : Parser) (what : String) (text : String) : Except String Syntax :=
  let base := unsafeBaseIO builtinTokenTable.get
  runWith (unsafeCast ()) base p what text

/-- Run a grammar parser over text, without elaborating anything. -/
@[implemented_by runImpl, never_extract] opaque run (p : Parser) (what : String) (text : String) : Except String Syntax

/-- Parse protocol text: the Lean header, structures, protocols and requirements. -/
def parseFile (text : String) : Except String Syntax := run file "structure, protocol, require or system" text

/-- Parse one annotation value, such as a fraction, duration or time expression. -/
def parseValue (p : Parser) (text : String) : Except String Syntax := run p "the end of the value" text

end LeanFM.Session.Grammar
