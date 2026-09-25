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
        migrator.registerMigration("v14-chosen-follows") { db in
            // Zulip follows topics on its own when you post in them. This holds the ones
            // set to All Messages on purpose, which are the only follows that notify
            // for every message.
            try db.create(table: "chosenFollow") { t in
                t.column("channelID", .integer).notNull()
                t.column("topic", .text).notNull().collate(.nocase)
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

    /// The topic's own level, or nil to follow its channel. A follow only counts when it
    /// was chosen here: one Zulip made by itself says nothing about how loud to be.
    public func notificationLevel(forTopic topic: String, inChannel channelID: Int) throws -> NotificationLevel? {
        try writer.read { db in
            let policy = try Self.topicPolicy(forTopic: topic, inChannel: channelID, db)
            if policy == .followed {
                return try Self.isChosenFollow(topic: topic, inChannel: channelID, db) ? .all : nil
            }
            return NotificationLevel(topicPolicy: policy)
        }
    }

    /// A level picked here: Zulip's policy for it, and whether the follow is a choice.
    public func setTopicLevel(_ level: NotificationLevel?, topic: String, inChannel channelID: Int) throws {
        try setTopicPolicy(level?.topicPolicy ?? .inherit, topic: topic, inChannel: channelID)
        try setChosenFollow(level == .all, topic: topic, inChannel: channelID)
    }

    /// What Zulip has for the topic, whoever set it.
    public func topicPolicy(forTopic topic: String, inChannel channelID: Int) throws -> TopicVisibilityPolicy {
        try writer.read { db in try Self.topicPolicy(forTopic: topic, inChannel: channelID, db) }
    }

    public func isChosenFollow(topic: String, inChannel channelID: Int) throws -> Bool {
        try writer.read { db in try Self.isChosenFollow(topic: topic, inChannel: channelID, db) }
    }

    public func setChosenFollow(_ chosen: Bool, topic: String, inChannel channelID: Int) throws {
        try writer.write { db in
            if chosen {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO chosenFollow (channelID, topic) VALUES (?, ?)",
                    arguments: [channelID, topic]
                )
            } else {
                try db.execute(
                    sql: "DELETE FROM chosenFollow WHERE channelID = ? AND topic = ?",
                    arguments: [channelID, topic]
                )
            }
        }
    }

    private static func topicPolicy(
        forTopic topic: String, inChannel channelID: Int, _ db: Database
    ) throws -> TopicVisibilityPolicy {
        try Int.fetchOne(
            db, sql: "SELECT policy FROM topicPolicy WHERE channelID = ? AND topic = ?",
            arguments: [channelID, topic]
        )
        .flatMap(TopicVisibilityPolicy.init(rawValue:)) ?? .inherit
    }

    private static func isChosenFollow(topic: String, inChannel channelID: Int, _ db: Database) throws -> Bool {
        try Int.fetchOne(
            db, sql: "SELECT 1 FROM chosenFollow WHERE channelID = ? AND topic = ?",
            arguments: [channelID, topic]
        ) != nil
    }

    /// A choice outlives its follow only until Zulip says the follow is gone. Otherwise
    /// a topic unfollowed elsewhere and later followed again by Zulip would hear every
    /// message again.
    static func forgetChoicesWithoutAFollow(_ db: Database) throws {
        try db.execute(sql: """
            DELETE FROM chosenFollow
             WHERE NOT EXISTS (
                SELECT 1 FROM topicPolicy p
                 WHERE p.channelID = chosenFollow.channelID AND p.topic = chosenFollow.topic
                   AND p.policy = ?
             )
            """, arguments: [TopicVisibilityPolicy.followed.rawValue])
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

/// Whether a message arriving on the live queue gets a banner on this device.
public struct BannerRule: Sendable, Equatable {
    public var directMessages: Bool
    public var mentions: Bool

    public init(directMessages: Bool, mentions: Bool) {
        self.directMessages = directMessages
        self.mentions = mentions
    }

    /// `level` is the topic's own level, else its channel's; nil for a direct message.
    public func allows(
        isDirect: Bool, isMentioned: Bool, isPersonallyMentioned: Bool, level: NotificationLevel?
    ) -> Bool {
        if isDirect { return directMessages }
        switch level ?? .zulipDefault {
        case .all:
            return true
        case .mentions:
            return mentions && isMentioned
        case .muted:
            // Zulip still delivers a mention by name from a muted channel or topic; an
            // `@all` stays quiet.
            return mentions && isPersonallyMentioned
        }
    }
}
