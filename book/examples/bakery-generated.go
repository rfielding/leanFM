// Code generated from Requirements.lean, Requirements.proto, and
// Implementation.lean. DO NOT EDIT.
package bakery

import (
	"context"
	"fmt"
	"time"

	"google.golang.org/protobuf/proto"
	pb "example.com/bakery/generated/bakerypb"
)

// Requirement: resource:Storefront
// Justification: each Storefront instance has finite inbound and outbound queues;
// a send to a full queue blocks and a receive from an empty queue blocks.
type Storefront struct {
	ID         string
	PaymentOut chan []byte
	BakeryOut  chan []byte
	ResultsIn  chan []byte
	CustomerOut chan []byte
	Now        func() time.Time
}

// Requirement: resource:Storefront
// Justification: instantiate the capacities selected by Implementation.lean.
func NewStorefront(id string, paymentCapacity, bakeryCapacity, resultCapacity, customerCapacity int) *Storefront {
	return &Storefront{
		ID:         id,
		PaymentOut: make(chan []byte, paymentCapacity),
		BakeryOut:  make(chan []byte, bakeryCapacity),
		ResultsIn:  make(chan []byte, resultCapacity),
		CustomerOut: make(chan []byte, customerCapacity),
		Now:        time.Now,
	}
}

// Requirement: proof:scenario protobuf round trip
// Justification: every generated event must resolve to bytes and be recoverable.
func writeProto(ctx context.Context, dst chan<- []byte, event *pb.ScenarioEvent) error {
	wire, err := proto.MarshalOptions{Deterministic: true}.Marshal(event)
	if err != nil {
		return fmt.Errorf("marshal scenario event: %w", err)
	}
	select {
	case dst <- wire: // Blocking bounded-channel send.
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

// Requirement: proof:scenario protobuf round trip
// Justification: received bytes recreate the typed event used by the grammar.
func readProto(ctx context.Context, src <-chan []byte) (*pb.ScenarioEvent, error) {
	select {
	case wire := <-src: // Blocking receive from an empty channel.
		var event pb.ScenarioEvent
		if err := proto.Unmarshal(wire, &event); err != nil {
			return nil, fmt.Errorf("unmarshal scenario event: %w", err)
		}
		return &event, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

// Requirement: task:fulfill_order
// Justification: implement the generated legal production beginning at OrderPlaced.
func (s *Storefront) HandleOrderPlaced(ctx context.Context, placed *pb.ScenarioEvent) error {
	order, ok := placed.Message.Atom.(*pb.RequirementEnvelope_OrderPlaced)
	if !ok {
		return fmt.Errorf("expected OrderPlaced, got %T", placed.Message.Atom)
	}

	// Requirement: grammar:payment_parallel_bake
	// Justification: payment and baking fork from the same OrderPlaced event.
	paymentRequest := &pb.ScenarioEvent{
		Id: placed.Id + ".payment-requested", Prior: []string{placed.Id},
		Session: placed.Session, Task: placed.Task,
		Src: s.ID, Dst: "payment-1", TimeAt: unixMilliseconds(s.Now()),
		Message: &pb.RequirementEnvelope{Atom: &pb.RequirementEnvelope_PaymentRequested{
			PaymentRequested: &pb.PaymentRequested{PriceCents: order.OrderPlaced.PriceCents},
		}},
	}
	bakeRequest := &pb.ScenarioEvent{
		Id: placed.Id + ".bake-requested", Prior: []string{placed.Id},
		Session: placed.Session, Task: placed.Task,
		Src: s.ID, Dst: "bakery-1", TimeAt: unixMilliseconds(s.Now()),
		Message: &pb.RequirementEnvelope{Atom: &pb.RequirementEnvelope_BakeRequested{
			BakeRequested: &pb.BakeRequested{
				Product: order.OrderPlaced.Product, Quantity: order.OrderPlaced.Quantity,
			},
		}},
	}

	sendErrors := make(chan error, 2)
	go func() { sendErrors <- writeProto(ctx, s.PaymentOut, paymentRequest) }()
	go func() { sendErrors <- writeProto(ctx, s.BakeryOut, bakeRequest) }()
	for range 2 {
		if err := <-sendErrors; err != nil {
			return err
		}
	}

	results := make(map[string]*pb.ScenarioEvent, 2)
	for len(results) < 2 {
		result, err := readProto(ctx, s.ResultsIn)
		if err != nil {
			return err
		}
		if result.Session != placed.Session || result.Task != placed.Task {
			return fmt.Errorf("result dispatcher delivered the wrong (session, task)")
		}
		switch result.Message.Atom.(type) {
		case *pb.RequirementEnvelope_PaymentAuthorized,
			*pb.RequirementEnvelope_PaymentDeclined:
			results["payment"] = result
		case *pb.RequirementEnvelope_BakeCompleted,
			*pb.RequirementEnvelope_BakeFailed:
			results["bake"] = result
		}
	}

	paymentResult := results["payment"]
	bakeResult := results["bake"]
	accepted := isPaymentAuthorized(paymentResult) && isBakeCompleted(bakeResult)

	// Requirement: grammar:payment_and_bake_join
	// Justification: OrderAccepted/Rejected is enabled only after the two-of-two join.
	decision := &pb.ScenarioEvent{
		Id: placed.Id + ".decision",
		Prior: []string{paymentResult.Id, bakeResult.Id, placed.Id},
		Session: placed.Session, Task: placed.Task,
		Src: s.ID, Dst: placed.Src, TimeAt: unixMilliseconds(s.Now()),
		JoinRequired: 2, JoinTotal: 2,
		JoinSelected: []string{paymentResult.Id, bakeResult.Id},
		Message: decisionMessage(accepted),
	}
	return writeProto(ctx, s.CustomerOut, decision)
}

// Requirement: performance:client-experienced byte rate
// Justification: pool work over the observation time experienced by each client.
func ClientExperiencedRate(samples []CompletedWork) (bytes, milliseconds uint64) {
	for _, sample := range samples {
		bytes += sample.BytesMoved
		milliseconds += sample.End.TimeAt - sample.Start.TimeAt
	}
	return bytes, milliseconds
}

// Requirement: performance:server aggregate byte throughput
// Justification: measure total work over one server wall-clock window.
func ServerAggregateRate(samples []CompletedWork) (bytes, milliseconds uint64) {
	start, end := samples[0].Start.TimeAt, samples[0].End.TimeAt
	for _, sample := range samples {
		bytes += sample.BytesMoved
		if sample.Start.TimeAt < start { start = sample.Start.TimeAt }
		if sample.End.TimeAt > end { end = sample.End.TimeAt }
	}
	return bytes, end - start
}

type CompletedWork struct {
	Start, End *pb.ScenarioEvent
	BytesMoved uint64
}

func unixMilliseconds(now time.Time) uint64 { return uint64(now.UnixMilli()) }

// The following helpers are generated by exhaustive matches over grammar atoms.
func isPaymentAuthorized(*pb.ScenarioEvent) bool
func isBakeCompleted(*pb.ScenarioEvent) bool
func decisionMessage(bool) *pb.RequirementEnvelope
