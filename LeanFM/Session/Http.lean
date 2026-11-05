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

/-- Cuts when some responses are streams. `streams a b` says that a response from `b` to `a` may
be a stream (server-sent events, chunked transfer): any number of messages travel back on the
connection the request came in on, so answering a request does not close it. -/
def httpCutsStreaming (g : Global R) (isHttp : R → R → Bool) (mayCall : R → R → Bool)
    (streams : R → R → Bool) : List String :=
  (runs g).flatMap (fun run =>
    let msgs := run.filterMap (fun s => match s with | .msg i => some i | .act _ _ => none)
    let byId (id : String) := msgs.find? (·.id == some id)
    let chain (i : Interaction R) : List String :=
      let rec go (fuel : Nat) (c : Option String) : List String :=
        match fuel, c with
        | fuel + 1, some id => id :: go fuel ((byId id).bind (·.cause))
        | _, _ => []
      go 64 i.cause
    let step := fun (acc : List (String × R × R) × List String) (i : Interaction R) =>
      let (pending, cuts) := acc
      if !isHttp i.src i.dst then acc else
      let inChain := (chain i).filterMap (fun id => pending.find? (·.1 == id))
      -- a response: the nearest pending request in the cause chain made by the receiver of this
      -- message to its sender
      match inChain.find? (fun (_, caller, callee) => callee == i.src && caller == i.dst) with
      | some (p, caller, callee) =>
        (if streams caller callee then pending else pending.filter (·.1 != p), cuts)
      | none =>
        let cuts :=
          if mayCall i.src i.dst then cuts
          else match inChain.find? (fun (_, _, callee) => callee == i.src) with
            | some (p, caller, _) => cuts ++ [s!"{i.label} answers {p}, which {caller} sent to {i.src}, but goes to {i.dst}"]
            | none => cuts ++ [s!"{i.label} is a request from {i.src} to {i.dst}, which {i.src} may not call"]
        (pending ++ [((i.id.getD i.label), i.src, i.dst)], cuts)
    (msgs.foldl step ([], [])).2) |>.eraseDups

/-- Cuts on HTTP channels. `isHttp a b` says whether the channel from `a` to `b` is HTTP, and
`mayCall a b` whether `a` may start a request to `b` (in a deployment, whether `b` exposes an
interface that `a` can reach). -/
def httpCuts (g : Global R) (isHttp : R → R → Bool) (mayCall : R → R → Bool) : List String :=
  httpCutsStreaming g isHttp mayCall (fun _ _ => false)

end LeanFM.Session.Global
