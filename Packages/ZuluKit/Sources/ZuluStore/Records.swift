import Foundation
import GRDB
import ZulipAPI

public struct ChannelRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable, Equatable {
    public static let databaseTableName = "channel"

    public var id: Int
    public var name: String
    public var description: String?
    public var color: String?
    public var isRestricted: Bool
    public var isMuted: Bool
    public var pinned: Bool

    public init(from subscription: Subscription) {
        id = subscription.stream_id
        name = subscription.name
        description = subscription.description
        color = subscription.color
        isRestricted = subscription.isRestricted
        isMuted = subscription.is_muted ?? false
        pinned = subscription.pin_to_top ?? false
    }
}

public struct TopicRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable, Identifiable {
    public static let databaseTableName = "topic"

    public var channelID: Int
    public var name: String
    public var maxMessageID: Int

    public var id: String { "\(channelID)/\(name)" }

    public init(channelID: Int, name: String, maxMessageID: Int) {
        self.channelID = channelID
        self.name = name
        self.maxMessageID = maxMessageID
    }
}

public struct MessageRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable, Equatable {
    public static let databaseTableName = "message"

    public var id: Int
    public var channelID: Int?
    public var topic: String?
    /// Sorted, comma-joined participant ids. Identifies a DM conversation without a
    /// separate table, and stays stable regardless of who sent which message.
    public var dmKey: String?
    public var senderID: Int
    public var senderName: String
    public var senderAvatar: String?
    public var renderedContent: String
    public var timestamp: Int
    public var isRead: Bool
    public var isMentioned: Bool
    public var editedAt: Int?

    public var date: Date { Date(timeIntervalSince1970: TimeInterval(timestamp)) }

    public init(
        id: Int,
        channelID: Int? = nil,
        topic: String? = nil,
        dmKey: String? = nil,
        senderID: Int,
        senderName: String,
        senderAvatar: String? = nil,
        renderedContent: String,
        timestamp: Int,
        isRead: Bool = false,
        isMentioned: Bool = false,
        editedAt: Int? = nil
    ) {
        self.id = id
        self.channelID = channelID
        self.topic = topic
        self.dmKey = dmKey
        self.senderID = senderID
        self.senderName = senderName
        self.senderAvatar = senderAvatar
        self.renderedContent = renderedContent
        self.timestamp = timestamp
        self.isRead = isRead
        self.isMentioned = isMentioned
        self.editedAt = editedAt
    }

    public init(from message: ZulipMessage, selfUserID: Int) {
        id = message.id
        senderID = message.sender_id
        senderName = message.sender_full_name
        senderAvatar = message.avatar_url
        renderedContent = message.content
        timestamp = message.timestamp
        isRead = message.isRead
        isMentioned = message.isMentioned
        editedAt = message.last_edit_timestamp

        if message.isChannelMessage {
            channelID = message.stream_id
            topic = message.subject
            dmKey = nil
        } else {
            channelID = nil
            topic = nil
            dmKey = Self.dmKey(for: message.dmParticipants.map(\.id), selfUserID: selfUserID)
        }
    }

    /// Includes every participant, the viewer included, so a note-to-self has a key too.
    public static func dmKey(for participantIDs: [Int], selfUserID: Int) -> String {
        var ids = Set(participantIDs)
        ids.insert(selfUserID)
        return ids.sorted().map(String.init).joined(separator: ",")
    }
}

public struct UserRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable, Equatable {
    public static let databaseTableName = "user"

    public var id: Int
    public var fullName: String
    public var email: String?
    public var avatarURL: String?
    public var isBot: Bool

    public init(from user: ZulipUser) {
        id = user.user_id
        fullName = user.full_name
        email = user.email
        avatarURL = user.avatar_url
        isBot = user.is_bot ?? false
    }

    public init(id: Int, fullName: String, email: String? = nil, avatarURL: String? = nil, isBot: Bool = false) {
        self.id = id
        self.fullName = fullName
        self.email = email
        self.avatarURL = avatarURL
        self.isBot = isBot
    }
}

public struct ReactionRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "reaction"

    public var messageID: Int
    public var emojiName: String
    public var emojiCode: String
    public var reactionType: String
    public var userID: Int

    public init(messageID: Int, reaction: Reaction) {
        self.messageID = messageID
        emojiName = reaction.emoji_name
        emojiCode = reaction.emoji_code
        reactionType = reaction.reaction_type
        userID = reaction.user_id
    }
}

/// Where the event queue left off, so a relaunch resumes instead of refetching.
public struct SyncStateRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "syncState"

    public var id: Int = 1
    public var queueID: String?
    public var lastEventID: Int

    public init(queueID: String?, lastEventID: Int) {
        self.queueID = queueID
        self.lastEventID = lastEventID
    }
}
