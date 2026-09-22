import Testing
@testable import ZuluPolls

struct PollReplayTests {

    /// `/poll What did you drink this morning?\nMilk\nTea`, as the server writes it.
    private static let definition = #"{"widget_type":"poll","extra_data":{"question":"What did you drink this morning?","options":["Milk","Tea"]}}"#

    private static let author = 58

    private func poll(_ events: [PollSubmessage]) -> Poll? {
        let log = [PollSubmessage(id: 1, senderID: Self.author, content: Self.definition)] + events
        return MessageWidget(submessages: log)?.poll
    }

    @Test func ordinaryMessageDeclaresNoWidget() {
        #expect(MessageWidget(submessages: []) == nil)
    }

    @Test func definitionSeedsCannedOptions() throws {
        let poll = try #require(poll([]))
        #expect(poll.question == "What did you drink this morning?")
        #expect(poll.options.map(\.key) == ["canned,0", "canned,1"])
        #expect(poll.options.map(\.text) == ["Milk", "Tea"])
        #expect(poll.options.allSatisfy { $0.voterIDs.isEmpty })
    }

    /// `/poll` on its own is legal and opens an empty poll anyone can add options to.
    @Test func definitionWithoutExtraDataIsAnEmptyPoll() throws {
        let log = [PollSubmessage(id: 1, senderID: 58, content: #"{"widget_type":"poll"}"#)]
        let poll = try #require(MessageWidget(submessages: log)?.poll)
        #expect(poll.question.isEmpty)
        #expect(poll.options.isEmpty)
    }

    @Test func voteThenUnvoteLeavesNoVoter() throws {
        let poll = try #require(poll([
            PollSubmessage(id: 2, senderID: 7, content: #"{"type":"vote","key":"canned,0","vote":1}"#),
            PollSubmessage(id: 3, senderID: 7, content: #"{"type":"vote","key":"canned,0","vote":-1}"#),
        ]))
        #expect(poll.options[0].voterIDs.isEmpty)
    }

    @Test func aVoterMayPickSeveralOptions() throws {
        let poll = try #require(poll([
            PollSubmessage(id: 2, senderID: 7, content: #"{"type":"vote","key":"canned,0","vote":1}"#),
            PollSubmessage(id: 3, senderID: 7, content: #"{"type":"vote","key":"canned,1","vote":1}"#),
            PollSubmessage(id: 4, senderID: 9, content: #"{"type":"vote","key":"canned,1","vote":1}"#),
        ]))
        #expect(poll.options[0].voterIDs == [7])
        #expect(poll.options[1].voterIDs == [7, 9])
    }

    /// Votes are a set keyed by voter, so the same vote twice changes nothing and a
    /// retraction of a vote never cast is not an error.
    @Test func repeatedAndUnmatchedVotesAreHarmless() throws {
        let poll = try #require(poll([
            PollSubmessage(id: 2, senderID: 7, content: #"{"type":"vote","key":"canned,0","vote":1}"#),
            PollSubmessage(id: 3, senderID: 7, content: #"{"type":"vote","key":"canned,0","vote":1}"#),
            PollSubmessage(id: 4, senderID: 9, content: #"{"type":"vote","key":"canned,0","vote":-1}"#),
        ]))
        #expect(poll.options[0].voterIDs == [7])
    }

    @Test func newOptionTakesTheSenderAndIndexAsItsKey() throws {
        let poll = try #require(poll([
            PollSubmessage(id: 2, senderID: 7, content: #"{"type":"new_option","idx":1,"option":"Coffee"}"#),
        ]))
        #expect(poll.options.map(\.key) == ["canned,0", "canned,1", "7,1"])
        #expect(poll.options.last?.text == "Coffee")
    }

    @Test func duplicateOptionTextIsDropped() throws {
        let poll = try #require(poll([
            PollSubmessage(id: 2, senderID: 7, content: #"{"type":"new_option","idx":1,"option":"Tea"}"#),
        ]))
        #expect(poll.options.count == 2)
    }

    @Test func duplicateTextInsideTheSlashCommandIsAlsoDropped() throws {
        let content = #"{"widget_type":"poll","extra_data":{"question":"q","options":["Milk","Milk","Tea"]}}"#
        let poll = try #require(
            MessageWidget(submessages: [PollSubmessage(id: 1, senderID: 58, content: content)])?.poll
        )
        #expect(poll.options.map(\.text) == ["Milk", "Tea"])
    }

    /// Events append out of band, so the array reaching replay is not reliably sorted.
    @Test func idOrderDecidesTheOutcomeNotArrayOrder() throws {
        let poll = try #require(poll([
            PollSubmessage(id: 4, senderID: 7, content: #"{"type":"vote","key":"canned,0","vote":1}"#),
            PollSubmessage(id: 3, senderID: 7, content: #"{"type":"vote","key":"canned,0","vote":-1}"#),
            PollSubmessage(id: 2, senderID: 7, content: #"{"type":"vote","key":"canned,0","vote":1}"#),
        ]))
        #expect(poll.options[0].voterIDs == [7])
    }

    @Test func theDefinitionIsWhicheverSubmessageHasTheLowestID() throws {
        let log = [
            PollSubmessage(id: 9, senderID: 7, content: #"{"type":"vote","key":"canned,0","vote":1}"#),
            PollSubmessage(id: 1, senderID: 58, content: Self.definition),
        ]
        let poll = try #require(MessageWidget(submessages: log)?.poll)
        #expect(poll.options[0].voterIDs == [7])
    }

    @Test func malformedContentIsSkippedRatherThanFatal() throws {
        let poll = try #require(poll([
            PollSubmessage(id: 2, senderID: 7, content: "not json at all"),
            PollSubmessage(id: 3, senderID: 7, content: #"{"type":"vote"}"#),
            PollSubmessage(id: 4, senderID: 7, content: "{"),
            PollSubmessage(id: 5, senderID: 7, content: #"{"type":"vote","key":"canned,1","vote":1}"#),
        ]))
        #expect(poll.options[1].voterIDs == [7])
    }

    @Test func aMalformedDefinitionDeclaresNoWidget() {
        #expect(MessageWidget(submessages: [PollSubmessage(id: 1, senderID: 58, content: "{}")]) == nil)
    }

    @Test func unknownEventTypesAreIgnored() throws {
        let poll = try #require(poll([
            PollSubmessage(id: 2, senderID: 7, content: #"{"type":"retract_everything"}"#),
            PollSubmessage(id: 3, senderID: 7, content: #"{"type":"vote","key":"canned,0","vote":1}"#),
        ]))
        #expect(poll.options[0].voterIDs == [7])
    }

    @Test func aVoteForAnUnknownKeyIsDropped() throws {
        let poll = try #require(poll([
            PollSubmessage(id: 2, senderID: 7, content: #"{"type":"vote","key":"99,4","vote":1}"#),
        ]))
        #expect(poll.options.allSatisfy { $0.voterIDs.isEmpty })
    }

    @Test func onlyTheMessageSenderMayChangeTheQuestion() throws {
        let poll = try #require(poll([
            PollSubmessage(id: 2, senderID: 7, content: #"{"type":"question","question":"hijacked"}"#),
            PollSubmessage(id: 3, senderID: Self.author, content: #"{"type":"question","question":"RIGHT NOW?"}"#),
        ]))
        #expect(poll.question == "RIGHT NOW?")
    }

    /// A todo list rides the same transport with a reversed key encoding and a `key` that
    /// is an int on one event and a string on another, so none of it is replayed here.
    @Test func todoWidgetsAreRecognisedButNotReplayed() {
        let content = #"{"widget_type":"todo","extra_data":{"task_list_title":"Today","tasks":[{"task":"Buy milk","desc":"2%"}]}}"#
        let log = [
            PollSubmessage(id: 1, senderID: 58, content: content),
            PollSubmessage(id: 2, senderID: 7, content: #"{"type":"new_task","key":2,"task":"Buy milk","desc":"","completed":false}"#),
            PollSubmessage(id: 3, senderID: 7, content: #"{"type":"strike","key":"2,58"}"#),
        ]
        #expect(MessageWidget(submessages: log) == .unsupported(type: "todo"))
    }

    @Test func zformWidgetsAreUnsupported() {
        let content = #"{"widget_type":"zform","extra_data":null}"#
        #expect(MessageWidget(submessages: [PollSubmessage(id: 1, senderID: 58, content: content)])
            == .unsupported(type: "zform"))
    }

    /// `msg_type` is free text in Zulip's database, so anything that is not a widget is
    /// dead weight rather than something to guess at.
    @Test func submessagesThatAreNotWidgetsAreSkipped() throws {
        let log = [
            PollSubmessage(id: 1, senderID: 58, msgType: "something_new", content: Self.definition),
            PollSubmessage(id: 2, senderID: 58, content: Self.definition),
            PollSubmessage(id: 3, senderID: 7, content: #"{"type":"vote","key":"canned,0","vote":1}"#),
        ]
        let poll = try #require(MessageWidget(submessages: log)?.poll)
        #expect(poll.options[0].voterIDs == [7])
    }
}

struct PollEventTests {

    private static let definition = #"{"widget_type":"poll","extra_data":{"question":"q","options":["Milk"]}}"#

    @Test func votingTogglesAgainstWhatTheLogAlreadySays() throws {
        let log = [
            PollSubmessage(id: 1, senderID: 58, content: Self.definition),
            PollSubmessage(id: 2, senderID: 7, content: #"{"type":"vote","key":"canned,0","vote":1}"#),
        ]
        let poll = try #require(MessageWidget(submessages: log)?.poll)
        #expect(poll.voteEvent(forOption: "canned,0", voter: 7) == .vote(key: "canned,0", add: false))
        #expect(poll.voteEvent(forOption: "canned,0", voter: 9) == .vote(key: "canned,0", add: true))
        #expect(poll.voteEvent(forOption: "canned,9", voter: 7) == nil)
    }

    /// Zulip's clients start at 1 and never reconcile with anyone else's, because the
    /// sender id in the key is what keeps it unique.
    @Test func theNextIndexContinuesAfterWhatTheSenderAlreadyAdded() throws {
        let log = [
            PollSubmessage(id: 1, senderID: 58, content: Self.definition),
            PollSubmessage(id: 2, senderID: 7, content: #"{"type":"new_option","idx":1,"option":"Tea"}"#),
            PollSubmessage(id: 3, senderID: 9, content: #"{"type":"new_option","idx":4,"option":"Coffee"}"#),
        ]
        let poll = try #require(MessageWidget(submessages: log)?.poll)
        #expect(poll.nextOptionIndex(forSender: 7) == 2)
        #expect(poll.nextOptionIndex(forSender: 9) == 5)
        #expect(poll.nextOptionIndex(forSender: 3) == 1)
    }

    @Test func eventsEncodeExactlyTheKeysTheServerAccepts() {
        #expect(PollEvent.vote(key: "58,1", add: true).json == #"{"key":"58,1","type":"vote","vote":1}"#)
        #expect(PollEvent.vote(key: "canned,0", add: false).json
            == #"{"key":"canned,0","type":"vote","vote":-1}"#)
        #expect(PollEvent.newOption(idx: 1, text: "Orange juice").json
            == #"{"idx":1,"option":"Orange juice","type":"new_option"}"#)
        #expect(PollEvent.question("What are you drinking RIGHT NOW?").json
            == #"{"question":"What are you drinking RIGHT NOW?","type":"question"}"#)
    }

    @Test func optionKeysPutTheSenderFirstAndNameTheSeededOnesCanned() {
        #expect(Poll.optionKey(senderID: 58, idx: 1) == "58,1")
        #expect(Poll.optionKey(senderID: nil, idx: 0) == "canned,0")
    }
}
