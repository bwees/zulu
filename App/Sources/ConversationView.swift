import SwiftUI
import ZuluEmoji
import ZuluStore

/// One conversation: a channel topic, or a DM. Reads messages out of the store and
/// backfills history, since the event queue only carries what arrives after it opened.
struct ConversationView: View {
    /// Spelled out here as well because the whole iOS shell navigates by
    /// `ConversationView.Source`, and the type itself is shared with the Mac app.
    typealias Source = ConversationSource

    let source: Source
    @Environment(AppModel.self) private var model

    @State private var loader: MessageHistoryLoader?
    @State private var readTracker: ReadTracker?
    /// Holds the message SwiftUI keeps pinned across data changes. Never written during a
    /// prepend — that is precisely what makes older messages arrive without a jump.
    @State private var scroll = ScrollPosition(idType: Int.self)
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
            VStack(spacing: 0) {
                TypingIndicatorView(source: source)
                ComposerBar(source: source, placeholder: placeholder)
            }
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
            if let forum = forumChannel {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("All topics", systemImage: "list.bullet") {
                        model.destination = .channel(forum.id)
                    }
                }
            }
        }
        .task(id: source) {
            let loader = MessageHistoryLoader(source: source, model: model)
            self.loader = loader
            readTracker = ReadTracker { ids in await model.markRead(ids) }
            // Nothing is marked read here: a conversation opens at its first unread, and
            // the rows the reader scrolls past mark themselves.
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
                            .swipeToReply {
                                ComposerInbox.shared.deliver(
                                    reply: ReplyDraft(message: entry.message),
                                    to: ConversationKey.of(source)
                                )
                            }
                    }
                    .onAppear { readTracker?.sawMessage(id: entry.message.id) }
                    .id(entry.message.id)
                }

                ForEach(model.pendingEntries(in: source, after: loader.messages)) { pending in
                    PendingMessageRow(message: pending.message, startsGroup: pending.startsGroup)
                        .padding(.top, pending.startsGroup ? 14 : 2)
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
        .scrollPosition($scroll, anchor: .top)
        .defaultScrollAnchor(.bottom)
        .onAppear {
            if let firstUnread = loader.firstUnreadID { scroll.scrollTo(id: firstUnread, anchor: .top) }
        }
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
            // Scrolling back down after reading history, and catching up on messages that
            // arrived while the conversation was open, both land here.
            if isNearBottom {
                Task { await model.markConversationRead(source) }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !atBottom {
                Button {
                    withAnimation(.snappy) { scroll.scrollTo(edge: .bottom) }
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
        // The identity anchor pins whatever is on screen, which is right while
        // reading back but wrong at the live edge: a new message would arrive below
        // the fold. Following it only while already at the bottom keeps both.
        //
        // The bottom edge, not the new message's id: anchoring an id scrolls that
        // message's top to the top of the viewport, which runs off the end of the
        // content when the message is the last one.
        .onChange(of: loader.messages.last?.id) { _, newest in
            guard atBottom, newest != nil else { return }
            withAnimation(.easeOut(duration: 0.2)) { scroll.scrollTo(edge: .bottom) }
        }
        // Sending always shows what was sent, even from partway up the history.
        .onChange(of: model.outbox.messages(in: source).count) { old, new in
            guard new > old else { return }
            withAnimation(.easeOut(duration: 0.2)) { scroll.scrollTo(edge: .bottom) }
        }
    }

    private var forumChannel: ChannelSummary? {
        guard case .topic(let channelID, _, _) = source,
              let channel = model.channel(channelID), channel.rendersAsForum
        else { return nil }
        return channel
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

