package notify_test

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/bwees/zulu/service/internal/notify"
)

const (
	recipientID = int64(7)
	senderID    = int64(42)
	channelID   = int64(100)
	topic       = "deploys"
)

func boolPtr(value bool) *bool { return &value }

// stateBuilder keeps each case in the table down to the settings it is actually
// about.
type stateBuilder struct {
	global       notify.GlobalSettings
	subscription notify.Subscription
	policy       notify.VisibilityPolicy
	policyTopic  string
	mutedUsers   []int64
}

func (b stateBuilder) build() *notify.State {
	state := notify.NewState()
	state.Global = b.global
	state.SetSubscription(channelID, b.subscription)
	if b.policy != notify.PolicyInherit {
		name := b.policyTopic
		if name == "" {
			name = topic
		}
		state.SetTopicPolicy(channelID, name, b.policy)
	}
	state.SetMutedUsers(b.mutedUsers)
	return state
}

func channelMessage() notify.Message {
	return notify.Message{
		ID:       1,
		Type:     notify.MessageTypeStream,
		SenderID: senderID,
		StreamID: channelID,
		Topic:    topic,
	}
}

func directMessage() notify.Message {
	return notify.Message{ID: 2, Type: notify.MessageTypePrivate, SenderID: senderID}
}

func TestDecide(t *testing.T) {
	defaults := notify.DefaultGlobalSettings()

	streamPushOn := defaults
	streamPushOn.EnableStreamPushNotifications = true

	tests := []struct {
		name    string
		message notify.Message
		flags   []string
		idle    bool
		state   stateBuilder
		want    notify.Trigger
	}{
		{
			name:    "own message never notifies",
			message: notify.Message{ID: 1, Type: notify.MessageTypeStream, SenderID: recipientID, StreamID: channelID, Topic: topic},
			idle:    true,
			state:   stateBuilder{global: streamPushOn},
			want:    notify.TriggerNone,
		},
		{
			name:    "muted sender beats a personal mention",
			message: channelMessage(),
			flags:   []string{notify.FlagMentioned},
			idle:    true,
			state:   stateBuilder{global: defaults, mutedUsers: []int64{senderID}},
			want:    notify.TriggerNone,
		},
		{
			name:    "a message that arrives already read is dropped",
			message: channelMessage(),
			flags:   []string{notify.FlagMentioned, notify.FlagRead},
			idle:    true,
			state:   stateBuilder{global: defaults},
			want:    notify.TriggerNone,
		},

		{
			name:    "direct message notifies",
			message: directMessage(),
			idle:    true,
			state:   stateBuilder{global: defaults},
			want:    notify.TriggerDirectMessage,
		},
		{
			name:    "direct message obeys the offline toggle",
			message: directMessage(),
			idle:    true,
			state: stateBuilder{global: func() notify.GlobalSettings {
				global := defaults
				global.EnableOfflinePushNotifications = false
				return global
			}()},
			want: notify.TriggerNone,
		},
		{
			name:    "direct message beats a mention flag",
			message: directMessage(),
			flags:   []string{notify.FlagMentioned},
			idle:    true,
			state:   stateBuilder{global: defaults},
			want:    notify.TriggerDirectMessage,
		},
		{
			name:    "a present user with online push off gets nothing",
			message: directMessage(),
			idle:    false,
			state: stateBuilder{global: func() notify.GlobalSettings {
				global := defaults
				global.EnableOnlinePushNotifications = false
				return global
			}()},
			want: notify.TriggerNone,
		},
		{
			name:    "a present user with online push on still gets the push",
			message: directMessage(),
			idle:    false,
			state:   stateBuilder{global: defaults},
			want:    notify.TriggerDirectMessage,
		},

		{
			name:    "a personal mention ignores a muted topic",
			message: channelMessage(),
			flags:   []string{notify.FlagMentioned},
			idle:    true,
			state:   stateBuilder{global: defaults, policy: notify.PolicyMuted},
			want:    notify.TriggerMention,
		},
		{
			name:    "a personal mention ignores a muted channel",
			message: channelMessage(),
			flags:   []string{notify.FlagMentioned},
			idle:    true,
			state:   stateBuilder{global: defaults, subscription: notify.Subscription{IsMuted: true}},
			want:    notify.TriggerMention,
		},
		{
			name:    "a personal mention ignores push_notifications: false on the channel",
			message: channelMessage(),
			flags:   []string{notify.FlagMentioned},
			idle:    true,
			state:   stateBuilder{global: defaults, subscription: notify.Subscription{PushNotifications: boolPtr(false)}},
			want:    notify.TriggerMention,
		},
		{
			name:    "a mention still needs the offline toggle",
			message: channelMessage(),
			flags:   []string{notify.FlagMentioned},
			idle:    true,
			state: stateBuilder{global: func() notify.GlobalSettings {
				global := defaults
				global.EnableOfflinePushNotifications = false
				return global
			}()},
			want: notify.TriggerNone,
		},
		{
			name:    "a mention outranks the channel push setting",
			message: channelMessage(),
			flags:   []string{notify.FlagMentioned},
			idle:    true,
			state:   stateBuilder{global: streamPushOn},
			want:    notify.TriggerMention,
		},

		{
			name:    "a topic wildcard in a followed topic gets the followed trigger",
			message: channelMessage(),
			flags:   []string{notify.FlagTopicWildcardMentioned},
			idle:    true,
			state:   stateBuilder{global: defaults, policy: notify.PolicyFollowed},
			want:    notify.TriggerTopicWildcardMentionInFollowedTopic,
		},
		{
			name:    "a channel wildcard in a followed topic gets the followed trigger",
			message: channelMessage(),
			flags:   []string{notify.FlagStreamWildcardMentioned},
			idle:    true,
			state:   stateBuilder{global: defaults, policy: notify.PolicyFollowed},
			want:    notify.TriggerStreamWildcardMentionInFollowedTopic,
		},
		{
			name:    "a topic wildcard notifies on default settings",
			message: channelMessage(),
			flags:   []string{notify.FlagTopicWildcardMentioned},
			idle:    true,
			state:   stateBuilder{global: defaults},
			want:    notify.TriggerTopicWildcardMention,
		},
		{
			name:    "a topic wildcard outranks a channel wildcard",
			message: channelMessage(),
			flags:   []string{notify.FlagTopicWildcardMentioned, notify.FlagStreamWildcardMentioned},
			idle:    true,
			state:   stateBuilder{global: defaults},
			want:    notify.TriggerTopicWildcardMention,
		},
		{
			name:    "the pre-224 wildcard flag counts as a channel wildcard",
			message: channelMessage(),
			flags:   []string{notify.FlagWildcardMentioned},
			idle:    true,
			state:   stateBuilder{global: defaults},
			want:    notify.TriggerStreamWildcardMention,
		},
		{
			name:    "a wildcard is suppressed in a muted topic",
			message: channelMessage(),
			flags:   []string{notify.FlagStreamWildcardMentioned},
			idle:    true,
			state:   stateBuilder{global: defaults, policy: notify.PolicyMuted},
			want:    notify.TriggerNone,
		},
		{
			name:    "a wildcard is suppressed in a muted channel",
			message: channelMessage(),
			flags:   []string{notify.FlagStreamWildcardMentioned},
			idle:    true,
			state:   stateBuilder{global: defaults, subscription: notify.Subscription{IsMuted: true}},
			want:    notify.TriggerNone,
		},
		{
			name:    "an explicit channel wildcard setting beats the channel mute",
			message: channelMessage(),
			flags:   []string{notify.FlagStreamWildcardMentioned},
			idle:    true,
			state: stateBuilder{
				global:       defaults,
				subscription: notify.Subscription{IsMuted: true, WildcardMentionsNotify: boolPtr(true)},
			},
			want: notify.TriggerStreamWildcardMention,
		},
		{
			name:    "an explicit channel wildcard setting does not beat a muted topic",
			message: channelMessage(),
			flags:   []string{notify.FlagStreamWildcardMentioned},
			idle:    true,
			state: stateBuilder{
				global:       defaults,
				subscription: notify.Subscription{IsMuted: true, WildcardMentionsNotify: boolPtr(true)},
				policy:       notify.PolicyMuted,
			},
			want: notify.TriggerNone,
		},
		{
			name:    "a wildcard still needs the offline toggle",
			message: channelMessage(),
			flags:   []string{notify.FlagStreamWildcardMentioned},
			idle:    true,
			state: stateBuilder{global: func() notify.GlobalSettings {
				global := defaults
				global.EnableOfflinePushNotifications = false
				return global
			}()},
			want: notify.TriggerNone,
		},

		{
			name:    "a followed topic notifies through a muted channel",
			message: channelMessage(),
			idle:    true,
			state: stateBuilder{
				global:       defaults,
				subscription: notify.Subscription{IsMuted: true},
				policy:       notify.PolicyFollowed,
			},
			want: notify.TriggerFollowedTopicPush,
		},
		{
			name:    "a followed topic notifies despite push_notifications: false on the channel",
			message: channelMessage(),
			idle:    true,
			state: stateBuilder{
				global:       defaults,
				subscription: notify.Subscription{PushNotifications: boolPtr(false)},
				policy:       notify.PolicyFollowed,
			},
			want: notify.TriggerFollowedTopicPush,
		},
		{
			name:    "a followed topic obeys its own global toggle",
			message: channelMessage(),
			idle:    true,
			state: stateBuilder{
				global: func() notify.GlobalSettings {
					global := defaults
					global.EnableFollowedTopicPushNotifications = false
					return global
				}(),
				policy: notify.PolicyFollowed,
			},
			want: notify.TriggerNone,
		},

		{
			name:    "the global channel setting is the fallback",
			message: channelMessage(),
			idle:    true,
			state:   stateBuilder{global: streamPushOn},
			want:    notify.TriggerStreamPush,
		},
		{
			name:    "channel push is off by default",
			message: channelMessage(),
			idle:    true,
			state:   stateBuilder{global: defaults},
			want:    notify.TriggerNone,
		},
		{
			name:    "a channel override of true beats a global false",
			message: channelMessage(),
			idle:    true,
			state:   stateBuilder{global: defaults, subscription: notify.Subscription{PushNotifications: boolPtr(true)}},
			want:    notify.TriggerStreamPush,
		},
		{
			name:    "a channel override of false beats a global true",
			message: channelMessage(),
			idle:    true,
			state:   stateBuilder{global: streamPushOn, subscription: notify.Subscription{PushNotifications: boolPtr(false)}},
			want:    notify.TriggerNone,
		},
		{
			name:    "an unmuted topic rescues a muted channel",
			message: channelMessage(),
			idle:    true,
			state: stateBuilder{
				global:       streamPushOn,
				subscription: notify.Subscription{IsMuted: true},
				policy:       notify.PolicyUnmuted,
			},
			want: notify.TriggerStreamPush,
		},
		{
			name:    "a muted channel suppresses the channel setting",
			message: channelMessage(),
			idle:    true,
			state:   stateBuilder{global: streamPushOn, subscription: notify.Subscription{IsMuted: true}},
			want:    notify.TriggerNone,
		},
		{
			name:    "topic policies match case-insensitively",
			message: channelMessage(),
			idle:    true,
			state: stateBuilder{
				global:      streamPushOn,
				policy:      notify.PolicyMuted,
				policyTopic: "DePloYs",
			},
			want: notify.TriggerNone,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			decision := notify.Decide(notify.Input{
				UserID:  recipientID,
				Message: test.message,
				Flags:   test.flags,
				Idle:    test.idle,
				State:   test.state.build(),
			})

			assert.Equal(t, test.want, decision.Trigger, "reason: %s", decision.Reason)
			assert.Equal(t, test.want != notify.TriggerNone, decision.Notify)
		})
	}
}

// An unsubscribed channel has no per-channel row, so the global setting has to
// apply rather than an implicit false.
func TestDecideWithoutSubscription(t *testing.T) {
	state := notify.NewState()
	state.Global.EnableStreamPushNotifications = true

	decision := notify.Decide(notify.Input{
		UserID:  recipientID,
		Message: channelMessage(),
		Idle:    true,
		State:   state,
	})

	require.True(t, decision.Notify)
	assert.Equal(t, notify.TriggerStreamPush, decision.Trigger)
}

func TestDecideWithoutState(t *testing.T) {
	decision := notify.Decide(notify.Input{UserID: recipientID, Message: directMessage(), Idle: true})

	assert.True(t, decision.Notify, "an empty mirror falls back to Zulip's defaults")
	assert.Equal(t, notify.TriggerDirectMessage, decision.Trigger)
}
