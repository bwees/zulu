package zulip

import (
	"encoding/json"
	"fmt"

	"github.com/bwees/zulu/service/internal/notify"
)

// BuildState turns a register snapshot into the settings mirror the notification
// decision reads.
func BuildState(response RegisterResponse) *notify.State {
	state := notify.NewState()

	global := notify.DefaultGlobalSettings()
	settings := response.UserSettings
	assignBool(&global.EnableStreamPushNotifications, settings.EnableStreamPushNotifications)
	assignBool(&global.EnableOfflinePushNotifications, settings.EnableOfflinePushNotifications)
	assignBool(&global.EnableOnlinePushNotifications, settings.EnableOnlinePushNotifications)
	assignBool(&global.WildcardMentionsNotify, settings.WildcardMentionsNotify)
	assignBool(&global.EnableFollowedTopicPushNotifications, settings.EnableFollowedTopicPushNotifications)
	assignBool(&global.EnableFollowedTopicWildcardMentionsNotify, settings.EnableFollowedTopicWildcardMentionsNotify)
	state.Global = global

	for _, subscription := range response.Subscriptions {
		state.SetSubscription(subscription.StreamID, notify.Subscription{
			IsMuted:                subscription.Muted(),
			PushNotifications:      subscription.PushNotifications,
			WildcardMentionsNotify: subscription.WildcardMentionsNotify,
		})
	}
	for _, topic := range response.UserTopics {
		state.SetTopicPolicy(topic.StreamID, topic.TopicName, notify.VisibilityPolicy(topic.VisibilityPolicy))
	}

	muted := make([]int64, 0, len(response.MutedUsers))
	for _, user := range response.MutedUsers {
		muted = append(muted, user.ID)
	}
	state.SetMutedUsers(muted)

	return state
}

// ApplyEvent folds a settings event into the mirror and reports whether anything
// changed, so a caller can persist only when it must.
//
// Unknown properties are ignored rather than treated as errors: the API docs
// require clients to tolerate property names they have never heard of.
func ApplyEvent(state *notify.State, event Event) (bool, error) {
	switch event.Type {
	case EventUserSettings:
		return applyUserSettings(state, event)
	case EventSubscription:
		return applySubscription(state, event)
	case EventUserTopic:
		return applyUserTopic(state, event)
	case EventMutedUsers:
		return applyMutedUsers(state, event)
	default:
		return false, nil
	}
}

func applyUserSettings(state *notify.State, event Event) (bool, error) {
	var decoded userSettingsEvent
	if err := json.Unmarshal(event.Raw, &decoded); err != nil {
		return false, fmt.Errorf("zulip: decode user_settings event: %w", err)
	}

	targets := map[string]*bool{
		"enable_stream_push_notifications":               &state.Global.EnableStreamPushNotifications,
		"enable_offline_push_notifications":              &state.Global.EnableOfflinePushNotifications,
		"enable_online_push_notifications":               &state.Global.EnableOnlinePushNotifications,
		"wildcard_mentions_notify":                       &state.Global.WildcardMentionsNotify,
		"enable_followed_topic_push_notifications":       &state.Global.EnableFollowedTopicPushNotifications,
		"enable_followed_topic_wildcard_mentions_notify": &state.Global.EnableFollowedTopicWildcardMentionsNotify,
	}
	target, known := targets[decoded.Property]
	if !known {
		return false, nil
	}

	var value bool
	if err := json.Unmarshal(decoded.Value, &value); err != nil {
		return false, fmt.Errorf("zulip: decode user_settings %s: %w", decoded.Property, err)
	}
	if *target == value {
		return false, nil
	}
	*target = value
	return true, nil
}

func applySubscription(state *notify.State, event Event) (bool, error) {
	var decoded subscriptionEvent
	if err := json.Unmarshal(event.Raw, &decoded); err != nil {
		return false, fmt.Errorf("zulip: decode subscription event: %w", err)
	}

	switch decoded.Op {
	case "add":
		for _, subscription := range decoded.Subscriptions {
			state.SetSubscription(subscription.StreamID, notify.Subscription{
				IsMuted:                subscription.Muted(),
				PushNotifications:      subscription.PushNotifications,
				WildcardMentionsNotify: subscription.WildcardMentionsNotify,
			})
		}
		return len(decoded.Subscriptions) > 0, nil

	case "remove":
		for _, subscription := range decoded.Subscriptions {
			state.RemoveSubscription(subscription.StreamID)
		}
		for _, streamID := range decoded.StreamIDs {
			state.RemoveSubscription(streamID)
		}
		return len(decoded.Subscriptions)+len(decoded.StreamIDs) > 0, nil

	case "update":
		return applySubscriptionProperty(state, decoded)

	default:
		return false, nil
	}
}

func applySubscriptionProperty(state *notify.State, event subscriptionEvent) (bool, error) {
	subscription := state.Subscription(event.StreamID)

	switch event.Property {
	case "is_muted", "in_home_view":
		var value bool
		if err := json.Unmarshal(event.Value, &value); err != nil {
			return false, fmt.Errorf("zulip: decode subscription %s: %w", event.Property, err)
		}
		// in_home_view is is_muted inverted; servers emit both on a change.
		subscription.IsMuted = value != (event.Property == "in_home_view")

	case "push_notifications":
		value, err := decodeNullableBool(event.Value)
		if err != nil {
			return false, fmt.Errorf("zulip: decode subscription push_notifications: %w", err)
		}
		subscription.PushNotifications = value

	case "wildcard_mentions_notify":
		value, err := decodeNullableBool(event.Value)
		if err != nil {
			return false, fmt.Errorf("zulip: decode subscription wildcard_mentions_notify: %w", err)
		}
		subscription.WildcardMentionsNotify = value

	default:
		return false, nil
	}

	state.SetSubscription(event.StreamID, subscription)
	return true, nil
}

func applyUserTopic(state *notify.State, event Event) (bool, error) {
	var decoded UserTopic
	if err := json.Unmarshal(event.Raw, &decoded); err != nil {
		return false, fmt.Errorf("zulip: decode user_topic event: %w", err)
	}
	policy := notify.VisibilityPolicy(decoded.VisibilityPolicy)
	if !policy.Valid() {
		// A newer server can send a policy this build does not know. Treating it
		// as "inherit" is the safe reading: it can only produce more
		// notifications, never fewer than the user asked for.
		policy = notify.PolicyInherit
	}
	state.SetTopicPolicy(decoded.StreamID, decoded.TopicName, policy)
	return true, nil
}

func applyMutedUsers(state *notify.State, event Event) (bool, error) {
	var decoded mutedUsersEvent
	if err := json.Unmarshal(event.Raw, &decoded); err != nil {
		return false, fmt.Errorf("zulip: decode muted_users event: %w", err)
	}
	ids := make([]int64, 0, len(decoded.MutedUsers))
	for _, user := range decoded.MutedUsers {
		ids = append(ids, user.ID)
	}
	state.SetMutedUsers(ids)
	return true, nil
}

// decodeNullableBool keeps Zulip's tri-state intact: JSON null means "inherit the
// global setting" and must not collapse to false.
func decodeNullableBool(raw json.RawMessage) (*bool, error) {
	if len(raw) == 0 || string(raw) == "null" {
		return nil, nil
	}
	var value bool
	if err := json.Unmarshal(raw, &value); err != nil {
		return nil, err
	}
	return &value, nil
}

func assignBool(target *bool, value *bool) {
	if value != nil {
		*target = *value
	}
}
