// Package zulip is the client for a Zulip server's public REST and events API.
// It assumes no server cooperation beyond a normal user's API key.
package zulip

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/bwees/zulu/service/internal/domain"
)

const (
	// DefaultLongpollTimeout is what to use when the server is too old to send
	// event_queue_longpoll_timeout_seconds. Heartbeats arrive every 45-55s, so a
	// poll that returns nothing at all by then has a dead connection.
	DefaultLongpollTimeout = 90 * time.Second

	// MaxResponseBytes caps a response body. A register snapshot on a large realm
	// can be megabytes; this service asks for four settings keys, so anything
	// approaching this cap means something is wrong.
	MaxResponseBytes = 32 << 20

	userAgent = "ZuluNotificationService/1.0"
)

type Client struct {
	http *http.Client
}

func NewClient() *Client {
	return &Client{
		http: &http.Client{
			// No client-level timeout: the long poll is bounded by its context,
			// and every other call sets its own.
			Transport: &http.Transport{
				MaxIdleConnsPerHost: 4,
				IdleConnTimeout:     90 * time.Second,
				ForceAttemptHTTP2:   true,
			},
		},
	}
}

// OwnUser is the subset of GET /users/me that registration needs. It doubles as
// the credential check: if this succeeds, the key works.
type OwnUser struct {
	UserID   int64  `json:"user_id"`
	Email    string `json:"email"`
	FullName string `json:"full_name"`
	IsBot    bool   `json:"is_bot"`
}

func (c *Client) OwnUser(ctx context.Context, creds domain.Credentials) (OwnUser, error) {
	var user OwnUser
	if err := c.do(ctx, creds, http.MethodGet, "/api/v1/users/me", nil, &user); err != nil {
		return OwnUser{}, err
	}
	return user, nil
}

// RegisterResponse is the part of POST /register this service reads.
type RegisterResponse struct {
	QueueID     string `json:"queue_id"`
	LastEventID int64  `json:"last_event_id"`

	ZulipFeatureLevel                int `json:"zulip_feature_level"`
	EventQueueLongpollTimeoutSeconds int `json:"event_queue_longpoll_timeout_seconds"`

	UserSettings  UserSettings   `json:"user_settings"`
	Subscriptions []Subscription `json:"subscriptions"`
	UserTopics    []UserTopic    `json:"user_topics"`
	MutedUsers    []MutedUser    `json:"muted_users"`
}

func (r RegisterResponse) LongpollTimeout() time.Duration {
	if r.EventQueueLongpollTimeoutSeconds <= 0 {
		return DefaultLongpollTimeout
	}
	return time.Duration(r.EventQueueLongpollTimeoutSeconds) * time.Second
}

// Register allocates an event queue and returns the settings snapshot with it.
//
// The queue asks for `message` events, which is what makes Zulip treat the user
// as present and stop sending its own push and email notifications — see
// README.md, "Open decisions". Requesting anything less defeats the purpose of
// the service.
func (c *Client) Register(ctx context.Context, creds domain.Credentials) (RegisterResponse, error) {
	eventTypes, err := json.Marshal([]string{
		"message",
		"update_message_flags",
		"user_settings",
		"subscription",
		"user_topic",
		"muted_users",
	})
	if err != nil {
		return RegisterResponse{}, fmt.Errorf("zulip: encode event types: %w", err)
	}
	fetchEventTypes, err := json.Marshal([]string{
		"user_settings",
		"subscription",
		"user_topic",
		"muted_users",
		"realm",
	})
	if err != nil {
		return RegisterResponse{}, fmt.Errorf("zulip: encode fetch event types: %w", err)
	}
	// notification_settings_null is what keeps the per-channel tri-state intact:
	// without it the server flattens "inherit the global setting" to false.
	capabilities, err := json.Marshal(map[string]bool{
		"notification_settings_null": true,
		"bulk_message_deletion":      true,
		"user_settings_object":       true,
		"empty_topic_name":           true,
	})
	if err != nil {
		return RegisterResponse{}, fmt.Errorf("zulip: encode client capabilities: %w", err)
	}

	form := url.Values{}
	form.Set("event_types", string(eventTypes))
	form.Set("fetch_event_types", string(fetchEventTypes))
	form.Set("client_capabilities", string(capabilities))
	// Notification bodies want the text the user typed, not rendered HTML.
	form.Set("apply_markdown", "false")
	form.Set("slim_presence", "true")
	form.Set("include_subscribers", "false")

	ctx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()

	var response RegisterResponse
	if err := c.do(ctx, creds, http.MethodPost, "/api/v1/register", form, &response); err != nil {
		return RegisterResponse{}, err
	}
	return response, nil
}

