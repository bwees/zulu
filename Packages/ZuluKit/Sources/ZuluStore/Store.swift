import Foundation
import GRDB
import ZulipAPI

/// The local-first store. Sync writes into it, the UI only ever reads out of it.
public final class ZuluStore: Sendable {
    public let writer: any DatabaseWriter

    /// Pass `nil` for an in-memory store.
    ///
    /// Takes a URL rather than a path because the app's container lives under
    /// "Application Support", and `URL.path()` percent-encodes that space into
    /// something SQLite cannot open.
    public init(url: URL?) throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        if let url {
            writer = try DatabasePool(path: url.path(percentEncoded: false), configuration: configuration)
        } else {
            writer = try DatabaseQueue(configuration: configuration)
        }
        try Self.migrator.migrate(writer)
    }

    public static func defaultURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let folder = base.appending(path: "Zulu", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "zulu.sqlite")
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "channel") { t in
                t.primaryKey("id", .integer)
                t.column("name", .text).notNull()
                t.column("description", .text)
                t.column("color", .text)
                t.column("isRestricted", .boolean).notNull().defaults(to: false)
                t.column("isMuted", .boolean).notNull().defaults(to: false)
                t.column("pinned", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "topic") { t in
                t.column("channelID", .integer).notNull()
                    .references("channel", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("maxMessageID", .integer).notNull()
                t.primaryKey(["channelID", "name"])
            }

            try db.create(table: "user") { t in
                t.primaryKey("id", .integer)
                t.column("fullName", .text).notNull()
                t.column("email", .text)
                t.column("avatarURL", .text)
                t.column("isBot", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "message") { t in
                t.primaryKey("id", .integer)
                t.column("channelID", .integer)
                t.column("topic", .text)
                t.column("dmKey", .text)
                t.column("senderID", .integer).notNull()
                t.column("senderName", .text).notNull()
                t.column("senderAvatar", .text)
                t.column("renderedContent", .text).notNull()
                t.column("timestamp", .integer).notNull()
                t.column("isRead", .boolean).notNull().defaults(to: false)
                t.column("isMentioned", .boolean).notNull().defaults(to: false)
                t.column("editedAt", .integer)
            }
            try db.create(index: "message_conversation", on: "message", columns: ["channelID", "topic", "id"])
            try db.create(index: "message_dm", on: "message", columns: ["dmKey", "id"])

            try db.create(table: "reaction") { t in
                t.column("messageID", .integer).notNull()
                    .references("message", onDelete: .cascade)
                t.column("emojiName", .text).notNull()
                t.column("emojiCode", .text).notNull()
                t.column("reactionType", .text).notNull()
                t.column("userID", .integer).notNull()
                t.primaryKey(["messageID", "reactionType", "emojiCode", "userID"])
            }

            try db.create(table: "syncState") { t in
                t.primaryKey("id", .integer)
                t.column("queueID", .text)
                t.column("lastEventID", .integer).notNull()
            }
        }

        return migrator
    }

    // MARK: writes

    public func replaceChannels(_ subscriptions: [Subscription]) throws {
        try writer.write { db in
            let keep = Set(subscriptions.map(\.stream_id))
            for existing in try ChannelRecord.fetchAll(db) where !keep.contains(existing.id) {
                try existing.delete(db)
            }
            for subscription in subscriptions {
                try ChannelRecord(from: subscription).save(db)
            }
        }
    }

    public func saveTopics(_ topics: [ChannelTopic], inChannel id: Int) throws {
        try writer.write { db in
            for topic in topics {
                try TopicRecord(channelID: id, name: topic.name, maxMessageID: topic.max_id).save(db)
            }
        }
    }

    public func saveUsers(_ users: [ZulipUser]) throws {
        try writer.write { db in
            for user in users { try UserRecord(from: user).save(db) }
        }
    }

    public func save(messages: [ZulipMessage], selfUserID: Int) throws {
        try writer.write { db in
            for message in messages {
                try Self.write(message, selfUserID: selfUserID, in: db)
            }
        }
    }

    static func write(_ message: ZulipMessage, selfUserID: Int, in db: Database) throws {
        try MessageRecord(from: message, selfUserID: selfUserID).save(db)
        try ReactionRecord
            .filter(Column("messageID") == message.id)
            .deleteAll(db)
        for reaction in message.reactions {
            try ReactionRecord(messageID: message.id, reaction: reaction).save(db)
        }
        // A DM's participants are the only place some users appear, so they are learned here.
        for participant in message.dmParticipants where try UserRecord.fetchOne(db, key: participant.id) == nil {
            try UserRecord(id: participant.id, fullName: participant.full_name, email: participant.email).save(db)
        }
        if try UserRecord.fetchOne(db, key: message.sender_id) == nil {
            try UserRecord(
                id: message.sender_id,
                fullName: message.sender_full_name,
                email: message.sender_email,
                avatarURL: message.avatar_url
            ).save(db)
        }
        if message.isChannelMessage, let channelID = message.stream_id {
            let existing = try TopicRecord
                .filter(Column("channelID") == channelID && Column("name") == message.subject)
                .fetchOne(db)
            if existing == nil || existing!.maxMessageID < message.id {
                try TopicRecord(channelID: channelID, name: message.subject, maxMessageID: message.id).save(db)
            }
        }
    }

    public func syncState() throws -> SyncStateRecord? {
        try writer.read { db in try SyncStateRecord.fetchOne(db, key: 1) }
    }

    public func saveSyncState(queueID: String?, lastEventID: Int) throws {
        try writer.write { db in
            try SyncStateRecord(queueID: queueID, lastEventID: lastEventID).save(db)
        }
    }

    public func clearAll() throws {
        try writer.write { db in
            for table in ["reaction", "message", "topic", "channel", "user", "syncState"] {
                try db.execute(sql: "DELETE FROM \(table)")
            }
        }
    }
}
