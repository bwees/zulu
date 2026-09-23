import GRDB
import SwiftUI
import ZuluStore

/// The Mac shell: a group rail and a channel list in one sidebar, a conversation beside
/// them.
///
/// The iOS drawer exists because a phone has room for one column at a time. A Mac window
/// does not have that problem, so the same information is laid out rather than stacked —
/// which is why this is its own view and not the drawer with the gesture taken out.
struct MacShellView: View {
    @Environment(AppModel.self) private var model

    private enum Section: Equatable, Hashable {
        case dms
        case group(String)
        case unfiled
    }

    @State private var section: Section = .unfiled
    @State private var channels: [ChannelSummary] = []
    @State private var promoted: [PromotedTopicSummary] = []
    @State private var promotedTask: Task<Void, Never>?
    @State private var selection: MacSelection?
    @State private var expanded: Set<Int> = []

    private static let railWidth: CGFloat = 64

    var body: some View {
        NavigationSplitView {
            HStack(spacing: 0) {
                rail
                Divider()
                channelList
            }
            .navigationSplitViewColumnWidth(min: 300, ideal: 320, max: 460)
        } detail: {
            switch selection {
            case .conversation(let source):
                MacConversationView(source: source).id(source)
            case .chatChannel(let id, let name):
                // A chat channel's messages live in whatever single topic it happens to
                // use, which is rarely the empty one. Resolving it here rather than in
                // the row keeps the sidebar from having to know a channel's contents.
                MacChannelView(channelID: id, channelName: name).id(id)
            case nil:
                EmptyStateView(text: "Pick a conversation.")
            }
        }
        .task(id: section) { await observe() }
    }

    // MARK: rail

    private var rail: some View {
        ScrollView {
            VStack(spacing: 10) {
                railButton(active: section == .dms, unread: model.dms.contains { $0.unreadCount > 0 }) {
                    section = .dms
                } label: {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                }

                Divider().frame(width: 26)

                ForEach(model.groups) { group in
                    railButton(
                        active: section == .group(group.id), unread: group.unreadCount > 0
                    ) {
                        section = .group(group.id)
                    } label: {
                        Text(initials(of: group.name)).font(.caption.weight(.bold))
                    }
                    .help(group.name)
                }

                if !model.groups.isEmpty { Divider().frame(width: 26) }

                railButton(
                    active: section == .unfiled,
                    unread: model.unfiledChannels.contains { $0.unreadCount > 0 }
                ) {
                    section = .unfiled
                } label: {
                    Image(systemName: "number")
                }
                .help("Channels")
            }
            .padding(.vertical, 10)
        }
        .frame(width: Self.railWidth)
        .scrollIndicators(.never)
        .background(.quaternary.opacity(0.4))
    }

    private func railButton<Face: View>(
        active: Bool,
        unread: Bool,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Face
    ) -> some View {
        Button(action: action) {
            label()
                .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .frame(width: 40, height: 40)
                .background(
                    active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                    in: RoundedRectangle(cornerRadius: active ? 12 : 20)
                )
                .overlay(alignment: .leading) {
                    // The unread pill sits outside the tile, the way Discord marks a
                    // server you have not read.
                    if unread || active {
                        Capsule()
                            .fill(.primary)
                            .frame(width: 3, height: active ? 22 : 8)
                            .offset(x: -10)
                    }
                }
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.18), value: active)
    }

    private func initials(of name: String) -> String {
        let words = name.split(separator: " ").prefix(2)
        return words.map { $0.prefix(1).uppercased() }.joined()
    }

    // MARK: channels

    /// Rows carry a `tag`, not a `NavigationLink`. In a `List(selection:)` driving a
    /// split view's detail column, a link has nothing to push onto and the row simply
    /// does not respond.
    private var channelList: some View {
        List(selection: $selection) {
            if section == .dms {
                ForEach(model.dms) { dm in
                    MacSidebarRow(
                        title: model.title(forDM: dm.dmKey),
                        subtitle: model.preview(forDM: dm),
                        symbol: nil,
                        restricted: false,
                        unread: dm.unreadCount
                    )
                    .tag(MacSelection.conversation(.dm(key: dm.dmKey)))
                }
            } else {
                ForEach(entries) { entry in
                    switch entry {
                    case .promoted(let topic):
                        MacSidebarRow(
                            title: topic.displayName,
                            subtitle: nil,
                            symbol: "number",
                            restricted: topic.isRestricted,
                            unread: topic.unreadCount
                        )
                        .tag(
                            MacSelection.conversation(
                                .topic(
                                    channelID: topic.channelID, name: topic.topic,
                                    channelName: topic.channelName
                                )
                            )
                        )
                    case .channel(let channel):
                        channelRow(channel)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(listTitle)
    }

    @ViewBuilder
    private func channelRow(_ channel: ChannelSummary) -> some View {
        if channel.rendersAsForum {
            // A forum gets the disclosure triangle and no icon beside it: the triangle
            // already says "this contains things", and a symbol next to it was just
            // clutter at sidebar size.
            DisclosureGroup(isExpanded: binding(forChannel: channel.id)) {
                MacTopicList(channel: channel)
            } label: {
                MacSidebarRow(
                    title: channel.name, subtitle: nil, symbol: nil,
                    restricted: channel.isRestricted, unread: channel.unreadCount
                )
            }
        } else {
            MacSidebarRow(
                title: channel.name, subtitle: nil, symbol: "number",
                restricted: channel.isRestricted, unread: channel.unreadCount
            )
            .tag(MacSelection.chatChannel(id: channel.id, name: channel.name))
        }
    }

    private var entries: [SidebarEntry] {
        SidebarEntry.merged(channels: channels, promoted: promoted)
    }

    private var listTitle: String {
        switch section {
        case .dms: "Direct Messages"
        case .unfiled: "Channels"
        case .group(let id): model.groups.first { $0.id == id }?.name ?? "Channels"
        }
    }

    /// A forum stays open once opened, because on a Mac the list is on screen the whole
    /// time and re-opening it on every visit would be busywork.
    private func binding(forChannel id: Int) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(id) },
            set: { isOpen in
                if isOpen { expanded.insert(id) } else { expanded.remove(id) }
            }
        )
    }

    private func observe() async {
        guard section != .dms, let writer = model.databaseWriter else { return }
        let groupID: String? = if case .group(let id) = section { id } else { nil }

        promotedTask?.cancel()
        if let observation = model.promotedTopicObservation(inGroup: groupID) {
            promotedTask = Task {
                do {
                    for try await rows in observation.values(in: writer) { promoted = rows }
                } catch {}
            }
        }
        guard let observation = model.channelObservation(inGroup: groupID) else { return }
        do {
            for try await rows in observation.values(in: writer) { channels = rows }
        } catch {
            // Observation ends when the section changes; nothing to recover.
        }
    }
}

