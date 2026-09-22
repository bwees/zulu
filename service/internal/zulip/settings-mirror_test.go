package zulip_test

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/bwees/zulu/service/internal/notify"
	"github.com/bwees/zulu/service/internal/zulip"
)

func decodeRegister(t *testing.T, body string) zulip.RegisterResponse {
	t.Helper()
	var response zulip.RegisterResponse
	require.NoError(t, json.Unmarshal([]byte(body), &response))
	return response
}

func decodeEvent(t *testing.T, body string) zulip.Event {
	t.Helper()
	var event zulip.Event
	require.NoError(t, json.Unmarshal([]byte(body), &event))
	return event
}

func TestBuildState(t *testing.T) {
	response := decodeRegister(t, `{
		"queue_id": "q1",
		"last_event_id": 12,
		"user_settings": {
			"enable_stream_push_notifications": true,
			"enable_offline_push_notifications": false
		},
		"subscriptions": [
			{"stream_id": 1, "is_muted": true, "push_notifications": null, "wildcard_mentions_notify": false},
			{"stream_id": 2, "is_muted": false, "push_notifications": true}
		],
		"user_topics": [
			{"stream_id": 1, "topic_name": "Deploys", "visibility_policy": 3},
			{"stream_id": 2, "topic_name": "noise", "visibility_policy": 1}
		],
		"muted_users": [{"id": 99, "timestamp": 1}]
	}`)

	state := zulip.BuildState(response)

	assert.True(t, state.Global.EnableStreamPushNotifications)
	assert.False(t, state.Global.EnableOfflinePushNotifications)
	assert.True(t, state.Global.EnableOnlinePushNotifications, "a field the server omitted keeps Zulip's default")

	assert.True(t, state.Subscription(1).IsMuted)
	assert.Nil(t, state.Subscription(1).PushNotifications, "null means inherit, not false")
	require.NotNil(t, state.Subscription(1).WildcardMentionsNotify)
	assert.False(t, *state.Subscription(1).WildcardMentionsNotify)

	assert.Equal(t, notify.PolicyFollowed, state.TopicPolicy(1, "deploys"))
	assert.Equal(t, notify.PolicyMuted, state.TopicPolicy(2, "noise"))
	assert.True(t, state.IsMutedUser(99))
}

// Older servers send in_home_view instead of is_muted.
func TestBuildStateAcceptsInHomeView(t *testing.T) {
	response := decodeRegister(t, `{"subscriptions": [{"stream_id": 1, "in_home_view": false}]}`)

	state := zulip.BuildState(response)

	assert.True(t, state.Subscription(1).IsMuted)
}

