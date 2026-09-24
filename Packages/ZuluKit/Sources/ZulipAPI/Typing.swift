import Foundation

public enum TypingOp: String, Sendable {
    case start
    case stop
}

/// Someone started or stopped composing. A channel event names its topic; a direct one
/// names everyone in the conversation, the sender included.
public struct TypingEvent: Sendable, Equatable {
    public let op: TypingOp
    public let senderID: Int
    public let channelID: Int?
    public let topic: String?
    public let recipientIDs: [Int]

    public init(op: TypingOp, senderID: Int, channelID: Int?, topic: String?, recipientIDs: [Int]) {
        self.op = op
        self.senderID = senderID
        self.channelID = channelID
        self.topic = topic
        self.recipientIDs = recipientIDs
    }
}

/// The `{user_id, email}` pair a typing event uses for people.
struct TypingUser: Decodable {
    let user_id: Int
}

/// The server keeps no typing state, so the client owns every timer. These are the
/// documented fallbacks for servers that do not send their own.
public enum TypingTiming {
    /// How often a start is repeated while someone keeps typing.
    public static let startedWait = Duration.seconds(10)
    /// Quiet time after which a typist is said to have stopped.
    public static let stoppedWait = Duration.seconds(5)
    /// How long a start is believed without a fresh one.
    public static let startedExpiry = Duration.seconds(15)
}

private enum TypingRecipientType {
    static let direct = "direct"
    static let channel = "stream"
}

extension ZulipClient {
    public func setTyping(_ op: TypingOp, inChannel channelID: Int, topic: String) async throws {
        _ = try await raw(.post, "typing", parameters: [
            "op": op.rawValue,
            "type": TypingRecipientType.channel,
            "stream_id": String(channelID),
            "topic": topic,
        ])
    }

    public func setTyping(_ op: TypingOp, toUsers ids: [Int]) async throws {
        _ = try await raw(.post, "typing", parameters: [
            "op": op.rawValue,
            "type": TypingRecipientType.direct,
            "to": Self.json(ids),
        ])
    }
}
