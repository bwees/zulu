import Foundation
import GRDB
import ZulipAPI
import ZuluEmoji

/// A realm custom emoji, deactivated ones included.
///
/// Deactivated emoji are kept because reactions and rendered messages still point at
/// them, and because the name is not a stable key — the server's uniqueness constraint
/// only covers active emoji, so a name can be handed to a different emoji later.
public struct RealmEmojiRecord: Codable, FetchableRecord, PersistableRecord, Sendable,
    Identifiable, Equatable
{
    public static let databaseTableName = "realmEmoji"

    /// The server's stringified emoji id, which is also the reaction's `emoji_code`.
    public var id: String
    public var name: String
    public var sourceURL: String
    public var stillURL: String?
    public var deactivated: Bool

    public init(from emoji: RealmEmoji) {
        id = emoji.id
        name = emoji.name
        sourceURL = emoji.source_url
        stillURL = emoji.still_url
        deactivated = emoji.deactivated ?? false
    }

    public init(id: String, name: String, sourceURL: String, stillURL: String? = nil, deactivated: Bool = false) {
        self.id = id
        self.name = name
        self.sourceURL = sourceURL
        self.stillURL = stillURL
        self.deactivated = deactivated
    }

    public var item: RealmEmojiItem {
        RealmEmojiItem(
            code: id, name: name, sourceURL: sourceURL, stillURL: stillURL, deactivated: deactivated
        )
    }
}

/// The server's unicode emoji table, cached whole.
///
/// It is one static file that only changes when the server is upgraded, so it is stored
/// as the bytes that came back rather than a table of names: nothing queries it in SQL,
/// and keeping the ETag next to the body is what makes the next fetch conditional.
public struct ServerEmojiDataRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "serverEmojiData"

    public var id: Int = 1
    public var url: String
    public var etag: String?
    public var json: Data

    public init(url: String, etag: String?, json: Data) {
        self.url = url
        self.etag = etag
        self.json = json
    }
}

/// A realm user group, which `@` can mention.
public struct UserGroupRecord: Codable, FetchableRecord, PersistableRecord, Sendable,
    Identifiable, Equatable
{
    public static let databaseTableName = "userGroup"

    public var id: Int
    public var name: String
    public var groupDescription: String?
    public var isSystemGroup: Bool
    /// Whether `can_mention_group` admits this viewer, worked out once when the groups
    /// are written because answering it needs every group at once.
    public var isMentionable: Bool

    public init(
        id: Int, name: String, groupDescription: String? = nil,
        isSystemGroup: Bool = false, isMentionable: Bool = true
    ) {
        self.id = id
        self.name = name
        self.groupDescription = groupDescription
        self.isSystemGroup = isSystemGroup
        self.isMentionable = isMentionable
    }
}

/// Who is subscribed to a channel. Only the ids: this exists to rank the people in a
/// channel's `@` list above everyone else, not to render a member list.
public struct ChannelSubscriberRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "channelSubscriber"

    public var channelID: Int
    public var userID: Int

    public init(channelID: Int, userID: Int) {
        self.channelID = channelID
        self.userID = userID
    }
}

extension DatabaseMigrator {
    mutating func registerEmojiMigration() {
        registerMigration("v6-emoji") { db in
            try db.create(table: "realmEmoji") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("sourceURL", .text).notNull()
                t.column("stillURL", .text)
                t.column("deactivated", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "serverEmojiData") { t in
                t.primaryKey("id", .integer)
                t.column("url", .text).notNull()
                t.column("etag", .text)
                t.column("json", .blob).notNull()
            }

            try db.create(table: "userGroup") { t in
                t.primaryKey("id", .integer)
                t.column("name", .text).notNull()
                t.column("groupDescription", .text)
                t.column("isSystemGroup", .boolean).notNull().defaults(to: false)
                t.column("isMentionable", .boolean).notNull().defaults(to: true)
            }

            try db.create(table: "channelSubscriber") { t in
                t.column("channelID", .integer).notNull()
                t.column("userID", .integer).notNull()
                t.primaryKey(["channelID", "userID"])
            }
        }
    }
}

/// The two halves of the catalogue, as they sit in the database. The unicode table is
/// still the raw JSON here so that a change to either half is one observation.
public struct EmojiSources: Sendable, Equatable {
    public var unicode: Data?
    public var realm: [RealmEmojiRecord]
}

// MARK: - Emoji

extension ZuluStore {

