import Foundation

extension ZulipClient {

    /// `reaction_type` has been optional since feature level 2, but a custom emoji's code
    /// is a realm-local id that means nothing on its own, so it is always sent.
    public func addReaction(
        toMessage id: Int, emojiName: String, emojiCode: String, reactionType: String
    ) async throws {
        _ = try await raw(.post, "messages/\(id)/reactions", parameters: [
            "emoji_name": emojiName,
            "emoji_code": emojiCode,
            "reaction_type": reactionType,
        ])
    }

    /// The server matches on `(reaction_type, emoji_code)`, but still requires a name, so
    /// the name to send is whichever alias the reaction was recorded under.
    public func removeReaction(
        fromMessage id: Int, emojiName: String, emojiCode: String, reactionType: String
    ) async throws {
        _ = try await raw(.delete, "messages/\(id)/reactions", parameters: [
            "emoji_name": emojiName,
            "emoji_code": emojiCode,
            "reaction_type": reactionType,
        ])
    }

    /// The message's markdown source, which quote-and-reply needs — the store only keeps
    /// the server's rendered HTML, and quoting HTML back at the server would render it twice.
    public func rawContent(ofMessage id: Int) async throws -> String {
        struct Response: Decodable { let raw_content: String }
        let response: Response = try await send(.get, "messages/\(id)")
        return response.raw_content
    }

    public func editMessage(_ id: Int, content: String) async throws {
        _ = try await raw(.patch, "messages/\(id)", parameters: ["content": content])
    }

    public func deleteMessage(_ id: Int) async throws {
        _ = try await raw(.delete, "messages/\(id)")
    }
}

extension ZulipError {
    /// Both codes mean the reaction already is what the request asked for, which is what a
    /// second tap looks like while the first is still in flight.
    public var leavesReactionAsRequested: Bool {
        code == "REACTION_ALREADY_EXISTS" || code == "REACTION_DOES_NOT_EXIST"
    }
}
