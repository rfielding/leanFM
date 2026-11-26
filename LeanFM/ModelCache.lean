import Lean

/-! The model token (clause selfhost.mcp.model-token): session_ctl keeps the state graphs of recent
protocols in memory, so the next question about the same protocol skips rebuilding one.

Requirements this module is held to:
* positive (AG): an entry is reused only when its token is held and the call's text and arguments
  are exactly those it was built from; the least recently used entry goes when the cache is full.
* negative (never): a token derived from the text, or guessable (16 random bytes, hexadecimal);
  an entry reused for another text (a mismatch is a miss); the cache over its size; anything on disk.
Tested in LeanFM/ModelCacheTests.lean. -/

namespace LeanFM.ModelCache
open Lean

structure Entry where
  token  : String
  /-- the call's arguments but `model`, compact JSON, compared in full -/
  key    : String
  draft  : Json
  states : Nat
  used   : Nat
  deriving Inhabited

def defaultCapacity : Nat := 16
def maxCapacity : Nat := 1024

initialize cache : IO.Ref (Array Entry) ← IO.mkRef #[]
initialize capacity : IO.Ref Nat ← IO.mkRef defaultCapacity
initialize clock : IO.Ref Nat ← IO.mkRef 0

/-- LEANFM_MODEL_CACHE, read once at startup: 1 to 1024 entries; anything else stops the server
naming the variable (selfhost.env.startup). -/
def configureFromEnv : IO Unit := do
  match ← IO.getEnv "LEANFM_MODEL_CACHE" with
  | none => pure ()
  | some raw => match raw.trimAscii.toString.toNat? with
    | some n => if n ≥ 1 && n ≤ maxCapacity then capacity.set n
                else throw <| IO.userError s!"LEANFM_MODEL_CACHE must be 1 to {maxCapacity}"
    | none => throw <| IO.userError "LEANFM_MODEL_CACHE must be a decimal number"

/-- The arguments that decide the state graph: everything the call sends but the token itself. -/
def keyOf (args : Json) : String :=
  match args with
  | .obj kvs => (Json.mkObj (kvs.toList.filter (·.1 != "model"))).compress
  | j => j.compress

def hex (bs : ByteArray) : String :=
  let digit (n : Nat) : Char := "0123456789abcdef".toList[n]!
  String.ofList (bs.toList.flatMap fun b => [digit (b.toNat / 16), digit (b.toNat % 16)])

def tick : IO Nat := clock.modifyGet fun t => (t + 1, t + 1)

/-- The entry for `token`, when it is held and was built from exactly these arguments. -/
def lookup (token key : String) : IO (Option Entry) := do
  let now ← tick
  let es ← cache.get
  match es.findIdx? (fun e => e.token == token && e.key == key) with
  | some i =>
    cache.set (es.modify i ({ · with used := now }))
    return some es[i]!
  | none => return none

/-- Keep a state graph under a new random token, dropping the least recently used entry when full. -/
def store (key : String) (draft : Json) (states : Nat) : IO String := do
  let token := hex (← IO.getRandomBytes 16)
  let now ← tick
  let cap ← capacity.get
  let es ← cache.get
  let es := if es.size < cap then es else
    match (es.toList.zipIdx.foldl (fun (best : Option (Entry × Nat)) (e, i) =>
        match best with
        | some (b, _) => if e.used < b.used then some (e, i) else best
        | none => some (e, i)) none) with
    | some (_, i) => es.eraseIdxIfInBounds i
    | none => es
  cache.set (es.push { token, key, draft, states, used := now })
  return token

def size : IO Nat := return (← cache.get).size
def clear : IO Unit := cache.set #[]

end LeanFM.ModelCache
