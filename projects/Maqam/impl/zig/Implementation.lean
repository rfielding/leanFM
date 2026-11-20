import LeanFM.Artifacts

/-!
# maqam-live: Zig implementation mapping (port in progress)

The second implementation of `spec/Requirements.lean`, written in Zig under `impl/zig/source/`.
It starts empty on purpose: `make spec-check` reports it as invalid and lists every actor and
message that still has no binding, so the check's report is the port's to-do list. Bind each
actor and message here as the Zig code that realizes it lands, the same way
`impl/rust/Implementation.lean` does for the Rust; the requirements never change for the port.

The Rust implementation stays the default, so an unfinished port never blocks the specification.
-/

namespace Project.Implementation

open LeanFM

def why (id reason : String) : List RequirementJustification := [{ requirementId := id, reason }]
def actor (name typeName file id : String) : ActorCodegen := { actor := name, typeName, sourceFile := file, justifications := why id "Implements the accepted actor role." }
def chan (name wire channel id reason : String) : MessageCodegen := { message := name, wireType := wire, transport := .inProcessChannel channel, justifications := why id reason }

def implementation : ImplementationSpec :=
  { requirementId := "maqam.visible_behavior"
  , target := .zig
  , moduleName := "maqam-live"
  , outputDirectory := "impl/zig/source/"
  , actors := []
  , messages := []
  , channels :=
      { sendFunction := ""
      , receiveFunction := ""
      , tryReceiveFunction := ""
      , closeFunction := ""
      , sendFull := .blockWithoutMutation
      , receiveEmpty := .blockWithoutMutation
      , tryReceiveEmpty := .returnNoneKeepRunnable
      , sendClosed := .rejectWithoutMutation
      , receiveClosed := .drainThenReturnClosed
      , closeSemantics := .idempotentWakeWaiters
      , justifications := [] } }

end Project.Implementation
