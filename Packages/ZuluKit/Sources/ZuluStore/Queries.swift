import Foundation
import GRDB
import ZulipAPI

/// A channel with the counts the sidebar needs, so the list is one query not N+1.
public struct ChannelSummary: Decodable, FetchableRecord, Sendable, Identifiable, Equatable {
    public var id: Int
    public var name: String
    public var isRestricted: Bool
    public var isMuted: Bool
    public var pinned: Bool
    public var topicCount: Int
    /// The detector's answer, already overruled by the person's choice if they made one.
    public var isForum: Bool
    public var unreadCount: Int
    public var mentionCount: Int

    /// A channel whose recent traffic all sits in one topic is a chat room in practice,
    /// whatever the server thinks. This is the auto-detection the map fixed.
    public var rendersAsForum: Bool { isForum }
}

public struct TopicSummary: Decodable, FetchableRecord, Sendable, Identifiable, Equatable {
    public var channelID: Int
    public var name: String
    public var maxMessageID: Int
    public var unreadCount: Int
    public var lastSender: String?
    public var lastTimestamp: Int?

    public var id: String { "\(channelID)/\(name)" }
    public var date: Date? { lastTimestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
}

public struct DMSummary: Decodable, FetchableRecord, Sendable, Identifiable, Equatable {
    public var dmKey: String
    public var unreadCount: Int
    public var lastMessageID: Int
    public var lastSender: String?
    public var lastTimestamp: Int?

    public var id: String { dmKey }
    public var participantIDs: [Int] { dmKey.split(separator: ",").compactMap { Int($0) } }
    public var date: Date? { lastTimestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
}

extension ZuluStore {

    public func observeChannels() -> ValueObservation<ValueReducers.Fetch<[ChannelSummary]>> {
        ValueObservation.tracking { db in
            try ChannelSummary.fetchAll(db, sql: """
                SELECT c.id, COALESCE(c.alias, c.name) AS name, c.isRestricted, c.isMuted, c.pinned,
                       COALESCE(c.modeOverride, c.detectedForum) AS isForum,
                       (SELECT COUNT(*) FROM topic t WHERE t.channelID = c.id) AS topicCount,
                       (SELECT COUNT(*) FROM unread u WHERE u.channelID = c.id) AS unreadCount,
                       (SELECT COUNT(*) FROM unread u
                         WHERE u.channelID = c.id AND u.isMention = 1) AS mentionCount
                  FROM channel c
                 WHERE \(ChannelVisibility.clause)
                 ORDER BY c.position IS NULL, c.position, c.pinned DESC, name COLLATE NOCASE
                """)
        }
    }

    public func observeTopics(inChannel id: Int) -> ValueObservation<ValueReducers.Fetch<[TopicSummary]>> {
        ValueObservation.tracking { db in
            try TopicSummary.fetchAll(db, sql: """
                SELECT t.channelID, t.name, t.maxMessageID,
                       (SELECT COUNT(*) FROM unread u
                         WHERE u.channelID = t.channelID AND u.topic = t.name) AS unreadCount,
                       (SELECT m.senderName FROM message m
                         WHERE m.channelID = t.channelID AND m.topic = t.name
                         ORDER BY m.id DESC LIMIT 1) AS lastSender,
                       (SELECT m.timestamp FROM message m
                         WHERE m.channelID = t.channelID AND m.topic = t.name
                         ORDER BY m.id DESC LIMIT 1) AS lastTimestamp
                  FROM topic t
                 WHERE t.channelID = ?
                   -- A promoted topic sits at channel level instead; listing it in
                   -- both places would duplicate it and count its unread twice.
                   AND t.name NOT IN (
                       SELECT topic FROM promotedTopic WHERE channelID = t.channelID
                   )
                 ORDER BY t.maxMessageID DESC
                """, arguments: [id])
        }
    }

    public func observeDMs() -> ValueObservation<ValueReducers.Fetch<[DMSummary]>> {
        ValueObservation.tracking { db in
            try DMSummary.fetchAll(db, sql: """
                SELECT m.dmKey,
                       (SELECT COUNT(*) FROM unread u WHERE u.dmKey = m.dmKey) AS unreadCount,
                       MAX(m.id) AS lastMessageID,
                       (SELECT s.senderName FROM message s WHERE s.dmKey = m.dmKey
                         ORDER BY s.id DESC LIMIT 1) AS lastSender,
                       (SELECT s.timestamp FROM message s WHERE s.dmKey = m.dmKey
                         ORDER BY s.id DESC LIMIT 1) AS lastTimestamp
                  FROM message m
                 WHERE m.dmKey IS NOT NULL
                 GROUP BY m.dmKey
                 ORDER BY lastMessageID DESC
                """)
        }
    }

