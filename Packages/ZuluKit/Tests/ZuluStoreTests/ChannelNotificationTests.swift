import Foundation
import Testing
import ZulipAPI
@testable import ZuluStore

@MainActor
struct ChannelNotificationTests {

    private func subscriptions(isMuted: Bool, push: String) throws -> [Subscription] {
        let json = """
            [{"stream_id": 7, "name": "engineering", "is_muted": \(isMuted), "push_notifications": \(push)}]
            """
        return try JSONDecoder().decode([Subscription].self, from: Data(json.utf8))
    }

    @Test(arguments: [
        (false, "true", NotificationLevel.all),
        (false, "false", .mentions),
        (false, "null", .mentions),
        (true, "true", .muted),
    ])
    func levelFollowsTheSubscription(isMuted: Bool, push: String, expected: NotificationLevel) throws {
        let store = try ZuluStore(url: nil)
        try store.replaceChannels(subscriptions(isMuted: isMuted, push: push))

        #expect(try store.notificationLevel(forChannel: 7) == expected)
    }

    @Test(arguments: NotificationLevel.allCases)
    func aLevelSetLocallyReadsBack(level: NotificationLevel) throws {
        let store = try ZuluStore(url: nil)
        try store.replaceChannels(subscriptions(isMuted: false, push: "null"))

        try store.setNotificationLevel(level, forChannel: 7)

        #expect(try store.notificationLevel(forChannel: 7) == level)
    }

    @Test func anUnknownChannelHasNoLevel() throws {
        let store = try ZuluStore(url: nil)
        #expect(try store.notificationLevel(forChannel: 99) == nil)
    }
}

@MainActor
struct NotificationLevelResolutionTests {

    private func store(channels: [Int]) throws -> ZuluStore {
        let store = try ZuluStore(url: nil)
        let json = "[" + channels.map { #"{"stream_id": \#($0), "name": "c\#($0)"}"# }.joined(separator: ",") + "]"
        try store.replaceChannels(JSONDecoder().decode([Subscription].self, from: Data(json.utf8)))
        return store
    }

    @Test func aChannelFollowsItsGroup() throws {
        let store = try store(channels: [7])
        let group = try store.createGroup(name: "Work")
        try store.setChannels([7], inGroup: group.id)
        try store.setNotificationLevel(.muted, forGroup: group.id)

        #expect(try store.effectiveNotificationLevel(forChannel: 7) == .muted)
        #expect(try store.channelsFollowing(group: group.id) == [7])
    }

    @Test func aChannelsOwnLevelBeatsItsGroup() throws {
        let store = try store(channels: [7, 8])
        let group = try store.createGroup(name: "Work")
        try store.setChannels([7, 8], inGroup: group.id)
        try store.setNotificationLevel(.muted, forGroup: group.id)
        try store.setNotificationOverride(.all, forChannel: 7)

        #expect(try store.effectiveNotificationLevel(forChannel: 7) == .all)
        #expect(try store.channelsFollowing(group: group.id) == [8])
    }

    @Test func anUngroupedChannelWithNoChoiceHasNoLevel() throws {
        let store = try store(channels: [7])
        #expect(try store.effectiveNotificationLevel(forChannel: 7) == nil)
    }

    @Test(arguments: NotificationLevel.allCases)
    func aTopicLevelRoundTripsThroughItsPolicy(level: NotificationLevel) throws {
        let store = try store(channels: [7])
        try store.setTopicLevel(level, topic: "lunch", inChannel: 7)

        #expect(try store.notificationLevel(forTopic: "lunch", inChannel: 7) == level)
        #expect(try store.isMuted(topic: "lunch", inChannel: 7) == (level == .muted))
    }

    @Test func inheritingClearsTheTopic() throws {
        let store = try store(channels: [7])
        try store.setTopicPolicy(.followed, topic: "lunch", inChannel: 7)
        try store.apply(UserTopic(stream_id: 7, topic_name: "lunch", visibility_policy: 0))

        #expect(try store.notificationLevel(forTopic: "lunch", inChannel: 7) == nil)
    }

    @Test func levelsTravelWithThePersonalShape() throws {
        let source = try store(channels: [7])
        let group = try source.createGroup(name: "Work")
        try source.setNotificationLevel(.mentions, forGroup: group.id)
        try source.setNotificationOverride(.all, forChannel: 7)

        let target = try store(channels: [7])
        try target.apply(source.localPersonalShape().shape)

        #expect(try target.notificationLevel(forGroup: group.id) == .mentions)
        #expect(try target.notificationOverride(forChannel: 7) == .all)
    }
}

/// Zulip follows a topic on its own when you post in it. Only a follow chosen here says
/// "every message"; the rest leave the topic at its channel's level.
@MainActor
struct ChosenFollowTests {

