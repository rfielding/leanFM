import LeanFM.Session.Syntax
import LeanFM.Session.Instances
import LeanFM.SessionTools

/-! Tests for selfhost.session.instances (decision session-instances): a system is Lean; its
instances interleave; a serial instance serves one session at a time, so two code paths that take
two of them in opposite orders deadlock, with the path; isolation holds over every step; properties
are checked per instance and for the system; a log of a system follows its actors. -/
namespace LeanFM.Session.InstanceTests
open Lean LeanFM LeanFM.Session LeanFM.Session.Instances

/-! ## A system in Lean -/

/-- Refresh locks the database, then invalidates the cache. -/
protocol Refresh (Client, Db, Cache) {
  l: Lock from Client to Db;
  c: Invalidate from Client to Cache cause l;
  Done from Cache to Client cause c;
  Unlock from Client to Db cause l;
}

/-- Evict takes the cache first, then writes back to the database: the opposite order. -/
protocol Evict (Client, Db, Cache) {
  e: Drop from Client to Cache;
  w: WriteBack from Client to Db cause e;
  Saved from Db to Client cause w;
  Dropped from Cache to Client cause e;
}

/-- Evict in Refresh's order: the database first. -/
protocol EvictInOrder (Client, Db, Cache) {
  w: Hold from Client to Db;
  e: Drop from Client to Cache cause w;
  Dropped from Cache to Client cause e;
  Saved from Db to Client cause w;
}

system Shop {
  instance db : Db serial;
  instance cache : Cache serial;
  accept Refresh (fresh Client, db, cache);
  accept Evict (fresh Client, db, cache);
}

system OrderedShop {
  instance db : Db serial;
  instance cache : Cache serial;
  accept Refresh (fresh Client, db, cache);
  accept EvictInOrder (fresh Client, db, cache);
}

/-- The same code paths against instances that serve each caller in a session of its own. -/
system ConcurrentShop {
  instance db : Db;
  instance cache : Cache;
  accept Refresh (fresh Client, db, cache);
  accept Evict (fresh Client, db, cache);
}

-- negative: the command refuses a player that is not a declared instance, and an unknown protocol
/-- error: accept Refresh: cache is not a shared instance declared before this accept; write fresh Cache for a new Cache per instance -/
#guard_msgs in
system Bad { instance db : Db; accept Refresh (fresh Client, db, cache); }

/-- error: accept Nope: no protocol Nope is defined -/
#guard_msgs in
system Bad2 { accept Nope (fresh Client); }

-- the command defines a System whose accepts are the protocols applied to their own roles
#guard Shop.accepts.map (fun x => x.protocolName) == ["Refresh", "Evict"]
#guard Shop.accepts.map (fun x => x.roles) == [["Client", "Db", "Cache"], ["Client", "Db", "Cache"]]
#guard (Shop.accepts.map (fun x => x.players)) == [[.fresh, .shared "db", .shared "cache"], [.fresh, .shared "db", .shared "cache"]]
#guard Shop.shared == [{ name := "db", role := "Db", serial := true }, { name := "cache", role := "Cache", serial := true }]
#guard ((Shop.accepts.head!.global.diagram ["Client", "Db", "Cache"]) == ((Refresh "Client" "Db" "Cache" : Global String).diagram ["Client", "Db", "Cache"]))

/-! ## Deadlock: two serial instances taken in opposite orders -/

def shop1 := SystemSpec.check { sys := Shop, instances := 1 }
#guard shop1 == ["deadlock after Lock@s1 from Client/s1 to Db/db -> Drop@s2 from Client/s2 to Cache/cache: s1 waits to send Invalidate from Client/s1 to Cache/cache (needs Cache/cache, which s2 holds); s2 waits to send WriteBack from Client/s2 to Db/db (needs Db/db, which s1 holds)"]
-- with two of each, the nearest deadlocks are described and the rest counted
def shop2 := (run Shop 2 [] []).toOption.get!
#guard shop2.deadlocks.length == maxDescribed + 1 && (shop2.deadlocks.getLast!.splitOn "more deadlocked states").length == 2
#guard shop2.graph.insts.map (fun x => x.id) == ["s1", "s2", "s3", "s4"]
#guard shop2.graph.insts.map (fun x => x.actors) ==
  [[("Client", "Client/s1"), ("Db", "Db/db"), ("Cache", "Cache/cache")], [("Client", "Client/s2"), ("Db", "Db/db"), ("Cache", "Cache/cache")],
   [("Client", "Client/s3"), ("Db", "Db/db"), ("Cache", "Cache/cache")], [("Client", "Client/s4"), ("Db", "Db/db"), ("Cache", "Cache/cache")]]
