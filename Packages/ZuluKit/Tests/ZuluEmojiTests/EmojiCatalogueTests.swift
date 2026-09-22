import Testing
@testable import ZuluEmoji

/// A stand-in for the server's table, small enough to reason about. The real one is
/// 1883 codes with the canonical name at index 0 and CLDR keywords after it.
private let table = ServerEmojiData(codeToNames: [
    "1f44d": ["+1", "thumbs_up", "like"],
    "1f389": ["tada", "party"],
    "1f642": ["slight_smile"],
    "2764": ["heart"],
    "1f6e0": ["working_on_it"],
    "1f419": ["octopus"],
    "1f604": ["smile"],
    "1f463": ["footprints"],
    "1f34b-200d-1f7e9": ["lime", "citrus", "margarita"],
])

private func emoji(_ name: String, _ code: String = "1", deactivated: Bool = false) -> RealmEmojiItem {
    RealmEmojiItem(
        code: code, name: name, sourceURL: "/user_avatars/2/emoji/images/\(code).png",
        deactivated: deactivated
    )
}

struct EmojiCatalogueTests {

    @Test func canonicalNameIsTheFirstOneAndTheRestAreAliases() {
        let catalogue = EmojiCatalogue(unicode: table)
        let thumbs = catalogue.resolve(name: "+1")
        #expect(thumbs?.code == "1f44d")
        #expect(thumbs?.aliases == ["thumbs_up", "like"])
        // An alias resolves to the same emoji, which still displays its canonical name.
        #expect(catalogue.resolve(name: "like")?.name == "+1")
    }

    // MARK: resolution order

    @Test func activeRealmEmojiShadowsTheUnicodeEmojiOfTheSameName() {
        let catalogue = EmojiCatalogue(unicode: table, realmEmoji: [emoji("smile", "7")])
        let resolved = catalogue.resolve(name: "smile")
        #expect(resolved?.kind == .realm)
        #expect(resolved?.code == "7")
        // And the shadowed unicode emoji is gone entirely, rather than offered under a
        // name that would resolve to something else.
        #expect(!catalogue.candidates.contains { $0.kind == .unicode && $0.code == "1f604" })
    }

    @Test func zulipIsSynthesizedBecauseTheServerNeverListsIt() {
        let catalogue = EmojiCatalogue(unicode: table)
        #expect(catalogue.resolve(name: "zulip")?.kind == .zulipExtra)
    }

    /// The server checks active realm emoji before `zulip`, so a realm emoji by that
    /// name wins and there is no second candidate under the same name.
    @Test func aRealmEmojiNamedZulipReplacesTheSynthesizedOne() {
        let catalogue = EmojiCatalogue(unicode: table, realmEmoji: [emoji("zulip", "9")])
        #expect(catalogue.resolve(name: "zulip")?.kind == .realm)
        #expect(!catalogue.candidates.contains { $0.kind == .zulipExtra })
    }