    private func store() throws -> ZuluStore {
        let store = try ZuluStore(url: nil)
        let json = #"[{"stream_id": 7, "name": "c7"}, {"stream_id": 8, "name": "c8"}]"#
        try store.replaceChannels(JSONDecoder().decode([Subscription].self, from: Data(json.utf8)))
        return store
    }

    private func followed(_ topic: String, in channelID: Int = 7) -> UserTopic {
        UserTopic(stream_id: channelID, topic_name: topic, visibility_policy: TopicVisibilityPolicy.followed.rawValue)
    }

    @Test func anAutomaticFollowLeavesTheTopicAtItsChannelsLevel() throws {
        let store = try store()
        try store.replaceMutedTopics([followed("lunch")])

        #expect(try store.notificationLevel(forTopic: "lunch", inChannel: 7) == nil)
        #expect(try store.topicPolicy(forTopic: "lunch", inChannel: 7) == .followed)
    }

    @Test func aFollowChosenHereHearsEverything() throws {
        let store = try store()
        try store.setTopicPolicy(.followed, topic: "lunch", inChannel: 7)
        try store.setChosenFollow(true, topic: "lunch", inChannel: 7)

        #expect(try store.notificationLevel(forTopic: "lunch", inChannel: 7) == .all)
    }

    @Test func aChoiceAloneDoesNotFollow() throws {
        let store = try store()
        try store.setChosenFollow(true, topic: "lunch", inChannel: 7)

        #expect(try store.notificationLevel(forTopic: "lunch", inChannel: 7) == nil)
    }

    @Test func mutedAndUnmutedNeedNoChoice() throws {
        let store = try store()
        try store.replaceMutedTopics([
            UserTopic(stream_id: 7, topic_name: "noise", visibility_policy: TopicVisibilityPolicy.muted.rawValue),
            UserTopic(stream_id: 7, topic_name: "quiet", visibility_policy: TopicVisibilityPolicy.unmuted.rawValue),
        ])

        #expect(try store.notificationLevel(forTopic: "noise", inChannel: 7) == .muted)
        #expect(try store.notificationLevel(forTopic: "quiet", inChannel: 7) == .mentions)
    }

    @Test func topicNamesMatchWhateverTheirCase() throws {
        let store = try store()
        try store.replaceMutedTopics([followed("Lunch")])
        try store.setChosenFollow(true, topic: "lunch", inChannel: 7)

        #expect(try store.notificationLevel(forTopic: "LUNCH", inChannel: 7) == .all)
    }

    @Test func aChoiceIsPerChannel() throws {
        let store = try store()
        try store.replaceMutedTopics([followed("lunch", in: 7), followed("lunch", in: 8)])
        try store.setChosenFollow(true, topic: "lunch", inChannel: 7)

        #expect(try store.notificationLevel(forTopic: "lunch", inChannel: 7) == .all)
        #expect(try store.notificationLevel(forTopic: "lunch", inChannel: 8) == nil)
    }

