import LeanFM.Session.Global

/-!
# The HTTP call discipline

Optional. Over HTTP a response travels back on the connection its request came in on. So every
message on an HTTP channel is either a request to a role that serves requests, or the response
to the nearest pending request in its `cause` chain, sent back to the role that asked. A global
type that breaks the rule is *cut*: it must be un-cut by writing the missing calls and returns,
or by giving the receiver an interface to call.
-/

namespace LeanFM.Session.Global

variable {R : Type} [DecidableEq R] [ToString R]

/-- Runs that reach the end of the protocol: like `runs`, but a run that goes round a loop again
(ends at `continue`) is left out, since it has not finished. -/
partial def finishedRuns : Global R → List (List (Step R))
  | .msg i k => (finishedRuns k).map (.msg i :: ·)
  | .act r l k => (finishedRuns k).map (.act r l :: ·)
  | .choice bs => bs.flatMap finishedRuns
  | .par bs k | .join _ bs k =>
    let front := bs.foldl (fun acc b => acc.flatMap (fun p => (finishedRuns b).map (p ++ ·))) [[]]
    front.flatMap (fun p => (finishedRuns k).map (p ++ ·))
  | .loop _ b => finishedRuns b
  | .sessions b k => finishedRuns k ++ (finishedRuns b).flatMap (fun p => (finishedRuns k).map (p ++ ·))
  | .box _ b k => finishedRuns (andThen b k)
  | .var _ => []
  | .done => [[]]

/-- Replays one run on the HTTP channels: the requests still waiting for a response at its end
(id or label, caller, callee, label) and the cuts found on the way. -/
def replay (isHttp : R → R → Bool) (mayCall : R → R → Bool) (streams : R → R → Bool)
    (run : List (Step R)) : List (String × R × R × String) × List String :=
  let msgs := run.filterMap (fun s => match s with | .msg i => some i | .act _ _ => none)
  let byId (id : String) := msgs.find? (·.id == some id)
  let chain (i : Interaction R) : List String :=
    let rec go (fuel : Nat) (c : Option String) : List String :=
      match fuel, c with
      | fuel + 1, some id => id :: go fuel ((byId id).bind (·.cause))
      | _, _ => []
    go 64 i.cause
  -- pending: (key, caller, callee, label, answered at least once)
  let step := fun (acc : List (String × R × R × String × Bool) × List String) (i : Interaction R) =>
    let (pending, cuts) := acc
    if !isHttp i.src i.dst then acc else
    let inChain := (chain i).filterMap (fun id => pending.find? (·.1 == id))
    -- a response: the nearest pending request in the cause chain made by the receiver of this
    -- message to its sender
    match inChain.find? (fun (_, caller, callee, _, _) => callee == i.src && caller == i.dst) with
    | some (p, caller, callee, _, _) =>
      (if streams caller callee
        then pending.map (fun e => if e.1 == p then (e.1, e.2.1, e.2.2.1, e.2.2.2.1, true) else e)
        else pending.filter (·.1 != p), cuts)
    | none =>
      let cuts :=
        if mayCall i.src i.dst then cuts
        else match inChain.find? (fun (_, _, callee, _, _) => callee == i.src) with
          | some (p, caller, _, _, _) => cuts ++ [s!"{i.label} answers {p}, which {caller} sent to {i.src}, but goes to {i.dst}"]
          | none => cuts ++ [s!"{i.label} is a request from {i.src} to {i.dst}, which {i.src} may not call"]
      (pending ++ [((i.id.getD i.label), i.src, i.dst, i.label, false)], cuts)
  let (pending, cuts) := msgs.foldl step ([], [])
  (pending.filterMap (fun (k, a, b, l, answered) => if answered then none else some (k, a, b, l)), cuts)

/-- Cuts when some responses are streams. `streams a b` says that a response from `b` to `a` may
be a stream (server-sent events, chunked transfer): any number of messages travel back on the
connection the request came in on, so answering a request does not close it. A request that a
run reaching the end of the protocol leaves without any response is a cut too: over HTTP every
request gets one. -/
def httpCutsStreaming (g : Global R) (isHttp : R → R → Bool) (mayCall : R → R → Bool)
    (streams : R → R → Bool) : List String :=
  let cuts := (runs g).flatMap (fun run => (replay isHttp mayCall streams run).2)
  let unanswered := (finishedRuns g).flatMap (fun run =>
    (replay isHttp mayCall streams run).1.map fun (k, caller, callee, label) =>
      let name := if k == label then label else s!"{label} ({k})"
      s!"{name} from {caller} to {callee} never gets a response")
  (cuts ++ unanswered).eraseDups

/-- Cuts on HTTP channels. `isHttp a b` says whether the channel from `a` to `b` is HTTP, and
`mayCall a b` whether `a` may start a request to `b` (in a deployment, whether `b` exposes an
interface that `a` can reach). -/
def httpCuts (g : Global R) (isHttp : R → R → Bool) (mayCall : R → R → Bool) : List String :=
  httpCutsStreaming g isHttp mayCall (fun _ _ => false)

end LeanFM.Session.Global
