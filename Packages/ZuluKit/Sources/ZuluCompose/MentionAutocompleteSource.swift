import Foundation
import ZuluEmoji

public struct PersonCandidate: Sendable, Equatable, Identifiable {
    public let id: Int
    public let fullName: String
    public let email: String?
    public let isBot: Bool
    public let avatarURL: String?
    /// Subscribed to the channel being composed to. Web ranks subscribers first and
    /// zulip-flutter has not caught up; this follows web.
    public let isSubscribedToChannel: Bool
    /// The newest message this person sent in the topic, in the channel, and in a direct
    /// message with the viewer. Message ids increase with time, so they sort as recency.
    public let latestInTopic: Int?
    public let latestInChannel: Int?
    public let latestInDirectMessages: Int?

    public init(
        id: Int,
        fullName: String,
        email: String? = nil,
        isBot: Bool = false,
        avatarURL: String? = nil,
        isSubscribedToChannel: Bool = false,
        latestInTopic: Int? = nil,
        latestInChannel: Int? = nil,
        latestInDirectMessages: Int? = nil
    ) {
        self.id = id
        self.fullName = fullName
        self.email = email
        self.isBot = isBot
        self.avatarURL = avatarURL
        self.isSubscribedToChannel = isSubscribedToChannel
        self.latestInTopic = latestInTopic
        self.latestInChannel = latestInChannel
        self.latestInDirectMessages = latestInDirectMessages
    }
}

public struct GroupCandidate: Sendable, Equatable, Identifiable {
    public let id: Int
    public let name: String
    public let description: String?
    /// Whether `can_mention_group` lets this viewer mention it out loud. Every group can
    /// be mentioned silently, so a group that fails this is still offered after `@_`.
    public let isMentionable: Bool

    public init(id: Int, name: String, description: String? = nil, isMentionable: Bool = true) {
        self.id = id
        self.name = name
        self.description = description
        self.isMentionable = isMentionable
    }
}

/// `@` — people, user groups, and the wildcards, including the silent `@_` forms.
///
/// Silence is not a separate trigger: the leading `_` is part of the query, which is why
/// backspacing from `@_bob` to `@bob` keeps the box open on the same list.
public struct MentionAutocompleteSource: AutocompleteSource {
    public let trigger: Character = "@"
    /// Wildcards, then people by match quality, then groups by match quality, then an
    /// email prefix match. zulip-flutter's table, with its ordering of groups after
    /// people kept.
    public let rankCount = 8

    private let people: [PersonCandidate]
    private let groups: [GroupCandidate]
    /// Full names held by more than one person, which is the only reason to spell out a
    /// user id — the server rejects `@**name|id**` when the name no longer matches.
    private let ambiguousNames: Set<String>

    public init(people: [PersonCandidate], groups: [GroupCandidate]) {
        // The candidate order is the tiebreak inside every rank bucket, so it is sorted
        // once here: subscription, then recency, then alphabetically. Bots are not sunk
        // below humans — a bot in this conversation, named exactly, should still win.
        self.people = people.sorted { left, right in
            if left.isSubscribedToChannel != right.isSubscribedToChannel {
                return left.isSubscribedToChannel
            }
            for recency in [\PersonCandidate.latestInTopic, \.latestInChannel, \.latestInDirectMessages] {
                let a = left[keyPath: recency]
                let b = right[keyPath: recency]
                if a != b { return (a ?? -1) > (b ?? -1) }
            }
            if left.isBot != right.isBot { return right.isBot }
            return left.fullName.localizedCaseInsensitiveCompare(right.fullName) == .orderedAscending
        }
        self.groups = groups.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        var seen: Set<String> = []
        var ambiguous: Set<String> = []
        for person in people {
            if !seen.insert(person.fullName).inserted { ambiguous.insert(person.fullName) }
        }
        // A person named "all" would produce `@**all**`, which is a wildcard and not
        // them, so their id has to be spelled out too.
        for wildcard in ComposeMarkup.Wildcard.allCases where seen.contains(wildcard.rawValue) {
            ambiguous.insert(wildcard.rawValue)
        }
        ambiguousNames = ambiguous
    }

