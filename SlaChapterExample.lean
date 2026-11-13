import LeanFM.SessionTools

/-! Generates the book's "Promises, assumptions and observation periods" section: the
    `session_sla` report for examples/sessions/UserLookup.leanfm against its stated assumptions,
    and the same tool on a small execution whose events carry reward vectors. Nothing here is
    written by hand: every number comes from LeanFM.Session.Sla through `session_sla`.
    Run from the LeanFM root: `lake env lean --run SlaChapterExample.lean`. -/

namespace SlaChapterExample
open Lean LeanFM LeanFM.SessionTools

/-- An event at `ms` milliseconds after a fixed instant; timestamps are nanoseconds since the
epoch, sent as decimal strings because they are past 2^53 (selfhost.session.envelope). -/
def t0 : Nat := 1794500000000000000
def ns (ms : Nat) : Json := Json.str (toString (t0 + ms * 1000000))

def ev (ms : Nat) (label src dst : String) (cause prev : Option Nat := none) (reward : Option Json := none) : Json :=
  Json.mkObj ([("ts", ns ms), ("label", Json.str label), ("from", Json.str src), ("to", Json.str dst)] ++
    (cause.map fun c => [("cause", ns c)]).getD [] ++ (prev.map fun p => [("prev", ns p)]).getD [] ++
    (reward.map fun r => [("reward", r)]).getD [])

def usd (role : String) (n : Int) : Json := Json.mkObj [(role, Json.mkObj [("USD", toJson n)])]

/-- A metered lookup: each answered ask moves the Browser's spend; the vector is written only
where it changes, and the third ask is never answered. -/
def execution : List Json :=
  [ ev 1000 "Ask" "A" "B" none none (some (usd "A" (-1)))
  , ev 1100 "Answer" "B" "A" (some 1000) (some 1000)
  , ev 2000 "Ask" "A" "B" none (some 1100) (some (usd "A" (-2)))
  , ev 2150 "Answer" "B" "A" (some 2000) (some 2000)
  , ev 3000 "Ask" "A" "B" none (some 2150) (some (usd "A" (-3)))
  , ev 4000 "Ask" "A" "B" none (some 3000) (some (usd "A" (-4)))
  , ev 4120 "Answer" "B" "A" (some 4000) (some 4000) ]

def metered := "protocol Metered (A, B) { q: Ask from A to B amount 1 USD; Answer from B to A cause q after 100 ms; }
require per q { at least 99/100 of q reach Answer within 300 ms over 300 entries; }"

def reportOf (r : Json) : String := (r.getObjValAs? String "report").toOption.getD ""

def main : IO Unit := do
  let lookupPath := "examples/sessions/UserLookup.leanfm"
  let lookup ← IO.FS.readFile lookupPath
  let design ← IO.ofExcept (sla (Json.mkObj [("lean", Json.str lookup)]))
  let run ← IO.ofExcept (sla (Json.mkObj [("lean", Json.str metered), ("events", Json.arr execution.toArray), ("at", ns 3000)]))
  IO.FS.createDirAll "book/generated"
  IO.FS.writeFile "book/generated/sla-userlookup.txt" (reportOf design ++ "\n")
  IO.FS.writeFile "book/generated/sla-execution.json" ((Json.arr execution.toArray).pretty ++ "\n")
  IO.FS.writeFile "book/generated/sla-execution.txt" (reportOf run ++ "\n")
  IO.FS.writeFile "book/generated/sla-provenance.txt" <| "\n".intercalate
    [ "prompt: the SLAs in the session type really seems to tie things together well. the way to keep state out of the actors is to put the state into the observable event stream."
    , "question: does UserLookup keep its promises under its stated assumptions, and what does an execution show before and after its observation period closes?"
    , s!"eventSource: {lookupPath}; the execution in SlaChapterExample.lean"
    , "reducer: LeanFM.SessionTools.sla (LeanFM.Session.Sla.design on the chain; Execution.make, trials and windows on the stream)"
    , "unit: entries of the require block's message id; probabilities as exact fractions; times in milliseconds; reward amounts per role and unit"
    , "boundary: the main protocol, one entry per occurrence of q; windows judged only once closed"
    , "generator: SlaChapterExample.lean" ] ++ "\n"
  IO.println s!"wrote book/generated/sla-*: design verdict {(design.getObjValAs? String "verdict").toOption.getD "?"}"

end SlaChapterExample

def main : IO Unit := SlaChapterExample.main