-- a deadlock breaks liveness for each instance: the checker's counterexample is the same path
#guard (SystemSpec.check { sys := Shop, instances := 1, perInstance := [.AF .terminal] }).getLast! ==
  "property {\"AF\":\"terminal\"} disproved for s2: Shop s2: on every path, eventually the claim finished@s2 has been made; counterexample: Lock@s1 -> Drop@s2 (and stays there)"

-- the same order in both code paths: no deadlock, and every instance finishes on every path
def ordered : SystemSpec :=
  { sys := OrderedShop, instances := 2, perInstance := [.AF .terminal, .AG (.EF .terminal)],
    properties := [.AG (.EF .terminal), .EF (sent% Dropped)] }
#guard ordered.check == []
-- instances that are not serial never wait for each other
#guard SystemSpec.check { sys := ConcurrentShop, instances := 2, perInstance := [.AF .terminal] } == []
-- a serial instance excludes interleavings: fewer states than the concurrent one
#guard ((explore OrderedShop 2).toOption.map (fun x => x.keys.size)).get! < ((explore ConcurrentShop 2).toOption.map (fun x => x.keys.size)).get!

/-! ## Per-instance and system properties -/

-- an instance's Unlock always follows its own Lock; Lock@s1 is not Lock@s2
def unlockAfterLock : SystemSpec :=
  { sys := OrderedShop, instances := 1, perInstance := [.AG (.or (.not (sent% Unlock)) (.not (sent% Lock)))] }
#guard unlockAfterLock.check == []
-- a system property sees every instance's messages: some run drops before any lock
#guard SystemSpec.check { sys := OrderedShop, instances := 1, properties := [.EF (sent% Drop)] } == []
-- a per-instance property is checked for each instance, and the instance where it fails is named
def holdEverywhere : SystemSpec := { sys := OrderedShop, instances := 1, perInstance := [.EF (sent% Hold)] }
#guard holdEverywhere.check ==
  ["property {\"EF\":{\"after\":\"Hold\"}} disproved for s1: OrderedShop s1: it is possible that eventually false (s1 never sends Hold, so it reads as false)"]

/-! ## Isolation over every step -/

def g1 := (explore OrderedShop 1).toOption.get!
#guard isolationProblems OrderedShop g1.insts g1.edges.toList == []
-- negative: a step of s1 reaching s2's client, and a step using an instance s1 was not given
def stray : Edge := { src := 0, dst := 0, inst := 0, step := { label := "Done", src := "Cache", dst := "Client" },
                      srcActor := "Cache/cache", dstActor := "Client/s2", finishes := false }
#guard isolationProblems OrderedShop g1.insts [stray] ==
  ["Done@s1 from Cache/cache to Client/s2: a message of s1 reaches Client/s2, which is not one of its actors"]
def other : System := { OrderedShop with shared := OrderedShop.shared ++ [{ name := "audit", role := "Cache" }] }
#guard isolationProblems other g1.insts [{ stray with dstActor := "Cache/audit", srcActor := "Client/s1" }] ==
  ["Done@s1 from Client/s1 to Cache/audit: s1 uses audit, which it was not given"]

/-! ## Bounds -/

#guard (explore Shop 0 |>.toOption.isNone) && (run Shop 3 [] [] |>.toOption.isNone)
#guard (match explore Shop 3 with | .error e => e | .ok _ => "") ==
  "3 instances of each of 2 accepts is 6 in all; at most 4 are explored"

/-! ## The text reading and the tool -/

