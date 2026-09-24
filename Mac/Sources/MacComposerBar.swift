import SwiftUI
import UniformTypeIdentifiers
import ZuluCompose

/// The compose bar owns its own draft, for the same reason the phone's does: the
/// conversation above it re-evaluates whenever the store changes, and the store changes
/// constantly.
struct MacComposerBar: View {
    let source: ConversationSource
    let placeholder: String

    @Environment(AppModel.self) private var model
    @Environment(MacUIState.self) private var ui

    @State private var draft = ""
    @State private var cursor = 0
    @State private var pendingCursor: Int?
    @State private var focusToken = 0
    @State private var replyingTo: ReplyDraft?
    @State private var uploading = false
    @State private var sendError: String?
    @State private var importingFiles = false
    @State private var showingEmoji = false
    @State private var autocomplete: ComposeAutocompleteController?
    @State private var typingSender: TypingSender?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let sendError {
                Label(sendError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
            }
            if uploading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Uploading…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let replyingTo { replyBanner(replyingTo) }

            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    importingFiles = true
                } label: {
                    Image(systemName: "paperclip")
                        .font(.body)
                        .frame(width: 26, height: 26)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .help("Attach Files")
                .padding(.bottom, 2)

                field

                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.semibold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send  ⏎")
                .padding(.bottom, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // Floats above the bar rather than sitting in it: in the bar, every suggestion
        // list that opened or closed resized it and moved the conversation.
        .overlay(alignment: .topLeading) {
            if let autocomplete, autocomplete.isOpen {
                MacAutocompleteBox(
                    suggestions: autocomplete.suggestions,
                    selectedIndex: autocomplete.selectedIndex
                ) { accept($0) }
                .padding(.horizontal, 12)
                .alignmentGuide(.top) { $0[.bottom] }
            }
        }
        .task(id: source) {
            typingSender?.stop()
            restoreDraft()
            typingSender = TypingSender { [model, source] op in await model.sendTyping(op, in: source) }
            EmojiCatalogueLoader.shared.start(store: model.storeForReading)
            let controller = ComposeAutocompleteController(model: model, source: source)
            await controller.prepare()
            autocomplete = controller
            focusToken += 1
        }
        // The emoji table arrives well after the conversation opens, so the sources are
        // rebuilt when it lands rather than waiting for it up front.
        .task(id: EmojiCatalogueLoader.shared.catalogue.candidates.count) {
            await autocomplete?.prepare()
        }
        .onChange(of: draft) {
            autocomplete?.update(draft: draft, cursorOffsetUTF16: cursor)
            model.saveDraft(draft, replyingTo: replyingTo, in: source)
        }
        .onChange(of: replyingTo) { model.saveDraft(draft, replyingTo: replyingTo, in: source) }
        .onDisappear { typingSender?.stop() }
        .onChange(of: cursor) { autocomplete?.update(draft: draft, cursorOffsetUTF16: cursor) }
        .onChange(of: ComposerInbox.shared.deliveries) { takeDelivery() }
        .onChange(of: ui.composerFocusRequests) { focusToken += 1 }
        .fileImporter(
            isPresented: $importingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { Task { await upload(urls: urls) } }
        }
    }

    private var field: some View {
        HStack(alignment: .bottom, spacing: 4) {
            MacComposerTextView(
                text: $draft,
                cursor: $cursor,
                pendingCursor: $pendingCursor,
                placeholder: placeholder,
                focusToken: focusToken,
                onKey: handle(_:),
                onEdit: { typingSender?.draftChanged(to: $0) },
                onFiles: { urls in Task { await upload(urls: urls) } },
                onImage: { data, type in
                    let name = "pasted-\(Self.stamp()).\(type.preferredFilenameExtension ?? "png")"
                    Task { await upload(data: data, filename: name, contentType: type.preferredMIME) }
                }
            )
            .padding(.leading, 6)

            Button {
                showingEmoji = true
            } label: {
                Image(systemName: "face.smiling")
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Emoji")
            .padding(.trailing, 4)
            .padding(.bottom, 3)
            .popover(isPresented: $showingEmoji, arrowEdge: .top) {
                MacEmojiPicker { insert($0) }
            }
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }

    /// Who is being answered, and enough of what they said to be sure it is the right
    /// message — the same information a sent reply shows, before it is sent.
    private func replyBanner(_ reply: ReplyDraft) -> some View {
        HStack(spacing: 8) {
            Capsule().fill(Color.accentColor).frame(width: 3)
            SenderAvatar(name: reply.author, userID: reply.authorID, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Label("Replying to \(reply.author)", systemImage: "arrowshape.turn.up.left.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Text(reply.preview).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                withAnimation(.snappy(duration: 0.2)) { replyingTo = nil }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Cancel reply  ⎋")
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
        .frame(height: 42)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: keys

    /// Return and Tab accept a suggestion when the box is open and otherwise fall
    /// through; Escape closes whatever is open, the box first and then the reply.
    private func handle(_ key: ComposerKey) -> Bool {
        let open = autocomplete?.isOpen == true
        switch key {
        case .send:
            if open, let suggestion = autocomplete?.selectedSuggestion {
                accept(suggestion)
                return true
            }
            send()
            return true
        case .tab:
            guard open, let suggestion = autocomplete?.selectedSuggestion else { return false }
            accept(suggestion)
            return true
        case .up:
            guard open else { return false }
            autocomplete?.moveSelection(by: -1)
            return true
        case .down:
            guard open else { return false }
            autocomplete?.moveSelection(by: 1)
            return true
        case .escape:
            if open {
                autocomplete?.dismiss()
                return true
            }
            if replyingTo != nil {
                withAnimation(.snappy(duration: 0.2)) { replyingTo = nil }
                return true
            }
            return false
        }
    }

    private func accept(_ suggestion: AutocompleteSuggestion) {
        guard let result = autocomplete?.complete(suggestion, in: draft) else { return }
        draft = result.text
        pendingCursor = result.cursorOffsetUTF16
        focusToken += 1
    }

    /// The picker hands back a shortcode rather than a character, because the server
    /// resolves the name against the realm's own emoji when it renders. It lands at the
    /// cursor, with a space before it so it does not run into the word before it.
    private func insert(_ shortcode: String) {
        let offset = max(0, min(cursor, draft.utf16.count))
        let index = String.Index(utf16Offset: offset, in: draft)
        var insertion = shortcode
        if index > draft.startIndex, let previous = draft[draft.index(before: index)...].first,
           !previous.isWhitespace {
            insertion = " " + insertion
        }
        draft.insert(contentsOf: insertion, at: index)
        pendingCursor = offset + insertion.utf16.count
        focusToken += 1
    }

    private func takeDelivery() {
        let key = ConversationKey.of(source)
        if let reply = ComposerInbox.shared.takeReply(for: key) {
            withAnimation(.snappy(duration: 0.24)) { replyingTo = reply }
            focusToken += 1
        }
        guard let text = ComposerInbox.shared.take(for: key) else { return }
        append(text)
        focusToken += 1
    }

    private func append(_ text: String) {
        if !draft.isEmpty, !draft.hasSuffix("\n") { draft += "\n" }
        draft += text
        pendingCursor = draft.utf16.count
    }

    /// Only into an empty composer, so coming back to the conversation never replaces
    /// something already typed. The cursor goes to the end, where typing left off.
    private func restoreDraft() {
        guard draft.isEmpty, replyingTo == nil, let saved = model.savedDraft(in: source) else { return }
        draft = saved.text
        replyingTo = saved.reply
        pendingCursor = saved.text.utf16.count
    }

    /// Hands the message to the outbox and clears at once; a failure shows on the
    /// message itself, with a resend.
    private func send() {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return }
        model.enqueue(typed, replyingTo: replyingTo, in: source)
        typingSender?.stop()
        sendError = nil
        draft = ""
        autocomplete?.dismiss()
        withAnimation(.snappy(duration: 0.2)) { replyingTo = nil }
    }

    // MARK: attachments

    private func upload(urls: [URL]) async {
        for url in urls where url.isFileURL {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let type = UTType(filenameExtension: url.pathExtension) ?? .data
            await upload(data: data, filename: url.lastPathComponent, contentType: type.preferredMIME)
        }
    }

    /// Zulip uploads first and embeds the result as ordinary markdown, so an attachment
    /// lands in the draft as a link the person can still edit or caption before sending.
    private func upload(data: Data, filename: String, contentType: String) async {
        uploading = true
        sendError = nil
        defer { uploading = false }

        switch await model.upload(data, filename: filename, contentType: contentType) {
        case .success(let markdown):
            append(markdown + "\n")
        case .failure(let message):
            sendError = message
        }
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: .now)
    }
}

/// The suggestion box, sitting above the field with the best match on top and the
/// keyboard's row highlighted. Click or Return picks; the composer moves the highlight.
struct MacAutocompleteBox: View {
    let suggestions: [AutocompleteSuggestion]
    let selectedIndex: Int
    let pick: (AutocompleteSuggestion) -> Void

    var body: some View {
        VStack(spacing: 1) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                Button { pick(suggestion) } label: {
                    HStack(spacing: 8) {
                        SuggestionIcon(icon: suggestion.icon)
                            .frame(width: 20, height: 20)
                        Text(suggestion.title)
                            .font(.callout)
                            .lineLimit(1)
                        if let subtitle = suggestion.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if index == selectedIndex {
                            Text("↩")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(
                        index == selectedIndex ? Color.accentColor.opacity(0.18) : .clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .frame(maxWidth: 460, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }
}
