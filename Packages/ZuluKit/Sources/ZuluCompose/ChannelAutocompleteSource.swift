import Foundation
import ZuluEmoji

public struct ChannelCandidate: Sendable, Equatable, Identifiable {
    public let id: Int
    public let name: String
    public let description: String?
    public let isSubscribed: Bool
    public let isPinned: Bool
    public let isMuted: Bool

    public init(
        id: Int,
        name: String,
        description: String? = nil,
        isSubscribed: Bool = true,
        isPinned: Bool = false,
        isMuted: Bool = false
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.isSubscribed = isSubscribed
        self.isPinned = isPinned
        self.isMuted = isMuted
    }
}

/// `#` — channel links.
public struct ChannelAutocompleteSource: AutocompleteSource {
    public let trigger: Character = "#"
    /// Name matches, then description matches. Both official clients fall back to
    /// descriptions once names run out.
    public let rankCount = 4

    private let candidates: [ChannelCandidate]

    /// Sorted once, at construction, so a keystroke only has to bucket by match quality.
    /// The order is web's `compare_by_activity` without the traffic figures Zulu does
    /// not store: subscribed first, then pinned and unmuted, then by name.
    public init(channels: [ChannelCandidate]) {
        candidates = channels.sorted { left, right in
            if left.isSubscribed != right.isSubscribed { return left.isSubscribed }
            if left.isPinned != right.isPinned { return left.isPinned }
            if left.isMuted != right.isMuted { return right.isMuted }
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }
    }

    /// A bare `#` lists nothing: with no channel named, every channel matches and the
    /// box is just noise over the keyboard.
    public func accepts(query: Substring) -> Bool {
        guard let first = query.first, !first.isWhitespace else { return false }
        return !query.contains(where: { $0 == "*" || $0 == "\n" })
    }

    /// `##name` and `@#name` are someone typing something else.
    public func allows(precedingCharacter: Character) -> Bool {
        precedingCharacter != "#" && precedingCharacter != "@"
    }

    public func suggestions(
        for query: String,
        in context: ComposeContext
    ) -> [(element: AutocompleteSuggestion, rank: Int)] {
        let normalized = MatchText.normalized(query)
        let words = MatchText.words(normalized)

        return candidates.compactMap { channel in
            let nameQuality = MatchText.quality(
                query: normalized,
                queryWords: words,
                name: MatchText.normalized(channel.name),
                looseSeparator: " "
            )
            let rank: Int
            if let nameQuality {
                rank = switch nameQuality {
                case .exact: 0
                case .prefix: 1
                case .wordAligned, .other: 2
                }
            } else if let description = channel.description,
                      MatchText.normalized(description).contains(normalized) {
                rank = 3
            } else {
                return nil
            }
            return (suggestion(for: channel), rank)
        }
    }

    private func suggestion(for channel: ChannelCandidate) -> AutocompleteSuggestion {
        AutocompleteSuggestion(
            id: "channel:\(channel.id)",
            title: channel.name,
            subtitle: channel.description,
            icon: .symbol("number"),
            insertion: ComposeMarkup.channelLink(id: channel.id, name: channel.name)
        )
    }
}
