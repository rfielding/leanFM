package store

import "context"

// Store is a minimal persistence interface.
type Store interface {
	SaveEvent(ctx context.Context, key string, payload []byte) error
	LoadEvents(ctx context.Context, key string) ([][]byte, error)
}

// NewInMemoryStore returns a very small in-memory implementation useful for
// development and tests.
func NewInMemoryStore() Store {
	return &memStore{m: map[string][][]byte{}}
}

type memStore struct{
	m map[string][][]byte
}

func (s *memStore) SaveEvent(ctx context.Context, key string, payload []byte) error {
	s.m[key] = append(s.m[key], append([]byte(nil), payload...))
	return nil
}

func (s *memStore) LoadEvents(ctx context.Context, key string) ([][]byte, error) {
	if v, ok := s.m[key]; ok {
		out := make([][]byte, len(v))
		for i := range v { out[i] = append([]byte(nil), v[i]...) }
		return out, nil
	}
	return nil, nil
}
