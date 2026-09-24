import Foundation
import Testing
@testable import ZuluCompose

struct OutboxLedgerTests {
    private typealias Ledger = OutboxLedger<String>

    private static let lunch = "c:7/lunch"
    private static let other = "d:3,5"
    private static let me = 5
    private static let window: TimeInterval = 300
    private static let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func sending(_ texts: String..., in conversation: String = lunch, tagged: Bool = true) -> (Ledger, [UUID]) {
        var ledger = Ledger()
        let ids = texts.enumerated().map { offset, text in
            let id = ledger.add(text, in: conversation, at: Self.start.addingTimeInterval(TimeInterval(offset)))
            ledger.attempting(id, tagged: tagged)
            return id
        }
        return (ledger, ids)
    }

    private func pending(_ ledger: Ledger, shown: Set<Int> = [], after preceding: Ledger.Preceding? = nil) -> [Ledger.Pending] {
        ledger.pending(in: Self.lunch, shown: shown, after: preceding, selfUserID: Self.me, groupingWindow: Self.window)
    }

    // MARK: adding

    @Test func aNewMessageIsDeliveringAndBelongsToItsConversation() {
        let (ledger, ids) = sending("hi")
        #expect(ledger.entry(ids[0])?.state == .delivering)
        #expect(ledger.entries(in: Self.lunch).map(\.payload) == ["hi"])
        #expect(ledger.entries(in: Self.other).isEmpty)
    }

    @Test func theLocalIDIsStablePerMessage() {
        let (ledger, ids) = sending("a", "b")
        #expect(ledger.entry(ids[0])?.localID == ids[0].uuidString)
        #expect(ledger.entry(ids[0])?.localID != ledger.entry(ids[1])?.localID)
    }

    // MARK: reply first, then echo

    @Test func theReplyGivesTheMessageItsID() {
        var (ledger, ids) = sending("hi")
        ledger.sent(ids[0], as: 900)
        #expect(ledger.entry(ids[0])?.sentID == 900)
    }

    @Test func aMessageIsDrawnUntilItsRealOneIsShown() {
        var (ledger, ids) = sending("hi")
        ledger.sent(ids[0], as: 900)
        #expect(pending(ledger).map(\.id) == ids)
        #expect(pending(ledger, shown: [900]).isEmpty)
    }

    @Test func settlingDropsOnlyWhatLanded() {
        var (ledger, ids) = sending("a", "b", "c")
        ledger.sent(ids[0], as: 900)
        ledger.sent(ids[1], as: 901)
        ledger.settle(landed: [900, 555])
        #expect(ledger.entries.map(\.payload) == ["b", "c"])
    }

    // MARK: echo first, then reply

    @Test func aTaggedEchoNamesItsSendExactly() {
        var (ledger, ids) = sending("a", "b")
        ledger.echoed(messageID: 901, localID: ids[1].uuidString, in: Self.lunch)
        #expect(ledger.entry(ids[0])?.sentID == nil)
        #expect(ledger.entry(ids[1])?.sentID == 901)
    }

    @Test func echoesArrivingOutOfOrderStillMatch() {
        var (ledger, ids) = sending("a", "b", "c")
        ledger.echoed(messageID: 903, localID: ids[2].uuidString, in: Self.lunch)
        ledger.echoed(messageID: 901, localID: ids[0].uuidString, in: Self.lunch)
        ledger.echoed(messageID: 902, localID: ids[1].uuidString, in: Self.lunch)
        #expect(ids.map { ledger.entry($0)?.sentID } == [901, 902, 903])
    }

    @Test func theReplyAfterATaggedEchoAgrees() {
        var (ledger, ids) = sending("a")
        ledger.echoed(messageID: 900, localID: ids[0].uuidString, in: Self.lunch)
        ledger.sent(ids[0], as: 900)
        #expect(ledger.entry(ids[0])?.sentID == 900)
        ledger.settle(landed: [900])
        #expect(ledger.entries.isEmpty)
    }

    @Test func aTaggedEchoForAMessageAlreadySettledClaimsNothing() {
        var (ledger, ids) = sending("a", tagged: false)
        ledger.echoed(messageID: 900, localID: "gone", in: Self.lunch)
        #expect(ledger.entry(ids[0])?.sentID == nil)
    }

