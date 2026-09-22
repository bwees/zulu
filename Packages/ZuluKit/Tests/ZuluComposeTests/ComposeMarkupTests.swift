import Testing
@testable import ZuluCompose

struct ComposeMarkupTests {

    @Test func anOrdinaryChannelIsABoldLink() {
        #expect(ComposeMarkup.channelLink(id: 9, name: "announce") == "#**announce**")
        #expect(ComposeMarkup.channelLink(id: 9, name: "design team") == "#**design team**")
    }

    @Test func topicsHangOffTheChannelName() {
        #expect(ComposeMarkup.topicLink(channelID: 9, channelName: "announce", topic: "ship it")
            == "#**announce>ship it**")
    }

    // MARK: the escaping trap

    /// `#**...**` cannot express these at all — `>` opens a topic, `*` closes the
    /// construct, and the rest are eaten by inline markdown before the link pattern
    /// ever sees them. Both official clients fall back to a plain markdown link.
    @Test(arguments: ["a`b", "design > ui", "a*b", "a&b", "a[b", "a]b", "cost $$5"])
    func namesThatCannotBeExpressedFallBackToALink(name: String) {
        #expect(!ComposeMarkup.isLinkable(name))
        let link = ComposeMarkup.channelLink(id: 7, name: name)
        #expect(link.hasPrefix("[#"))
        #expect(link.contains("](#narrow/channel/7-"))
    }

    @Test func theFallbackLinkEscapesEveryOffendingCharacter() {
        #expect(ComposeMarkup.channelLink(id: 7, name: "design > ui")
            == "[#design &gt; ui](#narrow/channel/7-design-.3E-ui)")
        #expect(ComposeMarkup.escaped("a`b*c&d[e]f") == "a&#96;b&#42;c&amp;d&#91;e&#93;f")
        #expect(ComposeMarkup.escaped("cost $$5") == "cost &#36;&#36;5")
    }

    /// The ampersand rule runs in the same pass as the rest, so an entity this
    /// introduces is never escaped a second time into `&amp;#96;`.
    @Test func escapingDoesNotRunTwiceOverItsOwnOutput() {
        #expect(ComposeMarkup.escaped("`") == "&#96;")
        #expect(!ComposeMarkup.escaped("a`b").contains("&amp;"))
    }

    /// A single `$` is only a problem doubled — `$$` opens Zulip's maths syntax.
    @Test func aLoneDollarIsFine() {
        #expect(ComposeMarkup.isLinkable("cost $5"))
        #expect(ComposeMarkup.channelLink(id: 7, name: "cost $5") == "#**cost $5**")
    }

    @Test func aBadTopicNameSinksTheWholeTopicLink() {
        let link = ComposeMarkup.topicLink(channelID: 7, channelName: "design", topic: "a>b")
        #expect(link == "[#design>a&gt;b](#narrow/channel/7-design/topic/a.3Eb)")
    }

    // MARK: mentions

    @Test func mentionsAreBoldAndSilentOnesCarryAnUnderscore() {
        #expect(ComposeMarkup.userMention(fullName: "Ada Lovelace") == "@**Ada Lovelace**")
        #expect(ComposeMarkup.userMention(fullName: "Ada Lovelace", silent: true)
            == "@_**Ada Lovelace**")
    }

    /// The id form is only correct while the name still matches, so it is emitted only
    /// where the name alone would be ambiguous.
    @Test func anIdIsOnlySpelledOutWhenItIsGiven() {
        #expect(ComposeMarkup.userMention(fullName: "Ada Lovelace", userID: 31)
            == "@**Ada Lovelace|31**")
    }

    @Test func groupMentionsUseSingleAsterisks() {
        #expect(ComposeMarkup.groupMention(name: "support") == "@*support*")
        #expect(ComposeMarkup.groupMention(name: "support", silent: true) == "@_*support*")
    }

    @Test func wildcardsAreOrdinaryMentionsOfAReservedWord() {
        #expect(ComposeMarkup.wildcardMention(.channel) == "@**channel**")
        #expect(ComposeMarkup.wildcardMention(.topic) == "@**topic**")
        #expect(ComposeMarkup.Wildcard.topic.isChannelWide == false)
    }

    @Test func emojiInsertTheirNameAndNeverTheirCode() {
        #expect(ComposeMarkup.emoji(named: "party_parrot") == ":party_parrot:")
    }
}
