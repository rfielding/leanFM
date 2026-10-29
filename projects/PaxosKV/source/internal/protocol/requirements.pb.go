// Code generated from internal/protocol/requirements.proto. DO NOT EDIT.
// requirement:paxos_kv.visible_behavior -- preserve protobuf bytes on replica links.
package protocol

import (
	"bufio"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
)

type Entry struct{ Key, Value string }

type SlotState struct {
	Slot, PromisedCounter, AcceptedCounter            uint64
	PromisedNode, AcceptedNode, Key, Value, RequestID string
	Committed                                         bool
}

type Envelope struct {
	Type, RequestID, BallotNode, Key, Value, Error, AcceptedBallotNode, Session string
	BallotCounter, Slot, AcceptedBallotCounter                                  uint64
	Success, Committed                                                          bool
	Entries                                                                     []Entry
	Slots                                                                       []SlotState
}

func tag(field int, wire byte) []byte { return putVarint(nil, uint64(field<<3)|uint64(wire)) }
func putVarint(dst []byte, v uint64) []byte {
	for v >= 0x80 {
		dst = append(dst, byte(v)|0x80)
		v >>= 7
	}
	return append(dst, byte(v))
}
func putString(dst []byte, field int, s string) []byte {
	if s == "" {
		return dst
	}
	dst = append(dst, tag(field, 2)...)
	dst = putVarint(dst, uint64(len(s)))
	return append(dst, s...)
}
func putUint(dst []byte, field int, v uint64) []byte {
	if v == 0 {
		return dst
	}
	dst = append(dst, tag(field, 0)...)
	return putVarint(dst, v)
}
func putBool(dst []byte, field int, v bool) []byte {
	if !v {
		return dst
	}
	dst = append(dst, tag(field, 0)...)
	return append(dst, 1)
}
func putMessage(dst []byte, field int, msg []byte) []byte {
	dst = append(dst, tag(field, 2)...)
	dst = putVarint(dst, uint64(len(msg)))
	return append(dst, msg...)
}

func (e Entry) marshal() []byte {
	var b []byte
	b = putString(b, 1, e.Key)
	b = putString(b, 2, e.Value)
	return b
}
func (s SlotState) marshal() []byte {
	var b []byte
	b = putUint(b, 1, s.Slot)
	b = putUint(b, 2, s.PromisedCounter)
	b = putString(b, 3, s.PromisedNode)
	b = putUint(b, 4, s.AcceptedCounter)
	b = putString(b, 5, s.AcceptedNode)
	b = putString(b, 6, s.Key)
	b = putString(b, 7, s.Value)
	b = putBool(b, 8, s.Committed)
	b = putString(b, 9, s.RequestID)
	return b
}
func (e Envelope) Marshal() []byte {
	var b []byte
	b = putString(b, 1, e.Type)
	b = putString(b, 2, e.RequestID)
	b = putUint(b, 3, e.BallotCounter)
	b = putString(b, 4, e.BallotNode)
	b = putUint(b, 5, e.Slot)
	b = putString(b, 6, e.Key)
	b = putString(b, 7, e.Value)
	b = putBool(b, 8, e.Success)
	b = putString(b, 9, e.Error)
	for _, x := range e.Entries {
		b = putMessage(b, 10, x.marshal())
	}
	b = putUint(b, 11, e.AcceptedBallotCounter)
	b = putString(b, 12, e.AcceptedBallotNode)
	b = putBool(b, 13, e.Committed)
	b = putString(b, 14, e.Session)
	for _, s := range e.Slots {
		b = putMessage(b, 15, s.marshal())
	}
	return b
}

type decoder struct {
	b []byte
	i int
}