    @Test func anUntaggedEchoGoesToTheOldestUntaggedSend() {
        var (ledger, ids) = sending("a", "b", tagged: false)
        ledger.echoed(messageID: 900, localID: nil, in: Self.lunch)
        ledger.echoed(messageID: 901, localID: nil, in: Self.lunch)
        #expect(ids.map { ledger.entry($0)?.sentID } == [900, 901])
    }

    @Test func anUntaggedEchoLeavesTaggedSendsAlone() {
        var (ledger, ids) = sending("a")
        ledger.echoed(messageID: 900, localID: nil, in: Self.lunch)
        #expect(ledger.entry(ids[0])?.sentID == nil)
    }

    @Test func anUntaggedEchoStaysInItsConversation() {
        var (ledger, ids) = sending("a", in: Self.other, tagged: false)
        ledger.echoed(messageID: 900, localID: nil, in: Self.lunch)
        #expect(ledger.entry(ids[0])?.sentID == nil)
    }

    @Test func anUntaggedEchoSkipsFailedSends() {
        var (ledger, ids) = sending("a", "b", tagged: false)
        ledger.failed(ids[0], reason: "offline")
        ledger.echoed(messageID: 900, localID: nil, in: Self.lunch)
        #expect(ledger.entry(ids[0])?.sentID == nil)
        #expect(ledger.entry(ids[1])?.sentID == 900)
    }

    @Test func theSameEchoTwiceClaimsOnlyOnce() {
        var (ledger, ids) = sending("a", "b", tagged: false)
        ledger.echoed(messageID: 900, localID: nil, in: Self.lunch)
        ledger.echoed(messageID: 900, localID: nil, in: Self.lunch)
        #expect(ids.map { ledger.entry($0)?.sentID } == [900, nil])
    }

    @Test func anEchoForAnIDAlreadyRepliedIsNotClaimedAgain() {
        var (ledger, ids) = sending("a", "b", tagged: false)
        ledger.sent(ids[0], as: 900)
        ledger.echoed(messageID: 900, localID: nil, in: Self.lunch)
        #expect(ledger.entry(ids[1])?.sentID == nil)
    }

    /// Guessing wrong is recoverable: the reply that follows names the right id.
    @Test func theReplyCorrectsAWrongGuess() {
        var (ledger, ids) = sending("a", tagged: false)
        ledger.echoed(messageID: 777, localID: nil, in: Self.lunch)
        ledger.sent(ids[0], as: 900)
        #expect(ledger.entry(ids[0])?.sentID == 900)
        #expect(pending(ledger, shown: [777]).map(\.id) == ids)
    }

    // MARK: failure

    @Test func aFailureCarriesItsReason() {
        var (ledger, ids) = sending("a")
        ledger.failed(ids[0], reason: "offline")
        #expect(ledger.entry(ids[0])?.state == .failed("offline"))
    }

    @Test func aTimeoutFailsAnUnansweredSend() {
        var (ledger, ids) = sending("a")
        ledger.timedOut(ids[0], reason: "slow")
        #expect(ledger.entry(ids[0])?.state == .failed("slow"))
    }

    @Test func aTimeoutAfterTheReplyChangesNothing() {
        var (ledger, ids) = sending("a")
        ledger.sent(ids[0], as: 900)
        ledger.timedOut(ids[0], reason: "slow")
        #expect(ledger.entry(ids[0])?.state == .delivering)
    }

    @Test func aTimeoutAfterTheEchoChangesNothing() {
        var (ledger, ids) = sending("a")
        ledger.echoed(messageID: 900, localID: ids[0].uuidString, in: Self.lunch)
        ledger.timedOut(ids[0], reason: "slow")
        #expect(ledger.entry(ids[0])?.state == .delivering)
    }

    @Test func aTimeoutDoesNotOverwriteARealFailure() {
        var (ledger, ids) = sending("a")
        ledger.failed(ids[0], reason: "rejected")
        ledger.timedOut(ids[0], reason: "slow")
        #expect(ledger.entry(ids[0])?.state == .failed("rejected"))
    }

    @Test func aLateReplyClearsATimeout() {
        var (ledger, ids) = sending("a")
        ledger.timedOut(ids[0], reason: "slow")
        ledger.sent(ids[0], as: 900)
        #expect(ledger.entry(ids[0])?.state == .delivering)
        #expect(ledger.entry(ids[0])?.sentID == 900)
    }

