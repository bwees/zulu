import SwiftUI
import ZuluStore

/// One conversation on the Mac: the same message history the phone shows, with a
/// composer that sends on Return.
struct MacConversationView: View {
    let source: ConversationSource

    @Environment(AppModel.self) private var model

    @State private var loader: MessageHistoryLoader?
    @State private var readTracker: ReadTracker?
    @State private var scroll = ScrollPosition(idType: Int.self)
    @State private var atBottom = true

    var body: some View {
        Group {
            if let loader, loader.isReady {
                history(loader)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .safeAreaInset(edge: .bottom) {
            MacComposerBar(source: source, placeholder: placeholder)
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        // Without a background the title sits directly on top of the newest message.
        .toolbarBackground(.visible, for: .windowToolbar)
        .task(id: source) {
            let loader = MessageHistoryLoader(source: source, model: model)
            self.loader = loader
            readTracker = ReadTracker { ids in await model.markRead(ids) }
            await loader.start()
            await model.markConversationRead(source)
        }
        .onDisappear {
            loader?.stop()
            Task { await readTracker?.flushNow() }
        }
    }

    private func history(_ loader: MessageHistoryLoader) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if loader.isLoadingOlder {
                    ProgressView().frame(maxWidth: .infinity).frame(height: 44)
                }
                ForEach(loader.grouped) { entry in
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
                    // A pointer has no swipe, so the reply affordance is the hover
                    // action a Mac user would look for instead.
                    .contextMenu {
                        Button("Reply") {
                            ComposerInbox.shared.deliver(
                                reply: ReplyDraft(message: entry.message),
                                to: ConversationKey.of(source)
                            )
                        }
                    }
                    .id(entry.message.id)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollPosition($scroll, anchor: .top)
        .defaultScrollAnchor(.bottom)
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
            if isNearBottom {
                Task { await model.markConversationRead(source) }
            }
        }
        .onChange(of: loader.messages.last?.id) { _, newest in
            guard atBottom, newest != nil else { return }
            withAnimation(.easeOut(duration: 0.2)) { scroll.scrollTo(edge: .bottom) }
        }
    }

    private var title: String {
        switch source {
        case .topic(_, let name, _): name.isEmpty ? "general chat" : name
        case .dm(let key): model.title(forDM: key)
        }
    }

    private var subtitle: String {
        switch source {
        case .topic(_, _, let channelName): "#\(channelName)"
        case .dm: "Direct message"
        }
    }

    private var placeholder: String {
        switch source {
        case .topic(_, let name, _): "Message \(name.isEmpty ? "general chat" : name)"
        case .dm(let key): "Message \(model.title(forDM: key))"
        }
    }
}
