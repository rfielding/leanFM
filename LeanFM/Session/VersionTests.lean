import LeanFM.Session.Syntax
import LeanFM.Session.Versions
import LeanFM.SessionTools

/-! Tests for selfhost.session.versions (decision session-versions): a file keeps the versions still
deployed; each version must have a clean upgrade path from the one before, or it does not compile;
the tools refuse the same texts; payload numbers survive every version; every event names its
version, and each session is checked against the version it names. -/
namespace LeanFM.Session.VersionTests
open Lean LeanFM LeanFM.Session LeanFM.SessionTools

/-! ## Versions in Lean, checked at compile time -/

protocol Lookup (Client, Server) version 1 {
  q: Get from Client to Server;
  Found from Server to Client cause q;
}

/-- Version 2 lets the server say Missing: the client upgrades first, then the server. -/
protocol Lookup (Client, Server) version 2 {
  q: Get from Client to Server;
  choice {
    Found from Server to Client cause q;
  } or {
    Missing from Server to Client cause q;
  }
}

-- negative: renaming the request has no clean upgrade path, so version 3 does not compile, and it
-- is not defined, so nothing can include it
/-- error: Lookup version 3 has no clean upgrade path from version 2: with Client upgraded, the deployment gets stuck at the start: Client is stuck trying to send Fetch to Server; Server waits to receive Get from Client; with Server upgraded, the deployment gets stuck at the start: Client is stuck trying to send Get to Server; Server waits to receive Fetch from Client -/
#guard_msgs in
protocol Lookup (Client, Server) version 3 {
  q: Fetch from Client to Server;
  Found from Server to Client cause q;
}

-- negative: versions go oldest first
/-- error: protocol Lookup version 2 follows version 2; versions go oldest first, each higher than the one before -/
#guard_msgs in
protocol Lookup (Client, Server) version 2 {
  q: Get from Client to Server;
  Found from Server to Client cause q;
}

/-- Version 4 stops answering Found: the server upgrades first, then the client. -/
protocol Lookup (Client, Server) version 4 {
  q: Get from Client to Server;
  Missing from Server to Client cause q;
}

-- a plain include means the newest version defined so far
protocol Front (User, Client, Server) {
  a: Ask from User to Client;
  include Lookup Client Server;
}

#guard ((Front "U" "C" "S" : Global String).labels) == ["Ask", "Get", "Missing"]
#guard ((Lookup.v2 "C" "S" : Global String).labels) == ["Get", "Found", "Missing"]

-- negative: a protocol defined without a version cannot gain one later
protocol Plain (A, B) { Ping from A to B; }
/-- error: protocol Plain is defined without a version; give every version of it a number -/
#guard_msgs in
protocol Plain (A, B) version 2 { Ping from A to B; }

/-! ## The upgrade path search -/

def lookupText (versions : List String) : String := "\n".intercalate versions
def v1 := "protocol Lookup (Client, Server) version 1 { q: Get from Client to Server; Found from Server to Client cause q; }"
def v2 := "protocol Lookup (Client, Server) version 2 { q: Get from Client to Server; choice { Found from Server to Client cause q; } or { Missing from Server to Client cause q; } }"
def v3bad := "protocol Lookup (Client, Server) version 3 { q: Fetch from Client to Server; Found from Server to Client cause q; }"
def v4 := "protocol Lookup (Client, Server) version 4 { q: Get from Client to Server; Missing from Server to Client cause q; }"

def args (text : String) (more : List (Prod String Json) := []) : Json := Json.mkObj ([("lean", Json.str text)] ++ more)
def reason (r : Except String Json) : String := match r with | .error e => e | .ok _ => ""
def field (r : Except String Json) (k : String) : Json := match r with | .ok j => j.getObjValD k | .error _ => Json.null
def str (r : Except String Json) (k : String) : String := (field r k).getStr?.toOption.getD ""

deriving instance Inhabited for LeanFM.SessionTools.Protocol
def parsed (text : String) : Protocol := (parseProtocol (args text)).toOption.get!

-- the orders found: the client first when the server gains an answer, the server first when it loses one
#guard (parsed (lookupText [v1, v2, v4])).upgrades.map (fun u => (u.fromVersion, u.toVersion, u.order)) ==
  [(1, 2, ["Client", "Server"]), (2, 4, ["Server", "Client"])]
-- every tool refuses a text whose newest version has no clean path, with the same reason as Lean
#guard (reason (check (args (lookupText [v1, v2, v3bad])))).startsWith
  "Lookup version 3 has no clean upgrade path from version 2: with Client upgraded, the deployment gets stuck at the start"
-- versions out of order, repeated, or mixed with an unversioned protocol of the same name
#guard (reason (check (args (lookupText [v2, v1])))).endsWith "protocol Lookup version 1 follows version 2; versions go oldest first, each higher than the one before"
#guard (reason (check (args (lookupText [v1, v1])))).endsWith "protocol Lookup version 1 follows version 1; versions go oldest first, each higher than the one before"
#guard (reason (check (args (lookupText [v1.replace " version 1" "", v2])))).endsWith "protocol Lookup is defined twice, once without a version; give every version of it a number"
#guard (reason (check (args (v1.replace "version 1" "version 0")))).endsWith "a version is 1 to 9999"

-- a role added in the new version joins with the last upgrade; the versions must share a role
#guard (match Versions.search ((parsed v1).global) ((parsed "protocol Lookup (Asker, Answerer) version 2 { q: Get from Asker to Answerer; Found from Answerer to Asker cause q; }").global)
    ["Client", "Server"] ["Asker", "Answerer"] with
  | .ok (.none [s]) => s.text == "with  upgraded, the deployment gets stuck at the start: the versions share no role, so no role can upgrade on its own; keep the old protocol's roles, or give the new one another name"
  | _ => false)

