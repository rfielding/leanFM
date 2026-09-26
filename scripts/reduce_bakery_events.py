#!/usr/bin/env python3
"""Stream LeanFM bakery JSONL and calculate empirical model inputs."""

from __future__ import annotations

import argparse
import json
from collections import Counter, defaultdict
from pathlib import Path


TERMINALS = {"OrderRejected", "OrderCancelled", "OrderDelivered", "DeliveryFailed"}


def ratio(numerator: int, denominator: int) -> dict[str, object]:
    return {"numerator": numerator, "denominator": denominator,
            "decimal": numerator / denominator if denominator else None}


def percentile(values: list[int], percent: int) -> int | None:
    if not values:
        return None
    ordered = sorted(values)
    return ordered[((len(ordered) - 1) * percent) // 100]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", nargs="?", type=Path, default=Path("examples/bakery-events.jsonl"))
    parser.add_argument("--output", type=Path, default=Path("examples/bakery-stats.json"))
    parser.add_argument("--tex-output", type=Path)
    args = parser.parse_args()

    kinds: Counter[str] = Counter()
    daily: dict[int, Counter[str]] = defaultdict(Counter)
    orders: dict[str, dict[str, object]] = defaultdict(lambda: {
        "start": None, "stop": None, "terminal": None, "events": 0, "bytes": 0})
    total_events = total_bytes = 0
    with args.input.open(encoding="utf-8") as stream:
        for line in stream:
            event = json.loads(line)
            total_events += 1
            total_bytes += event["bytes"]
            kinds[event["kind"]] += 1
            day = event["timeAt"] // 86_400_000
            values = event["values"]
            bucket = daily[day]
            bucket["events"] += 1
            bucket["bytes"] += event["bytes"]
            if event["kind"] == "OrderPlaced":
                bucket["orders"] += 1
            if event["kind"] == "PaymentAuthorized":
                bucket["gross_sales_cents"] += values.get("amount_cents", 0)
            if event["kind"] in {"BakeCompleted", "BakeFailed"}:
                bucket["ingredient_cost_cents"] += values.get("ingredient_cost_cents", 0)
            bucket["refunds_cents"] += values.get("refund_cents", 0)
            bucket["waste_units"] += values.get("waste_units", 0)
            bucket["waste_cents"] += values.get("waste_cents", 0)
            if event["kind"] == "ShiftPaid":
                bucket["employee_pay_cents"] += values.get("pay_cents", 0)
            if event["kind"] == "OrderDelivered":
                bucket["delivered"] += 1
            if event["task"] != "fulfill_order":
                continue
            order = orders[event["session"]]
            order["events"] = int(order["events"]) + 1
            order["bytes"] = int(order["bytes"]) + event["bytes"]
            time_at = event["timeAt"]
            order["start"] = time_at if order["start"] is None else min(int(order["start"]), time_at)
            order["stop"] = time_at if order["stop"] is None else max(int(order["stop"]), time_at)
            if event["kind"] in TERMINALS:
                order["terminal"] = event["kind"]

    latencies = [int(o["stop"]) - int(o["start"]) for o in orders.values()]
    outcomes = Counter(str(o["terminal"]) for o in orders.values())
    starts_stops: list[tuple[int, int]] = []
    for order in orders.values():
        starts_stops.append((int(order["start"]), 1))
        starts_stops.append((int(order["stop"]), -1))
    active = max_active = 0
    for _, delta in sorted(starts_stops, key=lambda item: (item[0], item[1])):
        active += delta
        max_active = max(max_active, active)

    order_count = len(orders)
    accepted = kinds["OrderAccepted"]
    dispatched = kinds["DeliveryRequested"]
    daily_rows = []
    for day in sorted(daily):
        bucket = daily[day]
        net_revenue = bucket["gross_sales_cents"] - bucket["refunds_cents"]
        profit = net_revenue - bucket["ingredient_cost_cents"] - bucket["employee_pay_cents"]
        daily_rows.append({
            "day": day + 1,
            "orders": bucket["orders"],
            "delivered": bucket["delivered"],
            "gross_sales_cents": bucket["gross_sales_cents"],
            "refunds_cents": bucket["refunds_cents"],
            "net_revenue_cents": net_revenue,
            "ingredient_cost_cents": bucket["ingredient_cost_cents"],
            "employee_pay_cents": bucket["employee_pay_cents"],
            "profit_cents": profit,
            "waste_units": bucket["waste_units"],
            "waste_cents": bucket["waste_cents"],
        })
    stats = {
        "source": str(args.input),
        "orders": order_count,
        "events": total_events,
        "bytes": total_bytes,
        "max_active_orders": max_active,
        "max_causal_concurrency_per_order": 2,
        "probabilities": {
            "payment_authorized": ratio(kinds["PaymentAuthorized"], order_count),
            "bake_completed": ratio(kinds["BakeCompleted"], order_count),
            "order_accepted": ratio(accepted, order_count),
            "cancelled_given_accepted": ratio(kinds["OrderCancelled"], accepted),
            "delivered_given_dispatched": ratio(kinds["OrderDelivered"], dispatched),
            "completed_successfully": ratio(kinds["OrderDelivered"], order_count),
        },
        "latency_ms": {
            "mean": sum(latencies) / len(latencies),
            "p50": percentile(latencies, 50),
            "p95": percentile(latencies, 95),
            "maximum": max(latencies),
        },
        "outcomes": dict(sorted(outcomes.items())),
        "event_kinds": dict(sorted(kinds.items())),
        "daily": daily_rows,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(stats, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    if args.tex_output:
        tex = "\n".join([
            "% Generated by scripts/reduce_bakery_events.py; do not edit.",
            f"\\newcommand{{\\BakeryOrders}}{{{order_count:,}}}",
            f"\\newcommand{{\\BakeryEvents}}{{{total_events:,}}}",
            f"\\newcommand{{\\BakeryBytes}}{{{total_bytes:,}}}",
            f"\\newcommand{{\\BakeryPaymentRatio}}{{{kinds['PaymentAuthorized']:,}/{order_count:,}}}",
            f"\\newcommand{{\\BakeryBakeRatio}}{{{kinds['BakeCompleted']:,}/{order_count:,}}}",
            f"\\newcommand{{\\BakeryAcceptRatio}}{{{accepted:,}/{order_count:,}}}",
            f"\\newcommand{{\\BakeryDeliveredRatio}}{{{kinds['OrderDelivered']:,}/{order_count:,}}}",
            f"\\newcommand{{\\BakeryMeanLatency}}{{{sum(latencies) / len(latencies):,.3f}}}",
            f"\\newcommand{{\\BakeryPFiftyLatency}}{{{percentile(latencies, 50):,}}}",
            f"\\newcommand{{\\BakeryPNinetyFiveLatency}}{{{percentile(latencies, 95):,}}}",
            f"\\newcommand{{\\BakeryMaxActive}}{{{max_active}}}",
            "\\def\\BakeryDailyProfitCoordinates{" + " ".join(
                f"({row['day']},{row['profit_cents'] / 100:.2f})" for row in daily_rows) + "}",
            "\\def\\BakeryDailyRevenueCoordinates{" + " ".join(
                f"({row['day']},{row['net_revenue_cents'] / 100:.2f})" for row in daily_rows) + "}",
            "\\def\\BakeryDailyPayCoordinates{" + " ".join(
                f"({row['day']},{row['employee_pay_cents'] / 100:.2f})" for row in daily_rows) + "}",
            "\\def\\BakeryDailyWasteCostCoordinates{" + " ".join(
                f"({row['day']},{row['waste_cents'] / 100:.2f})" for row in daily_rows) + "}",
            "\\def\\BakeryDailyWasteUnitsCoordinates{" + " ".join(
                f"({row['day']},{row['waste_units']})" for row in daily_rows) + "}",
            "\\def\\BakeryOrdersProfitCoordinates{" + " ".join(
                f"({row['orders']},{row['profit_cents'] / 100:.2f})" for row in daily_rows) + "}",
            "",
        ])
        args.tex_output.parent.mkdir(parents=True, exist_ok=True)
        args.tex_output.write_text(tex, encoding="utf-8")
    print(json.dumps(stats, sort_keys=True))


if __name__ == "__main__":
    main()
