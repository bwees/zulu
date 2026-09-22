import GRDB
import SwiftUI
import ZuluStore
import ZuluSync

/// The drawer shell, wired to the store. Structure follows the nav-shell prototype:
/// a rail, a channel list, and a message page that slides off them.
struct ShellView: View {
    @Environment(AppModel.self) private var model

    private enum Section: Equatable { case channels, dms }

    @State private var section: Section = .channels
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
                    systemImage: "bubble.left.and.bubble.right.fill",
                    active: section == .dms,
                    unread: model.dms.contains { $0.unreadCount > 0 },
                    // Every direct message is addressed to you, so each unread one counts.
                    mentions: model.dms.reduce(0) { $0 + $1.unreadCount }
                ) { section = .dms }

                Divider().frame(width: 28)

                railButton(
                    systemImage: "number",
                    active: section == .channels,
                    unread: model.channels.contains { $0.unreadCount > 0 },
                    mentions: model.channels.reduce(0) { $0 + $1.mentionCount }
                ) { section = .channels }
            }
            .padding(.vertical, 12)
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
        .frame(width: railW)
        .background(Color(.secondarySystemGroupedBackground).ignoresSafeArea(edges: .vertical))
    }

    /// Unread is a pill on the rail's edge; a count only appears when something actually
    /// needs an answer. A number for every unread message turns the rail into noise.
    private func railButton(
        systemImage: String,
        active: Bool,
        unread: Bool,
        mentions: Int,
        action: @escaping () -> Void
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: active ? 14 : 23)
        return Button(action: action) {
            Image(systemName: systemImage)
                .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .frame(width: 46, height: 46)
                .glassEffect(.regular.tint(active ? .accentColor : nil).interactive(), in: shape)
                .overlay(alignment: .bottomTrailing) {
                    if mentions > 0 {
                        Text(mentions > 99 ? "99+" : "\(mentions)")
                            .font(.caption2.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.red, in: Capsule())
                            .overlay(Capsule().stroke(Color(.secondarySystemGroupedBackground), lineWidth: 2))
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

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(section == .channels ? "Channels" : "Direct Messages")
                    .font(.headline)
                Spacer()
                SyncDot(status: model.status)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    switch section {
                    case .channels:
                        ForEach(model.channels) { channel in
                            channelRow(channel)
                        }
                    case .dms:
                        ForEach(model.dms) { dm in
                            dmRow(dm)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .refreshable { await model.refreshTopics() }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea(edges: .vertical))
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
    }

    private func dmRow(_ dm: DMSummary) -> some View {
        Button {
            model.destination = .dm(dm.dmKey)
            path = []
            setOpen(false)
        } label: {
            HStack(spacing: 8) {
                Avatar(name: model.title(forDM: dm.dmKey), size: 28)
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
            EmptyStateView(text: model.channels.isEmpty
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
