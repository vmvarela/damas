package engine

import (
	"testing"
	"time"
)

func TestTimerNoExpireWithLargeLimit(t *testing.T) {
	timer := NewTimer(1000)
	if timer.Expired() {
		t.Error("timer should not expire with large limit")
	}
}

func TestTimerExpiresAfter1ms(t *testing.T) {
	timer := NewTimer(1)
	time.Sleep(2 * time.Millisecond)
	if !timer.Expired() {
		t.Error("timer should expire after 1ms")
	}
}

func TestTimerZeroLimitNeverExpires(t *testing.T) {
	timer := NewTimer(0)
	time.Sleep(2 * time.Millisecond)
	if timer.Expired() {
		t.Error("timer with zero limit should never expire")
	}
}