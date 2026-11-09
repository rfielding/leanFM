# Temporal properties of a protocol: a trip-booking saga

The structure of a session type says who sends what and who decides. Some rules it cannot show:
a booking must never charge the card after the flight was refused, and every hold must end up
confirmed or released. `session_ctl` checks such rules as CTL formulas over the protocol's own
state graph, with `{"after": "Label"}` meaning "Label has just happened".

[`Trip-parallel.protocol`](Trip-parallel.protocol) holds the seat and the room at once, then
charges or releases both. It checks clean, but the Agency's last choice does not depend on what the
holds answered:

```
session_ctl {"AG": {"implies": [{"after": "NoSeat"}, {"AG": {"not": {"after": "Charge"}}}]}}
disproved: Book, HoldSeat, NoSeat, HoldRoom, RoomHeld, Charge
```

[`Trip.protocol`](Trip.protocol) holds the seat first, then the room, and confirms or releases
every hold. `session_check` also caught a dangling hold on the way: without the confirmations,
"Flights cannot tell which branch Payments chose". Now every property holds:

| property | formula | answer |
|---|---|---|
| never charge after no seat | `AG(after NoSeat → AG ¬after Charge)` | proved |
| a held seat is confirmed or released | `AG(after SeatHeld → AF(after SeatConfirmed ∨ after SeatReleased))` | proved |
| every booking ends | `AF terminal` | proved |

Both versions are checked by `LeanFM/SessionToolsTests.lean`.
