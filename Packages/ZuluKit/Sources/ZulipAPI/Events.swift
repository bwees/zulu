import Foundation

public struct RegisterResponse: Decodable, Sendable {
    public let queue_id: String?
    public let last_event_id: Int
    public let zulip_feature_level: Int?
    public let subscriptions: [Subscription]?
    public let realm_users: [ZulipUser]?
    public let max_message_length: Int?
}

/// Only the events Zulu acts on today. Anything else decodes to `.other` and is skipped,
/// which is also how the client survives a server newer than it is.
public enum ZulipEvent: Sendable {
    case message(ZulipMessage)
    case updateMessage(id: Int, renderedContent: String?)
    case deleteMessage(ids: [Int])
    case flags(operation: String, flag: String, messageIDs: [Int])
    case reaction(added: Bool, messageID: Int, reaction: Reaction)
    case subscriptionsChanged
    case heartbeat
    case other(String)

    public var eventType: String {
        switch self {
        case .message: "message"
        case .updateMessage: "update_message"
        case .deleteMessage: "delete_message"
        case .flags: "update_message_flags"
        case .reaction: "reaction"
        case .subscriptionsChanged: "subscription"
        case .heartbeat: "heartbeat"
        case .other(let name): name
        }
    }
}

struct EventEnvelope: Decodable {
    let id: Int
    let type: String
    let message: ZulipMessage?
    let message_id: Int?
    let message_ids: [Int]?
    let rendered_content: String?
    let operation: String?
    let op: String?
    let flag: String?
    let emoji_name: String?
    let emoji_code: String?
    let reaction_type: String?
    let user_id: Int?

    func decoded() -> ZulipEvent {
        switch type {
        case "message":
            if let message { return .message(message) }
        case "update_message":
            if let id = message_id { return .updateMessage(id: id, renderedContent: rendered_content) }
        case "delete_message":
            return .deleteMessage(ids: message_ids ?? [message_id].compactMap { $0 })
        case "update_message_flags":
            if let flag, let ids = message_ids {
                return .flags(operation: operation ?? op ?? "add", flag: flag, messageIDs: ids)
            }
        case "reaction":
            if let messageID = message_id, let name = emoji_name, let code = emoji_code,
               let kind = reaction_type, let user = user_id {
                return .reaction(
                    added: (op ?? operation) == "add",
                    messageID: messageID,
                    reaction: Reaction(emoji_name: name, emoji_code: code, reaction_type: kind, user_id: user)
                )
            }
        case "subscription", "stream":
            return .subscriptionsChanged
        case "heartbeat":
            return .heartbeat
        default:
            break
        }
        return .other(type)
    }
}

private struct EventsResponse: Decodable { let events: [EventEnvelope] }

public struct EventBatch: Sendable {
    public let events: [ZulipEvent]
    /// Ids increase but skip, because the server compresses flag events inside the queue.
    /// Track the maximum rather than assuming the next one is `+1`.
    public let lastEventID: Int
}

extension ZulipClient {

    public func register(eventTypes: [String] = [
        "message", "update_message", "delete_message", "update_message_flags",
        "reaction", "subscription", "stream", "realm_user", "user_topic",
    ]) async throws -> RegisterResponse {
        try await send(.post, "register", parameters: [
            "apply_markdown": "true",
            "client_gravatar": "false",
            "slim_presence": "true",
            "event_types": Self.json(eventTypes),
            "fetch_event_types": Self.json(["subscription", "realm_user", "realm"]),
            "include_subscribers": "false",
        ])
    }

    /// Long-polls. The server holds the socket open and answers with a heartbeat rather
    /// than an empty array, so the timeout here is deliberately longer than the server's.
    public func events(queueID: String, lastEventID: Int) async throws -> EventBatch {
        let response: EventsResponse = try await send(
            .get, "events",
            parameters: ["queue_id": queueID, "last_event_id": String(lastEventID)],
            timeout: 120
        )
        let highest = response.events.map(\.id).max() ?? lastEventID
        return EventBatch(events: response.events.map { $0.decoded() }, lastEventID: highest)
    }

    public func deleteQueue(queueID: String) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await send(.delete, "events", parameters: ["queue_id": queueID])
    }
}
