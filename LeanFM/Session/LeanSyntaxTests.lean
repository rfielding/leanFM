import Lean
import LeanFM.Session
import LeanFM.SessionTools

/-! Tests for selfhost.session.lean-syntax (decision session-lean-syntax): every session-type file is a
Lean file. `#elab_leanfm` elaborates a file exactly as `lake env lean File.leanfm` does (its header
must import only modules already loaded here), inside a namespace of its own; each one's protocol
then agrees with the text reading of the same file. -/
namespace LeanFM.Session.LeanSyntaxTests
open Lean Elab Command LeanFM.Session

/-- Elaborate `text` as the Lean file `file`: parse its header, check its imports, and elaborate every
command in namespace `ns`, reporting errors at the file's own lines. -/
def elabText (ns : Ident) (file text : String) : CommandElabM Unit := do
  let input := Parser.mkInputContext text file
  let (header, st, msgs) ← Parser.parseHeader input
  if msgs.hasErrors then throwError "{file}: its header does not parse"
  let imports := (headerToImports header).map (·.module)
  if !imports.contains `LeanFM.Session.Syntax then
    throwError "{file}: a session-type file starts with import LeanFM.Session.Syntax"
  for m in imports do
    if !(← getEnv).allImportedModuleNames.contains m then throwError "{file}: imports {m}, which is not loaded here"
  elabCommand (← `(namespace $ns))
  let mut st := st
  repeat
    let pmctx : Parser.ParserModuleContext :=
      { env := ← getEnv, options := ← getOptions, currNamespace := ← getCurrNamespace, openDecls := ← getOpenDecls }
    let (cmd, st', msgs') := Parser.parseCommand input pmctx st {}
    st := st'
    if msgs'.hasErrors then
      let texts ← msgs'.toList.mapM fun m => do
        pure s!"{file}:{m.pos.line}:{m.pos.column}: {← m.data.toString}"
      throwError "{"\n".intercalate texts}"
    if Parser.isTerminalCommand cmd then break
    withReader (fun ctx => { ctx with fileName := file, fileMap := input.fileMap }) (elabCommand cmd)
  elabCommand (← `(end $ns))

/-- `#elab_leanfm Ns "path"`: elaborate a session-type file, relative to this file, as Lean. -/
elab "#elab_leanfm " ns:ident path:str : command => do
  let dir := (System.FilePath.mk (← getFileName)).parent.getD "."
  let file := (dir / path.getString).toString
  elabText ns file (← IO.FS.readFile file)

/-- `#elab_leanfm_text Ns name`: elaborate the string constant `name` (text LeanFM wrote) as Lean. -/
elab "#elab_leanfm_text " ns:ident n:ident : command => do
  let c ← liftCoreM <| realizeGlobalConstNoOverload n
  let text ← liftTermElabM <| unsafe Meta.evalExpr String (mkConst ``String) (mkConst c)
  elabText ns s!"<{n.getId}>" text

/-- The text reading and the elaborated protocol agree: roles, diagram, issues and every projection. -/
def agrees (text : String) (g : Global String) : Bool :=
  match Text.parse text with
  | .error _ => false
  | .ok p =>
    p.global.diagram p.roles == g.diagram p.roles &&
    p.global.issues p.roles == g.issues p.roles &&
    p.roles.all fun r => ((p.global.project r).toOption.map Local.render) == ((g.project r).toOption.map Local.render)

/-! Every session-type file in the repository elaborates as Lean -/

#elab_leanfm PlaceOrderFile "../../examples/sessions/PlaceOrder.leanfm"
#elab_leanfm PingFile "../../examples/sessions/Ping.leanfm"
#elab_leanfm BoundedRideFile "../../examples/sessions/BoundedRide.leanfm"
#elab_leanfm DepositSettlementFile "../../examples/sessions/DepositSettlement.leanfm"
#elab_leanfm DispatchFile "../../examples/sessions/Dispatch.leanfm"
#elab_leanfm LimitOrderFile "../../examples/sessions/LimitOrder.leanfm"
#elab_leanfm LoanFile "../../examples/sessions/Loan.leanfm"
#elab_leanfm PricedDepositSettlementFile "../../examples/sessions/PricedDepositSettlement.leanfm"
#elab_leanfm RentWithRepairsFile "../../examples/sessions/RentWithRepairs.leanfm"
#elab_leanfm RentalFile "../../examples/sessions/Rental.leanfm"
#elab_leanfm RideFile "../../examples/sessions/Ride.leanfm"
#elab_leanfm UserLookupFile "../../examples/sessions/UserLookup.leanfm"
#elab_leanfm WeeklyRentFile "../../examples/sessions/WeeklyRent.leanfm"
#elab_leanfm OAuthFile "../../examples/oauth/SessionType.leanfm"
#elab_leanfm LendingFile "../../examples/vibecode/lending/Lending.protocol"
#elab_leanfm LendingV2File "../../examples/vibecode/lending/Lending-v2.protocol"
#elab_leanfm LoginFile "../../examples/vibecode/login/Login.protocol"
#elab_leanfm SignInFile "../../examples/vibecode/signin/SignIn.protocol"
#elab_leanfm TripFile "../../examples/vibecode/trip/Trip.protocol"
#elab_leanfm TripParallelFile "../../examples/vibecode/trip/Trip-parallel.protocol"
#elab_leanfm NestedFile "../../exports/nested-splits/Nested.leanfm"
#elab_leanfm DepositHistoriesFile "../../book/generated/legal-session-inference/DepositHistories.leanfm"
#elab_leanfm ScenariosFile "../../book/generated/legal-session-inference/Scenarios.leanfm"
#elab_leanfm CoreFile "../../book/generated/legal-session-inference/generative/Core.leanfm"
#elab_leanfm GoServerFile "../../projects/GoServer/source/cmd/demo/static/session/goserver.leanfm"

/-! The two readings agree -/

#guard agrees (include_str "../../examples/sessions/PlaceOrder.leanfm") (PlaceOrderFile.PlaceOrder "Client" "Shop" "Bank")
-- a declared choice with probabilities and delays, and a require block after the protocol
#guard agrees (include_str "../../examples/sessions/Ping.leanfm") (PingFile.PingServer "Client" "Server")
-- a bounded loop is unrolled into the same copies, with the same renamed ids
#guard agrees (include_str "../../examples/sessions/BoundedRide.leanfm") (BoundedRideFile.BoundedRide "Rider" "Platform" "Driver")
-- clocks, obligations and accruals do not change the global type
#guard agrees (include_str "../../examples/sessions/DepositSettlement.leanfm") (DepositSettlementFile.DepositSettlement "Tenant" "Landlord")
#guard agrees (include_str "../../examples/sessions/RentWithRepairs.leanfm") (RentWithRepairsFile.RentWithRepairs "Tenant" "Landlord")
#guard agrees (include_str "../../examples/sessions/Loan.leanfm") (LoanFile.Loan "Borrower" "Lender")
#guard agrees (include_str "../../examples/sessions/UserLookup.leanfm") (UserLookupFile.UserLookup "Browser" "Proxy" "Api" "Db")
-- a keyed sessions block
#guard agrees (include_str "../../examples/oauth/SessionType.leanfm") (OAuthFile.SignIn "Browser" "App" "Idp")
#guard agrees (include_str "../../examples/vibecode/lending/Lending.protocol") (LendingFile.Lending "Member" "Desk" "Librarian")
#guard agrees (include_str "../../examples/vibecode/trip/Trip-parallel.protocol") (TripParallelFile.Trip "Traveler" "Agency" "Flights" "Hotels" "Payments")

/-! Labels, conditions and copies -/

-- a label no structure declares is a structure that carries nothing, as the text reading treats it
example : PlaceOrderFile.SoldOut := PlaceOrderFile.SoldOut.mk
-- a declared label keeps its fields
example : PlaceOrderFile.Pay := { amount := 10, card_secr := "4242" }

namespace Copies
structure Try where n : Nat
protocol Retry (A, B) {
  rec Again at most 2 {
    t: Try from A to B where t.n > 0 and not (t.n = 7);
    choice { Ok from B to A cause t; } or { No from B to A cause t; continue Again; }
  } otherwise { GiveUp from A to B; }
}
end Copies
-- copy 2 reads its own ids, and its condition is the renamed text the text reading writes
#guard agrees "structure Try where n : Nat
protocol Retry (A, B) {
  rec Again at most 2 {
    t: Try from A to B where t.n > 0 and not (t.n = 7);
    choice { Ok from B to A cause t; } or { No from B to A cause t; continue Again; }
  } otherwise { GiveUp from A to B; }
}" (Copies.Retry "A" "B")
#guard ((Copies.Retry "A" "B").messages.map fun i => (i.id, i.cause, i.guard.map (·.text))) ==
  [(some "t", none, some "t.n > 0 and not (t.n = 7)"), (none, some "t", none), (none, some "t", none),
   (some "t_2", none, some "(t_2.n > 0) and (not (t_2.n = 7))"), (none, some "t_2", none), (none, some "t_2", none),
   (none, none, none)]

/-! Text LeanFM writes is Lean too -/

-- a protocol given as JSON is echoed as text: a whole Lean file, with its types
def fromJson : String :=
  ((LeanFM.SessionTools.parseProtocol ((Json.parse ("{\"protocol\": {\"name\": \"Asking\", \"roles\": [\"A\", \"B\"], " ++
    "\"types\": [{\"name\": \"Ask\", \"fields\": [\"n : Nat\"]}], \"steps\": [{\"msg\": \"Ask\", \"id\": \"a\", " ++
    "\"from\": \"A\", \"to\": \"B\", \"where\": \"a.n > 0 and a.n < 9\"}, {\"msg\": \"Answer\", \"from\": \"B\", \"to\": \"A\", " ++
    "\"cause\": \"a\"}]}}")).toOption.getD Json.null)).toOption.map (·.lean)).getD ""
#guard fromJson.startsWith "import LeanFM.Session.Syntax"
#elab_leanfm_text FromJson fromJson
#guard agrees fromJson (FromJson.Asking "A" "B")
-- the text written back from a parse, with its structures, elaborates and agrees
def rewritten : String := match Text.parse (include_str "../../examples/sessions/PlaceOrder.leanfm") with
  | .ok p => Text.writeAll p.types [{ name := p.name, roles := p.roles, body := p.body }]
  | .error e => e
#elab_leanfm_text Rewritten rewritten
#guard agrees rewritten (Rewritten.PlaceOrder "Client" "Shop" "Bank")
-- annotations written back (delays as samples, amounts, declared choices) are Lean as well
def rewrittenRide : String := match Text.parse (include_str "../../examples/sessions/BoundedRide.leanfm") with
  | .ok p => Text.writeAll p.types [{ name := p.name, roles := p.roles, body := p.body }]
  | .error e => e
#elab_leanfm_text RewrittenRide rewrittenRide

-- the language reference's example is a Lean file
def referenceExample : String :=
  ((((LeanFM.SessionTools.reference.splitOn "## A protocol\n\n```lean\n")[1]?).getD "").splitOn "```").head!
#guard referenceExample.startsWith "import LeanFM.Session.Syntax"
#elab_leanfm_text ReferenceExample referenceExample

/-! Negative: what is not Lean is an error when the file is elaborated -/

namespace Refused
structure Pay where amount : Nat
structure Quote where price : Nat

-- a field the message does not have
/-- error: Invalid field `total`: The environment does not contain `LeanFM.Session.LeanSyntaxTests.Refused.Pay.total`, so it is not possible to project the field `total` from an expression
  p
of type `Pay` -/
#guard_msgs (error) in
protocol Bad1 (A, B) { p: Pay from A to B where p.total = 1; }

-- an id no earlier message has
/-- error: where z.amount = 1: z is not the id of this message or an earlier one -/
#guard_msgs (error) in
protocol Bad2 (A, B) { p: Pay from A to B where z.amount = 1; }

-- a protocol and one of its labels cannot share a name
/-- error: protocol Quote has a message Quote; in Lean they would be two declarations with one name, so rename one of them -/
#guard_msgs (error) in
protocol Quote (A, B) { Quote from A to B; }

-- a repeated role would silently shadow the first
/-- error: role names must be distinct -/
#guard_msgs (error) in
protocol Bad3 (A, A) { Pay from A to A; }

-- Lean code is not a condition: the condition language has no function application or tactics, so
-- such a condition is an error, and nothing in it is elaborated
/-- error: where f p.amount: unexpected text after the condition -/
#guard_msgs (error) in
protocol Bad4 (A, B) { p: Pay from A to B where f p.amount; }

/-- error: where p.amount = 1 := by decide: unexpected character : -/
#guard_msgs (error) in
protocol Bad5 (A, B) { p: Pay from A to B where p.amount = 1 := by decide; }
end Refused

-- the text reading refuses the same name clash, and reads past the Lean header
#guard (Text.parse "protocol Quote (A, B) { Quote from A to B; }") matches .error _
-- and names that are Lean keywords, which Lean could not read
#guard (match Text.parse "protocol P (A, B) { protected: Pay from A to B; }" with
  | .error e => (e.splitOn "expected").length > 1 | .ok _ => false)
#guard (Text.parse "protocol P (A, B) { Pay from A to B; }") matches .ok _
def headed := "import LeanFM.Session.Syntax\n/-- d -/\nstructure Pay where amount : Nat\nprotocol P (A, B) { Pay from A to B; }"
#guard ((Text.parse headed).toOption.map fun p => p.types.map (·.doc)) == some ["d"]

end LeanFM.Session.LeanSyntaxTests
