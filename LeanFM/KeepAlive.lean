import Lean

/-! HTTP keep-alive for both servers (clause selfhost.mcp.keepalive): a connection stays open for
further requests until the client asks to close, a request cannot be read, it has served its
quota, or it sits idle too long; open connections are capped.

Requirements this module is held to:
* positive (AG): every setting is read once at startup and a bad one stops the server naming it.
* negative (never): more connections open than the cap (`tryOpen` refuses one more).
Tested in LeanFM/MCPTests.lean. -/

namespace LeanFM.KeepAlive

structure Settings where
  /-- requests one connection serves before it closes -/
  requests : Nat := 100
  /-- seconds a kept connection may wait for its next request -/
  idleSeconds : Nat := 30
  /-- connections open at once -/
  connections : Nat := 64
  deriving Inhabited

initialize settings : IO.Ref Settings ← IO.mkRef {}
initialize openCount : IO.Ref Nat ← IO.mkRef 0

private def envNat (name : String) (lo hi : Nat) : IO (Option Nat) := do
  match ← IO.getEnv name with
  | none => pure none
  | some raw => match raw.trimAscii.toString.toNat? with
    | some n => if lo ≤ n && n ≤ hi then pure (some n)
                else throw <| IO.userError s!"{name} must be {lo} to {hi}"
    | none => throw <| IO.userError s!"{name} must be a decimal number"

/-- LEANFM_KEEPALIVE_REQUESTS, LEANFM_KEEPALIVE_SECONDS and LEANFM_MAX_CONNECTIONS, read once at
startup (selfhost.env.startup). -/
def configureFromEnv : IO Unit := do
  let d : Settings := {}
  let requests := (← envNat "LEANFM_KEEPALIVE_REQUESTS" 1 100000).getD d.requests
  let idleSeconds := (← envNat "LEANFM_KEEPALIVE_SECONDS" 1 3600).getD d.idleSeconds
  let connections := (← envNat "LEANFM_MAX_CONNECTIONS" 1 100000).getD d.connections
  settings.set { requests, idleSeconds, connections }

/-- Count one more open connection, or refuse it when the cap is reached. -/
def tryOpen : IO Bool := do
  let cap := (← settings.get).connections
  openCount.modifyGet fun n => if n < cap then (true, n + 1) else (false, n)

def close : IO Unit := openCount.modify (· - 1)

/-- Whether a request's headers ask to close the connection after its answer. -/
def wantsClose (headers : List (String × String)) : Bool :=
  headers.any fun (k, v) => k.toLower == "connection" && (v.toLower.splitOn ",").any (·.trimAscii.toString == "close")

end LeanFM.KeepAlive
