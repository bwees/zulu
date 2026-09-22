import Foundation
import GRDB
import Testing
import ZulipAPI
@testable import ZuluStore

@MainActor
struct PersonalShapeTests {


    /// One value out of an observation. `first(where:)` on the stream trips Swift 6's
    /// sendability checks in a `@MainActor` test; a plain loop does not.
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
        return store
    }

    @Test func anAliasReplacesTheNameInTheSidebar() throws {
        let store = try makeStore()
        try store.setAlias("Eng", forChannel: 7)

        let channels = try store.writer.read { db in
            try ChannelSummary.fetchAll(db, sql: """
                SELECT c.id, COALESCE(c.alias, c.name) AS name, c.isRestricted, c.isMuted,
                       c.pinned, COALESCE(c.modeOverride, c.detectedForum) AS isForum,
                       0 AS topicCount, 0 AS unreadCount, 0 AS mentionCount
                  FROM channel c
                """)
        }
        #expect(channels.first?.name == "Eng")
    }

    /// The server's own name has to survive, because a mention must emit the real one.
    @Test func theRealNameIsStillThereUnderTheAlias() throws {
        let store = try makeStore()
        try store.setAlias("Eng", forChannel: 7)

        let real = try store.writer.read { db in
            try String.fetchOne(db, sql: "SELECT name FROM channel WHERE id = 7")
        }
        #expect(real == "engineering")
        #expect(try store.alias(forChannel: 7) == "Eng")
    }

    @Test func clearingAnAliasRestoresTheServerName() throws {
        let store = try makeStore()
        try store.setAlias("Eng", forChannel: 7)
        try store.setAlias(nil, forChannel: 7)
        #expect(try store.alias(forChannel: 7) == nil)
    }

    @Test func whitespaceOnlyAliasIsNoAlias() throws {
        let store = try makeStore()
        try store.setAlias("   ", forChannel: 7)
        #expect(try store.alias(forChannel: 7) == nil)
    }

    /// The working answer from the ticket: promoted topics leave the forum list, so they
    /// are never shown twice and their unread is never counted twice.
    @Test func aPromotedTopicLeavesTheForumListBeneathItsChannel() async throws {
        let store = try makeStore()
        try store.promote(topic: "standup", inChannel: 7)

        let topics = try await firstValue(
            store.observeTopics(inChannel: 7).values(in: store.writer)
        ) ?? []
        #expect(topics.map(\.name).sorted() == ["flaky tests", "old thread"])
    }

    @Test func aPromotedTopicCanBeFiledAwayFromItsChannel() async throws {
        let store = try makeStore()
        try await store.writer.write { db in
            try db.execute(
                sql: "INSERT INTO channelGroup (id, name, position) VALUES ('g1', 'School', 0)"
            )
        }
        try store.promote(topic: "standup", inChannel: 7, toGroup: "g1")

        let inGroup = try await firstValue(
            store.observePromotedTopics(inGroup: "g1").values(in: store.writer)
        ) ?? []
        let unfiled = try await firstValue(
            store.observePromotedTopics(inGroup: nil).values(in: store.writer)
        ) ?? []

        #expect(inGroup.map(\.topic) == ["standup"])
        #expect(unfiled.isEmpty)
    }

    @Test func aPromotionFollowsTheTopicWhenItIsRenamed() throws {
        let store = try makeStore()
        try store.promote(topic: "standup", inChannel: 7)
        try store.renamePromotedTopic(inChannel: 7, from: "standup", to: "daily standup")

        #expect(try store.isPromoted(topic: "daily standup", inChannel: 7))
        #expect(try store.isPromoted(topic: "standup", inChannel: 7) == false)
    }

    /// A promotion is a reference to a name. When the name stops existing the entry goes,
    /// rather than sitting dead in the sidebar.
    @Test func aPromotionWhoseTopicVanishedIsPruned() throws {
        let store = try makeStore()
        try store.promote(topic: "standup", inChannel: 7)
        try store.promote(topic: "flaky tests", inChannel: 7)

        try store.writer.write { db in
            try db.execute(sql: "DELETE FROM topic WHERE channelID = 7 AND name = 'standup'")
        }
        try store.pruneVanishedPromotions(inChannel: 7)

        #expect(try store.isPromoted(topic: "standup", inChannel: 7) == false)
        #expect(try store.isPromoted(topic: "flaky tests", inChannel: 7))
    }

    @Test func demotingPutsTheTopicBackInTheForumList() async throws {
        let store = try makeStore()
        try store.promote(topic: "standup", inChannel: 7)
        try store.demote(topic: "standup", inChannel: 7)

        let topics = try await firstValue(
            store.observeTopics(inChannel: 7).values(in: store.writer)
        ) ?? []
        #expect(topics.count == 3)
    }
}
