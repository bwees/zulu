import Foundation
import GRDB

/// A topic the viewer has lifted out of its channel to sit at channel level.
///
/// Zulip has no such concept, so like channel groups this is entirely the viewer's. A
/// promotion is a reference to a topic *name*, and Zulip topics are mutable in a way
/// channels are not — they get renamed, moved, and resolved — so a promotion has to
/// tolerate its target moving out from under it.
public struct PromotedTopicRecord: Codable, FetchableRecord, PersistableRecord, Sendable,
    Identifiable, Equatable
{
    public static let databaseTableName = "promotedTopic"

    public var channelID: Int
    public var topic: String
    /// A promoted topic can be filed away from its own channel — that is much of the point,
    /// since the reason to promote one is to put it where you actually look.
    public var groupID: String?
    public var position: Int

    public var id: String { "\(channelID)\u{1F}\(topic)" }

    public init(channelID: Int, topic: String, groupID: String? = nil, position: Int = 0) {
        self.channelID = channelID
        self.topic = topic
        self.groupID = groupID
        self.position = position
    }
}

/// A promoted topic with the counts and names the sidebar needs.
public struct PromotedTopicSummary: Decodable, FetchableRecord, Sendable, Identifiable, Equatable {
    public var channelID: Int
    public var topic: String
    public var groupID: String?
    public var channelName: String
    public var unreadCount: Int
    public var mentionCount: Int

    public var id: String { "\(channelID)\u{1F}\(topic)" }
    public var displayName: String { topic.isEmpty ? "general chat" : topic }
}

extension ZuluStore {

    static func registerPersonalShapeMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v8-personal-shape") { db in
            try db.alter(table: "channel") { t in
                // A name only this viewer sees. The server's name stays in `name`, because
                // a mention has to emit the real one to produce a working link.
                t.add(column: "alias", .text)
            }
            try db.create(table: "promotedTopic") { t in
                t.column("channelID", .integer).notNull()
                    .references("channel", onDelete: .cascade)
                t.column("topic", .text).notNull()
                t.column("groupID", .text).references("channelGroup", onDelete: .setNull)
                t.column("position", .integer).notNull().defaults(to: 0)
                t.primaryKey(["channelID", "topic"])
            }
        }
    }

    // MARK: aliases

    /// `nil` restores the server's own name.
    public func setAlias(_ alias: String?, forChannel id: Int) throws {
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        try writer.write { db in
            try db.execute(
                sql: "UPDATE channel SET alias = ? WHERE id = ?",
                arguments: [(trimmed?.isEmpty ?? true) ? nil : trimmed, id]
            )
        }
    }

    public func alias(forChannel id: Int) throws -> String? {
        try writer.read { db in
            try String.fetchOne(db, sql: "SELECT alias FROM channel WHERE id = ?", arguments: [id])
        }
    }

    // MARK: promotions

    public func promote(topic: String, inChannel channelID: Int, toGroup groupID: String? = nil) throws {
        try writer.write { db in
            let next = try Int.fetchOne(
                db, sql: "SELECT COALESCE(MAX(position), -1) + 1 FROM promotedTopic"
            ) ?? 0
            try PromotedTopicRecord(
                channelID: channelID, topic: topic, groupID: groupID, position: next
            ).save(db)
        }
    }

    public func demote(topic: String, inChannel channelID: Int) throws {
        try writer.write { db in
            try PromotedTopicRecord
                .filter(Column("channelID") == channelID && Column("topic") == topic)
                .deleteAll(db)
        }
    }

    public func isPromoted(topic: String, inChannel channelID: Int) throws -> Bool {
        try writer.read { db in
            try PromotedTopicRecord
                .filter(Column("channelID") == channelID && Column("topic") == topic)
                .fetchCount(db) > 0
        }
    }

    /// A promotion follows its topic when the server renames it. Without this the entry
    /// would quietly point at a name nobody uses any more.
    public func renamePromotedTopic(inChannel channelID: Int, from old: String, to new: String) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE OR REPLACE promotedTopic SET topic = ? WHERE channelID = ? AND topic = ?",
                arguments: [new, channelID, old]
            )
        }
    }

    /// Promotions whose topic no longer exists are dropped rather than left as dead rows in
    /// the sidebar. Called after a channel's topics are refetched, when the truth is known.
    public func pruneVanishedPromotions(inChannel channelID: Int) throws {
        try writer.write { db in
            try db.execute(sql: """
                DELETE FROM promotedTopic
                 WHERE channelID = ?
                   AND topic NOT IN (SELECT name FROM topic WHERE channelID = ?)
                """, arguments: [channelID, channelID])
        }
    }

    /// The promoted topics in one group, or — passing `nil` — the ones no group has claimed.
    public func observePromotedTopics(inGroup groupID: String?)
        -> ValueObservation<ValueReducers.Fetch<[PromotedTopicSummary]>>
    {
        let membership = groupID == nil ? "p.groupID IS NULL" : "p.groupID = ?"
        let arguments: StatementArguments = groupID.map { [$0] } ?? []

        return ValueObservation.tracking { db in
            try PromotedTopicSummary.fetchAll(db, sql: """
                SELECT p.channelID, p.topic, p.groupID,
                       COALESCE(c.alias, c.name) AS channelName,
                       (SELECT COUNT(*) FROM unread u
                         WHERE u.channelID = p.channelID AND u.topic = p.topic) AS unreadCount,
                       (SELECT COUNT(*) FROM unread u
                         WHERE u.channelID = p.channelID AND u.topic = p.topic
                           AND u.isMention = 1) AS mentionCount
                  FROM promotedTopic p
                  JOIN channel c ON c.id = p.channelID
                 WHERE \(membership)
                 ORDER BY p.position
                """, arguments: arguments)
        }
    }

    public func setGroup(_ groupID: String?, forPromotedTopic topic: String, inChannel channelID: Int) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE promotedTopic SET groupID = ? WHERE channelID = ? AND topic = ?",
                arguments: [groupID, channelID, topic]
            )
        }
    }
}
