import Foundation
import GRDB
import Testing
import ZulipAPI
@testable import ZuluStore

/// The server's snapshot of a channel has to land on top of the viewer's own columns
/// without taking them with it.
@MainActor
struct ChannelSyncTests {

    private func subscriptions() throws -> [Subscription] {
        let json = """
            [{"stream_id": 7, "name": "engineering", "description": "eng",
              "color": "#4f9", "invite_only": false, "is_muted": false, "pin_to_top": false}]
            """
        return try JSONDecoder().decode([Subscription].self, from: Data(json.utf8))
    }

    @Test func aSyncKeepsTheForumChoice() throws {
        let store = try ZuluStore(url: nil)
        let subscriptions = try subscriptions()
        try store.replaceChannels(subscriptions)
        try store.setModeOverride(.forum, forChannel: 7)

        try store.replaceChannels(subscriptions)

        let saved = try store.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT modeOverride FROM channel WHERE id = 7")
        }
        #expect(saved == ChannelMode.forum.rawValue)
    }

    @Test func aSyncKeepsTheDetectorsCachedAnswer() throws {
        let store = try ZuluStore(url: nil)
        let subscriptions = try subscriptions()
        try store.replaceChannels(subscriptions)
        try store.writer.write { db in
            try db.execute(sql: "UPDATE channel SET detectedForum = 1 WHERE id = 7")
        }

        try store.replaceChannels(subscriptions)

        let detected = try store.writer.read { db in
            try Bool.fetchOne(db, sql: "SELECT detectedForum FROM channel WHERE id = 7")
        }
        #expect(detected == true)
    }

    @Test func aSyncStillUpdatesWhatTheServerOwns() throws {
        let store = try ZuluStore(url: nil)
        try store.replaceChannels(try subscriptions())

        let renamed = """
            [{"stream_id": 7, "name": "engineering-2", "description": "eng",
              "color": "#4f9", "invite_only": true, "is_muted": false, "pin_to_top": true}]
            """
        try store.replaceChannels(
            try JSONDecoder().decode([Subscription].self, from: Data(renamed.utf8))
        )

        let row = try store.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT name, isRestricted, pinned FROM channel WHERE id = 7")
        }
        #expect(row?["name"] == "engineering-2")
        #expect(row?["isRestricted"] == true)
        #expect(row?["pinned"] == true)
    }
}

struct ChannelModeTests {

    @Test func noTopicsIsChat() {
        #expect(ChannelModeDetector.detectsAsForum(topicMaxIDs: []) == false)
    }

    @Test func oneTopicIsChat() {
        #expect(ChannelModeDetector.detectsAsForum(topicMaxIDs: [500]) == false)
    }

    /// Several topics all active around the same time — a real forum.
    @Test func interleavedTopicsAreAForum() {
        #expect(ChannelModeDetector.detectsAsForum(topicMaxIDs: [1000, 995, 990, 980]))
    }

    /// The long tail of dead topics a chat channel accumulates. The live topic has run away
    /// from every other one, which a plain topic count would misread as a forum.
    @Test func oneRunawayTopicIsChat() {
        #expect(ChannelModeDetector.detectsAsForum(topicMaxIDs: [9000, 120, 100]) == false)
    }

    @Test func aBurstAcrossTopicsAtTheSameIdIsAForum() {
        #expect(ChannelModeDetector.detectsAsForum(topicMaxIDs: [500, 500, 500]))
    }

    /// Exactly at the threshold counts as a forum, so a channel is only demoted to chat
    /// when one topic is clearly dominant.
    @Test func halfTheSpanIsStillAForum() {
        #expect(ChannelModeDetector.detectsAsForum(topicMaxIDs: [200, 150, 100]))
    }

    @Test func orderOfInputDoesNotMatter() {
        let scrambled = ChannelModeDetector.detectsAsForum(topicMaxIDs: [100, 9000, 120])
        let sorted = ChannelModeDetector.detectsAsForum(topicMaxIDs: [9000, 120, 100])
        #expect(scrambled == sorted)
    }
}
