package core

import (
	"testing"
)

func TestMoveListAddClearSlice(t *testing.T) {
	var list MoveList
	if list.Len() != 0 {
		t.Errorf("expected len 0, got %d", list.Len())
	}
	if len(list.Slice()) != 0 {
		t.Errorf("expected slice len 0, got %d", len(list.Slice()))
	}

	m1 := Move{From: 9, To: 18, Captured: [12]uint8{13}, NumCaptured: 1}
	m2 := Move{From: 9, To: 13, Captured: [12]uint8{}, NumCaptured: 0}

	if !list.Add(m1) {
		t.Error("Add(m1) should succeed")
	}
	if !list.Add(m2) {
		t.Error("Add(m2) should succeed")
	}
	if list.Len() != 2 {
		t.Errorf("expected len 2, got %d", list.Len())
	}
	if len(list.Slice()) != 2 {
		t.Errorf("expected slice len 2, got %d", len(list.Slice()))
	}
	if list.Slice()[0].From != 9 {
		t.Errorf("expected from=9, got %d", list.Slice()[0].From)
	}
	if list.Slice()[1].To != 13 {
		t.Errorf("expected to=13, got %d", list.Slice()[1].To)
	}
	if !IsCapture(list.Slice()[0]) {
		t.Error("m1 should be a capture")
	}
	if IsCapture(list.Slice()[1]) {
		t.Error("m2 should not be a capture")
	}

	list.Clear()
	if list.Len() != 0 {
		t.Errorf("expected len 0 after clear, got %d", list.Len())
	}
	if len(list.Slice()) != 0 {
		t.Errorf("expected slice len 0 after clear, got %d", len(list.Slice()))
	}
}

func TestMoveListCapacity(t *testing.T) {
	var list MoveList
	for i := 0; i < 256; i++ {
		m := Move{From: uint8(i), To: uint8(i + 1)}
		if !list.Add(m) {
			t.Errorf("Add failed at index %d", i)
		}
	}
	// 257th should fail
	m := Move{From: 0, To: 1}
	if list.Add(m) {
		t.Error("Add should fail when at capacity")
	}
}