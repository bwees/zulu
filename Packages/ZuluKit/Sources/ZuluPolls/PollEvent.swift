import Foundation

/// An event a client appends to a poll's log.
///
/// The server validates these with `check_dict_only`, so an unexpected key is a rejection
/// rather than something it ignores — which is why each case encodes its own exact shape.
public enum PollEvent: Sendable, Equatable {
    /// `add` is decided by the client. The server only ever applies a set-add or a
    /// set-remove, so two devices toggling the same option converge.
    case vote(key: String, add: Bool)
    case newOption(idx: Int, text: String)
    /// Rejected by the server for anyone but the message's sender.
    case question(String)

    /// The `content` parameter of `POST /api/v1/submessage`.
    public var json: String {
        switch self {
        case .vote(let key, let add):
            Self.encode(VotePayload(key: key, vote: add ? 1 : -1))
        case .newOption(let idx, let text):
            Self.encode(NewOptionPayload(idx: idx, option: text))
        case .question(let text):
            Self.encode(QuestionPayload(question: text))
        }
    }

    private struct VotePayload: Encodable {
        let type = "vote"
        let key: String
        let vote: Int
    }

    private struct NewOptionPayload: Encodable {
        let type = "new_option"
        let idx: Int
        let option: String
    }

    private struct QuestionPayload: Encodable {
        let type = "question"
        let question: String
    }

    private static func encode(_ payload: some Encodable) -> String {
        let encoder = JSONEncoder()
        // Zulip parses these, so key order means nothing to it — but a stable order means
        // the same event always produces the same string.
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(payload) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
