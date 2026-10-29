package trace

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestPriorIDsAreOptionalAndPlural(t *testing.T) {
	first, err := json.Marshal(Event{ID: "e0", Message: "PutRequest"})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(first), "priorIds") {
		t.Fatalf("minimal event unexpectedly has a predecessor: %s", first)
	}

	join, err := json.Marshal(Event{ID: "e3", PriorIDs: []string{"e1", "e2"}, Message: "Accept"})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(join), `"priorIds":["e1","e2"]`) {
		t.Fatalf("join did not preserve all immediate predecessors: %s", join)
	}
}
