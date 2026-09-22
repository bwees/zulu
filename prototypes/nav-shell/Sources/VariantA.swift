// PROTOTYPE — throwaway.
// Variant A — "Discord faithful": edge rail of groups + channel drawer that the
// message pane slides off of. Spatial hierarchy, gesture-driven, no tab bar.
import SwiftUI

struct VariantA: View {
    static let name = "Discord drawer"

    private enum Sel: Equatable {
        case channel(Int, Int)
        case dm(Int)
    }

    private enum Section: Equatable { case group(Int), dms }

    @State private var section: Section = .group(0)
    @State private var sel: Sel = .channel(0, 1)
    @State private var open = true
    @State private var drag: CGFloat = 0
    @State private var path: [Topic] = []

    private let railW: CGFloat = 68
    private let listW: CGFloat = 236
    private var drawerW: CGFloat { railW + listW }

    private var offset: CGFloat {
        min(max((open ? drawerW : 0) + drag, 0), drawerW)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Color(.systemGroupedBackground).ignoresSafeArea()
            drawer
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: offset > 0 ? 24 : 0))
                .shadow(color: .black.opacity(offset > 0 ? 0.25 : 0), radius: 18, x: -6)
                .offset(x: offset)
                .overlay {
                    if offset > drawerW * 0.4 {
                        Color.black.opacity(0.001)
                            .onTapGesture { withAnimation(.snappy) { open = false } }
                            .offset(x: offset)
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { v in
                            guard abs(v.translation.width) > abs(v.translation.height) else { return }
                            drag = v.translation.width
                        }
                        .onEnded { v in
                            let projected = offset + v.predictedEndTranslation.width * 0.4
                            withAnimation(.snappy) {
                                open = projected > drawerW / 2
                                drag = 0
                            }
                        }
                )
        }
    }

    // MARK: drawer

    private var drawer: some View {
        HStack(spacing: 0) {
            rail
            channelList
                .frame(width: listW)
        }
        .frame(width: drawerW)
    }

    private var rail: some View {
        ScrollView {
            VStack(spacing: 12) {
                railButton(
                    label: { Image(systemName: "bubble.left.and.bubble.right.fill") },
                    tint: .accentColor,
                    active: section == .dms,
                    badge: Fake.totalDMUnread,
                    mention: true
                ) { section = .dms }

                Divider().frame(width: 28)

                ForEach(Array(Fake.groups.enumerated()), id: \.element.id) { i, g in
                    railButton(
                        label: { Text(g.initials).font(.system(size: 15, weight: .bold)) },
                        tint: g.tint,
                        active: section == .group(i),
                        badge: g.unread,
                        mention: g.mentions > 0
                    ) {
                        section = .group(i)
                        sel = .channel(i, 0)
                        path = []
                    }
                }

                railButton(label: { Image(systemName: "plus") }, tint: .gray, active: false, badge: 0, mention: false) {}
            }
            .padding(.vertical, 12)
        }
        .frame(width: railW)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private func railButton<L: View>(
        @ViewBuilder label: () -> L,
        tint: Color,
        active: Bool,
        badge: Int,
        mention: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: active ? 14 : 24)
                    .fill(active ? tint.gradient : Color(.tertiarySystemFill).gradient)
                    .frame(width: 46, height: 46)
                    .overlay(label().foregroundStyle(active ? .white : .secondary))
                Badge(count: badge, mention: mention).offset(x: 2, y: -4)
            }
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(.primary)
                    .frame(width: 4, height: active ? 28 : (badge > 0 ? 10 : 0))
                    .offset(x: -13)
            }
        }
        .buttonStyle(.plain)
        .animation(.snappy, value: active)
    }

    private var channelList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(sectionTitle)
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    switch section {
                    case .dms:
                        ForEach(Array(Fake.dms.enumerated()), id: \.element.id) { i, d in
                            dmRow(i, d)
                        }
                    case .group(let gi):
                        ForEach(Array(Fake.groups[gi].channels.enumerated()), id: \.element.id) { ci, c in
                            channelRow(gi, ci, c)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
        }
        .background(Color(.systemGroupedBackground))
    }

    private var sectionTitle: String {
        switch section {
        case .dms: "Direct Messages"
        case .group(let i): Fake.groups[i].name
        }
    }

    private func channelRow(_ gi: Int, _ ci: Int, _ c: Channel) -> some View {
        let active = sel == .channel(gi, ci)
        return Button {
            sel = .channel(gi, ci)
            path = []
            withAnimation(.snappy) { open = false }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: c.mode == .forum ? "list.bullet.indent" : "number")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(c.name)
                    .font(.subheadline.weight(c.unread > 0 ? .semibold : .regular))
                    .foregroundStyle(c.unread > 0 ? .primary : .secondary)
                Spacer(minLength: 4)
                Badge(count: c.mentions, mention: true)
                if c.mentions == 0 { Badge(count: c.unread) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(active ? Color(.tertiarySystemFill) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func dmRow(_ i: Int, _ d: DM) -> some View {
        let active = sel == .dm(i)
        return Button {
            sel = .dm(i)
            path = []
            withAnimation(.snappy) { open = false }
        } label: {
            HStack(spacing: 8) {
                Avatar(name: d.name, size: 28)
                Text(d.name)
                    .font(.subheadline.weight(d.unread > 0 ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Badge(count: d.unread, mention: true)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(active ? Color(.tertiarySystemFill) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    // MARK: content

    private var content: some View {
        NavigationStack(path: $path) {
            Group {
                switch sel {
                case .dm(let i):
                    MessageList(title: Fake.dms[i].name, subtitle: nil, messages: Fake.dms[i].messages)
                case .channel(let gi, let ci):
                    let c = Fake.groups[gi].channels[ci]
                    if c.mode == .forum {
                        TopicListA(channel: c)
                    } else {
                        MessageList(title: "#\(c.name)", subtitle: nil, messages: c.topics[0].messages)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        withAnimation(.snappy) { open.toggle() }
                    } label: {
                        Image(systemName: "line.3.horizontal")
                    }
                }
            }
            .navigationDestination(for: Topic.self) { t in
                MessageList(title: t.name, subtitle: topicChannelName, messages: t.messages)
            }
        }
    }

    private var topicChannelName: String? {
        if case .channel(let gi, let ci) = sel { return "#\(Fake.groups[gi].channels[ci].name)" }
        return nil
    }
}

private struct TopicListA: View {
    let channel: Channel

    var body: some View {
        List {
            Section {
                ForEach(channel.topics) { t in
                    NavigationLink(value: t) {
                        HStack(alignment: .top, spacing: 10) {
                            UnreadDot(on: t.unread > 0).padding(.top, 6)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 5) {
                                    if t.followed { Image(systemName: "bell.fill").font(.caption2).foregroundStyle(.tint) }
                                    if t.muted { Image(systemName: "bell.slash.fill").font(.caption2).foregroundStyle(.secondary) }
                                    Text(t.name)
                                        .font(.subheadline.weight(t.unread > 0 ? .semibold : .regular))
                                        .lineLimit(1)
                                }
                                Text("\(t.lastSender): \(t.preview)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(t.when).font(.caption2).foregroundStyle(.secondary)
                                Badge(count: t.unread)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .swipeActions(edge: .leading) {
                        Button { } label: { Label("Follow", systemImage: "bell") }.tint(.blue)
                    }
                    .swipeActions(edge: .trailing) {
                        Button { } label: { Label("Mute", systemImage: "bell.slash") }.tint(.gray)
                        Button { } label: { Label("Read", systemImage: "checkmark") }.tint(.green)
                    }
                }
            } header: {
                Text("\(channel.topics.count) topics")
            }
        }
        .listStyle(.plain)
        .navigationTitle("#\(channel.name)")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button { } label: {
                Label("New topic", systemImage: "square.and.pencil")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
    }
}

extension Topic: Hashable {
    static func == (l: Topic, r: Topic) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}