def shopText := "protocol Refresh (Client, Db, Cache) {
  l: Lock from Client to Db;
  c: Invalidate from Client to Cache cause l;
  Done from Cache to Client cause c;
  Unlock from Client to Db cause l;
}
protocol Evict (Client, Db, Cache) {
  e: Drop from Client to Cache;
  w: WriteBack from Client to Db cause e;
  Saved from Db to Client cause w;
  Dropped from Cache to Client cause e;
}
system Shop {
  instance db : Db serial;
  instance cache : Cache serial;
  accept Refresh (fresh Client, db, cache);
  accept Evict (fresh Client, db, cache);
}"

-- the tools read the same system the Lean command defines
def readShop := (systemsOf shopText).toOption.get!.head!
#guard readShop.name == "Shop" && readShop.shared == Shop.shared &&
  readShop.accepts.map (fun x => x.players) == Shop.accepts.map (fun x => x.players) &&
  (readShop.accepts.zip Shop.accepts).all fun (a, b) => a.global.diagram a.roles == b.global.diagram b.roles

def tool (args : Json) : Except String Json := SessionTools.instances args
def field (r : Except String Json) (k : String) : String :=
  match r with | .ok j => (j.getObjValAs? String k).toOption.getD "" | .error e => e
def args (text : String) (more : List (Prod String Json) := []) : Json := Json.mkObj ([("lean", Json.str text)] ++ more)

#guard field (tool (args shopText [("instances", 1)])) "verdict" == "deadlock"
#guard (field (tool (args shopText [("instances", 1)])) "reading").startsWith
  "Shop: 1 deadlocked state with 2 instances; first: deadlock after Lock@s1 from Client/s1 to Db/db -> Drop@s2"
