import Foundation

extension ComposeMarkup {

    /// Where a message lives. A permalink and a quote attribution both need exactly this
    /// and nothing else.
    public enum MessageLocation: Sendable, Equatable {
        case topic(channelID: Int, channelName: String, topic: String)
        /// Every recipient but the viewer, which is what Zulip's `dm` operand names. A
        /// note to self is the one case where that is the viewer.
        case directMessage(userIDs: [Int])
    }

    /// The `#narrow/…/near/<id>` link that points at one message.
    ///
    /// Only the numeric prefix of each segment decides where the link goes, so a link
    /// built from a since-renamed channel still resolves to the right place.
    public static func permalink(
        toMessage id: Int, in location: MessageLocation, realmURL: URL
    ) -> String {
        let fragment: String
        switch location {
        case .topic(let channelID, let channelName, let topic):
            fragment = narrow(channelID: channelID, name: channelName, topic: topic)
        case .directMessage(let userIDs):
            let ids = userIDs.sorted().map(String.init).joined(separator: ",")
            fragment = "#narrow/dm/\(ids)-group"
        }
        var base = realmURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return "\(base)/\(fragment)/near/\(id)"
    }

    /// Zulip's quote-and-reply, spelled the way the web client spells it: a silent
    /// mention and a `said` link on one line, then the original's markdown in a quote
    /// fence.
    ///
    /// The trailing blank line is what leaves the cursor below the quote rather than
    /// welded to it.
    public static func quoteAndReply(
        author: String,
        authorID: Int?,
        messageID: Int,
        location: MessageLocation,
        realmURL: URL,
        rawContent: String
    ) -> String {
        let link = permalink(toMessage: messageID, in: location, realmURL: realmURL)
        let mention = userMention(fullName: author, userID: authorID, silent: true)
        let fence = String(repeating: "`", count: fenceLength(for: rawContent))
        return "\(mention) [said](\(link)):\n\(fence)quote\n\(rawContent)\n\(fence)\n\n"
    }

    /// A fence must outrun the longest run of backticks inside what it wraps, or a quoted
    /// code block closes the quote early and the rest of the message spills out of it.
    static func fenceLength(for content: String) -> Int {
        var longest = 0
        var run = 0
        for character in content {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        return max(3, longest + 1)
    }
}
