// Package domain holds the entities the whole service agrees on.
package domain

import (
	"time"

	"github.com/bwees/zulu/service/internal/notify"
)

// UserStatus is the service's own view of a registered account, not Zulip's.
type UserStatus string

const (
	// UserActive means the service holds a usable API key for this account.
	UserActive UserStatus = "active"
	// UserAuthFailed means Zulip rejected the stored key. Only the user can fix
	// it, by signing in again in the app: an account has exactly one API key and
	// regenerating it anywhere invalidates the copy held here.
	UserAuthFailed UserStatus = "auth_failed"
)

type User struct {
	ID           int64
	RealmURL     string
	ZulipUserID  int64
	Email        string
	Status       UserStatus
	StatusDetail string
	CreatedAt    time.Time
	UpdatedAt    time.Time
}

// Credentials are what Zulip's REST API wants: HTTP basic auth of email against
// the account's single API key.
type Credentials struct {
	RealmURL string
	Email    string
	APIKey   string
}

// APNs environments. A token is minted for exactly one of them, decided by the
// app's entitlement at signing time, and the same token sent to the wrong host
// comes back as BadDeviceToken — indistinguishable from a dead token.
const (
	EnvironmentProduction = "production"
	EnvironmentSandbox    = "sandbox"
)

const (
	PlatformIOS   = "ios"
	PlatformMacOS = "macos"
)

type Device struct {
	ID           string
	UserID       int64
	Token        string
	Environment  string
	Platform     string
	AppVersion   string
	RegisteredAt time.Time
	LastSeenAt   time.Time
}

func ValidEnvironment(environment string) bool {
	return environment == EnvironmentProduction || environment == EnvironmentSandbox
}

func ValidPlatform(platform string) bool {
	return platform == PlatformIOS || platform == PlatformMacOS
}

// QueueState is the durable half of an event queue worker: the Zulip queue it is
// polling, how far it has acknowledged, and the settings mirror built from that
// queue's register snapshot. Restarting the service resumes from this rather
// than registering a new queue.
type QueueState struct {
	QueueID     string
	LastEventID int64
	State       *notify.State
	UpdatedAt   time.Time
}

// WorkerHealth is what the app is shown when it asks whether notifications are
// actually working.
type WorkerHealth struct {
	// Running means an event queue worker exists for this user.
	Running bool
	// Connected means the worker currently holds a Zulip event queue.
	Connected bool
	// Parked means the worker deliberately gave its queue back, which hands
	// notification duty to Zulip's own push and email.
	Parked      bool
	ParkedUntil time.Time
	LastEventAt time.Time
	LastError   string
}
