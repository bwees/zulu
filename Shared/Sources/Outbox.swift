import Foundation
import Observation
import SwiftUI
import ZuluStore

/// A message the person has sent that the server has not yet echoed back. It shows in
/// the conversation straight away, and stays there in red with a retry if it fails.
struct OutgoingMessage: Identifiable, Equatable {
    enum State: Equatable {
        case sending
        case failed(String)
    }

    let id: UUID
    let source: ConversationSource
    /// What was typed, without the quote a reply adds at send time.
    let text: String
    let reply: ReplyDraft?
    let createdAt: Date
    var state: State = .sending
    /// The server's id once it accepted the message. The row stays until the message
    /// itself lands, so there is no gap between the two.
    var sentID: Int?
}

@MainActor
@Observable
final class Outbox {
    private(set) var messages: [OutgoingMessage] = []

    func messages(in source: ConversationSource) -> [OutgoingMessage] {
        messages.filter { $0.source == source }
    }

    func message(_ id: UUID) -> OutgoingMessage? {
        messages.first { $0.id == id }
    }

    func add(_ message: OutgoingMessage) {
        messages.append(message)
    }

    func update(_ id: UUID, _ change: (inout OutgoingMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[index])
    }

    func remove(_ id: UUID) {
        messages.removeAll { $0.id == id }
    }

    /// The event queue often delivers the echo before the send request returns, so an
    /// echo with no pending row yet is held until `sent` claims it.
    private var unclaimedEchoes: Set<Int> = []

    func sent(_ id: UUID, as messageID: Int) {
        if unclaimedEchoes.remove(messageID) != nil {
            remove(id)
        } else {
            update(id) { $0.sentID = messageID }
        }
    }

    func echoed(messageID: Int) {
        if messages.contains(where: { $0.sentID == messageID }) {
            messages.removeAll { $0.sentID == messageID }
        } else if messages.contains(where: { $0.state == .sending && $0.sentID == nil }) {
            unclaimedEchoes.insert(messageID)
        }
    }
}

extension AppModel {
    /// Returns at once. The message shows as pending until the server echoes it back.
    func enqueue(_ text: String, replyingTo reply: ReplyDraft?, in source: ConversationSource) {
        let message = OutgoingMessage(id: UUID(), source: source, text: text, reply: reply, createdAt: .now)
        outbox.add(message)
        Task { await deliver(message.id) }
    }

    func resend(_ id: UUID) {
        outbox.update(id) { $0.state = .sending }
        Task { await deliver(id) }
    }

    func discard(_ id: UUID) {
        outbox.remove(id)
    }

    private func deliver(_ id: UUID) async {
        guard let message = outbox.message(id) else { return }
        // The quote is assembled here rather than when the reply was started, so the
        // field held the person's own words the whole time they were typing.
        var text = message.text
        if let reply = message.reply, let quote = await quotedPrefix(for: reply, in: message.source) {
            text = quote + text
        }
        switch await sendReturningID(text, in: message.source) {
        case .sent(messageID: let sentID):
            outbox.sent(id, as: sentID)
        case .failed(let reason):
            outbox.update(id) { $0.state = .failed(reason) }
        }
    }
}

struct PendingEntry: Identifiable {
    let message: OutgoingMessage
    let startsGroup: Bool

    var id: UUID { message.id }
}

extension AppModel {
    /// The conversation's pending messages, minus any whose real message is already on
    /// screen. Only the first opens a group, and only if the last real message is not
    /// the person's own.
    func pendingEntries(in source: ConversationSource, after loaded: [MessageRecord]) -> [PendingEntry] {
        let loadedIDs = Set(loaded.map(\.id))
        let pending = outbox.messages(in: source).filter { $0.sentID.map { !loadedIDs.contains($0) } ?? true }
        let continuesOwn = loaded.last?.senderID == selfUserID
        return pending.enumerated().map { index, message in
            PendingEntry(message: message, startsGroup: index == 0 && !continuesOwn)
        }
    }
}

/// A pending message, drawn like the person's own message would be once it lands.
struct PendingMessageRow: View {
    let message: OutgoingMessage
    let startsGroup: Bool
    @Environment(AppModel.self) private var model

    private static let avatarSize: CGFloat = 36

    private var failure: String? {
        if case .failed(let reason) = message.state { return reason }
        return nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if startsGroup {
                SenderAvatar(name: senderName, userID: model.selfUserID, size: Self.avatarSize)
            } else {
                Color.clear.frame(width: Self.avatarSize, height: 1)
            }
            VStack(alignment: .leading, spacing: 3) {
                if startsGroup {
                    Text(senderName).font(.subheadline.weight(.semibold))
                }
                Text(Self.rendered(message.text))
                    .foregroundStyle(failure == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.red))
                    .opacity(message.state == .sending ? 0.5 : 1)
                    .textSelection(.enabled)
                if let failure {
                    HStack(spacing: 10) {
                        Label(failure, systemImage: "exclamationmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                        Button("Resend") { model.resend(message.id) }
                            .font(.caption.weight(.semibold))
                        Button("Discard", role: .destructive) { model.discard(message.id) }
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var senderName: String {
        model.selfUserID.map(model.name(forUser:)) ?? ""
    }

    /// Inline markdown only; the server renders the real thing once it lands.
    private static func rendered(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