/// One line of the Mac sidebar. A lock rides after the name rather than as a badge on an
/// icon, which at this size collided with the icon it was meant to annotate.
private struct MacSidebarRow: View {
    let title: String
    var subtitle: String?
    var symbol: String?
    var restricted = false
    var unread: Int

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 13)
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.callout.weight(unread > 0 ? .semibold : .regular))
                        .lineLimit(1)
                    if restricted {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Badge(count: unread)
        }
        .padding(.vertical, 1)
    }
}

/// The topics under one forum channel, nested in the sidebar rather than pushed onto a
/// second screen.
private struct MacTopicList: View {
    let channel: ChannelSummary
    @Environment(AppModel.self) private var model
    @State private var topics: [TopicSummary] = []
    @State private var loaded = false

    var body: some View {
        Group {
            if topics.isEmpty {
                // A placeholder, not nothing: the observation hangs off this view, and a
                // `ForEach` over an empty array produces no view to hang it on — so with
                // nothing here an expanded forum never loads its own topics.
                MacSidebarRow(
                    title: loaded ? "No topics yet" : "Loading…", symbol: nil, unread: 0
                )
                .foregroundStyle(.secondary)
                .selectionDisabled()
            } else {
                ForEach(topics) { topic in
                    MacSidebarRow(
                        title: topic.name.isEmpty ? "general chat" : topic.name,
                        symbol: nil,
                        unread: topic.unreadCount
                    )
                    .tag(
                        MacSelection.conversation(
                            .topic(
                                channelID: channel.id, name: topic.name,
                                channelName: channel.name
                            )
                        )
                    )
                    .contextMenu {
                        Button("Promote to sidebar") {
                            model.promote(topic: topic.name, inChannel: channel.id)
                        }
                    }
                }
            }
        }
        .task(id: channel.id) { await observe() }
    }

    private func observe() async {
        guard let writer = model.databaseWriter,
              let observation = model.topics(inChannel: channel.id)
        else { return }
        do {
            for try await rows in observation.values(in: writer) {
                topics = rows
                loaded = true
            }
        } catch {}
    }
}

/// What the sidebar can have selected.
///
/// A chat channel is not a conversation yet — which topic it means depends on what is in
/// it — so it stays a channel until something resolves it.
enum MacSelection: Hashable {
    case conversation(ConversationSource)
    case chatChannel(id: Int, name: String)
}

/// A channel that reads as chat rather than a forum: whatever single topic carries its
/// traffic, opened directly.
private struct MacChannelView: View {
    let channelID: Int
    let channelName: String

    @Environment(AppModel.self) private var model
    @State private var topics: [TopicSummary] = []
    @State private var loaded = false

    var body: some View {
        Group {
            if let newest = topics.max(by: { $0.maxMessageID < $1.maxMessageID }) {
                MacConversationView(
                    source: .topic(
                        channelID: channelID, name: newest.name, channelName: channelName
                    )
                )
                .id(newest.name)
            } else if loaded {
                EmptyStateView(text: "Nothing in #\(channelName) yet.")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: channelID) { await observe() }
    }

    private func observe() async {
        guard let writer = model.databaseWriter,
              let observation = model.topics(inChannel: channelID)
        else { return }
        do {
            for try await rows in observation.values(in: writer) {
                topics = rows
                loaded = true
            }
        } catch {}
    }
}
