// Package controller is the HTTP transport: decoding, status codes, and the
// OpenAPI description. All decisions live in the services it calls.
package controller

import "time"

// RegisterDeviceRequest is what the app posts once per launch.
//
// It carries the account's Zulip API key because Zulip has no second credential
// to give: one account, one key, shared by the app and this service. See
// SECURITY.md.
type RegisterDeviceRequest struct {
	RealmURL    string `json:"realmUrl" validate:"required" description:"Base URL of the Zulip organization, e.g. https://chat.example.com"`
	Email       string `json:"email" validate:"required" description:"The account's Zulip delivery email"`
	APIKey      string `json:"apiKey" validate:"required" description:"The account's Zulip API key"`
	DeviceToken string `json:"deviceToken" validate:"required" description:"APNs device token, hex encoded"`
	Platform    string `json:"platform" validate:"required,oneof=ios macos" description:"ios or macos"`
	Environment string `json:"environment" validate:"required,oneof=production sandbox" description:"APNs environment the token belongs to"`
	AppVersion  string `json:"appVersion" description:"Client version, for support"`
}

type RegisterDeviceResponse struct {
	DeviceID string `json:"deviceId"`
	// DeviceSecret authenticates every later call. It is shown once; a device
	// that loses it registers again.
	DeviceSecret string `json:"deviceSecret"`
	ZulipUserID  int64  `json:"zulipUserId"`
	RealmURL     string `json:"realmUrl"`
}

type DeviceResponse struct {
	DeviceID     string    `json:"deviceId"`
	Platform     string    `json:"platform"`
	Environment  string    `json:"environment"`
	AppVersion   string    `json:"appVersion"`
	RegisteredAt time.Time `json:"registeredAt"`
	LastSeenAt   time.Time `json:"lastSeenAt"`
	// Current marks the device making the request.
	Current bool `json:"current"`
}

type DeviceListResponse struct {
	Devices []DeviceResponse `json:"devices"`
}

type DeregisterResponse struct {
	Deregistered bool `json:"deregistered"`
}

// StatusResponse is how the app finds out that notifications are degraded.
type StatusResponse struct {
	RealmURL    string `json:"realmUrl"`
	ZulipUserID int64  `json:"zulipUserId"`
	// AccountStatus is "active" or "auth_failed". The latter means Zulip rejected
	// the stored API key and the user must sign in again.
	AccountStatus string `json:"accountStatus"`
	StatusDetail  string `json:"statusDetail,omitempty"`
	Devices       int    `json:"devices"`
	// QueueConnected is true while this service is watching the account's Zulip
	// events. While it is false, Zulip's own notifications take over again.
	QueueConnected bool `json:"queueConnected"`
	Parked         bool `json:"parked"`
	// ParkedUntil is when a parked worker will try again. Until then Zulip's own
	// notifications are back in charge.
	ParkedUntil time.Time `json:"parkedUntil,omitempty"`
	LastEventAt time.Time `json:"lastEventAt,omitempty"`
	LastError   string    `json:"lastError,omitempty"`
}

// TestNotificationResponse is what APNs answered for the test push.
type TestNotificationResponse struct {
	Sent       bool   `json:"sent"`
	StatusCode int    `json:"statusCode"`
	Reason     string `json:"reason,omitempty"`
}

type HealthResponse struct {
	Status string `json:"status"`
}
