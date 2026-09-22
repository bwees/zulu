import Foundation

/// The literal markdown a completion drops into the draft.
///
/// Zulip resolves all of this server-side at render time, so what matters here is that
/// the syntax is one the server's regexes actually match — a mention or a channel link
/// that does not parse is left as plain text with no error anywhere.
public enum ComposeMarkup {

    /// Characters a channel or topic name cannot contain if `#**name**` is to survive
    /// the server's markdown. `>` ends the channel name, `*` ends the whole construct,
    /// and the rest are eaten by inline markdown before the link pattern ever sees them.
    ///
    /// Both official clients keep exactly this set and fall back to an ordinary link.
    private static let entities: [Character: String] = [
        "`": "&#96;",
        ">": "&gt;",
        "*": "&#42;",
        "&": "&amp;",
        "[": "&#91;",
        "]": "&#93;",
    ]

    /// Whether `#**name**` can express this name at all.
    public static func isLinkable(_ name: String) -> Bool {
        if name.contains("$$") { return false }
        return !name.contains(where: { entities[$0] != nil })
    }

    /// Escapes in one pass, so an entity this introduces is never escaped again by the
    /// ampersand rule.
    static func escaped(_ name: String) -> String {
        var output = ""
        var index = name.startIndex
        while index < name.endIndex {
            let character = name[index]
            let next = name.index(after: index)
            if character == "$", next < name.endIndex, name[next] == "$" {
                output += "&#36;&#36;"
                index = name.index(after: next)
                continue
            }
            output += entities[character] ?? String(character)
            index = next
        }
        return output
    }

    // MARK: channels and topics

    public static func channelLink(id: Int, name: String) -> String {
        guard isLinkable(name) else {
            return "[#\(escaped(name))](\(narrow(channelID: id, name: name)))"
        }
        return "#**\(name)**"
    }

    public static func topicLink(channelID: Int, channelName: String, topic: String) -> String {
        guard isLinkable(channelName), isLinkable(topic) else {
            let url = narrow(channelID: channelID, name: channelName, topic: topic)
            return "[#\(escaped(channelName))>\(escaped(topic))](\(url))"
        }
        return "#**\(channelName)>\(topic)**"
    }

    /// The in-app narrow link a fallback points at. Only the numeric prefix decides
    /// where it goes; the rest of the slug is there so the URL reads like the channel.
    static func narrow(channelID: Int, name: String, topic: String? = nil) -> String {
        var url = "#narrow/channel/\(channelID)-\(hashComponent(name.replacingOccurrences(of: " ", with: "-")))"
        if let topic { url += "/topic/\(hashComponent(topic))" }
        return url
    }

    /// Zulip percent-encodes hash components and then swaps `%` for `.`, so that a URL
    /// fragment full of encoded bytes does not collide with its own path separators.
    static func hashComponent(_ text: String) -> String {
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-_.!~*'()")
        let encoded = text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
        return encoded.replacingOccurrences(of: "%", with: ".")
    }

    // MARK: mentions

    /// `@**Full Name**`, or `@**Full Name|id**` when the name alone is ambiguous.
    ///
    /// The id form is only emitted when it has to be: the server rejects
    /// `@**name|id**` outright if the name no longer matches that user, so an id
    /// attached to a stale name is worse than no id at all.
    public static func userMention(fullName: String, userID: Int? = nil, silent: Bool = false) -> String {
        let silence = silent ? "_" : ""
        guard let userID else { return "@\(silence)**\(fullName)**" }
        return "@\(silence)**\(fullName)|\(userID)**"
    }

    public static func groupMention(name: String, silent: Bool = false) -> String {
        "@\(silent ? "_" : "")*\(name)*"
    }

    public enum Wildcard: String, Sendable, CaseIterable {
        case all, everyone, channel, stream, topic

        /// Everything but `topic` notifies the whole channel; they are aliases for one
        /// another and the server treats them identically.
        public var isChannelWide: Bool { self != .topic }
    }

    /// There is no silent wildcard mention — the server has no syntax for one.
    public static func wildcardMention(_ wildcard: Wildcard) -> String {
        "@**\(wildcard.rawValue)**"
    }

    // MARK: emoji

    /// Always the name, never the code: the server resolves `:name:` through the realm's
    /// own emoji first, which is the behaviour a custom emoji depends on.
    public static func emoji(named name: String) -> String { ":\(name):" }
}
