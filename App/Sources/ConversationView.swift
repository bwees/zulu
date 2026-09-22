import GRDB
import PhotosUI
import UniformTypeIdentifiers
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
    @State private var showEmoji = false
    @State private var attachment: AttachmentSource?
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var uploading = false
    @State private var atBottom = true
    /// Snapshotted when the conversation opens, so the divider does not vanish the
    /// moment the messages behind it are marked read.
    @State private var firstUnreadID: Int?
    @State private var readTracker: ReadTracker?

    /// Five minutes, matching what Discord and Slack settle on.
    private static let groupingWindow = 5 * 60

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(grouped, id: \.message.id) { entry in
                        if entry.message.id == firstUnreadID {
                            UnreadDivider()
                                .padding(.top, 10)
                                .id(UnreadDivider.anchor)
                        }
                        MessageRow(message: entry.message, startsGroup: entry.startsGroup)
                            .onAppear { readTracker?.sawMessage(id: entry.message.id) }
                            .padding(.top, entry.startsGroup ? 14 : 2)
                            .id(entry.message.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(DisablesScrollToTop().frame(width: 0, height: 0))
            }
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let distance = geometry.contentSize.height
                    - (geometry.contentOffset.y + geometry.containerSize.height)
                return distance < 120
            } action: { _, isNearBottom in
                atBottom = isNearBottom
            }
            .overlay(alignment: .bottomTrailing) {
                if !atBottom {
                    Button {
                        withAnimation(.snappy) {
                            proxy.scrollTo(messages.last?.id, anchor: .bottom)
                        }
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
            .onChange(of: messages.last?.id) { _, last in
                guard let last, atBottom else { return }
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
        .photosPicker(isPresented: binding(for: .photos), selection: $pickedPhotos, maxSelectionCount: 5, matching: .any(of: [.images, .videos]))
        .task(id: pickedPhotos.count) { await uploadPickedPhotos() }
        .fileImporter(isPresented: binding(for: .files), allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await upload(urls: urls) } }
        }
        .fullScreenCover(isPresented: binding(for: .camera)) {
            CameraPicker { data in
                guard let data else { return }
                Task { await upload(data: data, filename: "photo.jpg", contentType: "image/jpeg") }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showEmoji) {
            EmojiPicker { draft.append($0) }
        }
        .task(id: source) {
            readTracker = ReadTracker { ids in await model.markRead(ids) }
            await load()
        }
        .onDisappear { Task { await readTracker?.flushNow() } }
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

    /// Discord's shape: attachments on a plus outside the field, emoji tucked inside it,
    /// send on the far side. Every icon control is the same circle.
    private var composer: some View {
        VStack(spacing: 6) {
            if let sendError {
                Text(sendError).font(.caption).foregroundStyle(.red)
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
    }

    private var field: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField(placeholder, text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
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

    private static let controlSize: CGFloat = 26

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
            var isFirstBatch = true
            for try await rows in observation.values(in: writer) {
                messages = rows
                if isFirstBatch {
                    firstUnreadID = rows.first { !$0.isRead }?.id
                    isFirstBatch = false
                }
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

struct UnreadDivider: View {
    static let anchor = "unread-divider"

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(.red.opacity(0.6)).frame(height: 1)
            Text("Unread")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.red)
            Rectangle().fill(.red.opacity(0.6)).frame(height: 1)
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
                        if message.editedAt != nil {
                            Text("edited").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                MessageBody(html: message.renderedContent)
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

// MARK: - Attachments

extension ConversationView {

    fileprivate func binding(for wanted: AttachmentSource) -> Binding<Bool> {
        Binding(
            get: { attachment == wanted },
            set: { if !$0, attachment == wanted { attachment = nil } }
        )
    }

    fileprivate func uploadPickedPhotos() async {
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

    fileprivate func upload(urls: [URL]) async {
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
    fileprivate func upload(data: Data, filename: String, contentType: String) async {
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
