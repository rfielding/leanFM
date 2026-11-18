import Std.Data.HashMap
import Std.Data.HashSet
import LeanFM.Session.Http
import LeanFM.Session.Calls
import LeanFM.Session.Conform

/-!
# Reviewing a protocol design (clause selfhost.session.review)

`Global.review` runs every check that applies to a protocol and answers findings, each with a
concrete edit to try, so a designer (or Claude) can iterate on one answer:

* the core rules (one decider per choice, every role can tell the branch, causes it saw), with the
  usual fix for each;
* the HTTP discipline wherever the protocol says a message is HTTP: a message with a `route` makes
  its channel HTTP and lets its sender call its receiver, so no flags are needed; a request that
  never gets a response comes with the response line to add, and a response to a routed request
  without a status is named;
* the session graph: a state reached by some steps from which the session can never end (a loop
  with no way out), with those steps;
* roles listed that take no part.

Negative requirements: a finding is never invented for a protocol that has none (the sample
protocols review clean); text from the protocol appears in findings and suggestions only as the
names it already had; the graph is bounded as for temporal properties and says so.
-/

namespace LeanFM.Session

structure Finding where
  kind       : String
  message    : String
  suggestion : String
  deriving Inhabited, Repr, BEq

namespace Review

/-- Text between `a` and `b` in `s`, if both occur in that order. -/
def between (s a b : String) : Option String :=
  match s.splitOn a with
  | _ :: rest :: _ => match rest.splitOn b with
    | x :: _ :: _ => some x
    | _ => none
  | _ => none

/-- The usual fix for an issue of the core rules. -/
def suggestCore (msg : String) : String :=
  if (msg.splitOn "cannot tell which branch").length > 1 then
    let r := (msg.splitOn " cannot tell").headD "the role"
    s!"Send {r} a message in each branch that says which branch it is; or, if {r} handles each request on its own (a mailer, a gateway), put its exchanges in nested sessions blocks."
  else if (msg.splitOn "never saw").length > 1 then
    "Give it as its cause a message its sender sent or received before it, or drop the cause."
  else if (msg.splitOn "race").length > 1 then
    "Let one role send the first message of every branch: that role decides."
  else if (msg.splitOn "cannot tell apart").length > 1 then
    "Start each kind of session the service handles with a different message."
  else "See the reference's Reading the answers."

/-- The usual fix for an HTTP cut. -/
def suggestHttp (msg : String) : String :=
  if (msg.splitOn "never gets a response").length > 1 then
    let head := (msg.splitOn " from ").headD ""
    let a := (between msg " from " " to ").getD "the caller"
    let b := (between msg " to " " never").getD "the callee"
    let (label, id) := match between head "(" ")" with
      | some i => ((head.splitOn " (").headD head, some i)
      | none => (head, none)
    match id with
    | some i => s!"Answer it: `{label}Done from {b} to {a} cause {i} status 200;` (or the status it means)."
    | none => s!"Give {label} an id (`x: {label} from {a} to {b} ...`), then answer it: `{label}Done from {b} to {a} cause x status 200;`."
  else if (msg.splitOn "may not call").length > 1 then
    "If the receiver serves it over HTTP, give it a route; otherwise make it the answer to a request the receiver made (cause naming that request)."
  else if (msg.splitOn "but goes to").length > 1 then
    "Send it back to the role that made the request, or make it a new request with its own route."
  else "See the reference's HTTP rules."

