import * as lp from "./lending_protocol.js";

const sent: lp.Message[] = [];
const wire: lp.Transport = (m) => { sent.push(m); };

const s1 = lp.desk("1", wire);
const r = s1.receive(sent[0]!);
const s2 = r.next;                 // DeskS2: sendLent or sendHold
// @ts-expect-error  the Desk cannot send Returned before a Return arrives
s2.sendReturned();
const s5 = s2.sendHold({ book: "Dune" });
const a = s5.receive(sent[1]!);
if (a.label === "Approved") {
  // @ts-expect-error  an approved hold is answered with Waitlisted, never Lent (the lending bug)
  a.next.sendLent();
  a.next.sendWaitlisted();
}
// @ts-expect-error  without checking the label, the next state could be either
a.next.sendWaitlisted();

const m = lp.member("2", wire).sendBorrow({ book: "Emma" });
const got = m.receive(sent[2]!);
switch (got.label) {
  case "Lent": got.next.sendReturn({ book: "Emma" }); break;     // narrowed to MemberS3
  // @ts-expect-error  a waitlisted member has finished; there is nothing to return
  case "Waitlisted": got.next.sendReturn(); break;
}
// message bodies are typed: a Hold needs its book, and has no other fields
// @ts-expect-error  a Hold without a book
lp.desk("3", wire).receive(sent[0]!).next.sendHold({});
// @ts-expect-error  a Hold has no field copies
lp.desk("4", wire).receive(sent[0]!).next.sendHold({ book: "Dune", copies: 2n });

// @ts-expect-error  states with the same shape are still different types
const wrong: lp.DeskS6 = s5;
void wrong;
