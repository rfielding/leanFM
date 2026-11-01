package goserver

import (
    "testing"
    "time"
)

// Requirement: goserver actorResources; accepted ImplementationSpec.channels.sendFull.
// Independent expectation: sending into a full open queue waits without mutation.
func TestAcceptedFullSendWaitsForSpace(t *testing.T) {
    channel := NewInprocessChannel(1)
    if err := channel.Send("first"); err != nil { t.Fatal(err) }
    finished := make(chan error, 1)
    go func() { finished <- channel.Send("second") }()
    select {
    case err := <-finished:
        t.Fatalf("accepted contract requires the second Send to wait for space; returned immediately: %v", err)
    case <-time.After(30 * time.Millisecond):
    }
    value, err := channel.Receive()
    if err != nil || value != "first" { t.Fatalf("first item changed: %v %v", value, err) }
    select {
    case err := <-finished:
        if err != nil { t.Fatalf("send did not complete after space became available: %v", err) }
    case <-time.After(time.Second):
        t.Fatal("send did not wake after receive")
    }
    value, err = channel.Receive()
    if err != nil || value != "second" { t.Fatalf("second item missing: %v %v", value, err) }
    channel.Close()
}
