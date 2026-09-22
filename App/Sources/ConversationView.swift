import GRDB
import SwiftUI
import ZuluStore

/// One conversation: a channel topic, or a DM. Reads messages out of the store and
/// backfills history, since the event queue only carries what arrives after it opened.
struct ConversationView: View {
    enum Source: Equatable, Hashable {
        case topic(channelID: Int, name: String, channelName: String)
        case dm(key: String)
    }

    let source: Source
    @Environment(AppModel.self) private var model

    @State private var messages: [MessageRecord] = []
    @State private var scrollPosition = ScrollPosition(idType: Int.self)
    @State private var readTracker: ReadTracker?

    /// The list stays hidden until the first page is in hand. Rendering an empty list and
    /// then animating it to the bottom as messages trickle in is the jank; waiting costs a
    /// moment of spinner and arrives already in the right place.
    @State private var ready = false
    /// Set a beat after the first render. Until then, arriving messages must not animate.
    @State private var settled = false

    @State private var atBottom = true
    @State private var moreHistoryExists = true
    @State private var loadingOlder = false
    /// Snapshotted when the conversation opens, so the divider does not vanish the moment
    /// the messages behind it are marked read.
    @State private var firstUnreadID: Int?

    /// Five minutes, matching what Discord and Slack settle on.
    private static let groupingWindow = 5 * 60

    var body: some View {
        Group {
            if ready {
                conversation
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .safeAreaBar(edge: .bottom) {
            ComposerBar(source: source, placeholder: placeholder)
        }
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
        .task(id: source) {
            readTracker = ReadTracker { ids in await model.markRead(ids) }
            await load()
        }
        .onDisappear { Task { await readTracker?.flushNow() } }
    }

    private var conversation: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if loadingOlder {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 12)
                }
                ForEach(grouped, id: \.message.id) { entry in
                    if entry.message.id == firstUnreadID {
                        UnreadDivider().padding(.top, 10)
                    }
                    MessageRow(message: entry.message, startsGroup: entry.startsGroup)
                        .padding(.top, entry.startsGroup ? 14 : 2)
                        .onAppear { readTracker?.sawMessage(id: entry.message.id) }
                        .id(entry.message.id)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(DisablesScrollToTop().frame(width: 0, height: 0))
        }
        .defaultScrollAnchor(.bottom)
        .scrollPosition($scrollPosition, anchor: .bottom)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .onScrollGeometryChange(for: ScrollEdges.self) { geometry in
            let fromBottom = geometry.contentSize.height
                - (geometry.contentOffset.y + geometry.containerSize.height)
            return ScrollEdges(
                nearTop: geometry.contentOffset.y < geometry.containerSize.height,
                nearBottom: fromBottom < 120
            )
        } action: { _, edges in
            atBottom = edges.nearBottom
            // Only a scroll the reader actually performed should pull in history. Without
            // that guard the keyboard appearing, or the list growing, fetches another page.
            guard edges.nearTop, settled, scrollPosition.isPositionedByUser else { return }
            Task { await loadOlder() }
        }
        .overlay(alignment: .bottomTrailing) {
            if !atBottom {
                Button {
                    // Going through ScrollPosition rather than a ScrollViewReader means this
                    // wins against an inertial scroll still in flight.
                    withAnimation(.snappy) { scrollPosition.scrollTo(edge: .bottom) }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.body.weight(.semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .padding(.trailing, 16)
                .padding(.bottom, 12)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: atBottom)
        .onChange(of: messages.last?.id) { _, _ in
            guard settled, atBottom else { return }
            withAnimation(.easeOut(duration: 0.2)) { scrollPosition.scrollTo(edge: .bottom) }
        }
    }

    private struct ScrollEdges: Equatable {
        let nearTop: Bool
        let nearBottom: Bool
    }

    /// Consecutive messages from one person collapse under a single header, the way every
    /// chat client does it. A long enough pause starts a new group even for the same sender,
    /// so a conversation picked up hours later does not read as one block.
    private var grouped: [(message: MessageRecord, startsGroup: Bool)] {
        var previous: MessageRecord?
        return messages.map { message in
            defer { previous = message }
            guard let previous, message.id != firstUnreadID else { return (message, true) }
            let sameSender = previous.senderID == message.senderID
            let closeInTime = message.timestamp - previous.timestamp < Self.groupingWindow
            return (message, !(sameSender && closeInTime))
        }
    }

    private var title: String {
        switch source {
        case .topic(_, let name, _): name.isEmpty ? "general chat" : name
        case .dm(let key): model.title(forDM: key)
        }
    }

    private var placeholder: String {
        switch source {
        case .topic(_, let name, _): "Message \(name.isEmpty ? "general chat" : name)"
        case .dm(let key): "Message \(model.title(forDM: key))"
        }
    }

    private func load() async {
        ready = false
        settled = false
        moreHistoryExists = true

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
            var isFirstBatch = true
            for try await rows in observation.values(in: writer) {
                messages = rows
                if isFirstBatch {
                    firstUnreadID = rows.first { !$0.isRead }?.id
                    isFirstBatch = false
                    ready = true
                    // One turn of the run loop is enough for the list to lay out at the
                    // bottom; animating anything before that is what makes opening a
                    // channel look like it is still loading.
                    Task {
                        try? await Task.sleep(for: .milliseconds(250))
                        settled = true
                    }
                }
            }
        } catch {
            // Observation ends when the view goes away; nothing to recover.
        }
    }

    private func loadOlder() async {
        guard moreHistoryExists, !loadingOlder, let oldest = messages.first?.id else { return }
        loadingOlder = true
        defer { loadingOlder = false }

        moreHistoryExists = switch source {
        case .topic(let channelID, let name, _):
            await model.loadOlder(channelID: channelID, topic: name, before: oldest)
        case .dm(let key):
            await model.loadOlder(dmKey: key, before: oldest)
        }
        // Prepended messages push everything down, so the message that was on screen is
        // pinned back where it was.
        scrollPosition.scrollTo(id: oldest, anchor: .top)
    }
}

struct UnreadDivider: View {
    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(.red.opacity(0.6)).frame(height: 1)
            Text("Unread").font(.caption2.weight(.semibold)).foregroundStyle(.red)
            Rectangle().fill(.red.opacity(0.6)).frame(height: 1)
        }
    }
}

struct MessageRow: View {
    let message: MessageRecord
    var startsGroup = true

    private static let avatarSize: CGFloat = 36

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
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
                        if message.editedAt != nil {
                            Text("edited").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                MessageContent(message: message)
            }
        }
    }
}

struct Avatar: View {
    let name: String
    var size: CGFloat = 36

    private var tint: Color {
        // Swift reseeds hashValue per process, so a name would change colour on every
        // launch. This one is stable.
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
