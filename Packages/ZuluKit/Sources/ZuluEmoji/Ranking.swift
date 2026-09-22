import Foundation

/// A stable sort into a small number of integer buckets.
///
/// Both official Zulip clients rank in two stages: match quality picks a bucket, and the
/// order candidates were already in decides ties inside it. Keeping the sort stable is
/// what makes that second stage work, so the expensive relevance ordering can be done
/// once when the candidate list is built rather than on every keystroke.
public enum Ranked {

    public static func sorted<Element>(_ items: [(element: Element, rank: Int)], buckets: Int) -> [Element] {
        var byRank: [[Element]] = Array(repeating: [], count: buckets)
        for item in items where item.rank >= 0 && item.rank < buckets {
            byRank[item.rank].append(item.element)
        }
        return byRank.flatMap { $0 }
    }
}

/// How well a query matched a name, best first. Shared by every autocomplete source and
/// by the emoji catalogue, because the distinctions are the same everywhere.
public enum MatchQuality: Int, Sendable, Equatable, Comparable {
    /// The query is the whole name.
    case exact = 0
    /// The query is a prefix of the name, but not all of it.
    case prefix = 1
    /// Every word of the query prefixes a distinct word of the name, in order, and the
    /// first of those is not the name's first word.
    case wordAligned = 2
    /// The query appears in the name but not at the start of any word.
    case other = 3

    public static func < (lhs: MatchQuality, rhs: MatchQuality) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum MatchText {
    /// Lowercased with diacritics folded away, so a lowercase unaccented query is always
    /// enough to find a name. Web ranks case-sensitive matches higher; zulip-flutter
    /// dropped that deliberately and this follows flutter.
    public static func normalized(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    /// Splits on the separators Zulip's own matchers treat as word boundaries.
    public static func words(_ text: String) -> [Substring] {
        text.split(whereSeparator: { $0 == " " || $0 == "_" || $0 == "-" || $0 == "/" })
    }

    /// Every query word prefix-matches a distinct name word, in order — the rule
    /// zulip-flutter uses, which finds "Chris Bobbe" from "ch bo" where web's single
    /// word-boundary bucket does not.
    public static func wordsPrefixMatch(query: [Substring], name: [Substring]) -> Bool {
        guard !query.isEmpty else { return false }
        var remaining = name[...]
        for word in query {
            guard let hit = remaining.firstIndex(where: { $0.hasPrefix(word) }) else { return false }
            remaining = remaining[remaining.index(after: hit)...]
        }
        return true
    }

    /// The quality of a whole-name match, or nil when the query is not in the name at all.
    ///
    /// `looseSeparator` is the character that, once the query contains it, forces the
    /// match to start at a word boundary — Zulip does this so `ab_cd` cannot be found by
    /// a query that starts mid-word.
    public static func quality(
        query: String,
        queryWords: [Substring],
        name: String,
        looseSeparator: Character
    ) -> MatchQuality? {
        if name == query { return .exact }
        if name.hasPrefix(query) { return .prefix }

        let nameWords = words(name)
        if wordsPrefixMatch(query: queryWords, name: nameWords) { return .wordAligned }
        if !query.contains(looseSeparator), !query.isEmpty, name.contains(query) { return .other }
        return nil
    }
}
