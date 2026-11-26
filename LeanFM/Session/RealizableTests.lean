import LeanFM.SessionTools

/-!
Tests of `session_realizable` (selfhost.session.buffers): what a deployment can do when each role
runs its own projection over a FIFO, lossless inbox of the size its protocol gives it. A request and
answer, Images and PlaceOrder are realizable; unrelated pairs are not held to the protocol's order; a
role owed a second message deadlocks; sizes let a sender run ahead and a full inbox makes it wait;
sizes are read from the role list and bounded; parallel roles are refused; and no other tool's answer
depends on sizes.
-/

namespace LeanFM.Session.RealizableTests
open Lean LeanFM.SessionTools

def run (text : String) : Json :=
  match realizable (Json.mkObj [("lean", Json.str text)]) with
  | .ok j => j
  | .error e => Json.mkObj [("error", Json.str e)]
def str (j : Json) (k : String) : String := (j.getObjValAs? String k).toOption.getD ""
def arr (j : Json) (k : String) : List String := ((j.getObjValD k).getArr?.toOption.getD #[]).toList.filterMap (·.getStr?.toOption)

-- a request and its answer, and the book's Images and PlaceOrder, at size 0
#guard str (run "protocol P (A, B) { q: Ask from A to B; Answer from B to A cause q; }") "verdict" == "realizable"
#guard str (run (include_str "../../examples/sessions/PlaceOrder.leanfm")) "verdict" == "realizable"
#guard str (run "protocol Images (Browser, Server) { g: GetImage from Browser to Server; choice { Image from Server to Browser cause g; } or { NotFound from Server to Browser cause g; } }") "verdict" == "realizable"

-- unrelated roles cannot be held to the protocol's order between their messages
def unrelated := run "protocol P (A, B, C, D) { X from A to B; Y from C to D; }"
#guard str unrelated "verdict" == "unrealizable"
#guard (str unrelated "problem").contains "Y from C to D can happen first, which the protocol does not allow"

-- a deadlock a buffer makes possible: C puts Y in B's one-slot inbox first, A cannot put X in (the
-- inbox is full) and B cannot take Y (it waits for X); the answer names the inbox and the waits
def jam := run "protocol P (A, B[1], C) { X from A to B; Y from C to B; }"
#guard str jam "verdict" == "unrealizable"
#guard (str jam "problem").startsWith "deadlock"
#guard arr (jam.getObjValD "inboxes") "B" == ["Y from C"] ||
  (((jam.getObjValD "inboxes").getObjValD "B").getArr?.toOption.getD #[]).toList.filterMap (·.getStr?.toOption) == ["Y from C"]
#guard ((((jam.getObjValD "waiting").getObjValD "B").getArr?.toOption.getD #[]).toList.filterMap (·.getStr?.toOption)).contains "receive X from A"
#guard ((((jam.getObjValD "waiting").getObjValD "A").getArr?.toOption.getD #[]).toList.filterMap (·.getStr?.toOption)).contains "send X to B"
-- at size 0 the same protocol is realizable: C cannot hand Y over until B takes it
#guard str (run "protocol P (A, B, C) { X from A to B; Y from C to B; }") "verdict" == "realizable"

-- with sizes the sender may run ahead; a full inbox makes it wait, never overflows
def ahead := run "protocol P (A, B[2]) { One from A to B; Two from A to B; Done from B to A; }"
#guard str ahead "verdict" == "realizable"
#guard ((ahead.getObjValD "sizes").getObjValAs? Nat "B").toOption == some 2
#guard (arr ahead "guarantees").any (·.contains "B's inbox holds at most 2")
#guard (arr ahead "guarantees").any (·.contains "A's inbox holds nothing")

-- a chain through a buffered role stays realizable
#guard str (run "protocol P (A, B[1], C) { X from A to B; Y from B to C; Z from C to A; }") "verdict" == "realizable"

-- sizes are read from the role list and bounded
#guard (str (run "protocol P (A, B[65]) { X from A to B; }") "error").contains "an inbox holds 0 to 64 messages"
#guard (((run "protocol P (A, B[3]) { X from A to B; }").getObjValD "sizes").getObjValAs? Nat "B").toOption == some 3

-- a role that runs parallel branches is refused, naming it
#guard (str (run "protocol P (A, B, C) { parallel { X from A to B; } and { Y from A to C; } }") "error").contains "parallel"

-- the protocol stays the specification: session_check is the same with and without sizes
def checked (t : String) : String := match check (Json.mkObj [("lean", Json.str t)]) with
  | .ok j => (j.getObjValAs? String "reading").toOption.getD "" | .error e => e
#guard checked "protocol P (A, B) { q: Ask from A to B; Answer from B to A cause q; }" ==
       checked "protocol P (A, B[4]) { q: Ask from A to B; Answer from B to A cause q; }"

end LeanFM.Session.RealizableTests
