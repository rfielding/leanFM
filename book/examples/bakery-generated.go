// Code generated from the bakery specification. DO NOT EDIT.
package bakery

import "context"

// A Lot is bread already baked for sale. Production is scheduled before the
// storefront opens; it is not started by a customer purchase.
type Lot struct { BatchID, Product string; Units uint32 }

// Shipment is a batch waiting in a bounded truck FIFO.
type Shipment struct { EnqueueEventID string; Lot Lot }
type Truck struct { ID string; Queue chan Shipment }

func NewTruck(id string, capacity int) *Truck {
	return &Truck{ID: id, Queue: make(chan Shipment, capacity)}
}

// Enqueue blocks when the truck queue is full. ShipmentEnqueued records its
// batch, truck, and queue position.
func (t *Truck) Enqueue(ctx context.Context, shipment Shipment) error {
	select {
	case t.Queue <- shipment:
		return emit("ShipmentEnqueued", shipment.EnqueueEventID)
	case <-ctx.Done(): return ctx.Err()
	}
}

// Deliver is the sole FIFO dequeue path. ShipmentDequeued points to its enqueue
// and the preceding dequeue, making transport order observable.
func (t *Truck) Deliver(ctx context.Context, store *Storefront) error {
	var previousDequeue string
	for {
		select {
		case shipment := <-t.Queue:
			dequeueID := nextID("shipment-dequeued")
			if err := emitWithPrior("ShipmentDequeued", dequeueID,
				shipment.EnqueueEventID, previousDequeue); err != nil { return err }
			store.Receive(shipment.Lot)
			previousDequeue = dequeueID
		case <-ctx.Done(): return ctx.Err()
		}
	}
}

type Storefront struct { Inventory map[string][]Lot } // FIFO lots by product.
func NewStorefront() *Storefront { return &Storefront{Inventory: make(map[string][]Lot)} }
func (s *Storefront) Receive(lot Lot) { s.Inventory[lot.Product] = append(s.Inventory[lot.Product], lot) }

// Purchase exchanges pre-made storefront inventory for money. Its messages are
// PurchaseRequested, InventoryReserved, PaymentTendered, and SaleCompleted.
// There is no per-order bake and no courier delivery.
func (s *Storefront) Purchase(ctx context.Context, product string, units uint32,
	priceCents uint64) error {
	requestID := nextID("purchase-requested")
	if err := emit("PurchaseRequested", requestID); err != nil { return err }
	allocation, ok := reserveFIFO(s.Inventory[product], units)
	if !ok { return emitWithPrior("StockoutReported", nextID("stockout"), requestID) }
	reservedID := nextID("inventory-reserved")
	if err := emitWithPrior("InventoryReserved", reservedID, requestID); err != nil { return err }
	paymentID := nextID("payment-tendered")
	if err := tender(ctx, priceCents); err != nil { return err }
	if err := emitWithPrior("PaymentTendered", paymentID, reservedID); err != nil { return err }
	commitAllocation(s.Inventory, product, allocation)
	return emitWithPrior("SaleCompleted", nextID("sale-completed"), reservedID, paymentID)
}

// Declarations standing for generated protobuf/event plumbing.
type Allocation struct{}
func emit(kind, id string) error
func emitWithPrior(kind, id string, prior ...string) error
func nextID(prefix string) string
func reserveFIFO(lots []Lot, units uint32) (Allocation, bool)
func commitAllocation(inventory map[string][]Lot, product string, allocation Allocation)
func tender(ctx context.Context, cents uint64) error