    @Test func aLateTaggedEchoClearsATimeout() {
        var (ledger, ids) = sending("a")
        ledger.timedOut(ids[0], reason: "slow")
        ledger.echoed(messageID: 900, localID: ids[0].uuidString, in: Self.lunch)
        #expect(ledger.entry(ids[0])?.state == .delivering)
    }

    @Test func resendingStartsDeliveringAgain() {
        var (ledger, ids) = sending("a", tagged: false)
        ledger.failed(ids[0], reason: "offline")
        ledger.attempting(ids[0], tagged: true)
        #expect(ledger.entry(ids[0])?.state == .delivering)
        #expect(ledger.entry(ids[0])?.tagged == true)
    }

    @Test func discardingRemovesOnlyThatMessage() {
        var (ledger, ids) = sending("a", "b")
        ledger.remove(ids[0])
        #expect(ledger.entries.map(\.id) == [ids[1]])
    }

    @Test func operationsOnAnUnknownIDAreIgnored() {
        var (ledger, _) = sending("a")
        let before = ledger.entries.map(\.id)
        ledger.sent(UUID(), as: 1)
        ledger.failed(UUID(), reason: "x")
        ledger.timedOut(UUID(), reason: "x")
        ledger.remove(UUID())
        #expect(ledger.entries.map(\.id) == before)
        #expect(ledger.entries[0].sentID == nil)
    }

    // MARK: grouping

    @Test func theFirstMessageOfAConversationStartsAGroup() {
        let (ledger, _) = sending("a")
        #expect(pending(ledger).map(\.startsGroup) == [true])
    }

    @Test func aMessageAfterSomeoneElseStartsAGroup() {
        let (ledger, _) = sending("a")
        let preceding = Ledger.Preceding(senderID: 9, date: Self.start)
        #expect(pending(ledger, after: preceding).map(\.startsGroup) == [true])
    }

    @Test func aMessageRightAfterYourOwnContinuesIt() {
        let (ledger, _) = sending("a")
        let preceding = Ledger.Preceding(senderID: Self.me, date: Self.start.addingTimeInterval(-60))
        #expect(pending(ledger, after: preceding).map(\.startsGroup) == [false])
    }

    @Test func aMessageLongAfterYourOwnStartsAGroup() {
        let (ledger, _) = sending("a")
        let preceding = Ledger.Preceding(senderID: Self.me, date: Self.start.addingTimeInterval(-Self.window))
        #expect(pending(ledger, after: preceding).map(\.startsGroup) == [true])
    }

    @Test func laterPendingMessagesContinueTheFirst() {
        let (ledger, _) = sending("a", "b", "c")
        #expect(pending(ledger).map(\.startsGroup) == [true, false, false])
    }

    /// Once the first lands it is the preceding message, and the next one still
    /// continues it: no header appears or vanishes as the messages land one by one.
    @Test func groupingHoldsAsMessagesLandOneByOne() {
        var (ledger, ids) = sending("a", "b")
        ledger.sent(ids[0], as: 900)
        let landed = Ledger.Preceding(senderID: Self.me, date: Self.start)
        #expect(pending(ledger, shown: [900], after: landed).map(\.startsGroup) == [false])
    }

    @Test func withoutKnowingWhoYouAreEveryMessageStartsAGroup() {
        let (ledger, _) = sending("a", "b")
        let preceding = Ledger.Preceding(senderID: Self.me, date: Self.start)
        let result = ledger.pending(
            in: Self.lunch, shown: [], after: preceding, selfUserID: nil, groupingWindow: Self.window
        )
        #expect(result.map(\.startsGroup) == [true, true])
    }

    @Test func pendingKeepsSendOrder() {
        let (ledger, ids) = sending("a", "b", "c")
        #expect(pending(ledger).map(\.id) == ids)
    }

    @Test func pendingIsScopedToItsConversation() {
        var (ledger, _) = sending("a")
        ledger.add("elsewhere", in: Self.other, at: Self.start)
        #expect(pending(ledger).map(\.entry.payload) == ["a"])
    }

    @Test func aFailedMessageIsStillDrawn() {
        var (ledger, ids) = sending("a")
        ledger.failed(ids[0], reason: "offline")
        #expect(pending(ledger).map(\.id) == ids)
    }
}