    /// Replaces the realm's emoji wholesale, which is the only shape the legacy
    /// `realm_emoji` event comes in — it resends the entire map on every change.
    public func replaceRealmEmoji(_ emoji: [String: RealmEmoji]) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM realmEmoji")
            for item in emoji.values { try RealmEmojiRecord(from: item).save(db) }
        }
    }

    public func realmEmoji() throws -> [RealmEmojiRecord] {
        try writer.read { db in try RealmEmojiRecord.fetchAll(db) }
    }

    public func cachedServerEmojiData() throws -> ServerEmojiDataRecord? {
        try writer.read { db in try ServerEmojiDataRecord.fetchOne(db, key: 1) }
    }

    public func saveServerEmojiData(url: String, etag: String?, json: Data) throws {
        try writer.write { db in
            try ServerEmojiDataRecord(url: url, etag: etag, json: json).save(db)
        }
    }

    /// Everything the catalogue is built from, in one read.
    public func observeEmojiSources() -> ValueObservation<ValueReducers.Fetch<EmojiSources>> {
        ValueObservation.tracking { db in
            EmojiSources(
                unicode: try ServerEmojiDataRecord.fetchOne(db, key: 1)?.json,
                realm: try RealmEmojiRecord.fetchAll(db)
            )
        }
    }
}

// MARK: - Mentionable things

extension ZuluStore {

    public func replaceUserGroups(_ groups: [RealmUserGroup], selfUserID: Int) throws {
        let mentionable = RealmUserGroup.mentionable(among: groups, by: selfUserID)
        try writer.write { db in
            try db.execute(sql: "DELETE FROM userGroup")
            for group in groups {
                try UserGroupRecord(
                    id: group.id,
                    name: group.name,
                    groupDescription: group.description,
                    isSystemGroup: group.is_system_group ?? false,
                    isMentionable: mentionable.contains(group.id)
                ).save(db)
            }
        }
    }

    public func userGroups() throws -> [UserGroupRecord] {
        try writer.read { db in try UserGroupRecord.fetchAll(db) }
    }

    public func replaceSubscribers(_ subscriptions: [Subscription]) throws {
        try writer.write { db in
            for subscription in subscriptions {
                guard let subscribers = subscription.subscribers else { continue }
                try ChannelSubscriberRecord
                    .filter(Column("channelID") == subscription.stream_id)
                    .deleteAll(db)
                for user in subscribers {
                    try ChannelSubscriberRecord(channelID: subscription.stream_id, userID: user).save(db)
                }
            }
        }
    }

    public func subscriberIDs(inChannel id: Int) throws -> Set<Int> {
        try writer.read { db in
            Set(try Int.fetchAll(
                db, sql: "SELECT userID FROM channelSubscriber WHERE channelID = ?", arguments: [id]
            ))
        }
    }

    /// The newest message each person sent in a conversation, which is how recency ranks
    /// the `@` list. Ids increase with time, so the id is the timestamp.
    public func latestMessageIDsBySender(channelID: Int, topic: String? = nil) throws -> [Int: Int] {
        try writer.read { db in
            let rows: [Row]
            if let topic {
                rows = try Row.fetchAll(db, sql: """
                    SELECT senderID, MAX(id) AS latest FROM message
                     WHERE channelID = ? AND topic = ? GROUP BY senderID
                    """, arguments: [channelID, topic])
            } else {
                rows = try Row.fetchAll(db, sql: """
                    SELECT senderID, MAX(id) AS latest FROM message
                     WHERE channelID = ? GROUP BY senderID
                    """, arguments: [channelID])
            }
            var latest: [Int: Int] = [:]
            for row in rows {
                let sender: Int = row["senderID"]
                latest[sender] = row["latest"]
            }
            return latest
        }
    }

    /// The newest direct message exchanged with each person, whoever sent it — a
    /// conversation is recent because it happened, not because of who spoke last.
    public func latestDirectMessageIDsByPerson(selfUserID: Int) throws -> [Int: Int] {
        try writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT dmKey, MAX(id) AS latest FROM message
                 WHERE dmKey IS NOT NULL GROUP BY dmKey
                """)
            var latest: [Int: Int] = [:]
            for row in rows {
                let key: String = row["dmKey"]
                let id: Int = row["latest"]
                for participant in key.split(separator: ",").compactMap({ Int($0) })
                where participant != selfUserID {
                    latest[participant] = max(latest[participant] ?? 0, id)
                }
            }
            return latest
        }
    }
}
