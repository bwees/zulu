package notify

// Trigger is Zulip's NotificationTriggers vocabulary. The server uses it only to
// pick an alert subtitle; this service uses it the same way.
type Trigger string

const (
	TriggerNone                                 Trigger = ""
	TriggerDirectMessage                        Trigger = "direct_message"
	TriggerMention                              Trigger = "mentioned"
	TriggerTopicWildcardMention                 Trigger = "topic_wildcard_mentioned"
	TriggerStreamWildcardMention                Trigger = "stream_wildcard_mentioned"
	TriggerTopicWildcardMentionInFollowedTopic  Trigger = "topic_wildcard_mentioned_in_followed_topic"
	TriggerStreamWildcardMentionInFollowedTopic Trigger = "stream_wildcard_mentioned_in_followed_topic"
	TriggerFollowedTopicPush                    Trigger = "followed_topic_push_notify"
	TriggerStreamPush                           Trigger = "stream_push_notify"
)

// Message flags set by the server. They are the only trustworthy mention signal:
// wildcard syntax inside a code block sets no flag, and a silent mention sets none
// either, so the message body must never be re-parsed to find mentions.
const (
	FlagRead                    = "read"
	FlagMentioned               = "mentioned"
	FlagStreamWildcardMentioned = "stream_wildcard_mentioned"
	FlagTopicWildcardMentioned  = "topic_wildcard_mentioned"
	// FlagWildcardMentioned is the pre-feature-level-224 flag, equivalent to a
	// stream wildcard mention.
	FlagWildcardMentioned = "wildcard_mentioned"
)

const (
	MessageTypeStream  = "stream"
	MessageTypePrivate = "private"
)

// Message is the subset of a Zulip message event the decision reads.
type Message struct {
	ID       int64
	Type     string
	SenderID int64
	StreamID int64
	Topic    string
}

// Input is everything the decision needs. Idle is the one input Zulip computes
// itself and never shares: the server ORs "has no live event queue" with
// "presence-idle", and both are meaningless here because this service's own queue
// makes the user look present.
type Input struct {
	UserID  int64
	Message Message
	Flags   []string
	Idle    bool
	State   *State
}

// Decision is the outcome. Reason names the rule that produced it and exists for
// logs and tests, not for the payload.
type Decision struct {
	Notify  bool
	Trigger Trigger
	Reason  string
}

func suppress(reason string) Decision { return Decision{Reason: reason} }

func fire(trigger Trigger) Decision {
	return Decision{Notify: true, Trigger: trigger, Reason: string(trigger)}
}

// Decide answers whether a message event should become a push for one user.
//
// It follows zerver/lib/notification_data.py: the universal vetoes, then the
// online gate, then an ordered trigger switch whose order matters because a
// message can satisfy several arms at once and the most salient one wins.
func Decide(in Input) Decision {
	state := in.State
	if state == nil {
		state = NewState()
	}
	flags := newFlagSet(in.Flags)
	global := state.Global

	if in.Message.SenderID == in.UserID {
		return suppress("own message")
	}
	if state.IsMutedUser(in.Message.SenderID) {
		return suppress("muted sender")
	}
	// The server re-checks the read flag when the push worker runs and drops the
	// push if the message is already read. A message can arrive already-read: the
	// docs warn that new messages are not necessarily unread.
	if flags.has(FlagRead) {
		return suppress("already read")
	}
	if !in.Idle && !global.EnableOnlinePushNotifications {
		return suppress("user is not idle and online push is off")
	}

	if in.Message.Type == MessageTypePrivate {
		if global.EnableOfflinePushNotifications {
			return fire(TriggerDirectMessage)
		}
		return suppress("direct message notifications are off")
	}

	sub := state.Subscription(in.Message.StreamID)
	policy := state.TopicPolicy(in.Message.StreamID, in.Message.Topic)

	// A personal or user-group mention is decided by the flag and the global
	// toggle alone. It never passes through the mute resolver, which is why
	// @-mentioning someone in a topic they muted still reaches them.
	if flags.has(FlagMentioned) && global.EnableOfflinePushNotifications {
		return fire(TriggerMention)
	}

	// Wildcard mentions obey the settings for personal mentions, so they are gated
	// by EnableOfflinePushNotifications too; their own toggles decide only whether
	// the user is eligible at all.
	wildcardAllowed := global.EnableOfflinePushNotifications
	followedWildcard := wildcardAllowed &&
		policy == PolicyFollowed &&
		global.EnableFollowedTopicWildcardMentionsNotify
	plainWildcard := wildcardAllowed && allowsInStreamTopic(streamTopicSettings{
		streamIsMuted:                      sub.IsMuted,
		policy:                             policy,
		streamSpecific:                     sub.WildcardMentionsNotify,
		global:                             global.WildcardMentionsNotify,
		channelSettingOverridesChannelMute: true,
	})

	switch {
	case followedWildcard && flags.has(FlagTopicWildcardMentioned):
		return fire(TriggerTopicWildcardMentionInFollowedTopic)
	case followedWildcard && flags.hasStreamWildcard():
		return fire(TriggerStreamWildcardMentionInFollowedTopic)
	case plainWildcard && flags.has(FlagTopicWildcardMentioned):
		return fire(TriggerTopicWildcardMention)
	case plainWildcard && flags.hasStreamWildcard():
		return fire(TriggerStreamWildcardMention)
	}

	// Following a topic is an additive notification path, not a stronger unmute:
	// it bypasses channel mute and the per-channel push override, and answers to
	// the global followed-topic setting only.
	if policy == PolicyFollowed && global.EnableFollowedTopicPushNotifications {
		return fire(TriggerFollowedTopicPush)
	}

	if allowsInStreamTopic(streamTopicSettings{
		streamIsMuted:                      sub.IsMuted,
		policy:                             policy,
		streamSpecific:                     sub.PushNotifications,
		global:                             global.EnableStreamPushNotifications,
		channelSettingOverridesChannelMute: false,
	}) {
		return fire(TriggerStreamPush)
	}

	return suppress("no trigger matched")
}

type streamTopicSettings struct {
	streamIsMuted  bool
	policy         VisibilityPolicy
	streamSpecific *bool
	global         bool
	// channelSettingOverridesChannelMute is true only for wildcard_mentions_notify,
	// the one setting whose explicit per-channel value beats a muted channel.
	channelSettingOverridesChannelMute bool
}

// allowsInStreamTopic is user_allows_notifications_in_StreamTopic: visibility
// policy first, then the per-channel override, then the global fallback.
func allowsInStreamTopic(s streamTopicSettings) bool {
	if s.policy == PolicyMuted {
		return false
	}
	if s.streamIsMuted && s.policy != PolicyUnmuted {
		if s.channelSettingOverridesChannelMute && s.streamSpecific != nil {
			return *s.streamSpecific
		}
		return false
	}
	if s.streamSpecific != nil {
		return *s.streamSpecific
	}
	return s.global
}

type flagSet map[string]bool

func newFlagSet(flags []string) flagSet {
	set := make(flagSet, len(flags))
	for _, flag := range flags {
		set[flag] = true
	}
	return set
}

func (f flagSet) has(flag string) bool { return f[flag] }

// hasStreamWildcard folds in the flag name used before feature level 224, when
// one flag covered both wildcard kinds and meant the channel-wide one.
func (f flagSet) hasStreamWildcard() bool {
	return f[FlagStreamWildcardMentioned] ||
		(f[FlagWildcardMentioned] && !f[FlagTopicWildcardMentioned])
}
