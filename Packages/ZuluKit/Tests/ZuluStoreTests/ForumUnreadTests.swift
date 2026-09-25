import Foundation
import GRDB
import Testing
import ZulipAPI
@testable import ZuluStore

/// A forum's own row lights for its general chat; its other topics light their own rows.
@MainActor
struct ForumUnreadTests {

    private func store(generalChat: String = "") throws -> ZuluStore {
        let store = try ZuluStore(url: nil)
        let json = #"[{"stream_id": 7, "name": "engineering"}]"#
        try store.replaceChannels(JSONDecoder().decode([Subscription].self, from: Data(json.utf8)))
        try store.setModeOverride(.forum, forChannel: 7)
        try store.writer.write { db in
            for (name, maxMessageID) in [(generalChat, 1), ("deploys", 2), ("a", 10), ("b", 11), ("c", 12)] {
                try db.execute(
                    sql: "INSERT INTO topic (channelID, name, maxMessageID) VALUES (7, ?, ?)",
                    arguments: [name, maxMessageID]
                )
            }
        }
        return store
    }

    private func addUnread(
        _ messageID: Int, topic: String, isMention: Bool = false, in store: ZuluStore
    ) throws {
        try store.writer.write { db in
            try db.execute(
                sql: "INSERT INTO unread (messageID, channelID, topic, isMention) VALUES (?, 7, ?, ?)",
                arguments: [messageID, topic, isMention]
            )
        }
    }

    private func channel(_ store: ZuluStore) async throws -> ChannelSummary {
        for try await rows in store.observeChannels(inGroup: nil).values(in: store.writer) {
            return try #require(rows.first)
        }
        throw CancellationError()
    }

    @Test func anUnreadTopicLeavesTheForumRowRead() async throws {
        let store = try store()
        try addUnread(1, topic: "deploys", in: store)

        let forum = try await channel(store)
        #expect(forum.unreadCount == 1)
        #expect(forum.rowUnreadCount == 0)
    }

    @Test func aMentionInATopicLeavesTheForumRowUncounted() async throws {
        let store = try store()
        try addUnread(1, topic: "deploys", isMention: true, in: store)
        try addUnread(2, topic: "", isMention: true, in: store)

        let forum = try await channel(store)
        #expect(forum.mentionCount == 2)
        #expect(forum.rowMentionCount == 1)
    }

    @Test(arguments: ["", "general chat", "(no topic)"])
    func anUnreadGeneralChatLightsTheForumRow(generalChat: String) async throws {
        let store = try store(generalChat: generalChat)
        try addUnread(1, topic: generalChat, in: store)

        let forum = try await channel(store)
        #expect(forum.rowUnreadCount == 1)
    }

    @Test func anOldUnreadTopicStaysInTheRecentList() async throws {
        let store = try store()
        try addUnread(1, topic: "deploys", in: store)

        var names: [String] = []
        for try await rows in store.observeRecentTopics(perChannel: 3).values(in: store.writer) {
            names = rows.map(\.name)
            break
        }
        #expect(names == ["c", "b", "a", "deploys"])
    }
}
