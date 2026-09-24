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
        try store.setTopicPolicy(level.topicPolicy, topic: "lunch", inChannel: 7)

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