    @Test func deactivatedRealmEmojiCannotBeTypedButStillDisplays() {
        let catalogue = EmojiCatalogue(
            unicode: table, realmEmoji: [emoji("retired", "4", deactivated: true)]
        )
        #expect(catalogue.resolve(name: "retired") == nil)
        #expect(catalogue.display(kind: .realm, code: "4", name: "retired")
            == .image(url: "/user_avatars/2/emoji/images/4.png", still: nil))
    }

    @Test func anUnknownNameResolvesToNothing() {
        #expect(EmojiCatalogue(unicode: table).resolve(name: "no_such_emoji") == nil)
    }

    // MARK: display

    @Test func displayFallsBackToLiteralTextRatherThanDroppingTheEmoji() {
        let catalogue = EmojiCatalogue(unicode: table)
        #expect(catalogue.display(kind: .realm, code: "404", name: "gone") == .text(":gone:"))
        #expect(catalogue.display(kind: .unicode, code: "nonsense", name: "gone") == .text(":gone:"))
        #expect(catalogue.display(reactionType: "invented", code: "1", name: "gone") == .text(":gone:"))
    }

    @Test func unicodeDisplayIsTheGlyph() {
        #expect(EmojiCatalogue(unicode: table).display(kind: .unicode, code: "1f44d", name: "+1")
            == .glyph("\u{1F44D}"))
    }

    // MARK: ranking

    /// With nothing typed the ranking has to produce the picker's layout on its own:
    /// popular first, then the realm's own emoji and `:zulip:`, then everything else.
    @Test func anEmptyQueryPutsPopularThenCustomEmojiFirst() {
        let catalogue = EmojiCatalogue(unicode: table, realmEmoji: [emoji("party_parrot", "3")])
        let names = catalogue.search("").map(\.name)

        #expect(Array(names.prefix(6)) == ["+1", "tada", "slight_smile", "heart", "working_on_it", "octopus"])
        #expect(names[6] == "party_parrot")
        #expect(names[7] == "zulip")
    }

    @Test func customEmojiOutrankUnicodeEmojiAtTheSameMatchQuality() {
        let catalogue = EmojiCatalogue(unicode: table, realmEmoji: [emoji("lime_custom", "3")])
        let names = catalogue.search("lim").map(\.name)
        #expect(names == ["lime_custom", "lime"])
    }

    /// The popular six sit above even a custom emoji, which is what the rank table says
    /// and what keeps `:+1:` one keystroke away in a realm full of custom emoji.
    @Test func popularEmojiOutrankCustomOnesAtAWorseMatchQuality() {
        let catalogue = EmojiCatalogue(unicode: table, realmEmoji: [emoji("smiley_custom", "3")])
        #expect(catalogue.search("smi").map(\.name) == ["slight_smile", "smiley_custom", "smile"])
    }

    @Test func anExactMatchBeatsEveryOtherKind() {
        let catalogue = EmojiCatalogue(unicode: table, realmEmoji: [emoji("time", "3")])
        // "lime" would otherwise rank above a unicode word match, but exact wins outright.
        #expect(catalogue.search("octopus").first?.name == "octopus")
    }

    @Test func aliasesAndKeywordsAreSearchable() {
        let catalogue = EmojiCatalogue(unicode: table)
        #expect(catalogue.search("margarita").first?.name == "lime")
        #expect(catalogue.search("thumbs").first?.name == "+1")
    }

    @Test func aQueryWithAnUnderscoreMustStartAtAWordBoundary() {
        let catalogue = EmojiCatalogue(unicode: table)
        #expect(catalogue.search("on_it").map(\.name).contains("working_on_it"))
        // "rking_on" starts mid-word, so it is not a match at all.
        #expect(!catalogue.search("rking_on").map(\.name).contains("working_on_it"))
    }

    @Test func aQueryWithoutAnUnderscoreMatchesAnywhereInTheName() {
        #expect(EmojiCatalogue(unicode: table).search("print").map(\.name).contains("footprints"))
    }

    @Test func spacesInTheQueryStandInForUnderscores() {
        #expect(EmojiCatalogue(unicode: table).search("working on").first?.name == "working_on_it")
    }

    /// Pasting the emoji itself finds it — after the presentation selector is dropped,
    /// which is the case the web client gets wrong.
    @Test func theGlyphItselfIsAnExactQuery() {
        let catalogue = EmojiCatalogue(unicode: table)
        #expect(catalogue.search("\u{2764}\u{FE0F}").first?.name == "heart")
        #expect(catalogue.search(" \u{1F419} ").first?.name == "octopus")
    }

    /// `:zulip:` needs no server data at all, so even the empty catalogue has it.
    @Test func anEmptyCatalogueHasOnlyZulip() {
        #expect(EmojiCatalogue.empty.search("smile").isEmpty)
        #expect(EmojiCatalogue.empty.candidates.map(\.name) == ["zulip"])
        #expect(!EmojiCatalogue.empty.hasUnicodeTable)
    }

    /// Until the server's table arrives the picker is not empty: the realm's own emoji
    /// are already there.
    @Test func realmEmojiAreUsableBeforeTheUnicodeTableArrives() {
        let catalogue = EmojiCatalogue(realmEmoji: [emoji("party_parrot", "3")])
        #expect(catalogue.search("").map(\.name) == ["party_parrot", "zulip"])
    }
}