-- the lending protocol: the Member cannot go first, yet a clean order exists, which the
-- role-by-role check alone does not show
def lendingV1 := include_str "../../examples/vibecode/lending/Lending.protocol"
def lendingV2 := include_str "../../examples/vibecode/lending/Lending-v2.protocol"
#guard (match Versions.search (parsed lendingV1).global (parsed lendingV2).global (parsed lendingV1).roles (parsed lendingV2).roles with
  | .ok (.clean o) => o == ["Desk", "Member", "Librarian"]
  | _ => false)

-- LeanFM's writer keeps the versions, so written text reads back as the same versions
#guard (match Text.readText (lookupText [v1, v2, v4]) with
  | .ok (defs, _) => match Text.readText (Text.write defs) with
    | .ok (back, _) => back.map (fun d => (d.name, d.version)) == [("Lookup", 1), ("Lookup", 2), ("Lookup", 4)]
    | .error _ => false
  | .error _ => false)

/-! ## session_compat over the text's own versions -/

#guard str (compat (args (lookupText [v1, v2]))) "reading" ==
  "Lookup version 1 -> Lookup version 2: upgrade first: Client; clean upgrade path: Client then Server"
#guard field (compat (args (lookupText [v1, v2]))) "upgradePath" ==
  Json.mkObj [("clean", true), ("order", Json.arr #["Client", "Server"])]

/-! ## The wire: names and versions in the envelope, numbers that survive every version -/

def protoOf (text : String) : String := str (types (args text)) "proto"
def has (s part : String) : Bool := (s.splitOn part).length > 1

#guard has (protoOf (lookupText [v1, v2])) "  string protocol = 11;" && has (protoOf v1) "  uint32 version = 12;"
-- Found keeps 17 in every version; Missing, new in version 2, is 18
#guard has (protoOf v1) "  oneof payload {\n    Get get = 16;\n    Found found = 17;\n  }"
#guard has (protoOf (lookupText [v1, v2])) "    Get get = 16;\n    Found found = 17;\n    Missing missing = 18;"
-- version 4 drops Found: its number and name stay reserved, and Missing keeps 18
#guard has (protoOf (lookupText [v1, v2, v4])) "  reserved 17; reserved \"found\"; // Found, dropped by a later version\n  oneof payload {\n    Get get = 16;\n    Missing missing = 18;\n  }"

-- the generated Lean module knows its version, accepts the one before it, and negotiates
def moduleOf (text : String) : String := str (types (args text)) "leanModule"
#guard has (moduleOf (lookupText [v1, v2, v4])) "def protocolVersion : Nat := 4"
#guard has (moduleOf (lookupText [v1, v2, v4])) "def acceptedVersions : List Nat := [2, 4]"
#guard has (moduleOf (lookupText [v1, v2, v4])) "  protocol : String := protocolName\n  version : Nat := protocolVersion"
#guard Versions.accepted [1, 2, 4] 4 == [2, 4] && Versions.accepted [1] 1 == [1]
#guard Versions.negotiate [2, 4] [1, 2] == some 2 && Versions.negotiate [2, 4] [4, 5] == some 4
-- negative: no version in common is none, never a guess
#guard Versions.negotiate [2, 4] [1, 3] == none

/-! ## Logs: every event names its version -/

def ev (id session label src dst : String) (version : Option Nat) (cause : Option String := none) : Json :=
  Json.mkObj ([("id", Json.str id), ("session", Json.str session), ("label", Json.str label), ("from", Json.str src), ("to", Json.str dst)] ++
    (version.map fun v => [("version", toJson v)]).getD [] ++ (cause.map fun c => [("cause", Json.str c)]).getD [])
def conformed (evs : List Json) : Except String Json :=
  conform (args (lookupText [v1, v2]) [("events", Json.arr evs.toArray)])

-- a version 1 session and a version 2 session in one log, each checked against its own version
#guard str (conformed [ev "a" "1" "Get" "Client" "Server" (some 1), ev "b" "1" "Found" "Server" "Client" (some 1) (some "a"),
                       ev "c" "2" "Get" "Client" "Server" (some 2), ev "d" "2" "Missing" "Server" "Client" (some 2) (some "c")]) "verdict" == "conforms"
-- negative: Missing is not part of version 1
#guard str (conformed [ev "a" "1" "Get" "Client" "Server" (some 1), ev "b" "1" "Missing" "Server" "Client" (some 1) (some "a")]) "verdict" == "violates"
-- negative: an event that names no version, a version the text does not keep, two versions in one session, another protocol
#guard str (conformed [ev "a" "1" "Get" "Client" "Server" none]) "reading" ==
  "Lookup: 1 version problem; first: event a: it names no version; Lookup has versions 1, 2, so every event says which it speaks"
#guard str (conformed [ev "a" "1" "Get" "Client" "Server" (some 7)]) "reading" ==
  "Lookup: 1 version problem; first: event a: version 7 is not a version of Lookup (1, 2)"
#guard (str (conformed [ev "a" "1" "Get" "Client" "Server" (some 1), ev "b" "1" "Found" "Server" "Client" (some 2) (some "a")]) "reading").endsWith
  "session 1: its events name versions 1, 2; one session speaks one version"
#guard str (conformed [(ev "a" "1" "Get" "Client" "Server" (some 1)).setObjVal! "protocol" (Json.str "Search")]) "reading" ==
  "Lookup: 1 version problem; first: event a: it belongs to protocol Search, not Lookup"

end LeanFM.Session.VersionTests
