import Foundation

/// One row of a message's submessage log, stripped to what replaying it needs.
///
/// Zulip names this id `id` inside a message's `submessages` array and `submessage_id` on
/// the `submessage` event. The two are normalised into this one field before they get here.
public struct PollSubmessage: Sendable, Equatable, Identifiable {
    /// The only `msg_type` Zulip has ever written. The column is free text, and the server
    /// echoes back whatever a client posts, so anything else is ignored rather than trusted.
    public static let widgetMessageType = "widget"

    public let id: Int
    public let senderID: Int
    public let msgType: String
    /// A JSON document, carried as a string.
    public let content: String

    public init(id: Int, senderID: Int, msgType: String = PollSubmessage.widgetMessageType, content: String) {
        self.id = id
        self.senderID = senderID
        self.msgType = msgType
        self.content = content
    }
}

/// One choice in a poll, and everyone who has voted for it.
public struct PollOption: Sendable, Equatable, Identifiable {
    /// `"<sender_id>,<idx>"`, with the literal `"canned"` in the sender slot for the options
    /// that came from the `/poll` message text.
    public let key: String
    public let text: String
    public var voterIDs: Set<Int>

    public var id: String { key }

    public init(key: String, text: String, voterIDs: Set<Int> = []) {
        self.key = key
        self.text = text
        self.voterIDs = voterIDs
    }
}

/// A poll, as it stands after the whole submessage log has been replayed.
///
/// Zulip's server never tallies a vote — it stores an ordered list of opaque events and
/// leaves every client to fold them into the same answer.
public struct Poll: Sendable, Equatable {
    public var question: String
    public private(set) var options: [PollOption]
    /// The message's sender. Only they may change the question.
    public let authorID: Int

    /// Options seeded from the `/poll` text have no sender, so Zulip's web client coined a
    /// constant to stand in for one.
    public static let cannedSender = "canned"

    public static func optionKey(senderID: Int?, idx: Int) -> String {
        "\(senderID.map(String.init(describing:)) ?? cannedSender),\(idx)"
    }

    /// The `idx` half of the key is local to whoever adds the option; the pair with the
    /// sender id is what makes it unique. Zulip's clients hold it in a counter that starts
    /// again at 1 on reload — reading it back off the log instead survives a relaunch.
    public func nextOptionIndex(forSender id: Int) -> Int {
        let mine = options.compactMap { option -> Int? in
            let parts = option.key.split(separator: ",")
            guard parts.count == 2, parts[0] == String(id) else { return nil }
            return Int(parts[1])
        }
        return (mine.max() ?? 0) + 1
    }

    /// Whether the toggle should add or remove. Votes are a set keyed by voter, so the
    /// client decides the direction and the server only applies it.
    public func voteEvent(forOption key: String, voter id: Int) -> PollEvent? {
        guard let option = options.first(where: { $0.key == key }) else { return nil }
        return .vote(key: key, add: !option.voterIDs.contains(id))
    }
}

/// What submessage 0 declares.
///
/// A message carrying any widget must not render its own body: the server leaves the raw
/// `/poll` text in `content` and every Zulip client throws that away rather than showing it
/// under the widget.
public enum MessageWidget: Sendable, Equatable {
    case poll(Poll)
    /// A widget kind Zulu does not draw — `todo`, `zform`, or something newer. Its events
    /// are left alone, since a todo list reverses the key encoding and changes the type of
    /// `key` between its own events.
    case unsupported(type: String)

    /// Returns `nil` when the log declares no widget, which is the case for every ordinary
    /// message.
    public init?(submessages: [PollSubmessage]) {
        let log = submessages
            .filter { $0.msgType == PollSubmessage.widgetMessageType }
            .sorted { $0.id < $1.id }

        guard let declaration = log.first,
              let definition = WidgetDefinition(json: declaration.content)
        else { return nil }

        guard definition.widgetType == "poll" else {
            self = .unsupported(type: definition.widgetType)
            return
        }
        self = .poll(Poll(
            definition: definition,
            authorID: declaration.senderID,
            events: log.dropFirst()
        ))
    }

    public var poll: Poll? {
        if case .poll(let poll) = self { return poll }
        return nil
    }
}

extension Poll {

    fileprivate init(definition: WidgetDefinition, authorID: Int, events: ArraySlice<PollSubmessage>) {
        question = definition.question
        options = []
        self.authorID = authorID

        for (idx, text) in definition.options.enumerated() {
            add(option: text, key: Poll.optionKey(senderID: nil, idx: idx))
        }
        for event in events { apply(event) }
    }

    private mutating func add(option text: String, key: String) {
        // `/poll` happily accepts the same line twice and the server stores both, so every
        // Zulip client drops the repeat. Keeping it would show an option the web app hides.
        guard !options.contains(where: { $0.text == text || $0.key == key }) else { return }
        options.append(PollOption(key: key, text: text))
    }

    private mutating func apply(_ submessage: PollSubmessage) {
        guard let event = PollEventPayload(json: submessage.content) else { return }

        switch event.type {
        case "new_option":
            guard let idx = event.idx, let option = event.option else { return }
            add(option: option, key: Poll.optionKey(senderID: submessage.senderID, idx: idx))

        case "question":
            guard submessage.senderID == authorID, let text = event.question else { return }
            question = text

        case "vote":
            guard let key = event.key, let vote = event.vote,
                  let index = options.firstIndex(where: { $0.key == key })
            else { return }
            if vote == 1 {
                options[index].voterIDs.insert(submessage.senderID)
            } else if vote == -1 {
                options[index].voterIDs.remove(submessage.senderID)
            }

        default:
            break
        }
    }
}

// MARK: - Wire shapes

struct WidgetDefinition {
    let widgetType: String
    let question: String
    let options: [String]

    private struct Wire: Decodable {
        let widget_type: String
        let extra_data: ExtraData?

        struct ExtraData: Decodable {
            let question: String?
            let options: [String]?
        }
    }

    init?(json: String) {
        guard let wire = Wire.decode(json) else { return nil }
        widgetType = wire.widget_type
        question = wire.extra_data?.question ?? ""
        options = wire.extra_data?.options ?? []
    }
}

/// Every poll event in one shape. A todo event decoded through this fails on `key`, which
/// is an int there and a string here — and a failed decode is dropped, not fatal.
struct PollEventPayload: Decodable {
    let type: String
    let idx: Int?
    let option: String?
    let question: String?
    let key: String?
    let vote: Int?
}

extension PollEventPayload {
    init?(json: String) {
        guard let decoded = Self.decode(json) else { return nil }
        self = decoded
    }
}

extension Decodable {
    /// Anything a hostile or newer server can put in a submessage has to be survivable, so
    /// every parse here answers with `nil` rather than throwing into the message list.
    static func decode(_ json: String) -> Self? {
        try? JSONDecoder().decode(Self.self, from: Data(json.utf8))
    }
}
