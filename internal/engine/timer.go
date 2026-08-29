package engine

import (
	"time"
)

// Timer implements a time limit for search.
// timeLimitMs == 0 means no limit.
type Timer struct {
	deadlineMs int64
}

// NewTimer creates a new timer.
// timeLimitMs == 0 means no limit (infinite deadline).
func NewTimer(timeLimitMs uint32) Timer {
	if timeLimitMs == 0 {
		return Timer{deadlineMs: int64(^uint64(0) >> 1)} // max int64
	}
	return Timer{deadlineMs: time.Now().UnixMilli() + int64(timeLimitMs)}
}

// Expired returns true if the timer has expired.
func (t Timer) Expired() bool {
	return time.Now().UnixMilli() >= t.deadlineMs
}