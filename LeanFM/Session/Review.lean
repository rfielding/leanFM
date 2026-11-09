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
  -- states that can still finish: terminals, and everything with an edge into them
  let mut canFinish := g.terminals
  let mut changed := true
  while changed do
    changed := false
    for (a, b, _) in g.edges do
      if canFinish.contains b && !canFinish.contains a then
        canFinish := a :: canFinish
        changed := true
  let doomed := g.states.filter (!canFinish.contains ·)
  if doomed.isEmpty then return []
  -- shortest steps from s0 to the first doomed state
  let mut parent : List (String × (String × String)) := []
  let mut seen := ["s0"]
  let mut frontier := ["s0"]
  let mut hit : Option String := if doomed.contains "s0" then some "s0" else none
  while hit.isNone && !frontier.isEmpty do
    let mut next := []
    for s in frontier do
      for (a, b, n) in g.edges do
        if a == s && !seen.contains b then
          seen := b :: seen
          parent := (b, (a, n.label)) :: parent
          next := next ++ [b]
          if hit.isNone && doomed.contains b then hit := some b
    frontier := next
  match hit with
  | none => return []
  | some d =>
    let mut path : List String := []
    let mut cur := d
    for _ in [0:g.states.length] do
      match parent.lookup cur with
      | some (p, l) => path := l :: path; cur := p
      | none => break
    return [path]

end Review

open Review in
/-- Every check that applies, as findings with suggested edits. -/
def Global.review (g : Global String) (roles : List String) : Except String (List Finding) := do
  let core := (g.issues roles).map fun m => { kind := "structure", message := m, suggestion := suggestCore m : Finding }
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
  let graph ← g.stateGraph
  let loops := (neverEnds graph).map fun path =>
    { kind := "liveness",
      message := if path.isEmpty then "the session can never end, whatever happens"
        else s!"after {", ".intercalate path}, the session can never end",
      suggestion := "Give the loop a branch that leaves it (one without continue), or end it." : Finding }
  let idle := roles.filter (fun r => !(msgs.any fun i => i.src == r || i.dst == r) && !g.involves r) |>.map fun r =>
    { kind := "roles", message := s!"{r} takes no part", suggestion := s!"Remove {r} from the role list, or give it its messages." : Finding }
  return core ++ http ++ statusless.eraseDups ++ loops ++ idle

end LeanFM.Session