func TestApplyEvent(t *testing.T) {
	tests := []struct {
		name    string
		event   string
		want    func(*testing.T, *notify.State)
		changed bool
	}{
		{
			name:    "global setting update",
			event:   `{"id": 1, "type": "user_settings", "op": "update", "property": "enable_stream_push_notifications", "value": true}`,
			changed: true,
			want: func(t *testing.T, state *notify.State) {
				assert.True(t, state.Global.EnableStreamPushNotifications)
			},
		},
		{
			name:    "an unknown global property is ignored",
			event:   `{"id": 1, "type": "user_settings", "op": "update", "property": "web_font_size_px", "value": 16}`,
			changed: false,
			want:    func(*testing.T, *notify.State) {},
		},
		{
			name:    "channel mute",
			event:   `{"id": 2, "type": "subscription", "op": "update", "stream_id": 1, "property": "is_muted", "value": true}`,
			changed: true,
			want: func(t *testing.T, state *notify.State) {
				assert.True(t, state.Subscription(1).IsMuted)
			},
		},
		{
			name:    "in_home_view is the inverse of is_muted",
			event:   `{"id": 2, "type": "subscription", "op": "update", "stream_id": 1, "property": "in_home_view", "value": false}`,
			changed: true,
			want: func(t *testing.T, state *notify.State) {
				assert.True(t, state.Subscription(1).IsMuted)
			},
		},
		{
			name:    "a channel push override reverting to null means inherit",
			event:   `{"id": 3, "type": "subscription", "op": "update", "stream_id": 1, "property": "push_notifications", "value": null}`,
			changed: true,
			want: func(t *testing.T, state *notify.State) {
				assert.Nil(t, state.Subscription(1).PushNotifications)
			},
		},
		{
			name:    "subscribing adds the channel",
			event:   `{"id": 4, "type": "subscription", "op": "add", "subscriptions": [{"stream_id": 9, "is_muted": true}]}`,
			changed: true,
			want: func(t *testing.T, state *notify.State) {
				assert.True(t, state.Subscription(9).IsMuted)
			},
		},
		{
			name:    "unsubscribing removes the channel",
			event:   `{"id": 5, "type": "subscription", "op": "remove", "subscriptions": [{"stream_id": 1}]}`,
			changed: true,
			want: func(t *testing.T, state *notify.State) {
				assert.Empty(t, state.Subscriptions)
			},
		},
		{
			name:    "following a topic",
			event:   `{"id": 6, "type": "user_topic", "stream_id": 1, "topic_name": "Deploys", "visibility_policy": 3}`,
			changed: true,
			want: func(t *testing.T, state *notify.State) {
				assert.Equal(t, notify.PolicyFollowed, state.TopicPolicy(1, "deploys"))
			},
		},
		{
			name:    "muted users arrive as a full replacement",
			event:   `{"id": 7, "type": "muted_users", "muted_users": [{"id": 3}]}`,
			changed: true,
			want: func(t *testing.T, state *notify.State) {
				assert.True(t, state.IsMutedUser(3))
				assert.False(t, state.IsMutedUser(99))
			},
		},
		{
			name:    "a message event changes no settings",
			event:   `{"id": 8, "type": "message", "message": {"id": 1}}`,
			changed: false,
			want:    func(*testing.T, *notify.State) {},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			state := notify.NewState()
			state.SetSubscription(1, notify.Subscription{PushNotifications: new(bool)})
			state.SetMutedUsers([]int64{99})

			changed, err := zulip.ApplyEvent(state, decodeEvent(t, test.event))

			require.NoError(t, err)
			assert.Equal(t, test.changed, changed)
			test.want(t, state)
		})
	}
}

func TestEventDecodingKeepsTheRawBody(t *testing.T) {
	event := decodeEvent(t, `{"id": 42, "type": "message", "message": {"id": 7, "subject": "deploys"}, "flags": ["mentioned"]}`)

	assert.Equal(t, int64(42), event.ID)
	assert.Equal(t, zulip.EventMessage, event.Type)

	message, err := zulip.DecodeMessageEvent(event)
	require.NoError(t, err)
	assert.Equal(t, int64(7), message.Message.ID)
	assert.Equal(t, "deploys", message.Message.Subject)
	assert.Equal(t, []string{"mentioned"}, message.Flags)
}

func TestMessageRecipients(t *testing.T) {
	channel := decodeEvent(t, `{"id": 1, "type": "message", "message": {"id": 1, "type": "stream", "display_recipient": "general"}}`)
	direct := decodeEvent(t, `{"id": 2, "type": "message", "message": {"id": 2, "type": "private",
		"display_recipient": [{"id": 9}, {"id": 3}]}}`)

	channelMessage, err := zulip.DecodeMessageEvent(channel)
	require.NoError(t, err)
	directMessage, err := zulip.DecodeMessageEvent(direct)
	require.NoError(t, err)

	assert.Equal(t, "general", channelMessage.Message.ChannelName())
	assert.Empty(t, channelMessage.Message.RecipientIDs())
	assert.Equal(t, []int64{3, 9}, directMessage.Message.RecipientIDs(), "sorted, so the conversation has one identity")
	assert.Empty(t, directMessage.Message.ChannelName())
}

func TestLongpollTimeout(t *testing.T) {
	assert.Equal(t, zulip.DefaultLongpollTimeout, zulip.RegisterResponse{}.LongpollTimeout(),
		"a server too old to send the field gets the documented fallback")
	assert.Equal(t, 120*time.Second, zulip.RegisterResponse{EventQueueLongpollTimeoutSeconds: 120}.LongpollTimeout())
}