/-- From a session's state graph: states from which no terminal state can be reached, each with
the steps that lead to it. -/
def neverEnds (g : StateGraph) : List (List String) := Id.run do
  -- states that can still finish: terminals, and backwards along edges from them (one pass over a
  -- reverse index, so it stays linear for graphs of thousands of states)
  let mut preds : Std.HashMap String (Array String) := {}
  let mut succs : Std.HashMap String (Array (String × String)) := {}
  for (a, b, n) in g.edges do
    preds := preds.insert b ((preds.getD b #[]).push a)
    succs := succs.insert a ((succs.getD a #[]).push (b, n.label))
  let mut canFinish : Std.HashSet String := {}
  let mut stack : Array String := #[]
  for t in g.terminals do
    if !canFinish.contains t then
      canFinish := canFinish.insert t
      stack := stack.push t
  while !stack.isEmpty do
    let s := stack.back!
    stack := stack.pop
    for p in preds.getD s #[] do
      if !canFinish.contains p then
        canFinish := canFinish.insert p
        stack := stack.push p
  let doomed : Std.HashSet String := g.states.foldl (fun acc s => if canFinish.contains s then acc else acc.insert s) {}
  if doomed.isEmpty then return []
  -- shortest steps from s0 to the first doomed state, breadth first
  let mut parent : Std.HashMap String (String × String) := {}
  let mut seen : Std.HashSet String := ({} : Std.HashSet String).insert "s0"
  let mut queue : Array String := #["s0"]
  let mut head := 0
  let mut hit : Option String := if doomed.contains "s0" then some "s0" else none
  while hit.isNone && head < queue.size do
    let s := queue[head]!
    head := head + 1
    for (b, label) in succs.getD s #[] do
      if hit.isNone && !seen.contains b then
        seen := seen.insert b
        parent := parent.insert b (s, label)
        queue := queue.push b
        if doomed.contains b then hit := some b
  match hit with
  | none => return []
  | some d =>
    let mut path : List String := []
    let mut cur := d
    for _ in [0:g.states.length] do
      match parent.get? cur with
      | some (p, l) => path := l :: path; cur := p
      | none => break
    return [path]

end Review

open Review in
/-- Every check that applies, as findings with suggested edits, with the checks that could not run and why: liveness needs the whole state graph,
and a protocol over its bound (GoServer's parallel sessions interleave into more than 2000 states)
is reported as not checked rather than stopping the review, so the structure, HTTP and role checks
still answer. -/
def Global.reviewAll (g : Global String) (roles : List String) : List Finding × List String := Id.run do
  let core := (g.issues roles ++ g.httpIssues).map fun m => { kind := "structure", message := m, suggestion := suggestCore m : Finding }
  -- HTTP where the protocol says so: routes mark requests
  let msgs := g.messages
  let routed := (msgs.filter (·.route.isSome)).map fun i => (i.src, i.dst)
  let isHttp (a b : String) := routed.contains (a, b) || routed.contains (b, a)
  let mayCall (a b : String) := routed.contains (a, b)
  let http := if routed.isEmpty then [] else
    (g.httpCuts isHttp mayCall).map fun m => { kind := "http", message := m, suggestion := suggestHttp m : Finding }
  let statusless := if routed.isEmpty then [] else
    (g.calls.flatMap fun c => c :: c.nested).filter (·.request.route.isSome) |>.flatMap fun c =>
      (c.responses.filter (·.status.isNone)).map fun r =>
        { kind := "http", message := s!"{r.label} answers {c.request.label} ({c.request.route.getD ""}) without a status",
          suggestion := s!"Add the status it means, such as `status 200`, to {r.label}." : Finding }
  let (graphLoops, notChecked) := match g.stateGraph with
    | .ok graph => (neverEnds graph, [])
    | .error why => ([], [s!"liveness (whether every session can end): {why}"])
  let loops := graphLoops.map fun path =>
    { kind := "liveness",
      message := if path.isEmpty then "the session can never end, whatever happens"
        else s!"after {", ".intercalate path}, the session can never end",
      suggestion := "Give the loop a branch that leaves it (one without continue), or end it." : Finding }
  let idle := roles.filter (fun r => !(msgs.any fun i => i.src == r || i.dst == r) && !g.involves r) |>.map fun r =>
    { kind := "roles", message := s!"{r} takes no part", suggestion := s!"Remove {r} from the role list, or give it its messages." : Finding }
  return (core ++ http ++ statusless.eraseDups ++ loops ++ idle, notChecked)

/-- The findings alone; a check that could not run is an error, as before. -/
def Global.review (g : Global String) (roles : List String) : Except String (List Finding) :=
  match g.reviewAll roles with
  | (fs, []) => .ok fs
  | (_, why :: _) => .error why

end LeanFM.Session
