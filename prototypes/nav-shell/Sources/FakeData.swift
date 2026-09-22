// PROTOTYPE — throwaway. Fake realm so the shells have real density to fight with.
import SwiftUI

enum ChannelMode { case forum, chat }

struct Msg: Identifiable {
    let id = UUID()
    let sender: String
    let body: String
    let when: String
    var reactions: [String] = []
}

struct Topic: Identifiable {
    let id = UUID()
    let name: String
    let unread: Int
    let lastSender: String
    let preview: String
    let when: String
    var followed = false
    var muted = false
    var messages: [Msg] = []
}

struct Channel: Identifiable {
    let id = UUID()
    let name: String
    let mode: ChannelMode
    var restricted = false
    var mentions: Int = 0
    var topics: [Topic]
    var unread: Int { topics.filter { !$0.muted }.reduce(0) { $0 + $1.unread } }
}

struct ChannelGroup: Identifiable {
    let id = UUID()
    let name: String
    let initials: String
    let tint: Color
    var channels: [Channel]
    var unread: Int { channels.reduce(0) { $0 + $1.unread } }
    var mentions: Int { channels.reduce(0) { $0 + $1.mentions } }
}

struct DM: Identifiable {
    let id = UUID()
    let name: String
    let preview: String
    let when: String
    let unread: Int
    let isGroup: Bool
    var messages: [Msg] = []
}

private func msgs(_ pairs: [(String, String, String)]) -> [Msg] {
    pairs.map { Msg(sender: $0.0, body: $0.1, when: $0.2) }
}

enum Fake {
    static let me = "bwees"

