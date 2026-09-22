import Foundation
import ZuluEmoji

/// What the composer is writing into, which is all a source needs to know about its
/// surroundings: who is subscribed where, and whether a channel wildcard makes sense.
public struct ComposeContext: Sendable, Equatable {
    public let channelID: Int?
    public let topic: String?

    public init(channelID: Int? = nil, topic: String? = nil) {
        self.channelID = channelID
        self.topic = topic
    }

    public var isDirectMessage: Bool { channelID == nil }
}

/// One row in the suggestion box. The box draws this and nothing else — it never learns
/// what kind of thing it is showing, which is what lets a source be added without
/// touching it.
public struct AutocompleteSuggestion: Sendable, Equatable, Identifiable {
    public enum Icon: Sendable, Equatable {
        case glyph(String)
        /// Realm-relative or absolute image path, for custom emoji and avatars.
        case image(String)
        case symbol(String)
    }

    public let id: String
    public let title: String
    public let subtitle: String?
    public let icon: Icon
    /// The finished markup, already escaped. A source is the only thing that knows how
    /// to spell what it suggests.
    public let insertion: String
    /// Whether a space belongs after the insertion. Emoji do not get one, because an
    /// emoji is usually followed immediately by more punctuation.
    public let insertTrailingSpace: Bool

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        icon: Icon,
        insertion: String,
        insertTrailingSpace: Bool = true
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.insertion = insertion
        self.insertTrailingSpace = insertTrailingSpace
    }
}

/// Everything one trigger character can complete.
///
/// A source owns its trigger, decides for itself when a query has stopped being one of
/// its queries, and spells its own insertions. The trigger scan, the ranking sort, the
/// box and the keyboard are shared, so a fourth source is a new conformance and one
/// more element in an array.
public protocol AutocompleteSource: Sendable {
    /// The character that opens the box.
    var trigger: Character { get }

    /// The number of rank buckets `suggestions` uses.
    var rankCount: Int { get }

    /// Whether the text between the trigger and the cursor is still a query.
    /// Returning false closes the box, which is how a source declines a trigger it
    /// does not own — an email address's `@`, say.
    func accepts(query: Substring) -> Bool

    /// Whether the character immediately before the trigger permits it. The shared rule
    /// (start of input, whitespace, or punctuation) has already passed; this is for the
    /// extra characters one source in particular has to refuse.
    func allows(precedingCharacter: Character) -> Bool

    func suggestions(for query: String, in context: ComposeContext) -> [(element: AutocompleteSuggestion, rank: Int)]
}

extension AutocompleteSource {
    public func accepts(query: Substring) -> Bool { true }
    public func allows(precedingCharacter: Character) -> Bool { true }
}

/// A trigger found in the draft, and the span a completion replaces.
public struct ActiveQuery: Sendable, Equatable {
    public let trigger: Character
    public let query: String
    /// From the trigger character through the cursor.
    public let range: Range<String.Index>

    public init(trigger: Character, query: String, range: Range<String.Index>) {
        self.trigger = trigger
        self.query = query
        self.range = range
    }
}

/// Finds the trigger, asks the right source, and sorts what comes back.
public struct AutocompleteEngine: Sendable {
    public let sources: [any AutocompleteSource]
    /// How far back to look for a trigger. Bounded so that a long draft does not get
    /// rescanned from the top on every keystroke; zulip-flutter derives this from the
    /// realm's `max_stream_name_length`, which is the longest thing a query can be.
    public let maxLookback: Int

    public init(sources: [any AutocompleteSource], maxChannelNameLength: Int = 60) {
        self.sources = sources
        // The trigger, an optional `**` or `_`, and the longest name a query can hold.
        maxLookback = maxChannelNameLength + 3
    }

    /// The rightmost trigger whose query still stands, or nil when nothing is open.
    ///
    /// A trigger only counts at the start of a word: mid-word `@` is an email address
    /// and mid-word `#` is a fragment, and neither should open a box. The characters
    /// that may precede one are start-of-input, whitespace, or punctuation — broader
    /// than whitespace alone, so `(@ali` opens just as `@ali` does.
    public func activeQuery(in text: String, cursor: String.Index) -> ActiveQuery? {
        var index = cursor
        var stepsBack = 0
        while index > text.startIndex, stepsBack < maxLookback {
            index = text.index(before: index)
            stepsBack += 1
            let character = text[index]
            guard let source = sources.first(where: { $0.trigger == character }) else { continue }

            if index > text.startIndex {
                let preceding = text[text.index(before: index)]
                guard preceding.isWhitespace || preceding.isPunctuation || preceding.isSymbol,
                      source.allows(precedingCharacter: preceding)
                else { continue }
            }

            let query = text[text.index(after: index)..<cursor]
            guard source.accepts(query: query) else { return nil }
            return ActiveQuery(trigger: character, query: String(query), range: index..<cursor)
        }
        return nil
    }

    public func suggestions(
        for active: ActiveQuery,
        in context: ComposeContext,
        limit: Int = 12
    ) -> [AutocompleteSuggestion] {
        guard let source = sources.first(where: { $0.trigger == active.trigger }) else { return [] }
        let ranked = source.suggestions(for: active.query, in: context)
        return Array(Ranked.sorted(ranked, buckets: source.rankCount).prefix(limit))
    }

    /// Replaces the trigger and everything typed after it with the completion.
    /// Returns the text and where the cursor now belongs.
    public func apply(
        _ suggestion: AutocompleteSuggestion,
        to text: String,
        replacing active: ActiveQuery
    ) -> (text: String, cursor: String.Index) {
        let insertion = suggestion.insertion + (suggestion.insertTrailingSpace ? " " : "")
        var updated = text
        updated.replaceSubrange(active.range, with: insertion)
        let offset = text.distance(from: text.startIndex, to: active.range.lowerBound) + insertion.count
        return (updated, updated.index(updated.startIndex, offsetBy: offset))
    }
}
