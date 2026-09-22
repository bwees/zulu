import Testing
@testable import ZuluMarkup

struct MessageMarkupTests {

    @Test func plainParagraph() {
        #expect(MessageMarkup.blocks(from: "<p>hello there</p>")
            == [.paragraph([InlineSpan(text: "hello there")])])
    }

    @Test func inlineStyling() {
        let blocks = MessageMarkup.blocks(from: "<p>a <strong>bold</strong> and <em>italic</em></p>")
        #expect(blocks == [.paragraph([
            InlineSpan(text: "a "),
            InlineSpan(text: "bold", bold: true),
            InlineSpan(text: " and "),
            InlineSpan(text: "italic", italic: true),
        ])])
    }

    @Test func linksCarryTheirHref() {
        let blocks = MessageMarkup.blocks(from: #"<p><a href="/user_uploads/2/x.jpg">x.jpg</a></p>"#)
        #expect(blocks == [.paragraph([
            InlineSpan(text: "x.jpg", link: "/user_uploads/2/x.jpg"),
        ])])
    }

    /// Verbatim from zulip.futo.org: a thumbnail wrapped in a link to the full image.
    @Test func inlineImageKeepsBothThumbnailAndFullSize() {
        let html = #"<div class="message_inline_image"><a href="/user_uploads/2/b5/Kj/image.jpeg" title="image.jpeg"><img data-original-dimensions="1206x2140" src="/user_uploads/thumbnail/2/b5/Kj/image.jpeg/840x560.webp"></a></div>"#
        let blocks = MessageMarkup.blocks(from: html)
        #expect(blocks == [.image(
            source: "/user_uploads/thumbnail/2/b5/Kj/image.jpeg/840x560.webp",
            link: "/user_uploads/2/b5/Kj/image.jpeg",
            alt: "image.jpeg"
        )])
    }

    /// Unicode emoji arrive as a span whose class carries the codepoint.
    @Test func emojiSpanBecomesTheCharacter() {
        let html = #"<p>Crossing 14,000 <span aria-label="taking a picture" class="emoji emoji-1f4f8" role="img" title="taking a picture">:taking_a_picture:</span></p>"#
        #expect(MessageMarkup.blocks(from: html)
            == [.paragraph([InlineSpan(text: "Crossing 14,000 \u{1F4F8}")])])
    }

    @Test func multiCodepointEmoji() {
        let html = #"<p><span class="emoji emoji-1f1fa-1f1f8">:us:</span></p>"#
        #expect(MessageMarkup.blocks(from: html)
            == [.paragraph([InlineSpan(text: "\u{1F1FA}\u{1F1F8}")])])
    }

    @Test func blockquoteKeepsItsOwnBlocks() {
        let html = "<blockquote>\n<p>quoted</p>\n</blockquote><p>reply</p>"
        #expect(MessageMarkup.blocks(from: html) == [
            .quote([.paragraph([InlineSpan(text: "quoted")])]),
            .paragraph([InlineSpan(text: "reply")]),
        ])
    }

    @Test func codeBlockKeepsLanguageAndText() {
        let html = #"<div class="codehilite"><pre><code class="language-swift">let x = 1</code></pre></div>"#
        #expect(MessageMarkup.blocks(from: html) == [.codeBlock(language: "swift", code: "let x = 1")])
    }

    @Test func bulletList() {
        let html = "<ul><li>one</li><li>two</li></ul>"
        #expect(MessageMarkup.blocks(from: html) == [.bulletList([
            [InlineSpan(text: "one")],
            [InlineSpan(text: "two")],
        ])])
    }

    @Test func entitiesAreDecoded() {
        #expect(MessageMarkup.blocks(from: "<p>a &amp; b &lt;c&gt; &#8212; d</p>")
            == [.paragraph([InlineSpan(text: "a & b <c> — d")])])
    }

    @Test func unknownElementsKeepTheirText() {
        #expect(MessageMarkup.blocks(from: "<p>before <mark>kept</mark> after</p>")
            == [.paragraph([InlineSpan(text: "before kept after")])])
    }

    /// Zulip always emits well-formed HTML, so the contract here is only that a
    /// malformed document never silently drops text.
    @Test func unclosedTagsDoNotLoseContent() {
        let text = MessageMarkup.blocks(from: "<p>first<p>second")
            .flatMap { block -> [InlineSpan] in
                if case .paragraph(let spans) = block { return spans }
                return []
            }
            .map(\.text).joined()
        #expect(text.contains("first"))
        #expect(text.contains("second"))
    }

    @Test func emptyContentProducesNoBlocks() {
        #expect(MessageMarkup.blocks(from: "").isEmpty)
        #expect(MessageMarkup.blocks(from: "<p></p>").isEmpty)
    }
}

/// Cases captured verbatim from zulip.futo.org.
struct RealWorldMarkupTests {

