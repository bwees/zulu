import Foundation
import Testing
import ZulipAPI
@testable import ZuluStore

private func record(
    _ name: String, _ code: String, user: Int,
    type: String = "unicode_emoji", message: Int = 1
) -> ReactionRecord {
    ReactionRecord(
        messageID: message, emojiName: name, emojiCode: code, reactionType: type, userID: user
    )
}

struct ReactionGroupingTests {

    /// `angry` and `angry_face` are one emoji under two names. Grouping by name would
    /// draw the same emoji twice with a count of one each.
    @Test func aliasesSharingACodeCollapseIntoOneChip() {
        let groups = ReactionGroup.group([
            record("angry", "1f620", user: 5),
            record("angry_face", "1f620", user: 6),
        ], selfUserID: nil)

        #expect(groups.count == 1)
        #expect(groups[0].emojiCode == "1f620")
        #expect(groups[0].count == 2)
        #expect(groups[0].userIDs == [5, 6])
    }

    /// A realm emoji's code is a realm-local id, so it can collide with a unicode
    /// codepoint string. The type is half the key for exactly this reason.
    @Test func theSameCodeInTwoTablesIsTwoChips() {
        let groups = ReactionGroup.group([
            record("tick", "1", user: 5, type: "realm_emoji"),
            record("one", "1", user: 6),
        ], selfUserID: nil)

        #expect(groups.count == 2)
        #expect(Set(groups.map(\.id)) == ["realm_emoji:1", "unicode_emoji:1"])
    }

    @Test func theChipIsNamedForTheAliasMostReactorsUsed() {
        let groups = ReactionGroup.group([
            record("angry_face", "1f620", user: 5),
            record("angry", "1f620", user: 6),
            record("angry", "1f620", user: 7),
        ], selfUserID: nil)

        #expect(groups[0].emojiName == "angry")
    }

    @Test func chipsKeepTheOrderTheirFirstReactionArrivedIn() {
        let groups = ReactionGroup.group([
            record("heart", "2764", user: 9),
            record("+1", "1f44d", user: 5),
            record("+1", "1f44d", user: 6),
        ], selfUserID: nil)

        #expect(groups.map(\.emojiCode) == ["2764", "1f44d"])
    }

    @Test func aChipKnowsWhetherYouAreInIt() {
        let records = [record("+1", "1f44d", user: 5), record("+1", "1f44d", user: 6)]

        #expect(ReactionGroup.group(records, selfUserID: 6)[0].includesSelf)
        #expect(!ReactionGroup.group(records, selfUserID: 7)[0].includesSelf)
        #expect(!ReactionGroup.group(records, selfUserID: nil)[0].includesSelf)
    }
}

struct ReactionToggleTests {

    @Test func tappingAnEmojiNobodyUsedAddsIt() {
        let toggle = ReactionGroup.toggle(
            emojiName: "+1", emojiCode: "1f44d", reactionType: "unicode_emoji",
            in: [], by: 5
        )
        #expect(toggle.adds)
        #expect(toggle.emojiName == "+1")
    }

    @Test func tappingAnEmojiSomeoneElseUsedAddsYourOwn() {
        let toggle = ReactionGroup.toggle(
            emojiName: "+1", emojiCode: "1f44d", reactionType: "unicode_emoji",
            in: [record("+1", "1f44d", user: 6)], by: 5
        )
        #expect(toggle.adds)
    }

    @Test func tappingAnEmojiYouAlreadyUsedRemovesIt() {
        let toggle = ReactionGroup.toggle(
            emojiName: "+1", emojiCode: "1f44d", reactionType: "unicode_emoji",
            in: [record("+1", "1f44d", user: 5)], by: 5
        )
        #expect(!toggle.adds)
    }

    /// The server rejects a name that does not resolve to the code it was sent with, so
    /// removal has to send back whichever alias the reaction was recorded under.
    @Test func removalSendsTheAliasTheReactionWasStoredUnder() {
        let toggle = ReactionGroup.toggle(
            emojiName: "thumbs_up", emojiCode: "1f44d", reactionType: "unicode_emoji",
            in: [record("+1", "1f44d", user: 5)], by: 5
        )
        #expect(!toggle.adds)
        #expect(toggle.emojiName == "+1")
    }

    /// The same code under a different type is somebody else's emoji entirely.
    @Test func aDifferentReactionTypeIsNotYourReaction() {
        let toggle = ReactionGroup.toggle(
            emojiName: "one", emojiCode: "1", reactionType: "unicode_emoji",
            in: [record("tick", "1", user: 5, type: "realm_emoji")], by: 5
        )
        #expect(toggle.adds)
    }
}

struct ReactionStoreTests {

    private func store() throws -> ZuluStore {
        let store = try ZuluStore(url: nil)
        try store.writer.write { db in
            try MessageRecord(
                id: 1, channelID: 7, topic: "t", senderID: 5, senderName: "A",
                renderedContent: "<p>hi</p>", timestamp: 0
            ).save(db)
            try MessageRecord(
                id: 2, channelID: 7, topic: "t", senderID: 5, senderName: "A",
                renderedContent: "<p>ho</p>", timestamp: 0
            ).save(db)
        }
        return store
    }

    @Test func groupsComeBackInTheOrderTheReactionsWereWritten() throws {
        let store = try store()
        for row in [
            record("heart", "2764", user: 9),
            record("+1", "1f44d", user: 5),
            record("thumbs_up", "1f44d", user: 6),
        ] {
            try store.setReaction(
                onMessage: 1, emojiName: row.emojiName, emojiCode: row.emojiCode,
                reactionType: row.reactionType, userID: row.userID, present: true
            )
        }

        let groups = try store.reactionGroups(forMessage: 1, selfUserID: 6)
        #expect(groups.map(\.emojiCode) == ["2764", "1f44d"])
        #expect(groups[1].count == 2)
        #expect(groups[1].includesSelf)
    }

    @Test func removingAReactionLeavesEveryoneElsesAlone() throws {
        let store = try store()
        try store.setReaction(
            onMessage: 1, emojiName: "+1", emojiCode: "1f44d",
            reactionType: "unicode_emoji", userID: 5, present: true
        )
        try store.setReaction(
            onMessage: 1, emojiName: "+1", emojiCode: "1f44d",
            reactionType: "unicode_emoji", userID: 6, present: true
        )
        try store.setReaction(
            onMessage: 1, emojiName: "+1", emojiCode: "1f44d",
            reactionType: "unicode_emoji", userID: 5, present: false
        )

        #expect(try store.reactionGroups(forMessage: 1, selfUserID: 5)[0].userIDs == [6])
    }

    @Test func theRealmsMostUsedEmojiAreCountedAcrossMessagesAndAliases() throws {
        let store = try store()
        for (message, name, code, user) in [
            (1, "+1", "1f44d", 5), (1, "thumbs_up", "1f44d", 6),
            (2, "+1", "1f44d", 7), (1, "heart", "2764", 8),
        ] {
            try store.setReaction(
                onMessage: message, emojiName: name, emojiCode: code,
                reactionType: "unicode_emoji", userID: user, present: true
            )
        }

        let tallies = try store.popularReactions(limit: 5)
        #expect(tallies.map(\.emojiCode) == ["1f44d", "2764"])
        #expect(tallies[0].uses == 3)
        #expect(tallies[0].emojiName == "+1")
    }
}
