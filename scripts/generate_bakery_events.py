#!/usr/bin/env python3
"""Generate bakery production, truck-queue, inventory, and retail events."""
from __future__ import annotations
import argparse, json
from collections import deque
from dataclasses import dataclass
from pathlib import Path

DAY_MS = 86_400_000
MINUTE_MS = 60_000
PRODUCTS = {"baguette": (450,115,2), "croissant": (325,95,2),
            "rye": (700,180,3), "sourdough": (850,225,3)}

class Lcg:
    def __init__(self, seed: int): self.state = seed & 0xFFFFFFFF
    def next(self):
        self.state = (1664525*self.state + 1013904223) & 0xFFFFFFFF
        return self.state
    def below(self, bound: int): return (self.next() * bound) >> 32

@dataclass
class Lot:
    batch_id: str; product: str; baked_day: int; freshness_days: int
    unit_cost_cents: int; units: int

def event(event_id, prior, session, task, kind, src, dst, time_at, byte_count, values=None):
    return {"id":event_id, "prior":prior, "session":session, "task":task,
            "kind":kind, "src":src, "dst":dst, "timeAt":time_at,
            "bytes":byte_count, "values":values or {}}

def expire_lots(day, inventory, rng, events):
    for product, lots in inventory.items():
        while lots and day-lots[0].baked_day >= lots[0].freshness_days:
            lot = lots.popleft()
            if not lot.units: continue
            session = f"charity-{lot.batch_id}"
            transfer = event(f"{session}-transfer", [], session, "charity_transfer", "CharityTransfer",
                "Storefront", "Charity", day*DAY_MS+4*60*MINUTE_MS, 64+rng.below(20),
                {"batch_id":lot.batch_id,"product":product,"donated_units":lot.units,
                 "eligible_value_cents":lot.units*lot.unit_cost_cents,
                 "freshness_days":lot.freshness_days})
            receipt = event(f"{session}-receipt", [transfer["id"]], session, "charity_transfer", "DonationReceiptRecorded",
                "Charity", "Storefront", transfer["timeAt"]+250+rng.below(751), 52+rng.below(18),
                {"batch_id":lot.batch_id,"product":product,"donated_units":lot.units,
                 "eligible_value_cents":lot.units*lot.unit_cost_cents})
            events += [transfer, receipt]

