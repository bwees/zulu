import SwiftUI
import ZuluEmoji
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

    @State private var loader: MessageHistoryLoader?
    @State private var readTracker: ReadTracker?
    /// The message SwiftUI keeps pinned across data changes. Never written during a
    /// prepend — that is precisely what makes older messages arrive without a jump.
    @State private var anchoredMessageID: Int?
    @State private var atBottom = true

    var body: some View {
        Group {
            if let loader, loader.isReady {
                conversation(loader)
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
                        // The alias is what the sidebar shows; the real name lives here
                        // so a reference to it elsewhere is still recognisable.
                        Text(model.headerSubtitle(forChannel: channelName))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task(id: source) {
            let loader = MessageHistoryLoader(source: source, model: model)
            self.loader = loader
            readTracker = ReadTracker { ids in await model.markRead(ids) }
            await loader.start()
        }
        .onDisappear {
            loader?.stop()
            Task { await readTracker?.flushNow() }
        }
    }

    private func conversation(_ loader: MessageHistoryLoader) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // Outside the ForEach and deliberately unidentified: a row that appears and
                // disappears inside the stack changes its subview count, which is one of the
                // documented causes of lazy-stack jank.
                if loader.isLoadingOlder {
                    ProgressView().frame(maxWidth: .infinity).frame(height: 44)
                }

                ForEach(loader.grouped) { entry in
                    // One child per message, always. Yielding nothing for some rows would
                    // change the stack's shape as the data moves.
                    VStack(alignment: .leading, spacing: 0) {
                        if entry.message.id == loader.firstUnreadID {
                            UnreadDivider().padding(.top, 10)
                        }
                        MessageRow(
                            message: entry.message,
                            startsGroup: entry.startsGroup,
                            reactions: loader.reactions[entry.message.id] ?? []
                        )
                            .padding(.top, entry.startsGroup ? 14 : 2)
                    }
                    .onAppear { readTracker?.sawMessage(id: entry.message.id) }
                    .id(entry.message.id)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(DisablesScrollToTop().frame(width: 0, height: 0))
        }
        // Anchoring by item identity is what keeps the view still while older messages are
        // prepended. Correcting the offset after the fact — the previous approach — fights
        // this mechanism instead of using it.
        .scrollPosition(id: $anchoredMessageID, anchor: .top)
        .defaultScrollAnchor(.bottom)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .onScrollPhaseChange { _, phase in loader.noteScrollPhase(phase) }
        .onScrollTargetVisibilityChange(idType: Int.self, threshold: 0.1) { visible in
            loader.noteVisible(visible)
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            let fromBottom = geometry.contentSize.height
                - (geometry.contentOffset.y + geometry.containerSize.height)
            return fromBottom < 120
        } action: { _, isNearBottom in
            atBottom = isNearBottom
        }
        .overlay(alignment: .bottomTrailing) {
            if !atBottom {
                Button {
                    // ScrollPosition holds the anchor, so going through it wins against an
                    // inertial scroll still in flight.
                    // Moving the anchor to the newest message is the same mechanism that
                    // holds position, so it wins against an inertial scroll in flight.
                    withAnimation(.snappy) { anchoredMessageID = loader.messages.last?.id }
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
    var reactions: [ReactionGroup] = []

    private static let avatarSize: CGFloat = 36

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if startsGroup {
                SenderAvatar(
                    name: message.senderName,
                    userID: message.senderID,
                    url: message.senderAvatar,
                    size: Self.avatarSize
                )
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
                MessageContent(message: message).messageActions(message, reactions: reactions)
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
