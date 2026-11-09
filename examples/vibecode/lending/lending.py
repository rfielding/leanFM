#!/usr/bin/env python3
"""A lending service built on lending_protocol.py, which LeanFM generated from Lending.protocol.

The generated module holds each role's typestate as classes: a state's methods are exactly what the
protocol allows there, a send fills in the cause the protocol names and logs the event, and a state
used twice raises. This file adds only what the protocol leaves open: the Desk's stock, the
Librarian's limit on holds, when members arrive, and the (simulated) network.

The network delivers in-flight messages in a seeded random order, so many members' sessions
interleave the way they would against a real server, and a seed reproduces a run.

    python3 lending.py > log.json              # a run: every session conforms
    python3 lending.py --bug > bug-log.json    # a Desk that goes around its typestate
"""

import argparse
import json
import random
import sys

import lending_protocol as lp


class Network:
    """In-flight messages, delivered in a seeded random order, and the event log."""

    def __init__(self, rng):
        self.rng, self.in_flight, self.log = rng, [], []

    def transport(self, message):
        self.in_flight.append(message)

    def deliver_one(self):
        return self.in_flight.pop(self.rng.randrange(len(self.in_flight)))


class Desk:
    """The Desk's decisions. Per session it keeps the state the generated classes returned."""

    def __init__(self, net, stock, bug=False):
        self.net, self.stock, self.bug = net, dict(stock), bug
        self.states, self.books = {}, {}

    def receive(self, m):
        sid = m["session"]
        state = self.states.get(sid) or lp.desk(sid, self.net.transport, self.net.log.append)
        msg, state = state.receive(m)
        if isinstance(state, lp.DeskS2):                    # a Borrow: lend, or ask for a hold
            book = self.books[sid] = msg["body"]["book"]
            if self.stock.get(book, 0) > 0:
                self.stock[book] -= 1
                state = state.send_lent()
            else:
                state = state.send_hold({"book": book})
        elif isinstance(state, lp.DeskS4):                  # a Return
            self.stock[self.books[sid]] += 1
            state = state.send_returned()
        elif isinstance(state, lp.DeskS6):                  # the hold was approved
            book = self.books[sid]
            if self.bug and self.stock.get(book, 0) > 0:
                # The bug: a copy came back while the hold was pending, so lend it now. DeskS6 has
                # no send_lent, so the shortcut has to go around the typestate to the endpoint.
                self.stock[book] -= 1
                state.endpoint.send("Member", "Lent", "l", "b", None)
                state = lp.DeskS3(state.endpoint)            # and carry on as if it had lent
            else:
                state = state.send_waitlisted()
        elif isinstance(state, lp.DeskS7):                  # the hold was denied
            state = state.send_refused()
        self.states[sid] = state


class Librarian:
    """Approves at most max_holds holds per book."""

    def __init__(self, net, max_holds=2):
        self.net, self.max_holds, self.holds = net, max_holds, {}

    def receive(self, m):
        state = lp.librarian(m["session"], self.net.transport, self.net.log.append)
        msg, state = state.receive(m)
        book = msg["body"]["book"]
        if self.holds.get(book, 0) < self.max_holds:
            self.holds[book] = self.holds.get(book, 0) + 1
            state.send_approved()
        else:
            state.send_denied()


class Member:
    """Borrows a book and, if it is lent, reads it and returns it."""

    def __init__(self, net, session, book):
        self.state = lp.member(session, net.transport, net.log.append)
        self.book = book

    def start(self):
        self.state = self.state.send_borrow({"book": self.book})

    def receive(self, m):
        msg, state = self.state.receive(m)
        if isinstance(state, lp.MemberS3):                  # Lent: read it, then return it
            state = state.send_return({"book": self.book})
        self.state = state


def run(members, seed, bug):
    rng = random.Random(seed)
    net = Network(rng)
    books = ["Dune", "Emma", "Ulysses"]
    desk = Desk(net, {"Dune": 2, "Emma": 1, "Ulysses": 1}, bug=bug)
    librarian = Librarian(net)
    waiting = [Member(net, str(i + 1), rng.choice(books)) for i in range(members)]
    active = {}
    while waiting or net.in_flight:
        # either a new member arrives or a message in flight is delivered
        if waiting and (not net.in_flight or rng.random() < 0.3):
            member = waiting.pop(0)
            active[member.state.endpoint.session] = member
            member.start()
            continue
        m = net.deliver_one()
        if m["to"] == "Desk":
            desk.receive(m)
        elif m["to"] == "Librarian":
            librarian.receive(m)
        else:
            active[m["session"]].receive(m)
    return net.log


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--members", type=int, default=20)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--bug", action="store_true", help="lend straight away on an approved hold")
    a = ap.parse_args()
    json.dump(run(a.members, a.seed, a.bug), sys.stdout, indent=1)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
