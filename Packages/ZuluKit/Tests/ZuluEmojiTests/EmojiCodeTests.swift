import Testing
@testable import ZuluEmoji

struct EmojiCodeTests {

    @Test func simpleEmojiIsItsCodepoint() {
        #expect(EmojiCode.code(for: "\u{1F44D}") == "1f44d")
        #expect(EmojiCode.glyph(for: "1f44d") == "\u{1F44D}")
    }

    /// The single most common way to get an emoji code wrong: Zulip strips the emoji
    /// presentation selector, and the server rejects `2764-fe0f` outright.
    @Test func variationSelectorIsStripped() {
        #expect(EmojiCode.code(for: "\u{2764}\u{FE0F}") == "2764")
        #expect(EmojiCode.code(for: "\u{2764}") == "2764")
    }

    @Test func codepointsAreZeroPaddedToFour() {
        #expect(EmojiCode.code(for: "#\u{20E3}") == "0023-20e3")
    }

    @Test func flagsAreARegionalIndicatorPair() {
        #expect(EmojiCode.code(for: "\u{1F1FA}\u{1F1F8}") == "1f1fa-1f1f8")
        #expect(EmojiCode.glyph(for: "1f1fa-1f1f8") == "\u{1F1FA}\u{1F1F8}")
    }

    @Test func zeroWidthJoinersSurvive() {
        let phoenix = "\u{1F426}\u{200D}\u{1F525}"
        #expect(EmojiCode.code(for: phoenix) == "1f426-200d-1f525")

        let running = "\u{1F3C3}\u{200D}\u{2640}\u{200D}\u{27A1}"
        #expect(EmojiCode.code(for: running) == "1f3c3-200d-2640-200d-27a1")
        #expect(EmojiCode.glyph(for: "1f3c3-200d-2640-200d-27a1") == running)
    }

    /// A code with a qualified heart in it still round-trips to the unqualified glyph,
    /// because the selector is dropped on the way in and never re-added.
    @Test func codeRoundTripsThroughGlyph() {
        let code = EmojiCode.code(for: "\u{2764}\u{FE0F}")!
        #expect(EmojiCode.code(for: EmojiCode.glyph(for: code)!) == code)
    }

    @Test func nonsenseCodeDoesNotDecode() {
        #expect(EmojiCode.glyph(for: "zzzz") == nil)
        #expect(EmojiCode.glyph(for: "") == nil)
        // Beyond the Unicode range.
        #expect(EmojiCode.glyph(for: "ffffffff") == nil)
    }
}