    @Test func unchoosingReturnsToTheChannel() throws {
        let store = try store()
        try store.replaceMutedTopics([followed("lunch")])
        try store.setChosenFollow(true, topic: "lunch", inChannel: 7)
        try store.setChosenFollow(false, topic: "lunch", inChannel: 7)

        #expect(try store.notificationLevel(forTopic: "lunch", inChannel: 7) == nil)
    }

    /// Unfollowed elsewhere, then followed again by Zulip on its own: the old choice
    /// must not come back with it.
    @Test func unfollowingOnTheServerForgetsTheChoice() throws {
        let store = try store()
        try store.replaceMutedTopics([followed("lunch")])
        try store.setChosenFollow(true, topic: "lunch", inChannel: 7)

        try store.apply(UserTopic(stream_id: 7, topic_name: "lunch", visibility_policy: 0))
        try store.apply(followed("lunch"))

        #expect(try store.notificationLevel(forTopic: "lunch", inChannel: 7) == nil)
    }

    @Test func aRegisterWithoutTheFollowForgetsTheChoice() throws {
        let store = try store()
        try store.replaceMutedTopics([followed("lunch"), followed("dinner")])
        try store.setChosenFollow(true, topic: "lunch", inChannel: 7)
        try store.setChosenFollow(true, topic: "dinner", inChannel: 7)

        try store.replaceMutedTopics([followed("dinner")])
        try store.apply(followed("lunch"))

        #expect(try store.notificationLevel(forTopic: "lunch", inChannel: 7) == nil)
        #expect(try store.notificationLevel(forTopic: "dinner", inChannel: 7) == .all)
    }

    @Test func aRegisterThatKeepsTheFollowKeepsTheChoice() throws {
        let store = try store()
        try store.replaceMutedTopics([followed("lunch")])
        try store.setChosenFollow(true, topic: "lunch", inChannel: 7)

        try store.replaceMutedTopics([followed("lunch")])

        #expect(try store.notificationLevel(forTopic: "lunch", inChannel: 7) == .all)
    }

    @Test func choicesTravelWithThePersonalShape() throws {
        let phone = try store()
        try phone.setChosenFollow(true, topic: "lunch", inChannel: 7)

        let mac = try store()
        try mac.replaceMutedTopics([followed("lunch"), followed("standup")])
        try mac.setChosenFollow(true, topic: "standup", inChannel: 7)
        try mac.apply(phone.localPersonalShape().shape)

        #expect(try mac.notificationLevel(forTopic: "lunch", inChannel: 7) == .all)
        #expect(try mac.notificationLevel(forTopic: "standup", inChannel: 7) == nil)
    }

    /// The follow can land from Zulip after the choice lands from the other device.
    @Test func aChoiceFromAnotherDeviceWaitsForItsFollow() throws {
        let phone = try store()
        try phone.setChosenFollow(true, topic: "lunch", inChannel: 7)

        let mac = try store()
        try mac.apply(phone.localPersonalShape().shape)
        #expect(try mac.notificationLevel(forTopic: "lunch", inChannel: 7) == nil)

        try mac.apply(followed("lunch"))
        #expect(try mac.notificationLevel(forTopic: "lunch", inChannel: 7) == .all)
    }

    @Test func choicesInChannelsThisDeviceLacksArePassedAlong() throws {
        let remote = PersonalShape(followedTopics: [.init(channelID: 99, topic: "elsewhere")])
        let local = try store().localPersonalShape()

        #expect(local.document(carryingOver: remote).followedTopics == [.init(channelID: 99, topic: "elsewhere")])
    }

    @Test func aDocumentFromBeforeChoicesStillReads() throws {
        let json = #"{"groups": [], "members": [], "channels": [], "promotions": []}"#
        let shape = try JSONDecoder().decode(PersonalShape.self, from: Data(json.utf8))
        #expect(shape.followedTopics.isEmpty)
    }

    @Test func signingOutForgetsChoices() throws {
        let store = try store()
        try store.setChosenFollow(true, topic: "lunch", inChannel: 7)
        try store.clearAll()
        #expect(try store.localPersonalShape().shape.followedTopics.isEmpty)
    }

