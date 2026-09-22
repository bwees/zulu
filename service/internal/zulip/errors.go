package zulip

import (
	"errors"
	"fmt"
	"time"
)

// Zulip error codes this service branches on.
const (
	CodeBadEventQueueID = "BAD_EVENT_QUEUE_ID"
	CodeRateLimitHit    = "RATE_LIMIT_HIT"
	CodeUnauthorized    = "UNAUTHORIZED"
	CodeAuthFailed      = "AUTHENTICATION_FAILED"
)

// APIError is a structured error response from a Zulip server.
type APIError struct {
	StatusCode int
	Code       string
	Msg        string
	// RetryAfter carries the header of the same name, which Zulip sends on rate
	// limits and which the official clients ignore.
	RetryAfter time.Duration
}

func (e *APIError) Error() string {
	if e.Code != "" {
		return fmt.Sprintf("zulip: %d %s: %s", e.StatusCode, e.Code, e.Msg)
	}
	return fmt.Sprintf("zulip: %d: %s", e.StatusCode, e.Msg)
}

func apiError(err error) *APIError {
	var apiErr *APIError
	if errors.As(err, &apiErr) {
		return apiErr
	}
	return nil
}

// IsBadEventQueueID reports whether the queue is gone. Recovery is a full
// re-register; the server treats it as normal, not as a fault.
func IsBadEventQueueID(err error) bool {
	apiErr := apiError(err)
	return apiErr != nil && apiErr.Code == CodeBadEventQueueID
}

// IsUnauthorized reports whether the stored API key no longer works. An account
// has one key, so this means the user regenerated it somewhere and every copy
// died at once.
func IsUnauthorized(err error) bool {
	apiErr := apiError(err)
	if apiErr == nil {
		return false
	}
	return apiErr.StatusCode == 401 || apiErr.Code == CodeUnauthorized || apiErr.Code == CodeAuthFailed
}

func IsRateLimited(err error) bool {
	apiErr := apiError(err)
	if apiErr == nil {
		return false
	}
	return apiErr.StatusCode == 429 || apiErr.Code == CodeRateLimitHit
}

// RetryAfter returns the server's requested delay, if it sent one.
func RetryAfter(err error) (time.Duration, bool) {
	apiErr := apiError(err)
	if apiErr == nil || apiErr.RetryAfter <= 0 {
		return 0, false
	}
	return apiErr.RetryAfter, true
}
