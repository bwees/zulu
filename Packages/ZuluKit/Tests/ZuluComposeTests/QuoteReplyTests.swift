import Foundation
import Testing
import ZuluMarkup
@testable import ZuluCompose

private let realm = URL(string: "https://realm.example")!
private let topic = ComposeMarkup.MessageLocation.topic(
    channelID: 7, channelName: "general", topic: "notes"
)

struct PermalinkTests {

    @Test func aChannelPermalinkNamesTheChannelByIDAndTheTopicBySlug() {
        #expect(ComposeMarkup.permalink(toMessage: 99, in: topic, realmURL: realm)
            == "https://realm.example/#narrow/channel/7-general/topic/notes/near/99")
    }

    /// Zulip encodes hash components and then swaps `%` for `.`, so a space in a topic
    /// becomes `.20` rather than a second path separator's worth of trouble.
    @Test func topicsWithSpacesAreHashEncoded() {
        let location = ComposeMarkup.MessageLocation.topic(
            channelID: 7, channelName: "dev help", topic: "build broke"
        )
        #expect(ComposeMarkup.permalink(toMessage: 3, in: location, realmURL: realm)
            == "https://realm.example/#narrow/channel/7-dev-help/topic/build.20broke/near/3")
    }

    @Test func aDirectMessagePermalinkListsItsRecipients() {
        #expect(ComposeMarkup.permalink(
            toMessage: 12, in: .directMessage(userIDs: [9, 4]), realmURL: realm
        ) == "https://realm.example/#narrow/dm/4,9-group/near/12")
    }

    /// A realm URL that came back from the server with a trailing slash must not produce
    /// a link with two.
    @Test func aTrailingSlashOnTheRealmURLIsNotDoubled() {
        let slashed = URL(string: "https://realm.example/")!
        #expect(ComposeMarkup.permalink(toMessage: 1, in: topic, realmURL: slashed)
            == "https://realm.example/#narrow/channel/7-general/topic/notes/near/1")
    }
}

struct QuoteAndReplyTests {

    @Test func theQuoteIsSpelledTheWayTheWebClientSpellsIt() {
        let markup = ComposeMarkup.quoteAndReply(
            author: "Ada Lovelace", authorID: 42, messageID: 99,
            location: topic, realmURL: realm, rawContent: "It works."
        )
        #expect(markup == """
            @_**Ada Lovelace|42** [said](https://realm.example/#narrow/channel/7-general/topic/notes/near/99):
            ```quote
            It works.
            ```


            """)
    }

    /// A quoted code block closes the fence early unless the fence is longer than
    /// anything inside it, and the rest of the reply then spills out of the quote.
    @Test func theFenceOutrunsBackticksInTheQuotedText() {
        let markup = ComposeMarkup.quoteAndReply(
            author: "Ada", authorID: nil, messageID: 1,
            location: topic, realmURL: realm, rawContent: "```\nlet x = 1\n```"
        )
        #expect(markup.contains("````quote\n"))
        #expect(markup.hasSuffix("\n````\n\n"))
    }

    @Test func anUnknownAuthorIDLeavesTheMentionUnqualified() {
        let markup = ComposeMarkup.quoteAndReply(
            author: "Ada Lovelace", authorID: nil, messageID: 1,
            location: topic, realmURL: realm, rawContent: "x"
        )
        #expect(markup.hasPrefix("@_**Ada Lovelace** [said]("))
    }

    @Test func theQuoteParsesBackIntoTheAuthorAndMessageItNamed() throws {
        let markup = ComposeMarkup.quoteAndReply(
            author: "Ada Lovelace", authorID: 42, messageID: 99,
            location: topic, realmURL: realm, rawContent: "It works."
        )

        #expect(MessageMarkup.blocks(from: try serverRendered(markup)) == [
            .quotedReply(
                author: "Ada Lovelace",
                messageID: 99,
                quoted: [.paragraph([InlineSpan(text: "It works.")])]
            ),
        ])
    }

    @Test func aQuoteOfACodeBlockSurvivesTheRoundTrip() throws {
        let markup = ComposeMarkup.quoteAndReply(
            author: "Ada", authorID: 42, messageID: 5,
            location: topic, realmURL: realm, rawContent: "```\nlet x = 1\n```"
        )
        let blocks = MessageMarkup.blocks(from: try serverRendered(markup))

        #expect(blocks == [
            .quotedReply(author: "Ada", messageID: 5, quoted: [
                .codeBlock(language: nil, code: "let x = 1"),
            ]),
        ])
    }
}

/// Zulip renders markdown on the server, so there is no offline round trip to be had.
/// This applies the renderings `api_docs/message-formatting.md` documents for the three
/// constructs quote-and-reply emits — a silent mention, an inline link, and a quote
/// fence. It reads the builder's own output, so a change to what the builder writes
/// fails here rather than quietly passing against a transcribed fixture.
private func serverRendered(_ markdown: String) throws -> String {
    var lines = markdown.components(separatedBy: "\n")
    let attribution = try #require(lines.first)
    lines.removeFirst()

    let mention = try #require(attribution.range(of: "@_**"))
    let said = try #require(attribution.range(of: "** [said]("))
    let name = String(attribution[mention.upperBound..<said.lowerBound])
    let link = String(attribution[said.upperBound...].dropLast(2))
    let userID = name.split(separator: "|").last.map(String.init) ?? ""
    let displayed = name.contains("|") ? String(name.split(separator: "|")[0]) : name

    let fence = try #require(lines.first).replacingOccurrences(of: "quote", with: "")
    lines.removeFirst()
    let close = try #require(lines.firstIndex(of: fence))
    let quoted = lines[..<close].joined(separator: "\n")

    return """
        <p><span class="user-mention silent" data-user-id="\(userID)">\(displayed)</span> \
        <a href="\(link)">said</a>:</p>
        <blockquote>
        \(rendered(quoted))
        </blockquote>
        """
}

/// Only the two shapes the quote tests put inside a fence.
private func rendered(_ markdown: String) -> String {
    guard markdown.hasPrefix("```") else { return "<p>\(markdown)</p>" }
    let body = markdown
        .components(separatedBy: "\n")
        .dropFirst()
        .dropLast()
        .joined(separator: "\n")
    return "<pre><code>\(body)\n</code></pre>"
}
