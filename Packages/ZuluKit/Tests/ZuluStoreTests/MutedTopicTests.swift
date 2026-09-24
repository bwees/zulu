import Foundation
import GRDB
import Testing
import ZulipAPI
@testable import ZuluStore

@MainActor
struct MutedTopicTests {

    private func firstValue<T>(_ stream: AsyncValueObservation<T>) async throws -> T? {
        for try await value in stream { return value }
        return nil
    }

    private func makeStore() throws -> ZuluStore {
        let store = try ZuluStore(url: nil)
        try store.writer.write { db in
            try db.execute(sql: """
                INSERT INTO channel (id, name, isRestricted, isMuted, pinned, detectedForum)
                VALUES (7, 'engineering', 0, 0, 0, 1)
                """)
            for (name, maxID) in [("flaky tests", 100), ("standup", 90), ("old thread", 50)] {
                try db.execute(
                    sql: "INSERT INTO topic (channelID, name, maxMessageID) VALUES (7, ?, ?)",
                    arguments: [name, maxID]
                )
            }
        }
        try store.writer.write { db in
            try UnreadRecord(messageID: 1, channelID: 7, topic: "flaky tests").save(db)
            try UnreadRecord(messageID: 2, channelID: 7, topic: "standup").save(db)
            try UnreadRecord(messageID: 3, channelID: 7, topic: "flaky tests", isMention: true).save(db)
        }
        return store
    }

    private func channel(in store: ZuluStore) async throws -> ChannelSummary? {
        try await firstValue(store.observeChannels().values(in: store.writer))?.first
    }

    @Test func aMutedTopicLeavesTheTopicList() async throws {
        let store = try makeStore()
        try store.setMuted(true, topic: "standup", inChannel: 7)

        let topics = try await firstValue(
            store.observeTopics(inChannel: 7).values(in: store.writer)
        ) ?? []
        #expect(topics.map(\.name) == ["flaky tests", "old thread"])
    }

    @Test func aMutedTopicLeavesRecentTopicsWithoutTakingASlot() async throws {
        let store = try makeStore()
        try store.setMuted(true, topic: "flaky tests", inChannel: 7)

        let recent = try await firstValue(
            store.observeRecentTopics(perChannel: 2).values(in: store.writer)
        ) ?? []
        #expect(recent.map(\.name) == ["standup", "old thread"])
    }

    @Test func aMutedTopicStopsCountingUnreadButKeepsItsMentions() async throws {
        let store = try makeStore()
        try store.setMuted(true, topic: "flaky tests", inChannel: 7)

        let summary = try await channel(in: store)
        #expect(summary?.unreadCount == 1)
        #expect(summary?.mentionCount == 1)
    }

    @Test func muteMatchingIgnoresCase() throws {
        let store = try makeStore()
        try store.setMuted(true, topic: "Standup", inChannel: 7)
        #expect(try store.isMuted(topic: "standup", inChannel: 7))
    }

    @Test func unmutingBringsTheTopicBack() async throws {
        let store = try makeStore()
        try store.setMuted(true, topic: "standup", inChannel: 7)
        try store.setMuted(false, topic: "standup", inChannel: 7)

        let summary = try await channel(in: store)
        #expect(summary?.unreadCount == 3)
    }

    @Test func onlyTheMutedPolicyIsKeptFromTheServer() throws {
        let store = try makeStore()
        try store.replaceMutedTopics([
            UserTopic(stream_id: 7, topic_name: "standup", visibility_policy: TopicVisibilityPolicy.muted.rawValue),
            UserTopic(stream_id: 7, topic_name: "old thread", visibility_policy: TopicVisibilityPolicy.followed.rawValue),
        ])

        #expect(try store.isMuted(topic: "standup", inChannel: 7))
        #expect(try store.isMuted(topic: "old thread", inChannel: 7) == false)
    }

    @Test func aPolicyChangeAwayFromMutedUnmutes() throws {
        let store = try makeStore()
        try store.setMuted(true, topic: "standup", inChannel: 7)
        try store.apply(UserTopic(
            stream_id: 7, topic_name: "standup", visibility_policy: TopicVisibilityPolicy.inherit.rawValue
        ))

        #expect(try store.isMuted(topic: "standup", inChannel: 7) == false)
    }
}
