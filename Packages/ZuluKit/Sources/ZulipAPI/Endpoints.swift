import Foundation

public struct MessagesPage: Decodable, Sendable {
    public let messages: [ZulipMessage]
    public let found_oldest: Bool
    public let found_newest: Bool
    /// The realm's retention policy truncated the old end. Distinct from `found_oldest`.
    public let history_limited: Bool?
    public let anchor: Int?
}

private struct SubscriptionsResponse: Decodable { let subscriptions: [Subscription] }
private struct TopicsResponse: Decodable { let topics: [ChannelTopic] }
private struct SendMessageResponse: Decodable { let id: Int }

extension ZulipClient {

    public enum Anchor: Sendable {
        case newest, oldest, firstUnread
        case id(Int)

        var wire: String {
            switch self {
            case .newest: "newest"
            case .oldest: "oldest"
            case .firstUnread: "first_unread"
            case .id(let value): String(value)
            }
        }
    }

    public func subscriptions() async throws -> [Subscription] {
        let response: SubscriptionsResponse = try await send(.get, "users/me/subscriptions")
        return response.subscriptions
    }

    public func topics(inChannel id: Int) async throws -> [ChannelTopic] {
        let response: TopicsResponse = try await send(.get, "users/me/\(id)/topics")
        return response.topics
    }

    public func messages(
        narrow: [NarrowFilter] = [],
        anchor: Anchor = .newest,
        before: Int = 50,
        after: Int = 0,
        includeAnchor: Bool = true
    ) async throws -> MessagesPage {
        try await send(.get, "messages", parameters: [
            "anchor": anchor.wire,
            "include_anchor": includeAnchor ? "true" : "false",
            "num_before": String(before),
            "num_after": String(after),
            "narrow": Self.json(narrow),
            "apply_markdown": "true",
            "client_gravatar": "false",
        ])
    }

    public func sendMessage(toChannel id: Int, topic: String, content: String) async throws -> Int {
        let response: SendMessageResponse = try await send(.post, "messages", parameters: [
            "type": "stream",
            "to": String(id),
            "topic": topic,
            "content": content,
        ])
        return response.id
    }

    public func sendMessage(toUsers ids: [Int], content: String) async throws -> Int {
        let response: SendMessageResponse = try await send(.post, "messages", parameters: [
            "type": "private",
            "to": Self.json(ids),
            "content": content,
        ])
        return response.id
    }

    /// Appends one event to a message's widget log — a vote, a new option, a new question.
    ///
    /// The route is real and both official mobile clients use it, but it is absent from
    /// Zulip's OpenAPI spec and the subsystem is documented as experimental, so it carries
    /// no stability promise.
    public func sendSubmessage(messageID: Int, content: String, msgType: String = "widget") async throws {
        struct Empty: Decodable {}
        let _: Empty = try await send(.post, "submessage", parameters: [
            "message_id": String(messageID),
            "msg_type": msgType,
            "content": content,
        ])
    }

    public func markAllRead() async throws {
        struct Empty: Decodable {}
        let _: Empty = try await send(.post, "mark_all_as_read")
    }

    /// Fetches an image or file from the realm. Same-origin only: the API key must never
    /// ride along to Gravatar or a preview host.
    public func media(at path: String) async throws -> Data {
        guard path.hasPrefix("/") else { return Data() }
        let url = realmURL.appending(path: String(path.dropFirst()))
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let account {
            let pair = "\(account.email):\(account.apiKey)"
            request.setValue("Basic \(Data(pair.utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        }
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }
}
