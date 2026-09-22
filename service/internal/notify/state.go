// Package notify reimplements Zulip's server-side "would this message notify the
// user" decision.
//
// Zulip computes that decision for every message but strips it out of the event
// stream before clients see it (`prune_internal_data`), so a third-party push
// service has to recompute it from the four settings layers it mirrors: global
// user settings, per-channel subscription settings, per-topic visibility policy,
// and the muted-user set.
package notify

import "strings"

// VisibilityPolicy mirrors UserTopic.VisibilityPolicy. The integers are Zulip's
// wire values and must not be renumbered.
type VisibilityPolicy int

const (
	PolicyInherit  VisibilityPolicy = 0
	PolicyMuted    VisibilityPolicy = 1
	PolicyUnmuted  VisibilityPolicy = 2
	PolicyFollowed VisibilityPolicy = 3
)

// Valid reports whether the policy is one this service understands. Servers newer
// than this build can send values that do not exist here yet.
func (p VisibilityPolicy) Valid() bool {
	return p >= PolicyInherit && p <= PolicyFollowed
}

// GlobalSettings holds the fields of Zulip's UserProfile that the push decision
// reads. The `enable_offline_*` name is Zulip's; it gates DMs and mentions in both
// the idle and the online path, not just offline delivery.
type GlobalSettings struct {
	EnableStreamPushNotifications             bool `json:"enable_stream_push_notifications"`
	EnableOfflinePushNotifications            bool `json:"enable_offline_push_notifications"`
	EnableOnlinePushNotifications             bool `json:"enable_online_push_notifications"`
	WildcardMentionsNotify                    bool `json:"wildcard_mentions_notify"`
	EnableFollowedTopicPushNotifications      bool `json:"enable_followed_topic_push_notifications"`
	EnableFollowedTopicWildcardMentionsNotify bool `json:"enable_followed_topic_wildcard_mentions_notify"`
}

// DefaultGlobalSettings are Zulip's own defaults, used for any field a server
// omits from the register snapshot.
func DefaultGlobalSettings() GlobalSettings {
	return GlobalSettings{
		EnableStreamPushNotifications:             false,
		EnableOfflinePushNotifications:            true,
		EnableOnlinePushNotifications:             true,
		WildcardMentionsNotify:                    true,
		EnableFollowedTopicPushNotifications:      true,
		EnableFollowedTopicWildcardMentionsNotify: true,
	}
}

// Subscription holds the per-channel layer. The pointer fields are Zulip's
// tri-state: nil means "inherit the global setting" and is never the same as false.
type Subscription struct {
	IsMuted                bool  `json:"is_muted"`
	PushNotifications      *bool `json:"push_notifications"`
	WildcardMentionsNotify *bool `json:"wildcard_mentions_notify"`
}

// State is one user's mirror of the four settings layers. It is rebuilt from a
// register snapshot and kept current from events; it is persisted alongside the
// queue cursor so a restart does not have to re-register.
type State struct {
	Global GlobalSettings `json:"global"`
	// Subscriptions is keyed by channel (stream) id.
	Subscriptions map[int64]Subscription `json:"subscriptions"`
	// TopicPolicies is channel id -> case-folded topic -> policy. Zulip's unique
	// constraint is on Lower(topic_name), so lookups must fold case.
	TopicPolicies map[int64]map[string]VisibilityPolicy `json:"topic_policies"`
	MutedUsers    map[int64]bool                        `json:"muted_users"`
}

func NewState() *State {
	return &State{
		Global:        DefaultGlobalSettings(),
		Subscriptions: map[int64]Subscription{},
		TopicPolicies: map[int64]map[string]VisibilityPolicy{},
		MutedUsers:    map[int64]bool{},
	}
}

// FoldTopic normalises a topic for policy lookup.
func FoldTopic(topic string) string { return strings.ToLower(topic) }

func (s *State) SetSubscription(streamID int64, sub Subscription) {
	if s.Subscriptions == nil {
		s.Subscriptions = map[int64]Subscription{}
	}
	s.Subscriptions[streamID] = sub
}

func (s *State) RemoveSubscription(streamID int64) {
	delete(s.Subscriptions, streamID)
	delete(s.TopicPolicies, streamID)
}

func (s *State) Subscription(streamID int64) Subscription {
	return s.Subscriptions[streamID]
}

// SetTopicPolicy records a per-topic visibility policy. PolicyInherit is stored as
// absence, which is how Zulip stores it: writing policy 0 deletes the UserTopic row.
func (s *State) SetTopicPolicy(streamID int64, topic string, policy VisibilityPolicy) {
	key := FoldTopic(topic)
	if policy == PolicyInherit || !policy.Valid() {
		if topics, ok := s.TopicPolicies[streamID]; ok {
			delete(topics, key)
			if len(topics) == 0 {
				delete(s.TopicPolicies, streamID)
			}
		}
		return
	}
	if s.TopicPolicies == nil {
		s.TopicPolicies = map[int64]map[string]VisibilityPolicy{}
	}
	if s.TopicPolicies[streamID] == nil {
		s.TopicPolicies[streamID] = map[string]VisibilityPolicy{}
	}
	s.TopicPolicies[streamID][key] = policy
}

func (s *State) TopicPolicy(streamID int64, topic string) VisibilityPolicy {
	return s.TopicPolicies[streamID][FoldTopic(topic)]
}

func (s *State) SetMutedUsers(ids []int64) {
	muted := make(map[int64]bool, len(ids))
	for _, id := range ids {
		muted[id] = true
	}
	s.MutedUsers = muted
}

func (s *State) IsMutedUser(id int64) bool { return s.MutedUsers[id] }