type eventsResponse struct {
	Events []Event `json:"events"`
}

// Events long-polls the queue. The caller's context must carry the poll timeout.
func (c *Client) Events(ctx context.Context, creds domain.Credentials, queueID string, lastEventID int64) ([]Event, error) {
	query := url.Values{}
	query.Set("queue_id", queueID)
	query.Set("last_event_id", strconv.FormatInt(lastEventID, 10))

	var response eventsResponse
	path := "/api/v1/events?" + query.Encode()
	if err := c.do(ctx, creds, http.MethodGet, path, nil, &response); err != nil {
		return nil, err
	}
	return response.Events, nil
}

// DeleteQueue hands the queue back. Doing this on shutdown matters twice over:
// abandoned queues accumulate message data in the server's memory, and while one
// is open Zulip suppresses its own notifications for the user.
func (c *Client) DeleteQueue(ctx context.Context, creds domain.Credentials, queueID string) error {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	form := url.Values{}
	form.Set("queue_id", queueID)
	return c.do(ctx, creds, http.MethodDelete, "/api/v1/events", form, nil)
}

func (c *Client) do(ctx context.Context, creds domain.Credentials, method, path string, form url.Values, out any) error {
	endpoint := strings.TrimSuffix(creds.RealmURL, "/") + path

	var body io.Reader
	if form != nil {
		body = strings.NewReader(form.Encode())
	}
	request, err := http.NewRequestWithContext(ctx, method, endpoint, body)
	if err != nil {
		return fmt.Errorf("zulip: build request: %w", err)
	}
	if form != nil {
		request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	request.Header.Set("Accept", "application/json")
	request.Header.Set("User-Agent", userAgent)
	request.Header.Set("Authorization", basicAuth(creds))

	response, err := c.http.Do(request)
	if err != nil {
		return fmt.Errorf("zulip: %s %s: %w", method, path, err)
	}
	defer response.Body.Close()

	payload, err := io.ReadAll(io.LimitReader(response.Body, MaxResponseBytes))
	if err != nil {
		return fmt.Errorf("zulip: read %s %s: %w", method, path, err)
	}

	if response.StatusCode != http.StatusOK {
		return newAPIError(response, payload)
	}
	if out == nil {
		return nil
	}
	if err := json.Unmarshal(payload, out); err != nil {
		return fmt.Errorf("zulip: decode %s %s: %w", method, path, err)
	}
	return nil
}

func newAPIError(response *http.Response, payload []byte) error {
	apiErr := &APIError{StatusCode: response.StatusCode}

	var decoded struct {
		Code string `json:"code"`
		Msg  string `json:"msg"`
	}
	if err := json.Unmarshal(payload, &decoded); err == nil {
		apiErr.Code = decoded.Code
		apiErr.Msg = decoded.Msg
	}
	if apiErr.Msg == "" {
		apiErr.Msg = strings.TrimSpace(string(payload))
	}
	if seconds, err := strconv.ParseFloat(response.Header.Get("Retry-After"), 64); err == nil && seconds > 0 {
		apiErr.RetryAfter = time.Duration(seconds * float64(time.Second))
	}
	return apiErr
}

// basicAuth is Zulip's scheme: the account's delivery email as the username and
// the API key as the password.
func basicAuth(creds domain.Credentials) string {
	raw := creds.Email + ":" + creds.APIKey
	return "Basic " + base64.StdEncoding.EncodeToString([]byte(raw))
}
