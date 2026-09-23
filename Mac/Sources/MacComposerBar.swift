import SwiftUI
import UniformTypeIdentifiers
import ZuluCompose

/// Return sends; Shift-Return starts a new line. That is what every Mac chat client does,
/// and it is the one behaviour a person notices immediately if it is wrong.
struct MacComposerBar: View {
    let source: ConversationSource
    let placeholder: String

    @Environment(AppModel.self) private var model

    @State private var draft = ""
    @State private var replyingTo: ReplyDraft?
    @State private var sending = false
    @State private var uploading = false
    @State private var sendError: String?
    @State private var importingFile = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let sendError {
                Text(sendError).font(.caption).foregroundStyle(.red)
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
                    importingFile = true
                } label: {
                    Image(systemName: "paperclip")
                }
                .buttonStyle(.borderless)
                .help("Attach a file")

                TextField(placeholder, text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($focused)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    .onSubmit { Task { await send() } }

                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .onChange(of: ComposerInbox.shared.deliveries) { takeDelivery() }
        .fileImporter(
            isPresented: $importingFile, allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { Task { await upload(urls: urls) } }
        }
    }

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
                Image(systemName: "xmark").font(.caption.weight(.bold))
            }
            .buttonStyle(.borderless)
        }
        .padding(.leading, 8)
        .padding(.vertical, 6)
        .frame(height: 42)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func takeDelivery() {
        let key = ConversationKey.of(source)
        if let reply = ComposerInbox.shared.takeReply(for: key) {
            withAnimation(.snappy(duration: 0.24)) { replyingTo = reply }
            focused = true
        }
        guard let text = ComposerInbox.shared.take(for: key) else { return }
        if !draft.isEmpty, !draft.hasSuffix("\n") { draft += "\n" }
        draft += text
        focused = true
    }

    private func send() async {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return }
        sending = true
        sendError = nil
        let previousDraft = draft
        let previousReply = replyingTo
        draft = ""
        withAnimation(.snappy(duration: 0.2)) { replyingTo = nil }
        defer { sending = false }

        let text: String
        if let previousReply, let quote = await model.quotedPrefix(for: previousReply, in: source) {
            text = quote + typed
        } else {
            text = typed
        }

        let failure: String?
        switch source {
        case .topic(let channelID, let name, _):
            failure = await model.send(text, toChannel: channelID, topic: name)
        case .dm(let key):
            failure = await model.send(text, toDM: key)
        }
        if let failure {
            sendError = failure
            draft = previousDraft
            replyingTo = previousReply
        }
    }

    private func upload(urls: [URL]) async {
        uploading = true
        sendError = nil
        defer { uploading = false }

        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let type = UTType(filenameExtension: url.pathExtension) ?? .data
            switch await model.upload(
                data, filename: url.lastPathComponent, contentType: type.preferredMIME
            ) {
            case .success(let markdown):
                if !draft.isEmpty, !draft.hasSuffix("\n") { draft += "\n" }
                draft += markdown + "\n"
            case .failure(let message):
                sendError = message
            }
        }
    }
}
