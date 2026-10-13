import LeanFM.Artifacts
import LeanFM.MDP
import LeanFM.MDPDiagram

namespace StochasticUserMDP
open LeanFM

inductive State where
  | start | requestQueued | menuReady
  | browseQueued | purchaseQueued
  | browseReady | purchaseReady
  | browsed | purchased
deriving DecidableEq, Repr

inductive Message where
  | openSession | showOptions | chooseBrowse | choosePurchase
  | showResults | confirmPurchase | observeResults | observeReceipt
deriving DecidableEq, Repr

def states : List State :=
  [.start, .requestQueued, .menuReady, .browseQueued, .purchaseQueued,
   .browseReady, .purchaseReady, .browsed, .purchased]

/-- The user is stochastic only at `menuReady`. Every server-controlled state
has one deterministic action. Dwell values are synthetic milliseconds. -/
def choices : State -> List (Choice State Message)
  | .start => [.action .openSession 1 .requestQueued]
  | .requestQueued => [.action .showOptions 1 .menuReady]
  | .menuReady => [.chanceEvents
      [ { weight := 3, dwell := 1, value := (.chooseBrowse, .browseQueued) }
      , { weight := 2, dwell := 1, value := (.choosePurchase, .purchaseQueued) } ]]
  | .browseQueued => [.action .showResults 2 .browseReady]
  | .purchaseQueued => [.action .confirmPurchase 5 .purchaseReady]
  | .browseReady => [.action .observeResults 1 .browsed]
  | .purchaseReady => [.action .observeReceipt 1 .purchased]
  | .browsed | .purchased => []

def mdp : MDP State Message := { choices }

def policy (state : State) : Option (Choice State Message) :=
  (choices state).head?

def serverStates : List State := [.requestQueued, .browseQueued, .purchaseQueued]

def exactlyOneDeterministicChoice (state : State) : Bool :=
  match choices state with
  | [choice] => choice.isDeterministic
  | _ => false

def initial : PathStats State Message :=
  { mass := 1, scale := 1, lastDwell := 0, elapsed := 0,
    state := .start, trace := [] }

def terminalPaths : List (PathStats State Message) :=
  runPolicy 5 policy [initial]

def commonScale : Nat := 5

def scaledMass (path : PathStats State Message) : Nat :=
  path.mass * (commonScale / path.scale)

def terminalMass : Nat :=
  terminalPaths.foldl (fun sum path => sum + scaledMass path) 0

def reward : State -> Nat
  | .browsed => 1
  | .purchased => 8
  | _ => 0

def expectedRewardNumerator : Nat :=
  terminalPaths.foldl (fun sum path => sum + scaledMass path * reward path.state) 0

def expectedLatencyNumerator : Nat :=
  terminalPaths.foldl (fun sum path => sum + scaledMass path * path.elapsed) 0

example : mdp.isValidOn states = true := by native_decide
example : serverStates.all exactlyOneDeterministicChoice = true := by native_decide
example : terminalPaths.map (fun path => (path.mass, path.scale, path.elapsed, path.state)) =
    [(3, 5, 6, .browsed), (2, 5, 9, .purchased)] := by native_decide
example : terminalMass = commonScale := by native_decide
example : expectedRewardNumerator = 19 := by native_decide
example : expectedLatencyNumerator = 36 := by native_decide

def interactionOutput : DesiredOutput :=
  { id := "mdp.stochastic_user.interaction"
  , prompt := "Give a worked MDP example with a deterministic server driven by a stochastic user and diagrams."
  , question := "Which messages carry stochastic choice and which server messages are deterministic?"
  , kind := .interactionDiagram
  , eventSource := "StochasticUserMDPExample.lean checked Message transitions"
  , reducer := "project sender, receiver, message, relative branch weight and deterministic probability-one steps"
  , unit := "messages and exact probability mass; synthetic example boundary" }

def stateOutput : DesiredOutput :=
  { id := "mdp.stochastic_user.states"
  , prompt := interactionOutput.prompt
  , question := "How does probability mass move through the composed user/server state space?"
  , kind := .stateMachine
  , eventSource := "StochasticUserMDPExample.lean checked State and Choice values"
  , reducer := "render every supported transition with its exact relative probability and dwell"
  , unit := "states, messages, exact probability and synthetic milliseconds" }

def chartOutput : DesiredOutput :=
  { id := "mdp.stochastic_user.outcomes"
  , prompt := interactionOutput.prompt
  , question := "What terminal distribution is induced by the user choice?"
  , kind := .function2d
  , eventSource := "runPolicy 5 over the checked policy from initial state"
  , reducer := "sum normalized terminal path mass by terminal state"
  , unit := "exact probability; one session and five transitions" }

def interactionTeX : String := MDPDiagram.renderInteractionTeX
  ["User", "Server"]
  [ { src := "User", dst := "Server", label := "openSession [1]" }
  , { src := "Server", dst := "User", label := "showOptions [1]" }
  , { src := "User", dst := "Server", label := "chooseBrowse [3/5]" }
  , { src := "Server", dst := "User", label := "showResults [1]" }
  , { src := "User", dst := "Server", label := "choosePurchase [2/5]" }
  , { src := "Server", dst := "User", label := "confirmPurchase [1]" } ]

def stateTeX : String := MDPDiagram.renderStateTeX
  [ { id := "start", label := "start", x := 0, y := 0 }
  , { id := "rq", label := "request queued", x := 0, y := -2 }
  , { id := "menu", label := "menu ready", x := 0, y := -4 }
  , { id := "bq", label := "browse queued", x := -4, y := -6 }
  , { id := "pq", label := "purchase queued", x := 4, y := -6 }
  , { id := "br", label := "results ready", x := -4, y := -8 }
  , { id := "pr", label := "receipt ready", x := 4, y := -8 }
  , { id := "bd", label := "browsed", x := -4, y := -10, terminal := true }
  , { id := "pd", label := "purchased", x := 4, y := -10, terminal := true } ]
  [ { src := "start", dst := "rq", label := "openSession; 1; 1 ms" }
  , { src := "rq", dst := "menu", label := "showOptions; 1; 1 ms" }
  , { src := "menu", dst := "bq", label := "chooseBrowse; 3/5; 1 ms" }
  , { src := "menu", dst := "pq", label := "choosePurchase; 2/5; 1 ms" }
  , { src := "bq", dst := "br", label := "showResults; 1; 2 ms" }
  , { src := "pq", dst := "pr", label := "confirmPurchase; 1; 5 ms" }
  , { src := "br", dst := "bd", label := "observe; 1; 1 ms" }
  , { src := "pr", dst := "pd", label := "observe; 1; 1 ms" } ]

def outcomeTeX : String := MDPDiagram.renderOutcomeBarsTeX
  [{ label := "browse", weight := 3 }, { label := "purchase", weight := 2 }]

def generate : IO Unit := do
  IO.FS.writeFile "book/generated/stochastic-user-interaction.tex" interactionTeX
  IO.FS.writeFile "book/generated/stochastic-user-states.tex" stateTeX
  IO.FS.writeFile "book/generated/stochastic-user-outcomes.tex" outcomeTeX
  IO.FS.writeFile "book/generated/stochastic-user-provenance.txt"
    (reprStr interactionOutput ++ "\n" ++ reprStr stateOutput ++ "\n" ++ reprStr chartOutput ++ "\n")
  IO.println "ok: stochastic user MDP has valid mass, deterministic server steps, reward 19/5, latency 36/5"

end StochasticUserMDP

def main : IO Unit := StochasticUserMDP.generate
