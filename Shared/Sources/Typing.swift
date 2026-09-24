import Foundation
import Observation
import SwiftUI
import ZulipAPI
import ZuluStore

/// Who is typing where, keyed by `ConversationKey`. Every start carries its own expiry,
/// so a typist whose connection dropped before sending a stop still disappears.
@MainActor
@Observable
final class TypingIndicators {
    private struct Typist: Hashable {
        let conversation: String
        let userID: Int
    }

    private var expiries: [Typist: Task<Void, Never>] = [:]

    func userIDs(in conversation: String) -> [Int] {
        expiries.keys.filter { $0.conversation == conversation }.map(\.userID)
    }

    func start(_ userID: Int, in conversation: String) {
        let typist = Typist(conversation: conversation, userID: userID)
        expiries[typist]?.cancel()
        expiries[typist] = Task { [weak self] in
            try? await Task.sleep(for: TypingTiming.startedExpiry)
            guard !Task.isCancelled else { return }
            self?.stop(userID, in: conversation)
        }
    }

    func stop(_ userID: Int, in conversation: String) {
        expiries.removeValue(forKey: Typist(conversation: conversation, userID: userID))?.cancel()
    }
}

/// Tells the server one composer is being typed in: a start repeated while typing goes
/// on, and a stop once it pauses, empties, or sends.
@MainActor
final class TypingSender {
    private let send: (TypingOp) async -> Void
    private var lastStart: ContinuousClock.Instant?
    private var stopTask: Task<Void, Never>?
    /// Requests are chained so a stop can never overtake the start before it.
    private var inFlight: Task<Void, Never>?

    init(send: @escaping (TypingOp) async -> Void) {
        self.send = send
    }

    func draftChanged(to draft: String) {
        guard !draft.isEmpty else {
            stop()
            return
        }
        let now = ContinuousClock.now
        if lastStart.map({ now - $0 >= TypingTiming.startedWait }) ?? true {
            lastStart = now
            enqueue(.start)
        }
        stopTask?.cancel()
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: TypingTiming.stoppedWait)
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    func stop() {
        stopTask?.cancel()
        stopTask = nil
        guard lastStart != nil else { return }
        lastStart = nil
        enqueue(.stop)
    }

    private func enqueue(_ op: TypingOp) {
        inFlight = Task { [previous = inFlight, send] in
            await previous?.value
            await send(op)
        }
    }
}

extension AppModel {
    func apply(_ event: TypingEvent) {
        guard let selfID = account?.userID, event.senderID != selfID else { return }
        let conversation: String
        if let channelID = event.channelID {
            conversation = ConversationKey.of(.topic(channelID: channelID, name: event.topic ?? "", channelName: ""))
        } else {
            conversation = ConversationKey.of(.dm(key: MessageRecord.dmKey(for: event.recipientIDs, selfUserID: selfID)))
        }
        switch event.op {
        case .start: typing.start(event.senderID, in: conversation)
        case .stop: typing.stop(event.senderID, in: conversation)
        }
    }

    /// A message landing is the end of its sender's typing, whether or not a stop
    /// arrives after it.
    func clearTyping(after message: ZulipMessage) {
        guard let selfID = account?.userID else { return }
        let source: ConversationSource = if let channelID = message.stream_id, message.isChannelMessage {
            .topic(channelID: channelID, name: message.subject, channelName: "")
        } else {
            .dm(key: MessageRecord.dmKey(for: message.dmParticipants.map(\.id), selfUserID: selfID))
        }
        typing.stop(message.sender_id, in: ConversationKey.of(source))
    }

    func typistNames(in source: ConversationSource) -> [String] {
        typing.userIDs(in: ConversationKey.of(source)).map(name(forUser:)).sorted()
    }
}

/// "Ana is typing…" under a conversation. Empty and zero-height when nobody is.
struct TypingIndicatorView: View {
    let source: ConversationSource
    @Environment(AppModel.self) private var model

    /// Past this many names the line stops listing them.
    private static let namedLimit = 2

    var body: some View {
        let names = model.typistNames(in: source)
        if let text = Self.describe(names) {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .transition(.opacity)
        }
    }

    static func describe(_ names: [String]) -> String? {
        switch names.count {
        case 0: nil
        case 1: "\(names[0]) is typing…"
        case ...namedLimit: "\(names.joined(separator: " and ")) are typing…"
        default: "Several people are typing…"
        }
    }
}
