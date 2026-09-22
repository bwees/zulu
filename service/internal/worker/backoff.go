package worker

import (
	"context"
	"math/rand/v2"
	"time"
)

// Backoff is the retry schedule the official clients use: an exponentially
// growing bound with full jitter, so a server coming back up does not get every
// worker at once.
type Backoff struct {
	first   time.Duration
	max     time.Duration
	current time.Duration
}

func NewBackoff(first, max time.Duration) *Backoff {
	return &Backoff{first: first, max: max}
}

func (b *Backoff) Reset() { b.current = 0 }

// Next returns a wait uniformly distributed over [0, bound].
func (b *Backoff) Next() time.Duration {
	if b.current == 0 {
		b.current = b.first
	} else {
		b.current = min(b.current*2, b.max)
	}
	return time.Duration(rand.Int64N(int64(b.current) + 1))
}

// sleep waits, unless the context ends first.
func sleep(ctx context.Context, duration time.Duration) error {
	if duration <= 0 {
		return ctx.Err()
	}
	timer := time.NewTimer(duration)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}
