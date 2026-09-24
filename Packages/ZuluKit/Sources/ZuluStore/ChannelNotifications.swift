import Foundation
import GRDB
import ZulipAPI

/// How loudly a topic, channel or group notifies. Zulip has no single setting for this,
/// so a channel's level is a combination of its subscription properties and a topic's
/// is its visibility policy. `nil` wherever one of these is optional means "inherit".
public enum NotificationLevel: Int, Sendable, CaseIterable {
    case all
    case mentions
    case muted

    public init(isMuted: Bool, pushNotifications: Bool?) {
        if isMuted {
            self = .muted
        } else if pushNotifications == true {
            self = .all
        } else {
            self = .mentions
        }
    }

    /// `inherit` has no level of its own, which is why this is failable.
    public init?(topicPolicy: TopicVisibilityPolicy) {
        switch topicPolicy {
        case .followed: self = .all
        case .unmuted: self = .mentions
        case .muted: self = .muted
        case .inherit: return nil
        }
    }

    public var isMuted: Bool { self == .muted }
    public var pushNotifications: Bool { self == .all }

    /// Following a topic is how Zulip notifies for every message in it, and unmuting is
    /// how a topic hears mentions inside a muted channel.
    public var topicPolicy: TopicVisibilityPolicy {
        switch self {
        case .all: .followed
        case .mentions: .unmuted
        case .muted: .muted
        }
    }

    public var label: String {
        switch self {
        case .all: "All Messages"
        case .mentions: "Mentions Only"
        case .muted: "Muted"
        }
    }
}

/// The channel settings Zulip would have with nothing chosen anywhere.
extension NotificationLevel {
    public static let zulipDefault = NotificationLevel.mentions
}

/// Every topic whose visibility is not `inherit`. Zulip owns it; this mirrors
/// `user_topics` beside `mutedTopic`, which the unread queries read.
struct TopicPolicyRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "topicPolicy"

    var channelID: Int
    var topic: String
    var policy: Int
}

extension ZuluStore {

    static func registerChannelNotificationMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v12-channel-push") { db in
            try db.alter(table: "channel") { t in
                t.add(column: "pushNotifications", .boolean)
            }
        }
        migrator.registerMigration("v13-notification-levels") { db in
            try db.alter(table: "channel") { t in
                // The viewer's own choice for this channel. Nil follows its group.
                t.add(column: "notificationOverride", .integer)
            }
            try db.alter(table: "channelGroup") { t in
                t.add(column: "notificationLevel", .integer)
            }
            try db.create(table: "topicPolicy") { t in
                t.column("channelID", .integer).notNull()
                t.column("topic", .text).notNull().collate(.nocase)
                t.column("policy", .integer).notNull()
                t.primaryKey(["channelID", "topic"])
            }
        }
    }

    // MARK: channels

    /// What Zulip currently has for the channel, whatever put it there.
    public func notificationLevel(forChannel id: Int) throws -> NotificationLevel? {
        try writer.read { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT isMuted, pushNotifications FROM channel WHERE id = ?", arguments: [id]
            ) else { return nil }
            return NotificationLevel(isMuted: row["isMuted"], pushNotifications: row["pushNotifications"])
        }
    }

    /// Written ahead of the server so the menu shows the new choice straight away. The
    /// next subscription event overwrites it with whatever the server kept.
    public func setNotificationLevel(_ level: NotificationLevel, forChannel id: Int) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE channel SET isMuted = ?, pushNotifications = ? WHERE id = ?",
                arguments: [level.isMuted, level.pushNotifications, id]
            )
        }
    }

    public func notificationOverride(forChannel id: Int) throws -> NotificationLevel? {
        try writer.read { db in
            try Int.fetchOne(
                db, sql: "SELECT notificationOverride FROM channel WHERE id = ?", arguments: [id]
            ).flatMap(NotificationLevel.init(rawValue:))
        }
    }

    public func setNotificationOverride(_ level: NotificationLevel?, forChannel id: Int) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE channel SET notificationOverride = ? WHERE id = ?",
                arguments: [level?.rawValue, id]
            )
        }
    }

    /// The level a channel should have: its own choice, else its group's. Nil when
    /// neither has one, which leaves Zulip's settings alone.
    public func effectiveNotificationLevel(forChannel id: Int) throws -> NotificationLevel? {
        try writer.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COALESCE(c.notificationOverride, g.notificationLevel)
                  FROM channel c
                  LEFT JOIN channelGroupMember m ON m.channelID = c.id
                  LEFT JOIN channelGroup g ON g.id = m.groupID
                 WHERE c.id = ?
                """, arguments: [id]).flatMap(NotificationLevel.init(rawValue:))
        }
    }

    // MARK: groups

    public func notificationLevel(forGroup id: String) throws -> NotificationLevel? {
        try writer.read { db in
            try Int.fetchOne(
                db, sql: "SELECT notificationLevel FROM channelGroup WHERE id = ?", arguments: [id]
            ).flatMap(NotificationLevel.init(rawValue:))
        }
    }

    public func setNotificationLevel(_ level: NotificationLevel?, forGroup id: String) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE channelGroup SET notificationLevel = ? WHERE id = ?",
                arguments: [level?.rawValue, id]
            )
        }
    }

    /// The group's channels that have no level of their own, which are the ones a
    /// change to the group reaches.
    public func channelsFollowing(group id: String) throws -> [Int] {
        try writer.read { db in
            try Int.fetchAll(db, sql: """
                SELECT m.channelID FROM channelGroupMember m
                  JOIN channel c ON c.id = m.channelID
                 WHERE m.groupID = ? AND c.notificationOverride IS NULL
                """, arguments: [id])
        }
    }

    // MARK: topics

    public func notificationLevel(forTopic topic: String, inChannel channelID: Int) throws -> NotificationLevel? {
        try writer.read { db in
            try Int.fetchOne(
                db, sql: "SELECT policy FROM topicPolicy WHERE channelID = ? AND topic = ?",
                arguments: [channelID, topic]
            )
            .flatMap(TopicVisibilityPolicy.init(rawValue:))
            .flatMap(NotificationLevel.init(topicPolicy:))
        }
    }

    public func setTopicPolicy(_ policy: TopicVisibilityPolicy, topic: String, inChannel channelID: Int) throws {
        try writer.write { db in try Self.setTopicPolicy(policy, topic: topic, inChannel: channelID, db) }
        try setMuted(policy == .muted, topic: topic, inChannel: channelID)
    }

    static func setTopicPolicy(
        _ policy: TopicVisibilityPolicy, topic: String, inChannel channelID: Int, _ db: Database
    ) throws {
        if policy == .inherit {
            try TopicPolicyRecord
                .filter(Column("channelID") == channelID && Column("topic") == topic)
                .deleteAll(db)
        } else {
            try TopicPolicyRecord(channelID: channelID, topic: topic, policy: policy.rawValue).save(db)
        }
    }
}
