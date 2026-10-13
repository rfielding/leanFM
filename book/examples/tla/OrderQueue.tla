----------------------------- MODULE OrderQueue -----------------------------
EXTENDS Integers, Sequences, FiniteSets, TLC
CONSTANTS Clients, Servers, Orders, QueueBound, CacheBits, ClockBound
Actors == Clients \cup Servers
Messages == [kind : {"placeOrder", "placedOrder"},
             order : Orders, replyTo : Clients]
NoMessage == [kind |-> "none", order |-> "none", replyTo |-> "none"]
VARIABLES inbox, pc, current, sent, placed, received, scratch, tick
vars == <<inbox, pc, current, sent, placed, received, scratch, tick>>

Init == /\ inbox = [a \in Actors |-> <<>>]
        /\ pc = [b \in Servers |-> "idle"]
        /\ current = [b \in Servers |-> NoMessage]
        /\ sent = {} /\ placed = {} /\ received = {}
        /\ scratch = [i \in 1..CacheBits |-> FALSE]
        /\ tick = 0

Send(a, b, o) ==
  /\ o \notin sent /\ Len(inbox[b]) < QueueBound
  /\ inbox' = [inbox EXCEPT ![b] = Append(@,
       [kind |-> "placeOrder", order |-> o, replyTo |-> a])]
  /\ sent' = sent \cup {o}
  /\ UNCHANGED <<pc, current, placed, received, scratch, tick>>

Receive(b) ==
  /\ pc[b] = "idle" /\ Len(inbox[b]) > 0
  /\ current' = [current EXCEPT ![b] = Head(inbox[b])]
  /\ inbox' = [inbox EXCEPT ![b] = Tail(@)]
  /\ pc' = [pc EXCEPT ![b] = "busy"]
  /\ UNCHANGED <<sent, placed, received, scratch, tick>>

Finish(b) ==
  LET m == current[b] IN
  /\ pc[b] = "busy" /\ Len(inbox[m.replyTo]) < QueueBound
  /\ placed' = placed \cup {m.order}
  /\ inbox' = [inbox EXCEPT ![m.replyTo] = Append(@,
       [kind |-> "placedOrder", order |-> m.order, replyTo |-> m.replyTo])]
  /\ pc' = [pc EXCEPT ![b] = "idle"]
  /\ current' = [current EXCEPT ![b] = NoMessage]
  /\ UNCHANGED <<sent, received, scratch, tick>>

ReadReply(a) ==
  /\ Len(inbox[a]) > 0
  /\ received' = received \cup {Head(inbox[a]).order}
  /\ inbox' = [inbox EXCEPT ![a] = Tail(@)]
  /\ UNCHANGED <<pc, current, sent, placed, scratch, tick>>

CacheStep == \E i \in 1..CacheBits:
  /\ scratch' = [scratch EXCEPT ![i] = ~@]
  /\ UNCHANGED <<inbox, pc, current, sent, placed, received, tick>>
ClockStep ==
  /\ (ClockBound = -1 \/ tick < ClockBound)
  /\ tick' = tick + 1
  /\ UNCHANGED <<inbox, pc, current, sent, placed, received, scratch>>
Next == (\E a \in Clients, b \in Servers, o \in Orders: Send(a,b,o))
     \/ (\E b \in Servers: Receive(b) \/ Finish(b))
     \/ (\E a \in Clients: ReadReply(a)) \/ CacheStep \/ ClockStep
Spec == Init /\ [][Next]_vars

TypeOK == /\ inbox \in [Actors -> Seq(Messages)]
          /\ \A a \in Actors: Len(inbox[a]) <= QueueBound
          /\ pc \in [Servers -> {"idle", "busy"}]
          /\ current \in [Servers -> Messages \cup {NoMessage}]
          /\ sent \subseteq Orders /\ placed \subseteq sent
          /\ received \subseteq placed
          /\ scratch \in [1..CacheBits -> BOOLEAN] /\ tick \in Nat
NoPrematureReply == \A a \in Clients:
  \A i \in 1..Len(inbox[a]): inbox[a][i].order \in placed
=============================================================================
