import Foundation
import GRDB
import Testing
import ZulipAPI
@testable import ZuluStore

/// A promoted topic's unreads show on its own row, not on its channel's as well.
@MainActor
struct PromotedUnreadTests {

    private func store() throws -> ZuluStore {
        let store = try ZuluStore(url: nil)
        let json = #"[{"stream_id": 7, "name": "engineering"}]"#
        try store.replaceChannels(JSONDecoder().decode([Subscription].self, from: Data(json.utf8)))
        try store.writer.write { db in
            try db.execute(sql: """
                INSERT INTO unread (messageID, channelID, topic, isMention) VALUES
                    (1, 7, 'lunch', 1), (2, 7, 'deploys', 0)
                """)
        }
        return store
    }

    private func firstValue<T>(_ stream: AsyncValueObservation<T>) async throws -> T? {
        for try await value in stream { return value }
        return nil
    }

    @Test func aPromotedTopicLeavesItsChannelsCounts() async throws {
        let store = try store()
        try store.promote(topic: "lunch", inChannel: 7)

        let channels = try await firstValue(store.observeChannels(inGroup: nil).values(in: store.writer))
        let channel = try #require(channels?.first)
        #expect(channel.unreadCount == 1)
        #expect(channel.mentionCount == 0)
    }

    @Test func aPromotedTopicCountsTowardTheGroupItIsFiledIn() async throws {
        let store = try store()
        let home = try store.createGroup(name: "Home")
        let elsewhere = try store.createGroup(name: "Elsewhere")
        try store.setChannels([7], inGroup: home.id)
        try store.promote(topic: "lunch", inChannel: 7, toGroup: elsewhere.id)

        let groups = try await firstValue(store.observeGroups().values(in: store.writer)) ?? []
        let homeSummary = try #require(groups.first { $0.id == home.id })
        let elsewhereSummary = try #require(groups.first { $0.id == elsewhere.id })
        #expect(homeSummary.unreadCount == 1)
        #expect(homeSummary.mentionCount == 0)
        #expect(elsewhereSummary.unreadCount == 1)
        #expect(elsewhereSummary.mentionCount == 1)
    }
}
