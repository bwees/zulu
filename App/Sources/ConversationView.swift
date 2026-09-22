import GRDB
import SwiftUI
import ZuluStore

/// One conversation: a channel topic, or a DM. Reads messages out of the store and
/// backfills history once, since the event queue only carries what arrives after it opened.
struct ConversationView: View {
    enum Source: Equatable, Hashable {
        case topic(channelID: Int, name: String, channelName: String)
        case dm(key: String)
    }

    let source: Source
    @Environment(AppModel.self) private var model

    @State private var messages: [MessageRecord] = []
    @State private var draft = ""
    @State private var sendError: String?
    @State private var sending = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(grouped, id: \.message.id) { entry in
                        MessageRow(message: entry.message, startsGroup: entry.startsGroup)
                            .padding(.top, entry.startsGroup ? 14 : 2)
                            .id(entry.message.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .onChange(of: messages.last?.id) { _, last in
                guard let last else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
        .safeAreaBar(edge: .bottom) { composer }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if case .topic(_, _, let channelName) = source {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(title).font(.headline).lineLimit(1)
                        Text("#\(channelName)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task(id: source) { await load() }
    }

    /// Consecutive messages from one person collapse under a single header, the way every
    /// chat client does it. A long enough pause starts a new group even for the same sender,
    /// so a conversation picked up hours later does not read as one block.
    private var grouped: [(message: MessageRecord, startsGroup: Bool)] {
        var previous: MessageRecord?
        return messages.map { message in
            defer { previous = message }
            guard let previous else { return (message, true) }
            let sameSender = previous.senderID == message.senderID
            let closeInTime = message.timestamp - previous.timestamp < Self.groupingWindow
            return (message, !(sameSender && closeInTime))
        }
    }

    /// Five minutes, matching what Discord and Slack settle on.
    private static let groupingWindow = 5 * 60

    private var title: String {
        switch source {
        case .topic(_, let name, _): name.isEmpty ? "general chat" : name
        case .dm(let key): model.title(forDM: key)
        }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if let sendError {
                Text(sendError).font(.caption).foregroundStyle(.red)
            }
            HStack(spacing: 10) {
                TextField(placeholder, text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: sending ? "ellipsis" : "arrow.up")
                        .font(.body.weight(.semibold))
                }
                .buttonStyle(.glassProminent)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var placeholder: String {
        switch source {
        case .topic(_, let name, _): "Message \(name.isEmpty ? "general chat" : name)"
        case .dm(let key): "Message \(model.title(forDM: key))"
        }
    }

    private func load() async {
        guard let writer = model.databaseWriter, let store = model.storeForReading else { return }
        let observation: ValueObservation<ValueReducers.Fetch<[MessageRecord]>>
        switch source {
        case .topic(let channelID, let name, _):
            observation = store.observeMessages(channelID: channelID, topic: name)
            await model.loadHistory(channelID: channelID, topic: name)
        case .dm(let key):
            observation = store.observeMessages(dmKey: key)
            await model.loadHistory(dmKey: key)
        }
        do {
            for try await rows in observation.values(in: writer) {
                messages = rows
                model.markRead(rows.filter { !$0.isRead }.map(\.id))
            }
        } catch {
            // Observation ends when the view goes away; nothing to recover.
        }
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sending = true
        sendError = nil
        let previous = draft
        draft = ""
        defer { sending = false }

        let failure: String?
        switch source {
        case .topic(let channelID, let name, _):
            failure = await model.send(text, toChannel: channelID, topic: name)
        case .dm(let key):
            failure = await model.send(text, toDM: key)
        }
        if let failure {
            sendError = failure
            draft = previous
        }
    }
}

struct MessageRow: View {
    let message: MessageRecord
    var startsGroup = true

    private static let avatarSize: CGFloat = 36
    private static let gutter: CGFloat = 10

    var body: some View {
        HStack(alignment: .top, spacing: Self.gutter) {
            if startsGroup {
                Avatar(name: message.senderName, size: Self.avatarSize)
            } else {
                // Continuations keep the text aligned under the header above them.
                Color.clear.frame(width: Self.avatarSize, height: 1)
            }

            VStack(alignment: .leading, spacing: 3) {
                if startsGroup {
                    HStack(spacing: 6) {
                        Text(message.senderName).font(.subheadline.weight(.semibold))
                        Text(message.date, format: .dateTime.hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(MessageContent.attributed(html: message.renderedContent, messageID: message.id))
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if message.editedAt != nil {
                Text("edited").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

struct Avatar: View {
    let name: String
    var size: CGFloat = 36

    private var tint: Color {
        let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo]
        let seed = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFFFF }
        return palette[seed % palette.count]
    }

    var body: some View {
        Circle()
            .fill(tint.gradient)
            .frame(width: size, height: size)
            .overlay(
                Text(name.prefix(1).uppercased())
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}
