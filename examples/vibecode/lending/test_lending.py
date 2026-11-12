"""Tests for the generated lending_protocol.py and the service built on it.

    cd examples/vibecode/lending && python3 -m unittest -v test_lending
"""

import json
import os
import unittest

import lending
import lending_protocol as lp

HERE = os.path.dirname(os.path.abspath(__file__))


class Wire:
    def __init__(self):
        self.sent, self.log = [], []

    def transport(self, m):
        self.sent.append(m)


class TypedMessages(unittest.TestCase):
    """selfhost.session.envelope: bodies are encoded and decoded against their message types."""

    def setUp(self):
        self.w = Wire()

    def test_received_body_is_its_message_type(self):
        lp.member("s1", self.w.transport).send_borrow(lp.Borrow(book="Dune"))
        msg, _ = lp.desk("s1", self.w.transport).receive(self.w.sent[-1])
        self.assertIsInstance(msg["body"], lp.Borrow)
        self.assertEqual(msg["body"].book, "Dune")

    def test_a_body_that_does_not_fit_is_refused(self):
        member = lp.member("s1", self.w.transport)
        with self.assertRaises(lp.ProtocolError):
            member.send_borrow({"book": "Dune", "copies": 2})
        with self.assertRaises(lp.ProtocolError):
            lp.member("s2", self.w.transport).send_borrow(lp.Borrow(book=7))
        bad = {"ts": "1", "id": "x", "session": "s3", "from": "Member", "to": "Desk", "label": "Borrow", "body": {}}
        with self.assertRaises(lp.ProtocolError):
            lp.desk("s3", self.w.transport).receive(bad)

    def test_integers_travel_as_decimal_strings(self):
        self.assertEqual(lp._to_wire("nat", "", 2**63 + 1, "x"), str(2**63 + 1))
        self.assertEqual(lp._from_wire("nat", "", "9223372036854775809", "x"), 2**63 + 1)
        with self.assertRaises(lp.ProtocolError):
            lp._from_wire("nat", "", 2**53 + 1, "x")  # a JSON number past 2**53 has lost its low bits
        with self.assertRaises(lp.ProtocolError):
            lp._from_wire("nat", "", "-1", "x")

    def test_every_event_has_a_unique_increasing_ns_timestamp(self):
        log = []
        member = lp.member("s1", self.w.transport, log.append)
        member.send_borrow(lp.Borrow(book="Dune"))
        lp.member("s2", self.w.transport, log.append).send_borrow(lp.Borrow(book="Emma"))
        ts = [int(e["ts"]) for e in log]
        self.assertEqual(len(set(ts)), len(ts))
        self.assertEqual(ts, sorted(ts))
        self.assertGreater(ts[0], 10**18)  # nanoseconds since the epoch: past 2**53


class GeneratedStates(unittest.TestCase):
    def setUp(self):
        self.w = Wire()

    def borrow(self, session="s1"):
        member = lp.member(session, self.w.transport, self.w.log.append)
        member.send_borrow(lp.Borrow(book="Dune"))
        return self.w.sent[-1]

    def test_send_fills_the_cause_the_protocol_names(self):
        b = self.borrow()
        state = lp.desk("s1", self.w.transport, self.w.log.append)
        _, s2 = state.receive(b)
        s2.send_lent()
        self.assertEqual(self.w.log[-1]["label"], "Lent")
        self.assertEqual(self.w.log[-1]["cause"], b["id"])

    def test_a_state_is_used_once(self):
        member = lp.member("s1", self.w.transport)
        member.send_borrow(lp.Borrow(book="Dune"))
        with self.assertRaises(lp.ProtocolError):
            member.send_borrow(lp.Borrow(book="Dune"))

    def test_receive_refuses_what_the_state_does_not_allow(self):
        desk = lp.desk("s1", self.w.transport)
        with self.assertRaises(lp.ProtocolError):
            desk.receive({"id": "x", "session": "s1", "from": "Member", "to": "Desk", "label": "Return"})
        with self.assertRaises(lp.ProtocolError):  # right label, wrong sender
            desk.receive({"id": "x", "session": "s1", "from": "Librarian", "to": "Desk", "label": "Borrow"})

    def test_a_refused_message_does_not_use_up_the_state(self):
        desk = lp.desk("s1", self.w.transport)
        with self.assertRaises(lp.ProtocolError):
            desk.receive({"id": "x", "session": "s1", "from": "Member", "to": "Desk", "label": "Return"})
        _, s2 = desk.receive(self.borrow())
        self.assertIsInstance(s2, lp.DeskS2)

    def test_a_message_of_another_session_is_refused(self):
        b = self.borrow("s2")
        with self.assertRaises(lp.ProtocolError):
            lp.desk("s1", self.w.transport).receive(b)

    def test_a_state_offers_only_its_methods(self):
        _, s2 = lp.desk("s1", self.w.transport).receive(self.borrow())
        s5 = s2.send_hold(lp.Hold(book="Dune"))
        self.assertFalse(hasattr(lp.DeskS6, "send_lent"))  # the bug cannot be written as a method
        self.assertIsInstance(s5, lp.DeskS5)


class Service(unittest.TestCase):
    def test_the_checked_in_logs_are_what_the_service_writes(self):
        for bug, name in [(False, "log.json"), (True, "bug-log.json")]:
            with open(os.path.join(HERE, name)) as f:
                self.assertEqual(lending.run(20, 1, bug), json.load(f), name)

    def test_every_session_ends(self):
        log = lending.run(50, 3, False)
        sessions = {e["session"] for e in log}
        ends = {e["session"] for e in log if e["label"] in ("Returned", "Waitlisted", "Refused")}
        self.assertEqual(sessions, ends)


if __name__ == "__main__":
    unittest.main()
