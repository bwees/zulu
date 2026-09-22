package zulip

import (
	"encoding/json"
	"fmt"
	"sort"
)

// Event types this service handles.
const (
	EventMessage            = "message"
	EventUpdateMessageFlags = "update_message_flags"
	EventUserSettings       = "user_settings"
	EventSubscription       = "subscription"
	EventUserTopic          = "user_topic"
	EventMutedUsers         = "muted_users"
	EventHeartbeat          = "heartbeat"
)

// Event is one entry of a GET /events response. The raw body is kept because
// each type has its own shape and most types are of no interest here.
type Event struct {
	ID   int64
	Type string
	Raw  json.RawMessage
}

func (e *Event) UnmarshalJSON(data []byte) error {
	var header struct {
		ID   int64  `json:"id"`
		Type string `json:"type"`
	}
	if err := json.Unmarshal(data, &header); err != nil {
		return fmt.Errorf("zulip: decode event header: %w", err)
	}
	e.ID = header.ID
	e.Type = header.Type
	e.Raw = append(json.RawMessage(nil), data...)
	return nil
}

// Message is the restricted message object that rides on a message event.
type Message struct {
	ID             int64  `json:"id"`
	Type           string `json:"type"`
	SenderID       int64  `json:"sender_id"`
	SenderFullName string `json:"sender_full_name"`
	StreamID       int64  `json:"stream_id"`
	// Subject is the topic. Zulip never renamed the field on the wire.
	Subject          string          `json:"subject"`
	Content          string          `json:"content"`
	Timestamp        int64           `json:"timestamp"`
	DisplayRecipient json.RawMessage `json:"display_recipient"`
}

// ChannelName returns the channel name for a channel message. On a DM the
// display_recipient field holds an array of users instead, and this is empty.
func (m Message) ChannelName() string {
	var name string
	if err := json.Unmarshal(m.DisplayRecipient, &name); err != nil {
		return ""
	}
	return name
}

// RecipientIDs returns the user ids of a direct message's participants, sorted,
// so a conversation has one stable identity however the array is ordered.
func (m Message) RecipientIDs() []int64 {
	var recipients []struct {
		ID int64 `json:"id"`
	}
	if err := json.Unmarshal(m.DisplayRecipient, &recipients); err != nil {
		return nil
	}
	ids := make([]int64, 0, len(recipients))
	for _, recipient := range recipients {
		ids = append(ids, recipient.ID)
	}
	sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
	return ids
}

type MessageEvent struct {
	Message Message  `json:"message"`
	Flags   []string `json:"flags"`
}

func DecodeMessageEvent(event Event) (MessageEvent, error) {
	var decoded MessageEvent
	if err := json.Unmarshal(event.Raw, &decoded); err != nil {
		return MessageEvent{}, fmt.Errorf("zulip: decode message event: %w", err)
	}
	return decoded, nil
}

// UserSettings is the notification slice of the register snapshot. Every field is
// a pointer so a server that does not send one keeps Zulip's documented default
// rather than silently reading as false.
type UserSettings struct {
	EnableStreamPushNotifications             *bool `json:"enable_stream_push_notifications"`
	EnableOfflinePushNotifications            *bool `json:"enable_offline_push_notifications"`
	EnableOnlinePushNotifications             *bool `json:"enable_online_push_notifications"`
	WildcardMentionsNotify                    *bool `json:"wildcard_mentions_notify"`
	EnableFollowedTopicPushNotifications      *bool `json:"enable_followed_topic_push_notifications"`
	EnableFollowedTopicWildcardMentionsNotify *bool `json:"enable_followed_topic_wildcard_mentions_notify"`
}

// Subscription is one entry of the register snapshot's subscriptions array.
type Subscription struct {
	StreamID int64 `json:"stream_id"`
	IsMuted  *bool `json:"is_muted"`
	// InHomeView is is_muted's deprecated inverse, still sent by older servers.
	InHomeView             *bool `json:"in_home_view"`
	PushNotifications      *bool `json:"push_notifications"`
	WildcardMentionsNotify *bool `json:"wildcard_mentions_notify"`
}

func (s Subscription) Muted() bool {
	if s.IsMuted != nil {
		return *s.IsMuted
	}
	if s.InHomeView != nil {
		return !*s.InHomeView
	}
	return false
}

type UserTopic struct {
	StreamID         int64  `json:"stream_id"`
	TopicName        string `json:"topic_name"`
	VisibilityPolicy int    `json:"visibility_policy"`
}

type MutedUser struct {
	ID int64 `json:"id"`
}

type userSettingsEvent struct {
	Op       string          `json:"op"`
	Property string          `json:"property"`
	Value    json.RawMessage `json:"value"`
}

type subscriptionEvent struct {
	Op            string          `json:"op"`
	Property      string          `json:"property"`
	StreamID      int64           `json:"stream_id"`
	Value         json.RawMessage `json:"value"`
	Subscriptions []Subscription  `json:"subscriptions"`
	StreamIDs     []int64         `json:"stream_ids"`
}

type mutedUsersEvent struct {
	MutedUsers []MutedUser `json:"muted_users"`
}
