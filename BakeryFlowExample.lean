import LeanFM.Artifacts
import LeanFM.MDPDiagram

namespace BakeryFlow
open LeanFM

def messages : List MDPDiagram.InteractionMessage :=
  [ { src := "Scheduler", dst := "Bakery", label := "BakeStarted(batch) before opening" }
  , { src := "Bakery", dst := "Truck", label := "ShipmentEnqueued(batch, position)" }
  , { src := "Truck", dst := "Storefront", label := "ShipmentDequeued(batch) FIFO" }
  , { src := "Customer", dst := "Storefront", label := "PurchaseRequested(product, quantity)" }
  , { src := "Storefront", dst := "Customer", label := "InventoryReserved(batch allocations)" }
  , { src := "Customer", dst := "Storefront", label := "PaymentTendered(amount)" }
  , { src := "Storefront", dst := "Customer", label := "SaleCompleted(bread, amount)" } ]

def output : DesiredOutput :=
  { id := "bakery.production_transport_retail"
  , prompt := "Bread is premade in the morning; trucks are queues shipping it to the storefront; customers exchange bread for money at the storefront."
  , question := "Where are baking, truck queueing, storefront inventory and the customer sale separated?"
  , kind := .interactionDiagram
  , eventSource := "the BatchBaked, ShipmentEnqueued, ShipmentDequeued, PurchaseRequested, InventoryReserved, PaymentTendered and SaleCompleted event schemas in scripts/generate_bakery_events.py"
  , reducer := "project the morning production and FIFO shipment prefix followed by the independent short retail-sale interaction"
  , unit := "messages, batches, queue positions, bread units and cents; one morning and one representative sale" }

def tex : String := MDPDiagram.renderInteractionTeX
  ["Scheduler", "Bakery", "Truck", "Storefront", "Customer"] messages

def main : IO Unit := do
  IO.FS.writeFile "book/generated/bakery-flow.tex" tex
  IO.FS.writeFile "book/generated/bakery-flow-provenance.txt" (reprStr output ++ "\n")
  IO.println "ok: bakery production, truck FIFO and retail sale diagram generated"

end BakeryFlow

def main : IO Unit := BakeryFlow.main