-- without serial instances the instances are independent: each has 5 protocol states (4 messages),
-- so 4 of them interleave over 5^4 = 625 states
#guard field (tool (args (shopText.replace " serial;" ";") [("instances", 2),
  ("perInstance", Json.arr #[Json.mkObj [("AF", "terminal")]])])) "reading" ==
  "Shop: 4 instances interleaved over 625 states: no deadlock, every step isolated, 4 properties proved"
-- a system formula over any instance's message, disproved with its path
#guard field (tool (args (shopText.replace " serial;" ";") [("instances", 1),
  ("properties", Json.arr #[Json.mkObj [("never", Json.mkObj [("after", "Saved")])]])])) "verdict" == "disproved"
-- the tool's limits
#guard (field (tool (args shopText [("instances", 3)])) "verdict").startsWith "instances is at most 4" ||
  (field (tool (args shopText [("instances", 3)])) "verdict").startsWith "3 instances of each"
#guard field (tool (args "protocol P (A, B) { Ping from A to B; }")) "verdict" ==
  "the text declares no system; add one after the protocols: system Shop { instance db : Db serial; accept Order (fresh Client, db); }"

/-! ## Systems the reading refuses -/

def refused (body : String) : String :=
  match Text.readText (shopText.replace "system Shop {
  instance db : Db serial;
  instance cache : Cache serial;
  accept Refresh (fresh Client, db, cache);
  accept Evict (fresh Client, db, cache);
}" body) with
  | .ok _ => "accepted"
  | .error e => e

#guard (refused "system S { instance db : Db; accept Nope (fresh Client, db); }").endsWith "accept Nope: no protocol Nope is defined before this system"
#guard (refused "system S { instance db : Db; accept Refresh (fresh Client, db); }").endsWith "accept Refresh needs one player for each of its 3 roles (Client, Db, Cache), not 2"
#guard (refused "system S { instance db : Db; instance c : Cache; accept Refresh (fresh Buyer, db, c); }").endsWith "accept Refresh: the role in this position is Client, so write fresh Client"
#guard (refused "system S { instance db : Db; accept Refresh (fresh Client, db, cache); }").endsWith "accept Refresh: cache is not a shared instance declared before this accept; write fresh Cache for a new Cache per instance"
#guard (refused "system S { instance db : Db; instance c : Cache; accept Refresh (fresh Client, c, db); }").endsWith "accept Refresh: c plays Cache, but the role in this position is Db"
#guard (refused "system S { instance db : Db; instance db : Db; accept Refresh (fresh Client, db, fresh Cache); }").endsWith "instance db is declared twice"
#guard (refused "system S { instance db : Db; }").endsWith "system S accepts nothing; add accept Protocol (fresh Role, ...);"
#guard (refused "system Refresh { accept Refresh (fresh Client, fresh Db, fresh Cache); }").endsWith "system Refresh has the name of a protocol"
#guard (refused "system S { instance db : Db; accept Refresh (fresh Client, db, fresh Cache); } system S { accept Refresh (fresh Client, fresh Db, fresh Cache); }").endsWith "system S is defined twice"
#guard (match Text.readText "system S { accept P (fresh A); } protocol P (A) { X at A; }" with | .error e => e | .ok _ => "").endsWith "a system follows the protocols it accepts"
-- system is a Lean keyword in a session-type file, so it is not a name
#guard (match Text.parse "protocol P (A, B) { system from A to B; }" with | .error _ => true | .ok _ => false)

/-! ## Logs of a system -/

def logged (from_ to_ : String) (id session label : String) (cause : Option String := none) : Json :=
  Json.mkObj ([("id", Json.str id), ("session", Json.str session), ("label", Json.str label),
    ("from", Json.str from_), ("to", Json.str to_)] ++ (cause.map fun c => [("cause", Json.str c)]).getD [])

def refreshLog (s client : String) : List Json :=
  [ logged client "Db/db" s!"{s}l" s "Lock", logged client "Cache/cache" s!"{s}c" s "Invalidate" (some s!"{s}l")
  , logged "Cache/cache" client s!"{s}d" s "Done" (some s!"{s}c"), logged client "Db/db" s!"{s}u" s "Unlock" (some s!"{s}l") ]

/-- The same system with Refresh last, so conformance checks Refresh's sessions. -/
def refreshLast := "protocol Evict (Client, Db, Cache) {
  e: Drop from Client to Cache;
  w: WriteBack from Client to Db cause e;
  Saved from Db to Client cause w;
  Dropped from Cache to Client cause e;
}
protocol Refresh (Client, Db, Cache) {
  l: Lock from Client to Db;
  c: Invalidate from Client to Cache cause l;
  Done from Cache to Client cause c;
  Unlock from Client to Db cause l;
}
system Shop {
  instance db : Db serial;
  instance cache : Cache serial;
  accept Refresh (fresh Client, db, cache);
  accept Evict (fresh Client, db, cache);
}"

def conformArgs (evs : List Json) : Json := Json.mkObj [("lean", Json.str refreshLast), ("events", Json.arr evs.toArray)]
def conformed (evs : List Json) : Except String Json := SessionTools.conform (conformArgs evs)

#guard field (conformed (refreshLog "1" "Client/c1" ++ refreshLog "2" "Client/c2")) "verdict" == "conforms"
-- an actor that names no instance
#guard (field (conformed (refreshLog "1" "Client")) "reading").endsWith "Client names no instance; system Shop declares its instances, so every actor is Role/instance"
-- a fresh actor in two sessions: one instance's thread receiving another's messages
#guard (field (conformed (refreshLog "1" "Client/c1" ++ refreshLog "2" "Client/c1")) "reading").endsWith
  "Client/c1 belongs to session 1; a fresh actor is in one instance only, but it also appears in session 2"
-- a shared instance playing a role it does not play, and an instance no accept was given
#guard (field (conformed ((refreshLog "1" "Client/c1").set 0 (logged "Client/c1" "Db/cache" "1l" "1" "Lock"))) "reading").endsWith
  "Db/cache: cache plays Cache, not Db"
#guard (field (conformed (refreshLog "1" "Client/c1" |>.map fun e => if (e.getObjValAs? String "to").toOption == some "Db/db" then e.setObjVal! "to" (Json.str "Db/backup") else e)) "reading").endsWith
  "Db/backup: Db is never fresh in system Shop; it is played by db"

end LeanFM.Session.InstanceTests
