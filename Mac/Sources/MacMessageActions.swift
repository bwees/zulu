import SwiftUI
import ZuluEmoji
import ZuluStore

extension View {
    /// The Mac's answer to the phone's long press: a bar that appears on hover and a
    /// context menu on right-click, both offering the same things.
    func macMessageActions(_ message: MessageRecord, in source: ConversationSource) -> some View {
        modifier(MacMessageActions(message: message, source: source))
    }
}

private struct MacMessageActions: ViewModifier {
    let message: MessageRecord
    let source: ConversationSource

    @Environment(AppModel.self) private var model
    @Environment(MacUIState.self) private var ui
    @Environment(\.macQuickReactions) private var quickReactions

    @State private var hovering = false
    @State private var showingPicker = false
    @State private var controller: MessageActionsController?
    @State private var confirmingDelete = false

    /// The bar stays while its popover is up, or the popover would lose its anchor and
    /// close the moment the pointer moved.
    private var barVisible: Bool { hovering || showingPicker }

    private var isOwn: Bool { model.isOwn(message) }

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(barVisible ? Color.primary.opacity(0.045) : .clear)
            }
            .padding(.horizontal, -8)
            .overlay(alignment: .topTrailing) {
                if barVisible {
                    bar.offset(x: -4, y: -12)
                }
            }
            .onHover { hovering = $0 }
            .contextMenu { menu }
            .task(id: message.id) {
                controller = MessageActionsController(message: message, model: model)
            }
            .confirmationDialog("Delete this message?", isPresented: $confirmingDelete) {
                Button("Delete", role: .destructive) {
                    Task { _ = await controller?.delete() }
                }
            } message: {
                Text("It is deleted for everyone, and cannot be undone.")
            }
    }

    private var bar: some View {
        HStack(spacing: 2) {
            ForEach(quickReactions) { quick in
                barButton(help: ":\(quick.name):") {
                    Task { await controller?.react(to: quick) }
                } label: {
                    EmojiDisplayView(display: display(of: quick), size: 15)
                }
            }
            if !quickReactions.isEmpty { Divider().frame(height: 14) }

            barButton(help: "Add Reaction") {
                showingPicker = true
            } label: {
                Image(systemName: "face.smiling")
            }
            .popover(isPresented: $showingPicker, arrowEdge: .bottom) {
                MacEmojiPicker { shortcode in
                    Task { await controller?.react(toShortcode: shortcode) }
                }
            }

            barButton(help: "Reply") {
                reply()
            } label: {
                Image(systemName: "arrowshape.turn.up.left")
            }

            if isOwn {
                barButton(help: "Edit") {
                    edit()
                } label: {
                    Image(systemName: "pencil")
                }
            }

            Menu {
                Button("Copy Text") { controller?.copyText() }
                Button("Copy Link") { controller?.copyLink() }
                ownActions
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 22)
                    .contentShape(.rect)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .padding(3)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .transition(.opacity)
    }

    private func barButton<Label: View>(
        help: String, action: @escaping () -> Void, @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            label()
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 22)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private var menu: some View {
        Button("Reply") { reply() }
        Menu("React") {
            ForEach(quickReactions) { quick in
                Button(":\(quick.name):") { Task { await controller?.react(to: quick) } }
            }
            if !quickReactions.isEmpty { Divider() }
            Button("Add Reaction…") { showingPicker = true }
        }
        Divider()
        Button("Copy Text") { controller?.copyText() }
        Button("Copy Link") { controller?.copyLink() }
        ownActions
    }

    @ViewBuilder
    private var ownActions: some View {
        if isOwn {
            Divider()
            Button("Edit Message") { edit() }
            Button("Delete Message…", role: .destructive) { confirmingDelete = true }
        }
    }

    private func edit() {
        Task { _ = await controller?.edit() }
        ui.requestComposerFocus()
    }

    private func reply() {
        ComposerInbox.shared.deliver(reply: ReplyDraft(message: message), to: ConversationKey.of(source))
        ui.requestComposerFocus()
    }

    private func display(of quick: QuickReaction) -> EmojiDisplay {
        EmojiCatalogueLoader.shared.catalogue
            .display(reactionType: quick.type, code: quick.code, name: quick.name)
    }
}

