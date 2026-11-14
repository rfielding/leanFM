import LeanFM.SessionTools
import Lean.Data.Json.Elab

/-! Tests for selfhost.session.envelope (decision session-envelope): every event that crosses a
tool boundary has a declared shape. Integers travel as decimal strings; generated streams carry
unique nanosecond timestamps; a session key is a typed field that conformance checks; the event
envelope is written as protobuf. -/
namespace LeanFM.Session.EnvelopeTests
open Lean LeanFM LeanFM.Session LeanFM.SessionTools

def args (text : String) (extra : List (String × Json) := []) : Json := Json.mkObj ([("lean", Json.str text)] ++ extra)
def reason (r : Except String Json) : String := match r with | .error e => e | .ok _ => ""
def str (r : Except String Json) (k : String) : String :=
  match r with | .ok j => (j.getObjValAs? String k).toOption.getD "" | .error e => e
def has (s part : String) : Bool := (s.splitOn part).length > 1

/-! Generated streams: a ts per event in nanoseconds, unique, after everything it happened after -/

def events (r : Except String Json) : List Json :=
  match r with | .ok j => (match j.getObjValD "events" with | .arr a => a.toList | _ => []) | .error _ => []

def tsOf (e : Json) : Option Nat := (e.getObjValAs? String "ts").toOption.bind fun s => s.toNat?

/-- every ts is a decimal string; all distinct; each later than the events it names as prior or cause -/
def wellStamped (evs : List Json) : Bool :=
  let ts := evs.filterMap tsOf
  let byId := evs.filterMap fun e => ((e.getObjValAs? Nat "id").toOption.bind fun i => (tsOf e).map (i, ·))
  let before (e : Json) : List Nat :=
    (match e.getObjValD "prior" with | .arr a => a.toList.filterMap (·.getNat?.toOption) | _ => []) ++
    ((e.getObjValAs? Nat "cause").toOption).toList
  !evs.isEmpty && ts.length == evs.length && ts.eraseDups.length == ts.length &&
    evs.all fun e => (before e).all fun x => match byId.lookup x, tsOf e with
      | some a, some b => a < b
      | _, _ => true

def sim (file : String) (extra : List (String × Json) := []) : Except String Json := simulate (args file extra)
def placeOrder := include_str "../../examples/sessions/PlaceOrder.leanfm"
def userLookup := include_str "../../examples/sessions/UserLookup.leanfm"
def limitOrder := include_str "../../examples/sessions/LimitOrder.leanfm"
-- an untimed run of eight concurrent sessions, a timed run, and a chain with a loop
#guard wellStamped (events (sim placeOrder [("seed", toJson (3 : Nat))]))
#guard wellStamped (events (sim userLookup [("seed", toJson (5 : Nat)), ("instances", toJson (6 : Nat))]))
#guard wellStamped (events (sim limitOrder [("seed", toJson (2 : Nat))]))
#guard str (sim placeOrder) "tsUnit" == "ns"
-- sessions run on session-relative clocks, so their times repeat; their timestamps do not
def timedRun := events (sim userLookup [("instances", toJson (6 : Nat))])
#guard ((timedRun.filterMap fun e => (e.getObjValAs? Nat "time").toOption).eraseDups.length < timedRun.length) &&
  ((timedRun.filterMap tsOf).eraseDups.length == timedRun.length)

-- stampNs on its own: equal times are separated, and an event waits for what it happened after
#guard ((stampNs #[json% {id: 1, time: 5}, json% {id: 2, time: 5}, json% {id: 3, time: 4, prior: [1]}]).toList.map tsOf) ==
  [some 5000000, some 5000001, some 5000002]

/-! Session keys: the session is a typed field of the protocol, and conformance checks it -/

def keyed := "structure Ask where\n  caller : String\n\nprotocol K (A, B) {\n  sessions by a.caller {\n    a: Ask from A to B;\n    Reply from B to A cause a;\n  }\n}"
#guard ((Text.parse keyed).toOption.map (·.keys)) == some [("a", "caller")]

def ev (id session label src dst : String) (cause : Option String := none) (fields : Option Json := none) : Json :=
  Json.mkObj ([("id", Json.str id), ("session", Json.str session), ("from", Json.str src), ("to", Json.str dst), ("label", Json.str label)] ++
    (cause.map fun c => [("cause", Json.str c)]).getD [] ++ (fields.map fun f => [("fields", f)]).getD [])
def keyedLog (session caller : String) (withField : Bool := true) : Except String Json :=
  conform (args keyed [("events", Json.arr #[
    ev "e1" session "Ask" "A" "B" none (if withField then some (Json.mkObj [("caller", Json.str caller)]) else none),
    ev "e2" session "Reply" "B" "A" (some "e1")])])
#guard str (keyedLog "alice" "alice") "verdict" == "conforms"
#guard str (keyedLog "s1" "alice") "verdict" == "violates"
#guard has (str (keyedLog "s1" "alice") "reading") "the session key a.caller is alice, so this session's events must name session alice, not s1"
#guard has (str (keyedLog "alice" "alice" false) "reading") "Ask does not log the session key a.caller"
-- a Nat key compares as its decimal value, whether it was logged as a string or a safe number
def natKeyed := keyed.replace "caller : String" "caller : Nat"
#guard str (conform (args natKeyed [("events", Json.arr #[ev "e1" "18446744073709551615" "Ask" "A" "B" none (some (json% {caller: "18446744073709551615"})),
  ev "e2" "18446744073709551615" "Reply" "B" "A" (some "e1")])])) "verdict" == "conforms"
-- generated code logs the key with its message, as it logs what conditions read
#guard has (str (skeleton (args keyed)) "code") "READS = {\"a\": [\"caller\"]}"

-- negative: the key must be a Nat or String field of a message of its block, and not a secret
#guard has (reason (check (args (keyed.replace "sessions by a.caller" "sessions by z.caller")))) "z is not the id of a message of this sessions block"
#guard has (reason (check (args (keyed.replace "caller : String" "caller : Bool")))) "a session key is a Nat or String field"
#guard has (reason (check (args (keyed.replace "caller : String" "caller_secr : String" |>.replace "a.caller" "a.caller_secr")))) "may not be a secret"
#guard has (reason (check (args (keyed.replace "a.caller" "a.name")))) "Ask has no field name"

/-! The envelope as protobuf -/

def proto := str (types (args placeOrder)) "proto"
#guard has proto "message Event {\n  uint64 ts = 1;"
#guard has proto "  oneof payload {\n    CreateOrder create_order = 11;\n    Quote quote = 12;\n    Pay pay = 13;"
-- the clock readings of the sender and the receiver travel in every event (selfhost.session.timelines)
#guard has proto "  uint64 sent_at = 9;" && has proto "  uint64 received_at = 10;"
#guard has (reason (types (args "structure Event where n : Nat\nprotocol P (A, B) { Event from A to B; }"))) "would collide with the event envelope"

end LeanFM.Session.EnvelopeTests