def morning_production(day, orders_today, inventory, rng, events):
    truck = f"Truck-{1+day%2}"
    queued = []
    # Mean requested quantity is 3.5 and products are equiprobable. Bake with
    # headroom so ordinary variation produces waste as well as occasional
    # stockout rather than making nearly half of customers fail.
    per_product = max(1, orders_today)*11//10
    for production_slot, (product, (_, unit_cost, freshness)) in enumerate(PRODUCTS.items()):
        units = per_product+rng.below(max(2, per_product//3+1))
        batch_id, session = f"day-{day+1:03d}-{product}", f"batch-day-{day+1:03d}-{product}"
        started_at = day*DAY_MS+(4*60+production_slot*8)*MINUTE_MS
        started = event(f"{session}-start", [], session, "stock_storefront", "BakeStarted", "Scheduler", "Bakery",
            started_at, 48+rng.below(16), {"batch_id":batch_id,"product":product,"planned_units":units})
        baked = event(f"{session}-baked", [started["id"]], session, "stock_storefront", "BatchBaked", "Bakery", "Shipping",
            started_at+(50+rng.below(31))*MINUTE_MS, 64+rng.below(24),
            {"batch_id":batch_id,"product":product,"units_baked":units,
             "ingredient_cost_cents":units*unit_cost,"freshness_days":freshness})
        loaded = event(f"{session}-enqueued", [baked["id"]], session, "stock_storefront", "ShipmentEnqueued", "Bakery", truck,
            baked["timeAt"]+500+rng.below(1501), 60+rng.below(20),
            {"batch_id":batch_id,"product":product,"units":units,"truck_id":truck,
             "queue_position":0,"queue_capacity_batches":len(PRODUCTS)})
        lot = Lot(batch_id,product,day,freshness,unit_cost,units)
        events += [started,baked,loaded]; queued.append((lot,loaded))
    # Queue position and dequeue order come from the observable enqueue time,
    # not from product declaration or production-start order.
    queued.sort(key=lambda pair: (pair[1]["timeAt"], pair[1]["id"]))
    for position, (_, loaded) in enumerate(queued):
        loaded["values"]["queue_position"] = position
    previous = None; arrival_base = day*DAY_MS+7*60*MINUTE_MS
    for position, (lot,loaded) in enumerate(queued):
        prior = [loaded["id"]]+([previous] if previous else [])
        unloaded = event(f"batch-{lot.batch_id}-dequeued", prior, f"batch-{lot.batch_id}",
            "stock_storefront", "ShipmentDequeued", truck, "Storefront", arrival_base+position*2*MINUTE_MS+rng.below(30001),
            58+rng.below(22), {"batch_id":lot.batch_id,"product":lot.product,
            "units_stocked":lot.units,"truck_id":truck,"queue_position":position})
        events.append(unloaded); inventory[lot.product].append(lot); previous = unloaded["id"]

def reserve_fifo(lots, quantity):
    if sum(lot.units for lot in lots) < quantity: return None
    remaining, allocation = quantity, []
    for lot in lots:
        take=min(lot.units,remaining)
        if take: allocation.append((lot,take)); remaining-=take
        if not remaining: break
    for lot,take in allocation: lot.units-=take
    while lots and not lots[0].units: lots.popleft()
    return allocation

def retail_sale(order, arrival, inventory, rng):
    product=list(PRODUCTS)[rng.below(len(PRODUCTS))]; quantity=1+rng.below(6)
    price=PRODUCTS[product][0]*quantity; session=f"retail-{order:06d}"
    requested=event(f"{session}-request",[],session,"retail_sale","PurchaseRequested","Customer","Storefront",arrival,
        58+rng.below(24),{"product":product,"quantity":quantity,"price_cents":price})
    allocation=reserve_fifo(inventory[product],quantity)
    if allocation is None:
        stockout=event(f"{session}-stockout",[requested["id"]],session,"retail_sale","StockoutReported","Storefront","Customer",
            arrival+80+rng.below(421),44+rng.below(18),{"product":product,"requested_units":quantity,
            "available_units":sum(lot.units for lot in inventory[product]),"outcome":"stockout"})
        return [requested,stockout]
    reserved=event(f"{session}-reserved",[requested["id"]],session,"retail_sale","InventoryReserved","Storefront","Customer",
        arrival+80+rng.below(421),62+rng.below(24),{"product":product,"quantity":quantity,
        "batch_allocations":[{"batch_id":lot.batch_id,"units":units} for lot,units in allocation]})
    tendered=event(f"{session}-payment",[reserved["id"]],session,"retail_sale","PaymentTendered","Customer","Storefront",
        reserved["timeAt"]+150+rng.below(851),48+rng.below(20),{"amount_cents":price})
    completed=event(f"{session}-completed",[reserved["id"],tendered["id"]],session,"retail_sale","SaleCompleted",
        "Storefront","Customer",tendered["timeAt"]+100+rng.below(401),54+rng.below(22),
        {"product":product,"quantity":quantity,"amount_cents":price,"outcome":"sold"})
    return [requested,reserved,tendered,completed]

def shift_events(day,rng):
    staff=[("Baker-A","baker",2200),("Baker-B","baker",2200),("Baker-C","baker",2300),
           ("Counter-A","counter",1800),("Counter-B","counter",1800),("Driver-A","driver",2000),
           ("Manager","manager",2800)]
    result=[]
    for index,(employee,role,hourly) in enumerate(staff):
        minutes=420+rng.below(121); stop=day*DAY_MS+(13*60+rng.below(180))*MINUTE_MS
        result.append(event(f"day-{day+1:03d}-shift-{index+1}",[],f"day-{day+1:03d}","employee_pay","ShiftPaid",
            "Payroll","Employee",stop,52,{"employee":employee,"role":role,"minutes":minutes,
            "hourly_cents":hourly,"pay_cents":minutes*hourly//60}))
    return result

def main():
    parser=argparse.ArgumentParser(); parser.add_argument("--orders",type=int,default=20_000)
    parser.add_argument("--days",type=int,default=35); parser.add_argument("--seed",type=int,default=0xBA4E12)
    parser.add_argument("--output",type=Path,default=Path("examples/bakery-events.jsonl")); args=parser.parse_args()
    rng=Lcg(args.seed); inventory={product:deque() for product in PRODUCTS}; events=[]; order=0
    base,remainder=divmod(args.orders,args.days)
    for day in range(args.days):
        expire_lots(day,inventory,rng,events); orders_today=base+(day<remainder)
        morning_production(day,orders_today,inventory,rng,events)
        open_at=day*DAY_MS+8*60*MINUTE_MS; window=9*60*MINUTE_MS
        for index in range(orders_today):
            order+=1; arrival=open_at+(index+1)*window//(orders_today+1)+rng.below(5001)
            events += retail_sale(order,arrival,inventory,rng)
        events += shift_events(day,rng)
    events.sort(key=lambda item:(item["timeAt"],item["id"])); args.output.parent.mkdir(parents=True,exist_ok=True)
    with args.output.open("w",encoding="utf-8") as stream:
        for item in events: stream.write(json.dumps(item,separators=(",",":"),sort_keys=True)+"\n")
    print(json.dumps({"orders":args.orders,"events":len(events),"days":args.days,
                      "seed":args.seed,"output":str(args.output)},sort_keys=True))

if __name__ == "__main__": main()
