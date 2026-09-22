package notify_test

import (
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/bwees/zulu/service/internal/notify"
)

func TestTopicPolicyStorage(t *testing.T) {
	tests := []struct {
		name    string
		written string
		read    string
		policy  notify.VisibilityPolicy
		want    notify.VisibilityPolicy
	}{
		{name: "exact match", written: "Deploys", read: "Deploys", policy: notify.PolicyMuted, want: notify.PolicyMuted},
		{name: "different case", written: "Deploys", read: "dePLOYs", policy: notify.PolicyFollowed, want: notify.PolicyFollowed},
		{name: "unknown topic inherits", written: "Deploys", read: "other", policy: notify.PolicyMuted, want: notify.PolicyInherit},
		{name: "empty topic is a real topic", written: "", read: "", policy: notify.PolicyMuted, want: notify.PolicyMuted},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			state := notify.NewState()
			state.SetTopicPolicy(1, test.written, test.policy)

			assert.Equal(t, test.want, state.TopicPolicy(1, test.read))
		})
	}
}

// Zulip stores "inherit" as the absence of a row; writing policy 0 deletes it.
func TestSetTopicPolicyInheritRemovesTheRow(t *testing.T) {
	state := notify.NewState()
	state.SetTopicPolicy(1, "deploys", notify.PolicyMuted)

	state.SetTopicPolicy(1, "deploys", notify.PolicyInherit)

	assert.Equal(t, notify.PolicyInherit, state.TopicPolicy(1, "deploys"))
	assert.Empty(t, state.TopicPolicies, "the channel's map is pruned when its last topic goes")
}

// A policy value from a newer server must not be stored, or the resolver would
// compare against a number it has no rule for.
func TestSetTopicPolicyIgnoresUnknownValues(t *testing.T) {
	state := notify.NewState()

	state.SetTopicPolicy(1, "deploys", notify.VisibilityPolicy(99))

	assert.Equal(t, notify.PolicyInherit, state.TopicPolicy(1, "deploys"))
}

func TestStateSurvivesJSONRoundTrip(t *testing.T) {
	state := notify.NewState()
	state.Global.EnableStreamPushNotifications = true
	state.SetSubscription(7, notify.Subscription{IsMuted: true, PushNotifications: boolPtr(false)})
	state.SetTopicPolicy(7, "Deploys", notify.PolicyFollowed)
	state.SetMutedUsers([]int64{11})

	encoded, err := json.Marshal(state)
	require.NoError(t, err)

	restored := notify.NewState()
	require.NoError(t, json.Unmarshal(encoded, restored))

	assert.Equal(t, state, restored)
	assert.Equal(t, notify.PolicyFollowed, restored.TopicPolicy(7, "deploys"))
	require.NotNil(t, restored.Subscription(7).PushNotifications)
	assert.False(t, *restored.Subscription(7).PushNotifications)
	assert.True(t, restored.IsMutedUser(11))
}

func TestRemoveSubscriptionDropsTopicPolicies(t *testing.T) {
	state := notify.NewState()
	state.SetSubscription(7, notify.Subscription{})
	state.SetTopicPolicy(7, "deploys", notify.PolicyMuted)

	state.RemoveSubscription(7)

	assert.Empty(t, state.Subscriptions)
	assert.Equal(t, notify.PolicyInherit, state.TopicPolicy(7, "deploys"))
}