    /// A bare `@` lists everyone, which is what both official clients do. What closes
    /// the box is a character no name can contain — most often the `@` of an email
    /// address the person is really typing.
    public func accepts(query: Substring) -> Bool {
        !query.contains(where: { $0 == "*" || $0 == "@" || $0 == "`" || $0 == "\"" || $0 == ">" || $0.isNewline })
    }

    public func suggestions(
        for rawQuery: String,
        in context: ComposeContext
    ) -> [(element: AutocompleteSuggestion, rank: Int)] {
        let silent = rawQuery.hasPrefix("_")
        let query = silent ? String(rawQuery.dropFirst()) : rawQuery
        let normalized = MatchText.normalized(query)
        let words = MatchText.words(normalized)

        var results: [(element: AutocompleteSuggestion, rank: Int)] = []

        // No silent wildcard exists, so `@_` offers none.
        if !silent, let wildcard = firstMatchingWildcard(normalized, in: context) {
            results.append((suggestion(for: wildcard, in: context), 0))
        }

        for person in people {
            if let quality = MatchText.quality(
                query: normalized, queryWords: words,
                name: MatchText.normalized(person.fullName), looseSeparator: " "
            ), quality != .other {
                results.append((suggestion(for: person, silent: silent), quality.rawValue + 1))
                continue
            }
            if !normalized.isEmpty,
               let email = person.email,
               MatchText.normalized(email).hasPrefix(normalized) {
                results.append((suggestion(for: person, silent: silent), 7))
            }
        }

        for group in groups where silent || group.isMentionable {
            guard let quality = MatchText.quality(
                query: normalized, queryWords: words,
                name: MatchText.normalized(group.name), looseSeparator: " "
            ), quality != .other else { continue }
            results.append((suggestion(for: group, silent: silent), quality.rawValue + 4))
        }

        return results
    }

    /// Only one channel wildcard is ever shown: `all`, `everyone`, `channel` and
    /// `stream` all notify the same people, so listing them all is four ways to say one
    /// thing.
    private func firstMatchingWildcard(
        _ query: String,
        in context: ComposeContext
    ) -> ComposeMarkup.Wildcard? {
        let offered: [ComposeMarkup.Wildcard] = context.isDirectMessage
            ? [.all, .everyone]
            : [.all, .everyone, .channel, .stream, .topic]
        return offered.first { $0.rawValue.hasPrefix(query) }
    }

    private func suggestion(for wildcard: ComposeMarkup.Wildcard, in context: ComposeContext) -> AutocompleteSuggestion {
        AutocompleteSuggestion(
            id: "wildcard:\(wildcard.rawValue)",
            title: "@\(wildcard.rawValue)",
            subtitle: context.isDirectMessage
                ? "Notify recipients"
                : wildcard.isChannelWide ? "Notify all channel subscribers" : "Notify this conversation",
            icon: .symbol("megaphone"),
            insertion: ComposeMarkup.wildcardMention(wildcard)
        )
    }

    private func suggestion(for person: PersonCandidate, silent: Bool) -> AutocompleteSuggestion {
        AutocompleteSuggestion(
            id: "user:\(person.id)",
            title: person.fullName,
            subtitle: person.isBot ? "Bot" : person.email,
            icon: person.avatarURL.map { .image($0) } ?? .symbol("person.crop.circle"),
            insertion: ComposeMarkup.userMention(
                fullName: person.fullName,
                userID: ambiguousNames.contains(person.fullName) ? person.id : nil,
                silent: silent
            )
        )
    }

    private func suggestion(for group: GroupCandidate, silent: Bool) -> AutocompleteSuggestion {
        AutocompleteSuggestion(
            id: "group:\(group.id)",
            title: group.name,
            subtitle: group.description,
            icon: .symbol("person.2"),
            insertion: ComposeMarkup.groupMention(name: group.name, silent: silent)
        )
    }
}
