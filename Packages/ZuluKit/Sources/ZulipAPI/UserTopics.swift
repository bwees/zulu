import Foundation

/// Zulip's integers for `UserTopic.visibility_policy`.
public enum TopicVisibilityPolicy: Int, Sendable {
    case inherit = 0
    case muted = 1
    case unmuted = 2
    case followed = 3
}

public struct UserTopic: Decodable, Sendable {
    public let stream_id: Int
    public let topic_name: String
    public let visibility_policy: Int

    public init(stream_id: Int, topic_name: String, visibility_policy: Int) {
        self.stream_id = stream_id
        self.topic_name = topic_name
        self.visibility_policy = visibility_policy
    }

    public var policy: TopicVisibilityPolicy? { TopicVisibilityPolicy(rawValue: visibility_policy) }
}

extension ZulipClient {
    public func setTopicVisibility(
        _ policy: TopicVisibilityPolicy, topic: String, inChannel channelID: Int
    ) async throws {
        _ = try await raw(.post, "user_topics", parameters: [
            "stream_id": String(channelID),
            "topic": topic,
            "visibility_policy": String(policy.rawValue),
        ])
    }
}