func (d *decoder) varint() (uint64, error) {
	var v uint64
	for shift := uint(0); shift < 64; shift += 7 {
		if d.i >= len(d.b) {
			return 0, io.ErrUnexpectedEOF
		}
		c := d.b[d.i]
		d.i++
		v |= uint64(c&0x7f) << shift
		if c < 0x80 {
			return v, nil
		}
	}
	return 0, errors.New("protobuf varint overflow")
}
func (d *decoder) bytes() ([]byte, error) {
	n, e := d.varint()
	if e != nil {
		return nil, e
	}
	if n > uint64(len(d.b)-d.i) {
		return nil, io.ErrUnexpectedEOF
	}
	p := d.b[d.i : d.i+int(n)]
	d.i += int(n)
	return p, nil
}
func (d *decoder) skip(w uint64) error {
	switch w {
	case 0:
		_, e := d.varint()
		return e
	case 2:
		_, e := d.bytes()
		return e
	default:
		return fmt.Errorf("unsupported protobuf wire type %d", w)
	}
}
func decodeFields(b []byte, set func(int, uint64, []byte) error) error {
	d := decoder{b: b}
	for d.i < len(b) {
		t, e := d.varint()
		if e != nil {
			return e
		}
		f, w := int(t>>3), t&7
		if f == 0 {
			return errors.New("zero protobuf field")
		}
		if w == 0 {
			v, e := d.varint()
			if e != nil {
				return e
			}
			if e = set(f, v, nil); e != nil {
				return e
			}
		} else if w == 2 {
			p, e := d.bytes()
			if e != nil {
				return e
			}
			if e = set(f, 0, p); e != nil {
				return e
			}
		} else if e = d.skip(w); e != nil {
			return e
		}
	}
	return nil
}
func decodeEntry(b []byte) (x Entry, e error) {
	e = decodeFields(b, func(f int, _ uint64, p []byte) error {
		if f == 1 {
			x.Key = string(p)
		} else if f == 2 {
			x.Value = string(p)
		}
		return nil
	})
	return
}
func decodeSlot(b []byte) (s SlotState, e error) {
	e = decodeFields(b, func(f int, v uint64, p []byte) error {
		switch f {
		case 1:
			s.Slot = v
		case 2:
			s.PromisedCounter = v
		case 3:
			s.PromisedNode = string(p)
		case 4:
			s.AcceptedCounter = v
		case 5:
			s.AcceptedNode = string(p)
		case 6:
			s.Key = string(p)
		case 7:
			s.Value = string(p)
		case 8:
			s.Committed = v != 0
		case 9:
			s.RequestID = string(p)
		}
		return nil
	})
	return
}
func Unmarshal(b []byte) (e Envelope, err error) {
	err = decodeFields(b, func(f int, v uint64, p []byte) error {
		switch f {
		case 1:
			e.Type = string(p)
		case 2:
			e.RequestID = string(p)
		case 3:
			e.BallotCounter = v
		case 4:
			e.BallotNode = string(p)
		case 5:
			e.Slot = v
		case 6:
			e.Key = string(p)
		case 7:
			e.Value = string(p)
		case 8:
			e.Success = v != 0
		case 9:
			e.Error = string(p)
		case 10:
			x, xerr := decodeEntry(p)
			if xerr != nil {
				return xerr
			}
			e.Entries = append(e.Entries, x)
		case 11:
			e.AcceptedBallotCounter = v
		case 12:
			e.AcceptedBallotNode = string(p)
		case 13:
			e.Committed = v != 0
		case 14:
			e.Session = string(p)
		case 15:
			s, serr := decodeSlot(p)
			if serr != nil {
				return serr
			}
			e.Slots = append(e.Slots, s)
		}
		return nil
	})
	return
}

const MaxFrame = 1 << 20

func WriteFrame(w io.Writer, e Envelope) error {
	b := e.Marshal()
	if len(b) > MaxFrame {
		return errors.New("protobuf frame too large")
	}
	var h [4]byte
	binary.BigEndian.PutUint32(h[:], uint32(len(b)))
	if err := writeAll(w, h[:]); err != nil {
		return err
	}
	return writeAll(w, b)
}
func writeAll(w io.Writer, b []byte) error {
	for len(b) > 0 {
		n, e := w.Write(b)
		if e != nil {
			return e
		}
		if n == 0 {
			return io.ErrShortWrite
		}
		b = b[n:]
	}
	return nil
}
func ReadFrame(r io.Reader) (Envelope, error) {
	br, ok := r.(*bufio.Reader)
	if !ok {
		br = bufio.NewReader(r)
	}
	var h [4]byte
	if _, e := io.ReadFull(br, h[:]); e != nil {
		return Envelope{}, e
	}
	n := binary.BigEndian.Uint32(h[:])
	if n > MaxFrame {
		return Envelope{}, errors.New("protobuf frame too large")
	}
	b := make([]byte, n)
	if _, e := io.ReadFull(br, b); e != nil {
		return Envelope{}, e
	}
	return Unmarshal(b)
}
