/-! LeanFM video demo: the three snippets the video shows, checked by Lean.
ASCII only: `->`, `forall`, `exists`, `Not`, `/\`. -/

/-! ## Act 2: data lives forever. A migration that can always step back toward V1 until V1 is retired. -/
inductive MigrationStage where
  | v1Only | dualWriteActive | v2VerifyParity | v2OnlyRetiredV1
  deriving DecidableEq, Repr

open MigrationStage in
def CanTransition : MigrationStage -> MigrationStage -> Prop
  | v1Only, dualWriteActive => True
  | dualWriteActive, v1Only => True              -- roll back
  | dualWriteActive, v2VerifyParity => True
  | v2VerifyParity, dualWriteActive => True      -- roll back
  | v2VerifyParity, v2OnlyRetiredV1 => True
  | _, _ => False

/-- Until V1 is retired, every stage can still reach V1 in one or two steps: a rollback exists. -/
theorem migration_is_reversible :
    forall s : MigrationStage, Not (s = .v2OnlyRetiredV1) ->
      s = .v1Only \/ exists next, CanTransition s next /\ (next = .v1Only \/ CanTransition next .v1Only) := by
  intro s h
  cases s with
  | v1Only => exact Or.inl rfl
  | dualWriteActive => exact Or.inr (Exists.intro .v1Only (And.intro trivial (Or.inl rfl)))
  | v2VerifyParity => exact Or.inr (Exists.intro .dualWriteActive (And.intro trivial (Or.inr trivial)))
  | v2OnlyRetiredV1 => exact absurd rfl h

/-! ## Act 3: a message is a value together with a proof about it; the gate runs before allocation. -/
structure Message (a : Type) (P : a -> Prop) where
  private mk ::
  val : a
  ok  : P val

structure IngressLimits where
  maxFrameBytes : Nat
  maxQueueDepth : Nat

inductive HostileRejection where
  | frameTooLarge (size limit : Nat)
  | queueFlood (depth limit : Nat)
  | malformed (why : String)
  | refused
  deriving Repr

def ingestHostilePacket {a : Type} (limits : IngressLimits) (depth : Nat)
    (decode : ByteArray -> Except String a) (P : a -> Prop) [DecidablePred P]
    (raw : ByteArray) : Except HostileRejection (Message a P) := do
  if raw.size > limits.maxFrameBytes then throw (.frameTooLarge raw.size limits.maxFrameBytes)
  if depth >= limits.maxQueueDepth then throw (.queueFlood depth limits.maxQueueDepth)
  match decode raw with
  | .error why => throw (.malformed why)
  | .ok v => if h : P v then pure (Message.mk v h) else throw .refused

def limits : IngressLimits := { maxFrameBytes := 1024, maxQueueDepth := 64 }
def decodeLen (raw : ByteArray) : Except String Nat := pure raw.size

#eval (ingestHostilePacket limits 3 decodeLen (fun n => n > 0) (ByteArray.mk (Array.replicate 4096 0))).map (·.val)
#eval (ingestHostilePacket limits 64 decodeLen (fun n => n > 0) (ByteArray.mk #[1, 2, 3])).map (·.val)
#eval (ingestHostilePacket limits 3 decodeLen (fun n => n > 0) (ByteArray.mk #[1, 2, 3])).map (·.val)

/-! ## Act 4: HTTP contracts. Verified services follow HTTP; quarantined legacy actors are allowed their quirks. -/
inductive Method where | GET | POST deriving DecidableEq, Repr
inductive StatusClass where | ok2xx | client4xx | server5xx | fake200Error deriving DecidableEq, Repr
inductive ActorTrust where
  | verified
  | quarantined (reason : String)
  deriving Repr

structure Endpoint where
  name : String
  method : Method
  hasBody : Bool
  status : StatusClass
  deriving Repr

def EndpointContract.check (trust : ActorTrust) (e : Endpoint) : Except String Endpoint :=
  match trust with
  | .quarantined _ => pure e
  | .verified =>
    if e.method == .GET && e.hasBody then throw s!"[{e.name}] HTTP violation: GET requests cannot carry a body"
    else if e.status == .fake200Error then throw s!"[{e.name}] HTTP violation: an error answered with 200 OK"
    else pure e

#eval EndpointContract.check .verified { name := "UploadBlob", method := .GET, hasBody := true, status := .ok2xx }
#eval EndpointContract.check (.quarantined "Legacy vendor Swagger API")
  { name := "LegacySync", method := .GET, hasBody := true, status := .fake200Error }
