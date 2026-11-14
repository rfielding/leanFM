import LeanFM.Session.Global

/-!
# Systems: protocols instantiated (clause selfhost.session.instances)

A server's accept spawns one instance of a protocol per connection. A `System` says which instances
exist: shared instances, created once (a database, a cache), and the protocols accepted against
them. Each accept is one instance: a fresh session id, a fresh actor for every role marked `fresh`,
and a declared shared instance for every other role.

```
system Shop {
  instance db : Db serial;
  instance cache : Cache;
  accept Order (fresh Client, db, cache);
}
```

An instance owns its state exclusively: its protocol state (where it is in its protocol) and, in a
later phase, its data. Instances interact only by messages, and only with the instances they were
given. A `serial` instance serves one session at a time: from its first message in a session until
that session's protocol no longer mentions its role, other sessions wait for it. An instance that
is not serial serves its callers concurrently, one session each.

This module is only the data, so that a Lean file declaring a system pays for nothing else;
`Session.Instances` explores and checks it.
-/

namespace LeanFM.Session

/-- An instance created once and shared by the instances it is given to. Its actor is
`role/name`; it plays its role, and only its role, in every protocol that is given it. -/
structure Shared where
  name : String
  role : String
  serial : Bool := false
  deriving Repr, BEq, Inhabited

/-- Who plays a role in an accepted instance. -/
inductive Player where
  /-- a new actor for every instance, `Role/session` -/
  | fresh
  /-- the declared shared instance of that name -/
  | shared (inst : String)
  deriving Repr, BEq, Inhabited

/-- A protocol accepted against shared instances: every accept is one instance. -/
structure Accept where
  protocolName : String
  /-- the protocol's roles, in its own order -/
  roles : List String
  /-- who plays each role, in the same order -/
  players : List Player
  global : Global String
  deriving Inhabited

structure System where
  name : String
  shared : List Shared := []
  accepts : List Accept := []
  deriving Inhabited

namespace System

def sharedNamed (s : System) (n : String) : Option Shared := s.shared.find? (fun x => x.name == n)

end System
end LeanFM.Session
