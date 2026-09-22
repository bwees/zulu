// Package service holds the business logic. Services use repositories; they do
// not use each other.
package service

import "errors"

var (
	// ErrInvalidInput is a caller mistake: a malformed realm URL, an unknown
	// platform, a missing device token.
	ErrInvalidInput = errors.New("service: invalid input")
	// ErrCredentialsRejected means the Zulip server refused the API key.
	ErrCredentialsRejected = errors.New("service: zulip rejected the credentials")
	// ErrUnauthenticated means the device secret presented is not one we issued.
	ErrUnauthenticated = errors.New("service: unauthenticated")
	// ErrNotFound means the device does not exist, or belongs to someone else.
	ErrNotFound = errors.New("service: not found")
)
