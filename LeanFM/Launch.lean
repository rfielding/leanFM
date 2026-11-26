import Std.Time
import LeanFM.EventLog
import LeanFM.Env

/-! How long a server took from launch to its first line of code (clause selfhost.env.launch).

Everything a program computes before `main` (each module's top-level constants and initializers) is
invisible to its own logs. The shell stamps the launch, `LEANFM_LAUNCHED_NS=$(date +%s%N)`, and the
server reads the stamp first in `main`: the gap is that cost. -/

namespace LeanFM.Launch

/-- The variable holding the launch time, nanoseconds since the Unix epoch. -/
def envName : String := "LEANFM_LAUNCHED_NS"

/-- Milliseconds from launch to `main`, once `read` has seen a stamp. -/
initialize initMs : IO.Ref (Option Nat) ← IO.mkRef none

/-- The stamp itself, nanoseconds since the Unix epoch, once `read` has seen one. -/
initialize stampNs : IO.Ref (Option Nat) ← IO.mkRef none

/-- Read the stamp, first in `main`. Unset means no measurement; a malformed stamp, or one more than a
second after now, stops the server naming the variable. -/
def read : IO Unit := do
  let now : Int := (← Std.Time.Timestamp.now).toNanosecondsSinceUnixEpoch.val
  match ← IO.getEnv envName with
  | none => pure ()
  | some raw =>
    let v := raw.trimAscii.toString
    let some stamp := v.toNat?
      | throw <| IO.userError s!"{envName} must be the launch time in nanoseconds since the Unix epoch, as date +%s%N writes it, not {(v.take 40).toString}"
    if (stamp : Int) > now + 1000000000 then
      throw <| IO.userError s!"{envName} is {stamp}, more than a second after the moment it was read ({now}); set it just before launching the server"
    initMs.set (some ((now - stamp).toNat / 1000000))
    stampNs.set (some stamp)

/-- The listening line's suffix: ` (initialized in N ms)`, or nothing without a stamp. -/
def note : IO String := do
  return match ← initMs.get with
    | some ms => s!" (initialized in {ms} ms)"
    | none => ""

/-- This process as an actor in event lines: `exe@pid`. -/
def actor (exe : String) : IO String := return s!"{exe}@{← IO.Process.getPID}"

/-- Which code is running (selfhost.env.launch): the commit, the tracked files that differ from it (at
most 20 named, the rest counted) and whether none do, so a log says whether it came from a clean,
reproducible commit. Outside a checkout, or without git, the commit is null and clean is false. -/
def provenance : IO (List (String × Lean.Json)) := do
  let run (args : Array String) : IO (Option String) := do
    try
      let o ← IO.Process.output { cmd := "git", args }
      return if o.exitCode == 0 then some o.stdout else none
    catch _ => return none
  let commit := (← run #["rev-parse", "HEAD"]).map (·.trimAscii.toString) |>.filter (·.length == 40)
  let changed := ((← run #["diff", "--name-only", "HEAD"]).map fun s => (s.splitOn "\n").filter (· != "")).getD []
  return [("commit", match commit with | some c => Lean.Json.str c | none => Lean.Json.null),
    ("changedFiles", Lean.Json.arr ((changed.take 20).map Lean.Json.str).toArray),
    ("changedFilesMore", Lean.toJson (changed.length - min changed.length 20)),
    ("clean", Lean.Json.bool (commit.isSome && changed.isEmpty))]

/-- The startup as event lines of protocol ServerStart (selfhost.session.event-log): Launch from the
shell at the stamp, when there is one, then MainEntered from the server back to the shell. Returns
the Launch event's id, the cause of what follows. -/
def emitStart (h : IO.FS.Stream) (exe : String) : IO (Option String) := do
  let me ← actor exe
  let launch ← match ← stampNs.get with
    | some t => some <$> EventLog.emit h me me "ServerStart" "Launch" (.inl ("Shell", "Server")) (ts := some t)
    | none => pure none
  -- the configuration it started with: each variable it reads, a secret only as set (selfhost.env.registry)
  let _ ← EventLog.emit h me me "ServerStart" "MainEntered" (.inl ("Server", "Shell")) (cause := launch)
    (payload := Lean.Json.mkObj ((← provenance) ++ [("settings", ← Env.settings exe)]))
  return launch

/-- The server listens: the Listening event line, caused by the Launch. -/
def emitListening (h : IO.FS.Stream) (exe : String) (launch : Option String) : IO Unit := do
  let me ← actor exe
  let _ ← EventLog.emit h me me "ServerStart" "Listening" (.inl ("Server", "Shell")) (cause := launch)

end LeanFM.Launch
