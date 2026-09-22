import Testing
import ZuluEmoji
@testable import ZuluCompose

private func titles(
    _ source: some AutocompleteSource,
    _ query: String,
    context: ComposeContext = ComposeContext(channelID: 1, topic: "ship it")
) -> [String] {
    AutocompleteEngine(sources: [source])
        .suggestions(for: ActiveQuery(trigger: source.trigger, query: query, range: "".startIndex..<"".startIndex),
                     in: context, limit: 50)
        .map(\.title)
}

private func insertions(
    _ source: some AutocompleteSource,
    _ query: String,
    context: ComposeContext = ComposeContext(channelID: 1, topic: "ship it")
) -> [String] {
    AutocompleteEngine(sources: [source])
        .suggestions(for: ActiveQuery(trigger: source.trigger, query: query, range: "".startIndex..<"".startIndex),
                     in: context, limit: 50)
        .map(\.insertion)
}

struct ChannelSourceTests {

    private let source = ChannelAutocompleteSource(channels: [
        ChannelCandidate(id: 1, name: "design", isPinned: false),
        ChannelCandidate(id: 2, name: "design ideas", isPinned: true),
        ChannelCandidate(id: 3, name: "product design", isMuted: true),
        ChannelCandidate(id: 4, name: "general", description: "designs live here"),
        ChannelCandidate(id: 5, name: "archive", isSubscribed: false),
    ])

    @Test func exactThenPrefixThenWordThenDescription() {
        #expect(titles(source, "design")
            == ["design", "design ideas", "product design", "general"])
    }

    @Test func pinnedChannelsWinTiesAndMutedOnesLose() {
        #expect(titles(source, "desi").prefix(2) == ["design ideas", "design"])
    }

    /// Match quality decides the bucket; everything else only orders ties. So an
    /// unsubscribed channel with a better match still comes first.
    @Test func matchQualityOutranksSubscription() {
        #expect(titles(source, "a") == ["archive", "design ideas", "general"])
    }

    @Test func channelsTheViewerIsNotInLoseTies() {
        let source = ChannelAutocompleteSource(channels: [
            ChannelCandidate(id: 1, name: "design lab", isSubscribed: false),
            ChannelCandidate(id: 2, name: "design ideas"),
        ])
        #expect(titles(source, "design") == ["design ideas", "design lab"])
    }

    @Test func aChannelWithAwkwardCharactersStillCompletes() {
        let source = ChannelAutocompleteSource(channels: [
            ChannelCandidate(id: 7, name: "design > ui"),
        ])
        #expect(insertions(source, "design") == ["[#design &gt; ui](#narrow/channel/7-design-.3E-ui)"])
    }
}

struct MentionSourceTests {

    private let people = [
        PersonCandidate(id: 1, fullName: "Ada Lovelace", email: "ada@example.com"),
        PersonCandidate(
            id: 2, fullName: "Alan Turing", email: "alan@example.com",
            isSubscribedToChannel: true, latestInTopic: 40
        ),
        PersonCandidate(
            id: 3, fullName: "Alonzo Church", email: "alonzo@example.com",
            isSubscribedToChannel: true, latestInChannel: 90
        ),
        PersonCandidate(id: 4, fullName: "Grace Hopper", email: "grace@example.com", isBot: true),
    ]

    private var source: MentionAutocompleteSource {
        MentionAutocompleteSource(people: people, groups: [
            GroupCandidate(id: 10, name: "alumni"),
            GroupCandidate(id: 11, name: "admins", isMentionable: false),
        ])
    }

    /// Subscription first, then recency, then alphabetical — web's rule for the first
    /// and zulip-flutter's for the rest.
    @Test func subscribersOutrankRecencyWhichOutranksTheAlphabet() {
        #expect(titles(source, "al") == ["@all", "Alan Turing", "Alonzo Church", "alumni"])
    }

    /// Someone who spoke in this very topic beats someone who only spoke in the channel,
    /// however much more recently.
    @Test func recencyInTheTopicBeatsRecencyInTheChannel() {
        #expect(titles(source, "a").prefix(3) == ["@all", "Alan Turing", "Alonzo Church"])
    }

    /// Groups sit in their own buckets below every person bucket, so even a group named
    /// exactly what was typed loses to someone whose name merely starts with it.
    @Test func everyGroupRanksBelowEveryPerson() {
        let source = MentionAutocompleteSource(people: people, groups: [
            GroupCandidate(id: 10, name: "al"),
            GroupCandidate(id: 11, name: "alumni"),
        ])
        #expect(titles(source, "al")
            == ["@all", "Alan Turing", "Alonzo Church", "al", "alumni"])
    }

    /// A group the viewer may not mention out loud would produce a message the server
    /// refuses, so it is not offered — but it is still offered silently.
    @Test func aGroupTheViewerCannotMentionIsOnlyOfferedSilently() {
        #expect(!titles(source, "admin").contains("admins"))
        #expect(titles(source, "_admin").contains("admins"))
    }

    @Test func silentQueriesInsertTheSilentForms() {
        #expect(insertions(source, "_Ada") == ["@_**Ada Lovelace**"])
        #expect(insertions(source, "_alum") == ["@_*alumni*"])
    }

    /// There is no silent wildcard syntax on the server, so `@_` offers none.
    @Test func silentQueriesOfferNoWildcards() {
        #expect(!titles(source, "_al").contains("@all"))
    }

    @Test func onlyOneChannelWildcardIsEverOffered() {
        // `all`, `everyone`, `channel` and `stream` notify the same people.
        #expect(titles(source, "").filter { $0.hasPrefix("@") } == ["@all"])
        #expect(titles(source, "chan") == ["@channel"])
    }

    @Test func directMessagesOfferNoChannelWildcard() {
        #expect(!titles(source, "chan", context: ComposeContext()).contains("@channel"))
        #expect(titles(source, "every", context: ComposeContext()) == ["@everyone"])
    }

    @Test func emailPrefixesAreTheLastResort() {
        #expect(titles(source, "grace@ex") == ["Grace Hopper"])
    }

    /// A bot that matches better than a human still wins, which is where zulip-flutter
    /// deliberately parted from web.
    @Test func botsAreNotSunkBelowABetterMatch() {
        #expect(titles(source, "grace") == ["Grace Hopper"])
    }

    /// `@**name|id**` is rejected by the server the moment the name stops matching, so
    /// the id only appears where the name alone would pick the wrong person.
    @Test func anIdIsSpelledOutOnlyWhenTheNameIsAmbiguous() {
        let source = MentionAutocompleteSource(people: [
            PersonCandidate(id: 1, fullName: "Ada Lovelace"),
            PersonCandidate(id: 2, fullName: "Ada Lovelace"),
            PersonCandidate(id: 3, fullName: "Alan Turing"),
        ], groups: [])
        #expect(insertions(source, "Ada") == ["@**Ada Lovelace|1**", "@**Ada Lovelace|2**"])
        #expect(insertions(source, "Alan") == ["@**Alan Turing**"])
    }

    /// Someone actually named "all" would otherwise be mentioned as the wildcard.
    @Test func aPersonNamedLikeAWildcardAlwaysGetsTheirId() {
        let source = MentionAutocompleteSource(
            people: [PersonCandidate(id: 5, fullName: "all")], groups: []
        )
        #expect(insertions(source, "all").contains("@**all|5**"))
    }
}