    @Test(arguments: [NotificationLevel.mentions, .muted, nil])
    func movingOffAllMessagesForgetsTheChoice(level: NotificationLevel?) throws {
        let store = try store()
        try store.setTopicLevel(.all, topic: "lunch", inChannel: 7)
        try store.setTopicLevel(level, topic: "lunch", inChannel: 7)

        #expect(try store.isChosenFollow(topic: "lunch", inChannel: 7) == false)
        #expect(try store.notificationLevel(forTopic: "lunch", inChannel: 7) == level)
    }
}

struct BannerRuleTests {
    private let everything = BannerRule(directMessages: true, mentions: true)

    @Test func aMentionsOnlyChannelIsQuietWithoutAMention() {
        #expect(!everything.allows(isDirect: false, isMentioned: false, isPersonallyMentioned: false, level: .mentions))
    }

    @Test func aMentionsOnlyChannelSpeaksForAMention() {
        #expect(everything.allows(isDirect: false, isMentioned: true, isPersonallyMentioned: true, level: .mentions))
        #expect(everything.allows(isDirect: false, isMentioned: true, isPersonallyMentioned: false, level: .mentions))
    }

    @Test func anAllMessagesChannelSpeaksForEverything() {
        #expect(everything.allows(isDirect: false, isMentioned: false, isPersonallyMentioned: false, level: .all))
    }

    @Test func aMutedChannelHearsOnlyMentionsByName() {
        #expect(!everything.allows(isDirect: false, isMentioned: false, isPersonallyMentioned: false, level: .muted))
        #expect(!everything.allows(isDirect: false, isMentioned: true, isPersonallyMentioned: false, level: .muted))
        #expect(everything.allows(isDirect: false, isMentioned: true, isPersonallyMentioned: true, level: .muted))
    }

    @Test func withMentionBannersOffOnlyAllMessagesSpeaks() {
        let rule = BannerRule(directMessages: true, mentions: false)
        #expect(!rule.allows(isDirect: false, isMentioned: true, isPersonallyMentioned: true, level: .mentions))
        #expect(!rule.allows(isDirect: false, isMentioned: true, isPersonallyMentioned: true, level: .muted))
        #expect(rule.allows(isDirect: false, isMentioned: false, isPersonallyMentioned: false, level: .all))
    }

    @Test func directMessagesFollowTheirOwnSwitch() {
        #expect(everything.allows(isDirect: true, isMentioned: false, isPersonallyMentioned: false, level: nil))
        let off = BannerRule(directMessages: false, mentions: true)
        #expect(!off.allows(isDirect: true, isMentioned: true, isPersonallyMentioned: true, level: nil))
    }

    @Test func aChannelWithNoLevelIsMentionsOnly() {
        #expect(!everything.allows(isDirect: false, isMentioned: false, isPersonallyMentioned: false, level: nil))
    }

    /// The reported bug end to end: a channel on Mentions Only whose topic Zulip followed
    /// after you posted in it.
    @MainActor
    @Test func anAutomaticallyFollowedTopicInAMentionsOnlyChannelStaysQuiet() throws {
        let store = try ZuluStore(url: nil)
        let json = #"[{"stream_id": 7, "name": "c7", "is_muted": false, "push_notifications": false}]"#
        try store.replaceChannels(JSONDecoder().decode([Subscription].self, from: Data(json.utf8)))
        try store.replaceMutedTopics([
            UserTopic(stream_id: 7, topic_name: "lunch", visibility_policy: TopicVisibilityPolicy.followed.rawValue),
        ])

        let level = try store.notificationLevel(forTopic: "lunch", inChannel: 7)
            ?? store.notificationLevel(forChannel: 7)
        #expect(level == .mentions)
        #expect(!everything.allows(isDirect: false, isMentioned: false, isPersonallyMentioned: false, level: level))
    }
}