    /// An uploaded image sits inside a paragraph, marked `inline-image`. It has to break
    /// out into its own block or it renders as the filename in the middle of a sentence.
    @Test func inlineImageInsideAParagraphBecomesItsOwnBlock() {
        let html = #"<p><img alt="image.png" class="inline-image" data-original-content-type="image/png" data-original-dimensions="2062x1664" data-original-src="/user_uploads/2/60/Tng/image.png" src="/user_uploads/thumbnail/2/60/Tng/image.png/840x560.webp"></p>"#
        #expect(MessageMarkup.blocks(from: html) == [.image(
            source: "/user_uploads/thumbnail/2/60/Tng/image.png/840x560.webp",
            link: "/user_uploads/2/60/Tng/image.png",
            alt: "image.png"
        )])
    }

    /// Realm custom emoji are images too, but they belong in the text.
    @Test func customEmojiStaysInlineAndKeepsItsImage() {
        let html = #"<p>light mode <img alt=":baguettebonk:" class="emoji" src="/user_avatars/2/emoji/images/eb0bc477.gif" title="baguettebonk"></p>"#
        #expect(MessageMarkup.blocks(from: html) == [.paragraph([
            InlineSpan(text: "light mode "),
            InlineSpan(text: ":baguettebonk:", emojiURL: "/user_avatars/2/emoji/images/eb0bc477.gif"),
        ])])
    }

    @Test func textAndImageInOneParagraphSplitInOrder() {
        let html = #"<p>before <img class="inline-image" src="/user_uploads/a.png"> after</p>"#
        let blocks = MessageMarkup.blocks(from: html)
        #expect(blocks.count == 3)
        #expect(blocks[0] == .paragraph([InlineSpan(text: "before")]))
        if case .image(let source, _, _) = blocks[1] {
            #expect(source == "/user_uploads/a.png")
        } else {
            Issue.record("expected an image block in the middle")
        }
        #expect(blocks[2] == .paragraph([InlineSpan(text: "after")]))
    }

    @Test func mentionsAreMarked() {
        let html = #"<p><span class="user-mention silent" data-user-id="2323">Brandon Wees</span> hello</p>"#
        #expect(MessageMarkup.blocks(from: html) == [.paragraph([
            InlineSpan(text: "Brandon Wees", mention: true),
            InlineSpan(text: " hello"),
        ])])
    }

    @Test func quotedReplyKeepsItsImageInsideTheQuote() {
        let html = ##"<p><span class="user-mention silent" data-user-id="2323">Brandon Wees</span> <a href="#narrow/channel/108/near/498801">said</a>:</p><blockquote><p><img alt="x.png" class="inline-image" src="/user_uploads/thumbnail/x.png/840x560.webp"></p></blockquote><p>Thanks</p>"##
        let blocks = MessageMarkup.blocks(from: html)
        #expect(blocks.count == 3)
        if case .quote(let inner) = blocks[1] {
            #expect(inner.count == 1)
            if case .image(let source, _, _) = inner[0] {
                #expect(source == "/user_uploads/thumbnail/x.png/840x560.webp")
            } else {
                Issue.record("the quote should hold an image block")
            }
        } else {
            Issue.record("expected a quote block")
        }
    }
}

struct QuotedReplyTests {

    /// The shape Zulip's quote-and-reply produces, captured from zulip.futo.org.
    @Test func attributionAndQuoteFoldIntoOneReply() {
        let html = ##"<p><span class="user-mention silent" data-user-id="2323">Brandon Wees</span> <a href="#narrow/channel/108-immich-off-topic/topic//near/498801">said</a>:</p><blockquote><p>the original words</p></blockquote><p>Thanks</p>"##
        let blocks = MessageMarkup.blocks(from: html)
        #expect(blocks == [
            .quotedReply(
                author: "Brandon Wees",
                messageID: 498801,
                quoted: [.paragraph([InlineSpan(text: "the original words")])]
            ),
            .paragraph([InlineSpan(text: "Thanks")]),
        ])
    }

    /// A quote the person typed themselves has no attribution line, so it stays a quote.
    @Test func plainBlockquoteIsNotAReply() {
        let html = "<blockquote><p>just quoting</p></blockquote><p>my point</p>"
        #expect(MessageMarkup.blocks(from: html) == [
            .quote([.paragraph([InlineSpan(text: "just quoting")])]),
            .paragraph([InlineSpan(text: "my point")]),
        ])
    }

    /// Prose that mentions someone and links a message is not an attribution line.
    @Test func mentionFollowedByQuoteIsNotAReplyUnlessItEndsWithAColon() {
        let html = ##"<p><span class="user-mention" data-user-id="9">Ana</span> look at <a href="#narrow/channel/1/near/5">this</a> please</p><blockquote><p>x</p></blockquote>"##
        let blocks = MessageMarkup.blocks(from: html)
        #expect(blocks.count == 2)
        if case .quotedReply = blocks[0] {
            Issue.record("ordinary prose should not be folded into a reply")
        }
    }

    @Test func replyWithoutANearLinkIsNotFolded() {
        let html = ##"<p><span class="user-mention" data-user-id="9">Ana</span> said:</p><blockquote><p>x</p></blockquote>"##
        let blocks = MessageMarkup.blocks(from: html)
        if case .quotedReply = blocks.first {
            Issue.record("an attribution with no message link should not be folded")
        }
    }

    @Test func replyKeepsImagesInsideTheQuotedPart() {
        let html = ##"<p><span class="user-mention silent" data-user-id="1">B</span> <a href="#narrow/channel/1/near/42">said</a>:</p><blockquote><p><img alt="x.png" class="inline-image" src="/user_uploads/thumbnail/x.png"></p></blockquote>"##
        let blocks = MessageMarkup.blocks(from: html)
        guard case .quotedReply(_, let id, let quoted) = blocks.first else {
            Issue.record("expected a quoted reply")
            return
        }
        #expect(id == 42)
        #expect(quoted == [.image(source: "/user_uploads/thumbnail/x.png", link: nil, alt: "x.png")])
    }
}