    static let groups: [ChannelGroup] = [
        ChannelGroup(name: "FUTO", initials: "FU", tint: .orange, channels: [
            Channel(name: "general", mode: .chat, topics: [
                Topic(name: "general", unread: 3, lastSender: "marcy", preview: "anyone else seeing the build hang?", when: "9:41", messages: msgs([
                    ("dana", "morning all", "9:12"),
                    ("marcy", "coffee machine is down again", "9:20"),
                    ("theo", "third time this month", "9:21"),
                    ("marcy", "anyone else seeing the build hang?", "9:41"),
                ]))
            ]),
            Channel(name: "engineering", mode: .forum, mentions: 1, topics: [
                Topic(name: "flaky sync tests", unread: 12, lastSender: "theo", preview: "reverted the retry change for now", when: "11:03", followed: true, messages: msgs([
                    ("theo", "the event-queue tests fail about 1 in 8 runs on CI", "10:40"),
                    ("dana", "is it the re-register path?", "10:44"),
                    ("theo", "pretty sure. the fixture doesn't wait for the new queue id", "10:52"),
                    ("theo", "reverted the retry change for now", "11:03"),
                ])),
                Topic(name: "GRDB migration plan", unread: 0, lastSender: "dana", preview: "v3 lands behind a flag", when: "Tue", messages: msgs([
                    ("dana", "v3 lands behind a flag", "Tue"),
                ])),
                Topic(name: "@bwees can you look at #2841", unread: 1, lastSender: "priya", preview: "needs a second pair of eyes", when: "8:55", messages: msgs([
                    ("priya", "@bwees can you look at #2841, needs a second pair of eyes", "8:55"),
                ])),
                Topic(name: "swift 6 concurrency audit", unread: 4, lastSender: "theo", preview: "sendable warnings down to 40", when: "Mon", messages: msgs([
                    ("theo", "sendable warnings down to 40", "Mon"),
                ])),
                Topic(name: "postmortem: 09-14 outage", unread: 0, lastSender: "dana", preview: "doc is up for comment", when: "Sep 15", messages: msgs([
                    ("dana", "doc is up for comment", "Sep 15"),
                ])),
                Topic(name: "hiring loop feedback", unread: 0, lastSender: "priya", preview: "moved to the private channel", when: "Sep 12", muted: true, messages: msgs([
                    ("priya", "moved to the private channel", "Sep 12"),
                ])),
            ]),
            Channel(name: "design", mode: .forum, topics: [
                Topic(name: "compose bar explorations", unread: 7, lastSender: "june", preview: "v4 puts the topic chip inline", when: "10:15", followed: true, messages: msgs([
                    ("june", "v4 puts the topic chip inline", "10:15"),
                ])),
                Topic(name: "icon set", unread: 0, lastSender: "june", preview: "SF Symbols only for now", when: "Mon", messages: msgs([
                    ("june", "SF Symbols only for now", "Mon"),
                ])),
                Topic(name: "dark mode contrast", unread: 2, lastSender: "sam", preview: "the muted rows fail AA", when: "Sun", messages: msgs([
                    ("sam", "the muted rows fail AA", "Sun"),
                ])),
            ]),
            Channel(name: "releases", mode: .forum, restricted: true, topics: [
                Topic(name: "2026.9.1", unread: 0, lastSender: "ci", preview: "build 4471 promoted", when: "7:02", messages: msgs([
                    ("ci", "build 4471 promoted", "7:02"),
                ])),
                Topic(name: "2026.9.0", unread: 0, lastSender: "ci", preview: "shipped", when: "Sep 8", messages: msgs([
                    ("ci", "shipped", "Sep 8"),
                ])),
            ]),
            Channel(name: "random", mode: .chat, topics: [
                Topic(name: "general", unread: 0, lastSender: "sam", preview: "look at this bird", when: "Yesterday", messages: msgs([
                    ("sam", "look at this bird", "Yesterday"),
                ]))
            ]),
        ]),
        ChannelGroup(name: "Zulip Dev", initials: "ZD", tint: .blue, channels: [
            Channel(name: "api design", mode: .forum, mentions: 2, topics: [
                Topic(name: "event queue lifetimes", unread: 23, lastSender: "gnprice", preview: "the 10 minute default is the one to beat", when: "11:50", followed: true, messages: msgs([
                    ("gnprice", "the 10 minute default is the one to beat", "11:50"),
                ])),
                Topic(name: "topic move semantics", unread: 5, lastSender: "alya", preview: "propagate_mode needs docs", when: "9:30", messages: msgs([
                    ("alya", "propagate_mode needs docs", "9:30"),
                ])),
                Topic(name: "@bwees re: unread counts", unread: 1, lastSender: "alya", preview: "you asked about muted rollup", when: "Tue", messages: msgs([
                    ("alya", "you asked about muted rollup", "Tue"),
                ])),
            ]),
            Channel(name: "mobile", mode: .forum, topics: [
                Topic(name: "flutter client status", unread: 3, lastSender: "chris", preview: "beta 14 is out", when: "Mon", messages: msgs([
                    ("chris", "beta 14 is out", "Mon"),
                ])),
                Topic(name: "notification bouncer", unread: 0, lastSender: "tim", preview: "self-hosters need to register", when: "Sep 10", messages: msgs([
                    ("tim", "self-hosters need to register", "Sep 10"),
                ])),
            ]),
            Channel(name: "help", mode: .chat, topics: [
                Topic(name: "general", unread: 1, lastSender: "newcomer", preview: "how do I get an API key?", when: "12:01", messages: msgs([
                    ("newcomer", "how do I get an API key?", "12:01"),
                ]))
            ]),
        ]),
        ChannelGroup(name: "Home Lab", initials: "HL", tint: .green, channels: [
            Channel(name: "infra", mode: .chat, restricted: true, topics: [
                Topic(name: "general", unread: 0, lastSender: "bwees", preview: "moved the NAS to 10G", when: "Sat", messages: msgs([
                    ("bwees", "moved the NAS to 10G", "Sat"),
                ]))
            ]),
            Channel(name: "alerts", mode: .chat, topics: [
                Topic(name: "general", unread: 41, lastSender: "prometheus", preview: "disk usage 91% on nas-01", when: "12:14", messages: msgs([
                    ("prometheus", "disk usage 91% on nas-01", "12:14"),
                ]))
            ]),
        ]),
        ChannelGroup(name: "Reading", initials: "RD", tint: .purple, channels: [
            Channel(name: "papers", mode: .forum, topics: [
                Topic(name: "CRDTs for chat ordering", unread: 0, lastSender: "bwees", preview: "skimmed, not convinced", when: "Sep 9", messages: msgs([
                    ("bwees", "skimmed, not convinced", "Sep 9"),
                ])),
            ]),
        ]),
    ]

    static let dms: [DM] = [
        DM(name: "priya", preview: "thanks, merged", when: "11:58", unread: 0, isGroup: false, messages: msgs([
            ("priya", "thanks, merged", "11:58"),
        ])),
        DM(name: "theo", preview: "can you take the on-call swap friday?", when: "10:02", unread: 2, isGroup: false, messages: msgs([
            ("theo", "can you take the on-call swap friday?", "10:02"),
        ])),
        DM(name: "june, sam", preview: "june: pushed the new spacing", when: "Yesterday", unread: 5, isGroup: true, messages: msgs([
            ("june", "pushed the new spacing", "Yesterday"),
        ])),
        DM(name: "dana", preview: "you: sounds good", when: "Mon", unread: 0, isGroup: false, messages: msgs([
            ("bwees", "sounds good", "Mon"),
        ])),
        DM(name: "alya, gnprice, chris", preview: "chris: see the thread in #api design", when: "Sep 14", unread: 0, isGroup: true, messages: msgs([
            ("chris", "see the thread in #api design", "Sep 14"),
        ])),
    ]

    static var totalDMUnread: Int { dms.reduce(0) { $0 + $1.unread } }
    static var totalMentions: Int { groups.reduce(0) { $0 + $1.mentions } }
}
