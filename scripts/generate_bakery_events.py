#!/usr/bin/env python3
"""Generate the canonical deterministic LeanFM bakery event stream."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

DAY_MS = 86_400_000


class Lcg:
    def __init__(self, seed: int) -> None:
        self.state = seed & 0xFFFFFFFF

    def next(self) -> int:
        self.state = (1664525 * self.state + 1013904223) & 0xFFFFFFFF
        return self.state

    def below(self, bound: int) -> int:
        return self.next() % bound

    def chance(self, numerator: int, denominator: int = 1000) -> bool:
        return self.below(denominator) < numerator


def event(order: int, index: int, prior: list[str], kind: str, src: str,
          dst: str, start: int, duration: int, byte_count: int,
          values: dict[str, object] | None = None) -> dict[str, object]:
    session = f"bakery-{order:06d}"
    return {
        "id": f"{session}-e{index}",
        "prior": prior,
        "session": session,
        "task": "fulfill_order",
        "kind": kind,
        "src": src,
        "dst": dst,
        "timeAt": start + duration,
        "bytes": byte_count,
        "values": values or {},
    }


def generate_order(order: int, arrival: int, rng: Lcg) -> list[dict[str, object]]:
    product = ["baguette", "croissant", "rye", "sourdough"][rng.below(4)]
    quantity = 1 + rng.below(6)
    price_cents = {"baguette": 450, "croissant": 325, "rye": 700, "sourdough": 850}[product] * quantity
    ingredient_cost_cents = {"baguette": 115, "croissant": 95, "rye": 180, "sourdough": 225}[product] * quantity
    events: list[dict[str, object]] = []

    e0 = event(order, 0, [], "OrderPlaced", "Customer", "Storefront",
               arrival, 100 + rng.below(901), 72 + rng.below(40),
               {"product": product, "quantity": quantity, "price_cents": price_cents,
                "ingredient_cost_cents": ingredient_cost_cents})
    events.append(e0)

    fork_start = int(e0["timeAt"])
    e1 = event(order, 1, [str(e0["id"])], "PaymentRequested", "Storefront", "Payment",
               fork_start, 100 + rng.below(401), 48 + rng.below(24), {"price_cents": price_cents})
    e2 = event(order, 2, [str(e0["id"])], "BakeRequested", "Storefront", "Bakery",
               fork_start, 100 + rng.below(401), 56 + rng.below(32),
               {"product": product, "quantity": quantity,
                "ingredient_cost_cents": ingredient_cost_cents})
    events.extend([e1, e2])

    payment_ok = rng.chance(940)
    baked_ok = rng.chance(970)
    e3 = event(order, 3, [str(e1["id"])],
               "PaymentAuthorized" if payment_ok else "PaymentDeclined",
               "Payment", "Storefront", int(e1["timeAt"]), 500 + rng.below(4501),
               44 + rng.below(20), {"authorized": payment_ok,
                                     "amount_cents": price_cents if payment_ok else 0})
    e4 = event(order, 4, [str(e2["id"])],
               "BakeCompleted" if baked_ok else "BakeFailed",
               "Bakery", "Storefront", int(e2["timeAt"]), 600_000 + rng.below(3_000_001),
               52 + rng.below(36), {"completed": baked_ok,
                                    "ingredient_cost_cents": ingredient_cost_cents,
                                    "waste_units": 0 if baked_ok else quantity,
                                    "waste_cents": 0 if baked_ok else ingredient_cost_cents})
    events.extend([e3, e4])

    join_start = max(int(e3["timeAt"]), int(e4["timeAt"]))
    accepted = payment_ok and baked_ok
    e5 = event(order, 5, [str(e3["id"]), str(e4["id"])],
               "OrderAccepted" if accepted else "OrderRejected",
               "Storefront", "Customer", join_start, 100 + rng.below(901),
               40 + rng.below(24),
               {"outcome": "accepted" if accepted else "rejected",
                "refund_cents": price_cents if payment_ok and not accepted else 0})
    events.append(e5)
    if not accepted:
        return events

    if rng.chance(80):
        e6 = event(order, 6, [str(e5["id"])], "OrderCancelled", "Customer", "Storefront",
                   int(e5["timeAt"]), 100 + rng.below(901), 36 + rng.below(20),
                   {"outcome": "cancelled", "refund_cents": price_cents,
                    "waste_units": quantity, "waste_cents": ingredient_cost_cents})
        events.append(e6)
        return events

    e6 = event(order, 6, [str(e5["id"])], "DeliveryRequested", "Storefront", "Courier",
               int(e5["timeAt"]), 1 + rng.below(5), 48 + rng.below(24))
    e7 = event(order, 7, [str(e6["id"])], "CourierAssigned", "Courier", "Storefront",
               int(e6["timeAt"]), 30_000 + rng.below(270_001), 40 + rng.below(24))
    delivered = rng.chance(960)
    e8 = event(order, 8, [str(e7["id"])],
               "OrderDelivered" if delivered else "DeliveryFailed",
               "Courier", "Customer", int(e7["timeAt"]), 600_000 + rng.below(4_800_001),
               44 + rng.below(28),
               {"outcome": "delivered" if delivered else "delivery_failed",
                "price_cents": price_cents,
                "refund_cents": 0 if delivered else price_cents,
                "waste_units": 0 if delivered else quantity,
                "waste_cents": 0 if delivered else ingredient_cost_cents})
    events.extend([e6, e7, e8])
    return events


def shift_events(days: int, rng: Lcg) -> list[dict[str, object]]:
    staff = [
        ("Baker-A", "baker", 2200), ("Baker-B", "baker", 2200),
        ("Baker-C", "baker", 2300), ("Counter-A", "counter", 1800),
        ("Counter-B", "counter", 1800), ("Courier-A", "courier", 2000),
        ("Courier-B", "courier", 2000), ("Manager", "manager", 2800),
    ]
    result: list[dict[str, object]] = []
    for day in range(days):
        for index, (employee, role, hourly_cents) in enumerate(staff):
            minutes = 420 + rng.below(181)
            start = day * DAY_MS + (5 * 60 + rng.below(180)) * 60_000
            stop = start + minutes * 60_000
            pay_cents = (minutes * hourly_cents) // 60
            result.append({
                "id": f"day-{day + 1:03d}-shift-{index + 1}", "prior": [],
                "session": f"day-{day + 1:03d}", "task": "employee_pay",
                "kind": "ShiftPaid", "src": "Payroll", "dst": "Employee",
                "timeAt": stop, "bytes": 52,
                "values": {"employee": employee, "role": role, "minutes": minutes,
                           "hourly_cents": hourly_cents, "pay_cents": pay_cents},
            })
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--orders", type=int, default=20_000)
    parser.add_argument("--seed", type=int, default=0xBA4E12)
    parser.add_argument("--output", type=Path, default=Path("examples/bakery-events.jsonl"))
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    rng = Lcg(args.seed)
    arrival = 0
    event_count = 0
    with args.output.open("w", encoding="utf-8") as stream:
        for order in range(1, args.orders + 1):
            arrival += 30_000 + rng.below(240_001)
            for item in generate_order(order, arrival, rng):
                stream.write(json.dumps(item, separators=(",", ":"), sort_keys=True) + "\n")
                event_count += 1
        days = arrival // DAY_MS + 1
        for item in shift_events(days, rng):
            stream.write(json.dumps(item, separators=(",", ":"), sort_keys=True) + "\n")
            event_count += 1
    print(json.dumps({"orders": args.orders, "events": event_count,
                      "seed": args.seed, "output": str(args.output)}, sort_keys=True))


if __name__ == "__main__":
    main()
