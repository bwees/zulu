import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The compose bar owns its own draft.
///
/// It used to live inside `ConversationView`, which re-evaluates whenever the store
/// changes — and the store changes constantly, since reading messages writes to it. Every
/// one of those rebuilds cost the text field its focus, so only the first character of
/// anything typed survived. Holding the draft down here keeps the field out of that path.
struct ComposerBar: View {
    let source: ConversationView.Source
    let placeholder: String

    @Environment(AppModel.self) private var model

    @State private var draft = ""
    @State private var sending = false
    @State private var uploading = false
    @State private var sendError: String?
    @State private var showEmoji = false
    @State private var attachment: AttachmentSource?
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @FocusState private var focused: Bool

    /// Every icon control in the bar is the same circle, so the row reads as one piece.
    private static let controlSize: CGFloat = 26

    var body: some View {
        VStack(spacing: 6) {
            if let sendError {
                Text(sendError).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if uploading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Uploading…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Button("Photo Library", systemImage: "photo.on.rectangle") { attachment = .photos }
                    Button("Choose Files", systemImage: "folder") { attachment = .files }
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button("Take Photo", systemImage: "camera") { attachment = .camera }
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                        .frame(width: Self.controlSize, height: Self.controlSize)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)

                field

                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.semibold))
                        .frame(width: Self.controlSize, height: Self.controlSize)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .sheet(isPresented: $showEmoji) { EmojiPicker { draft.append($0) } }
        .photosPicker(
            isPresented: binding(for: .photos), selection: $pickedPhotos,
            maxSelectionCount: 5, matching: .any(of: [.images, .videos])
        )
        .task(id: pickedPhotos.count) { await uploadPickedPhotos() }
        .fileImporter(
            isPresented: binding(for: .files), allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { Task { await upload(urls: urls) } }
        }
        .fullScreenCover(isPresented: binding(for: .camera)) {
            CameraPicker { data in
                guard let data else { return }
                Task { await upload(data: data, filename: "photo.jpg", contentType: "image/jpeg") }
            }
            .ignoresSafeArea()
        }
    }

    private var field: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField(placeholder, text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .focused($focused)
                .padding(.leading, 14)
                .padding(.vertical, 9)

            Button {
                showEmoji = true
            } label: {
                Image(systemName: "face.smiling")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: Self.controlSize, height: Self.controlSize)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 7)
            .padding(.bottom, 5)
        }
        .glassEffect(.regular, in: .capsule)
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

    // MARK: attachments

    private func binding(for wanted: AttachmentSource) -> Binding<Bool> {
        Binding(
            get: { attachment == wanted },
            set: { if !$0, attachment == wanted { attachment = nil } }
        )
    }

    private func uploadPickedPhotos() async {
        guard !pickedPhotos.isEmpty else { return }
        let items = pickedPhotos
        pickedPhotos = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let type = item.supportedContentTypes.first ?? .data
            let name = "\(UUID().uuidString.prefix(8)).\(type.preferredFilenameExtension ?? "dat")"
            await upload(data: data, filename: name, contentType: type.preferredMIME)
        }
    }

    private func upload(urls: [URL]) async {
        for url in urls {
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
            if !draft.isEmpty, !draft.hasSuffix("\n") { draft += "\n" }
            draft += markdown + "\n"
        case .failure(let message):
            sendError = message
        }
    }
}
