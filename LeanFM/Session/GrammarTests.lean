import LeanFM.Session.Grammar

/-! Tests for hazard parser.environment (selfhost.session.text): the protocol grammar parses no
antiquotation. Before, `$(e)` where a name belongs, or `%$(e)` after a token, sent Lean's term parser
to the placeholder environment `run` passes, and the server crashed on one request. Each form is now a
parse error; doc comments still parse, and a module doc is still refused. -/
namespace LeanFM.Session.GrammarTests
open LeanFM.Session.Grammar

def refused (text : String) (msg : String) : Bool :=
  match parseFile text with
  | .ok _ => false
  | .error e => (e.splitOn msg).length > 1

def parses (text : String) : Bool := (parseFile text).toOption.isSome

#guard refused "protocol Ping (A, B) { p: Ping from $(1 + 2) to B; }" "expected identifier"
#guard refused "protocol Ping (A, B) { p: Ping from $x to B; }" "expected identifier"
#guard refused "protocol Ping (A, B) { p:%$(1 + 2) Ping from A to B; }" "line 1"
#guard refused "protocol Ping (A, B) {%$(1 + 2) p: Ping from A to B; }" "line 1"
#guard refused "protocol Ping (A, B) { $[p: Ping from A to B;]* }" "line 1"
#guard refused "protocol $(Lean.Elab.Command.elabCommand) (A, B) { p: Ping from A to B; }" "expected identifier"
#guard parses "/-- A request and its answer. -/\nprotocol P (A, B) { p: Ask from A to B; Answer from B to A cause p; }"
#guard refused "/-! a module doc -/\nprotocol P (A, B) { p: Ask from A to B; }" "module doc"

end LeanFM.Session.GrammarTests
