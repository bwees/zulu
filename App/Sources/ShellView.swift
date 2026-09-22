import GRDB
import SwiftUI
import ZuluStore
import ZuluSync

/// The drawer shell, wired to the store. Structure follows the nav-shell prototype:
/// a rail, a channel list, and a message page that slides off them.
struct ShellView: View {
    @Environment(AppModel.self) private var model

    private enum Section: Equatable, Hashable {
        case dms
        case group(String)
        /// Channels no group has claimed, so filing is optional rather than required.
        case unfiled
    }

    @State private var section: Section = .unfiled
    @State private var visibleChannels: [ChannelSummary] = []
    @State private var editingGroup: String?
    @State private var creatingGroup = false
    @State private var newGroupName = ""
    @State private var open = true
    @State private var drag: CGFloat = 0
    @State private var drawerMounted = true
    @State private var path: [ConversationView.Source] = []

    private let railW: CGFloat = 80
    private let listW: CGFloat = 236
    private var drawerW: CGFloat { railW + listW }

    private var offset: CGFloat { min(max((open ? drawerW : 0) + drag, 0), drawerW) }

    private static let slide = Animation.snappy(duration: 0.24, extraBounce: 0)

    private func setOpen(_ value: Bool) {
        if value { drawerMounted = true }
        withAnimation(Self.slide, completionCriteria: .removed) {
            open = value
            drag = 0
        } completion: {
            if !open { drawerMounted = false }
        }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Color(.systemBackground).ignoresSafeArea()
            if drawerMounted { drawer }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    RoundedRectangle(cornerRadius: offset > 0 ? 28 : 0)
                        .fill(Color(.systemBackground))
                        .shadow(color: .black.opacity(offset > 0 ? 0.28 : 0), radius: 20, x: -8)
                        .ignoresSafeArea()
                }
                .offset(x: offset)
                .overlay {
                    if offset > drawerW * 0.4 {
                        Color.black.opacity(0.001)
                            .onTapGesture { setOpen(false) }
                            .offset(x: offset)
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { value in
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
                            // Left-to-right belongs to the drawer; right-to-left is left
                            // alone so row swipe actions keep it.
                            guard open || value.translation.width > 0 else { return }
                            if value.translation.width > 0 { drawerMounted = true }
                            drag = value.translation.width
                        }
                        .onEnded { value in
                            let projected = offset + value.predictedEndTranslation.width * 0.4
                            setOpen(projected > drawerW / 2)
                        }
                )
        }
    }

    // MARK: drawer

    private var drawer: some View {
        HStack(spacing: 0) {
            rail
            list.frame(width: listW)
        }
        .frame(width: drawerW)
    }

    private var rail: some View {
        ScrollView {
            VStack(spacing: 12) {
                railButton(
                    active: section == .dms,
                    unread: model.dms.contains { $0.unreadCount > 0 },
                    // Every direct message is addressed to you, so each unread one counts.
                    mentions: model.dms.reduce(0) { $0 + $1.unreadCount }
                ) { section = .dms } label: {
                    RailIcon(systemImage: "bubble.left.and.bubble.right.fill", active: section == .dms)
                }

                Divider().frame(width: 28)

                ForEach(model.groups) { group in
                    railButton(
                        active: section == .group(group.id),
                        unread: group.unreadCount > 0,
                        mentions: group.mentionCount
                    ) {
                        section = .group(group.id)
                    } label: {
                        GroupAvatar(
                            name: group.name, icon: group.icon,
                            active: section == .group(group.id)
                        )
                    }
                    .contextMenu {
                        Button("Edit group", systemImage: "pencil") { editingGroup = group.id }
                        Button("Delete group", systemImage: "trash", role: .destructive) {
                            if section == .group(group.id) { section = .unfiled }
                            model.deleteGroup(id: group.id)
                        }
                    }
                }

                if !model.groups.isEmpty { Divider().frame(width: 28) }

                railButton(
                    active: section == .unfiled,
                    unread: model.unfiledChannels.contains { $0.unreadCount > 0 },
                    mentions: model.unfiledChannels.reduce(0) { $0 + $1.mentionCount }
                ) { section = .unfiled } label: {
                    RailIcon(systemImage: "number", active: section == .unfiled)
                }

                railButton(active: false, unread: false, mentions: 0) {
                    newGroupName = ""
                    creatingGroup = true
                } label: {
                    RailIcon(systemImage: "plus")
                }
            }
            .padding(.vertical, 12)
        }
        // Liquid Glass morphs beyond a controls bounds, and a ScrollView clips by
        // default, which shears the animation off mid-flight.
        .scrollClipDisabled()
        .scrollEdgeEffectStyle(.soft, for: .all)
        .frame(width: railW)
        .background(Color(.secondarySystemGroupedBackground).ignoresSafeArea(edges: .vertical))
    }

    /// Unread is a pill on the rail's edge; a count only appears when something actually
    /// needs an answer. A number for every unread message turns the rail into noise.
    private func railButton<Face: View>(
        active: Bool,
        unread: Bool,
        mentions: Int,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Face
    ) -> some View {
        Button(action: action) {
            label()
                .frame(width: 46, height: 46)
                .overlay(alignment: .bottomTrailing) {
                    if mentions > 0 {
                        Text(mentions > 99 ? "99+" : "\(mentions)")
                            .font(.caption2.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.red, in: Capsule())
                            .overlay(
                                Capsule().stroke(Color(.secondarySystemGroupedBackground), lineWidth: 2)
                            )
                            .fixedSize()
                            .offset(x: 4, y: 3)
                    }
                }
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(.primary)
                        .frame(width: 4, height: active ? 26 : (unread ? 10 : 0))
                        .offset(x: -15)
                }
        }
        .buttonStyle(.plain)
        .animation(.snappy, value: active)
        .animation(.snappy, value: unread)
    }

    private var listTitle: String {
        switch section {
        case .dms: "Direct Messages"
        case .unfiled: model.groups.isEmpty ? "Channels" : "Unfiled"
        case .group(let id): model.groups.first { $0.id == id }?.name ?? "Channels"
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(listTitle).font(.headline).lineLimit(1)
                Spacer()
                SyncDot(status: model.status)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if section == .dms {
                        ForEach(model.dms) { dm in dmRow(dm) }
                    } else {
                        ForEach(visibleChannels) { channel in
                            channelRow(channel)
                            if channel.rendersAsForum {
                                topicBranch(under: channel)
                            }
                        }
                        if visibleChannels.isEmpty {
                            Text(emptyListMessage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 12)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .refreshable { await model.refreshTopics() }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea(edges: .vertical))
        .task(id: section) { await observeChannels() }
    }

    private var emptyListMessage: String {
        switch section {
        case .group: "No channels in this group yet. Long-press its icon to edit."
        default: "Every channel is filed into a group."
        }
    }

    private func observeChannels() async {
        guard section != .dms else { return }
        let groupID: String? = if case .group(let id) = section { id } else { nil }
        guard let writer = model.databaseWriter,
              let observation = model.channelObservation(inGroup: groupID)
        else { return }
        do {
            for try await rows in observation.values(in: writer) {
                visibleChannels = rows
            }
        } catch {
            // Observation ends when the section changes; nothing to recover.
        }
    }

    private func channelRow(_ channel: ChannelSummary) -> some View {
        Button {
            model.destination = .channel(channel.id)
            path = []
            setOpen(false)
        } label: {
            HStack(spacing: 8) {
                ChannelIcon(isForum: channel.rendersAsForum, restricted: channel.isRestricted)
                    .foregroundStyle(.secondary)
                    .frame(width: 26, alignment: .leading)
                Text(channel.name)
                    .font(.subheadline.weight(channel.unreadCount > 0 ? .semibold : .regular))
                    .foregroundStyle(channel.unreadCount > 0 ? .primary : .secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if channel.mentionCount > 0 {
                    Badge(count: channel.mentionCount, mention: true)
                } else if channel.unreadCount > 0 {
                    Circle().fill(.primary).frame(width: 7, height: 7)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                model.destination == .channel(channel.id) ? Color(.tertiarySystemFill) : .clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Picker("Show as", selection: Binding(
                get: { model.modeOverride(forChannel: channel.id) },
                set: { model.setMode($0, forChannel: channel.id) }
            )) {
                Text("Automatic").tag(ChannelMode?.none)
                ForEach(ChannelMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(ChannelMode?.some(mode))
                }
            }
        }
    }

    /// A forum channel's live conversations, hung under it on a bracket so a topic is one
    /// tap away instead of two. Only the few most recent, or the sidebar becomes the
    /// conversation list.
    @ViewBuilder
    private func topicBranch(under channel: ChannelSummary) -> some View {
        let topics = model.recentTopics[channel.id] ?? []
        if !topics.isEmpty {
            HStack(alignment: .top, spacing: 0) {
                TopicBracket(count: topics.count)
                    .stroke(.tertiary, lineWidth: 1.5)
                    .frame(width: 16)
                    .padding(.leading, 16)

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(topics) { topic in
                        Button {
                            model.destination = .channel(channel.id)
                            path = [.topic(
                                channelID: channel.id, name: topic.name, channelName: channel.name
                            )]
                            setOpen(false)
                        } label: {
                            HStack(spacing: 6) {
                                Text(topic.name.isEmpty ? "general chat" : topic.name)
                                    .font(.footnote.weight(topic.unreadCount > 0 ? .semibold : .regular))
                                    .foregroundStyle(topic.unreadCount > 0 ? .primary : .secondary)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                if topic.unreadCount > 0 {
                                    Circle().fill(.primary).frame(width: 6, height: 6)
                                }
                            }
                            .frame(height: Self.topicRowHeight)
                            .padding(.horizontal, 8)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.trailing, 8)
        }
    }

    private static let topicRowHeight: CGFloat = 26

    /// The elbow bracket Discord draws beside nested threads.
    private struct TopicBracket: Shape {
        let count: Int

        func path(in rect: CGRect) -> Path {
            var path = Path()
            let rowHeight = ShellView.topicRowHeight
            let lastCentre = rowHeight * (CGFloat(count) - 0.5)
            path.move(to: CGPoint(x: rect.minX, y: 0))
            path.addLine(to: CGPoint(x: rect.minX, y: lastCentre - 6))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + 6, y: lastCentre),
                control: CGPoint(x: rect.minX, y: lastCentre)
            )
            path.addLine(to: CGPoint(x: rect.maxX, y: lastCentre))

            for index in 0..<max(count - 1, 0) {
                let centre = rowHeight * (CGFloat(index) + 0.5)
                path.move(to: CGPoint(x: rect.minX, y: centre))
                path.addLine(to: CGPoint(x: rect.maxX, y: centre))
            }
            return path
        }
    }

    private func dmRow(_ dm: DMSummary) -> some View {
        Button {
            model.destination = .dm(dm.dmKey)
            path = []
            setOpen(false)
        } label: {
            HStack(spacing: 8) {
                SenderAvatar(
                    name: model.title(forDM: dm.dmKey),
                    userID: model.soleParticipant(inDM: dm.dmKey),
                    size: 28
                )
                Text(model.title(forDM: dm.dmKey))
                    .font(.subheadline.weight(dm.unreadCount > 0 ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Badge(count: dm.unreadCount, mention: true)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                model.destination == .dm(dm.dmKey) ? Color(.tertiarySystemFill) : .clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: content

    private var content: some View {
        NavigationStack(path: $path) {
            destinationView
                .navigationDestination(for: ConversationView.Source.self) { source in
                    ConversationView(source: source)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { setOpen(!open) } label: { Image(systemName: "line.3.horizontal") }
                    }
                }
        }
        .sheet(item: Binding(get: { editingGroup.map(Identified.init) },
                             set: { editingGroup = $0?.value })) { wrapper in
            GroupEditor(groupID: wrapper.value)
        }
        .alert("New group", isPresented: $creatingGroup) {
            TextField("Name", text: $newGroupName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let name = newGroupName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                model.createGroup(named: name)
            }
        } message: {
            Text("Group channels however you like. Groups stay on your devices — Zulip has no idea they exist.")
        }
        .onChange(of: model.pendingGroupToEdit) { _, id in
            guard let id else { return }
            editingGroup = id
            section = .group(id)
            model.pendingGroupToEdit = nil
        }
    }

    /// `sheet(item:)` needs something Identifiable, and a bare String is not.
    private struct Identified: Identifiable {
        let value: String
        var id: String { value }
    }

    @ViewBuilder
    private var destinationView: some View {
        switch model.destination {
        case .channel(let id):
            if let channel = model.channel(id) {
                ChannelView(channel: channel)
            } else {
                EmptyStateView(text: "That channel is no longer available.")
            }
        case .dm(let key):
            ConversationView(source: .dm(key: key))
        case nil:
            EmptyStateView(text: model.allChannels.isEmpty
                ? "Syncing your channels…"
                : "Pick a channel to start reading.")
        }
    }
}

struct EmptyStateView: View {
    let text: String
    var body: some View {
        VStack {
            Spacer()
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
            Spacer()
        }
        .navigationTitle("Zulu")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SyncDot: View {
    let status: SyncStatus

    private var tint: Color {
        switch status {
        case .live: .green
        case .connecting: .orange
        case .failed: .red
        case .idle: .gray
        }
    }

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: 7, height: 7)
            .help(label)
    }

    private var label: String {
        switch status {
        case .live: "Connected"
        case .connecting: "Connecting"
        case .failed(let message): message
        case .idle: "Not connected"
        }
    }
}

struct Badge: View {
    let count: Int
    var mention = false

    var body: some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(mention ? Color.red : Color.secondary, in: Capsule())
        }
    }
}

struct ChannelIcon: View {
    let isForum: Bool
    var restricted = false
    var size: CGFloat = 15
    var cutout: Color = Color(.systemGroupedBackground)

    var body: some View {
        Image(systemName: isForum ? "bubble.left.and.text.bubble.right" : "number")
            .font(.system(size: size))
            .overlay(alignment: .topTrailing) {
                if restricted {
                    Image(systemName: "lock.fill")
                        .font(.system(size: size * 0.5, weight: .bold))
                        .padding(size * 0.14)
                        .background(cutout, in: Circle())
                        .offset(x: size * 0.34, y: -size * 0.2)
                }
            }
    }
}