    public func observeMessages(channelID: Int, topic: String)
        -> ValueObservation<ValueReducers.Fetch<[MessageRecord]>>
    {
        ValueObservation.tracking { db in
            try MessageRecord
                .filter(Column("channelID") == channelID && Column("topic") == topic)
                .order(Column("id"))
                .fetchAll(db)
        }
    }

    public func observeMessages(dmKey: String) -> ValueObservation<ValueReducers.Fetch<[MessageRecord]>> {
        ValueObservation.tracking { db in
            try MessageRecord
                .filter(Column("dmKey") == dmKey)
                .order(Column("id"))
                .fetchAll(db)
        }
    }

    public func observeUsers() -> ValueObservation<ValueReducers.Fetch<[UserRecord]>> {
        ValueObservation.tracking { db in try UserRecord.fetchAll(db) }
    }

    public func reactions(forMessage id: Int) throws -> [ReactionRecord] {
        try writer.read { db in
            try ReactionRecord.filter(Column("messageID") == id).fetchAll(db)
        }
    }

    public func markRead(messageIDs: [Int]) throws {
        try writer.write { db in
            try MessageRecord
                .filter(messageIDs.contains(Column("id")))
                .updateAll(db, Column("isRead").set(to: true))
        }
    }
}

// MARK: - Mutations the sync engine needs, so GRDB stays inside this target

extension ZuluStore {

    public func channels() throws -> [ChannelRecord] {
        try writer.read { db in try ChannelRecord.fetchAll(db) }
    }

    public func deleteMessages(ids: [Int]) throws {
        try writer.write { db in
            try MessageRecord.filter(ids.contains(Column("id"))).deleteAll(db)
        }
    }

    public func setRead(ids: [Int], read: Bool) throws {
        try writer.write { db in
            try MessageRecord
                .filter(ids.contains(Column("id")))
                .updateAll(db, Column("isRead").set(to: read))
        }
    }

    public func updateRenderedContent(id: Int, html: String) throws {
        try writer.write { db in
            try MessageRecord
                .filter(Column("id") == id)
                .updateAll(db, Column("renderedContent").set(to: html))
        }
    }

    public func setReaction(_ reaction: Reaction, onMessage id: Int, added: Bool) throws {
        try writer.write { db in
            if added {
                try ReactionRecord(messageID: id, reaction: reaction).save(db)
            } else {
                try ReactionRecord
                    .filter(Column("messageID") == id
                        && Column("emojiCode") == reaction.emoji_code
                        && Column("reactionType") == reaction.reaction_type
                        && Column("userID") == reaction.user_id)
                    .deleteAll(db)
            }
        }
    }
}

extension ZuluStore {
    /// The most recently active topics across every channel, so the sidebar can show a
    /// channel's live conversations without a query per channel.
    public func observeRecentTopics(perChannel limit: Int = 3)
        -> ValueObservation<ValueReducers.Fetch<[TopicSummary]>>
    {
        ValueObservation.tracking { db in
            try TopicSummary.fetchAll(db, sql: """
                SELECT t.channelID, t.name, t.maxMessageID,
                       (SELECT COUNT(*) FROM unread u
                         WHERE u.channelID = t.channelID AND u.topic = t.name) AS unreadCount,
                       (SELECT m.senderName FROM message m
                         WHERE m.channelID = t.channelID AND m.topic = t.name
                         ORDER BY m.id DESC LIMIT 1) AS lastSender,
                       (SELECT m.timestamp FROM message m
                         WHERE m.channelID = t.channelID AND m.topic = t.name
                         ORDER BY m.id DESC LIMIT 1) AS lastTimestamp
                  FROM topic t
                 WHERE t.name NOT IN (
                           SELECT topic FROM promotedTopic WHERE channelID = t.channelID
                       )
                   AND (
                        SELECT COUNT(*) FROM topic peer
                         WHERE peer.channelID = t.channelID
                           AND peer.maxMessageID > t.maxMessageID
                       ) < ?
                 ORDER BY t.channelID, t.maxMessageID DESC
                """, arguments: [limit])
        }
    }
}
