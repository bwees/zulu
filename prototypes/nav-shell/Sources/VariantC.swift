// PROTOTYPE — throwaway.
// Variant C — "Topic inbox": the root is a flat, recency-sorted list of topics and
// DMs. Topics are literally the top-level objects; channels and groups are a filter
// you reach for, not a hierarchy you walk. Two taps to any conversation.
import SwiftUI

private enum Row: Identifiable {
    case topic(ChannelGroup, Channel, Topic)
    case dm(DM)

    var id: UUID {
        switch self {
        case .topic(_, _, let t): t.id
        case .dm(let d): d.id
        }
    }
    var unread: Int {
        switch self {
        case .topic(_, _, let t): t.unread
        case .dm(let d): d.unread
        }
    }
    var when: String {
        switch self {
        case .topic(_, _, let t): t.when
        case .dm(let d): d.when
        }
    }
}

private enum Filter: String, CaseIterable, Identifiable {
    case all = "All"
    case unread = "Unread"
    case followed = "Following"
    case dms = "DMs"
    var id: String { rawValue }
}

struct VariantC: View {
    static let name = "Topic inbox"

    @State private var filter: Filter = .all
    @State private var groupFilter: ChannelGroup.ID? = nil
    @State private var showBrowser = false

    private var rows: [Row] {
        var out: [Row] = []
        for g in Fake.groups where groupFilter == nil || g.id == groupFilter {
            for c in g.channels {
                for t in c.topics { out.append(.topic(g, c, t)) }
            }
        }
        if groupFilter == nil {
            out.append(contentsOf: Fake.dms.map { Row.dm($0) })
        }
        switch filter {
        case .all: break
        case .unread: out = out.filter { $0.unread > 0 }
        case .followed: out = out.filter { if case .topic(_, _, let t) = $0 { return t.followed } else { return false } }
        case .dms: out = out.filter { if case .dm = $0 { return true } else { return false } }
        }
        return out.sorted { rank($0.when) < rank($1.when) }
    }

    private func rank(_ when: String) -> Int {
        if when.contains(":") { return 0 }
        if when == "Yesterday" { return 1 }
        if ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].contains(when) { return 2 }
        return 3
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(rows) { row in
                    switch row {
                    case .topic(let g, let c, let t):
                        NavigationLink {
                            MessageList(title: t.name, subtitle: "#\(c.name)", messages: t.messages)
                        } label: { topicRow(g, c, t) }
                        .swipeActions(edge: .trailing) {
                            Button { } label: { Label("Mute", systemImage: "bell.slash") }.tint(.gray)
                            Button { } label: { Label("Read", systemImage: "checkmark") }.tint(.green)
                        }
                    case .dm(let d):
                        NavigationLink {
                            MessageList(title: d.name, subtitle: nil, messages: d.messages)
                        } label: { dmRow(d) }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle(groupFilter.flatMap { id in Fake.groups.first { $0.id == id }?.name } ?? "Inbox")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Filter.allCases) { f in
                            chip(f.rawValue, active: filter == f, tint: .accentColor) { filter = f }
                        }
                        Divider().frame(height: 20)
                        chip("All groups", active: groupFilter == nil, tint: .secondary) { groupFilter = nil }
                        ForEach(Fake.groups) { g in
                            chip(g.name, active: groupFilter == g.id, tint: g.tint) { groupFilter = g.id }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .scrollIndicators(.hidden)
                .background(.bar)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showBrowser = true } label: { Image(systemName: "square.grid.2x2") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("New topic", systemImage: "square.and.pencil") {}
                        Button("New DM", systemImage: "person.badge.plus") {}
                        Divider()
                        Button("Mark inbox read", systemImage: "checkmark") {}
                    } label: { Image(systemName: "square.and.pencil") }
                }
            }
            .sheet(isPresented: $showBrowser) { BrowserC() }
        }
    }

    private func chip(_ label: String, active: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: { withAnimation(.snappy, action) }) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(active ? tint.opacity(0.2) : Color(.tertiarySystemFill), in: Capsule())
                .foregroundStyle(active ? .primary : .secondary)
        }
        .buttonStyle(.plain)
    }

    private func topicRow(_ g: ChannelGroup, _ c: Channel, _ t: Topic) -> some View {
        HStack(alignment: .top, spacing: 10) {
            UnreadDot(on: t.unread > 0).padding(.top, 7)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Circle().fill(g.tint).frame(width: 7, height: 7)
                    Text(c.name).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                    if t.followed { Image(systemName: "bell.fill").font(.system(size: 9)).foregroundStyle(.tint) }
                    if t.muted { Image(systemName: "bell.slash.fill").font(.system(size: 9)).foregroundStyle(.secondary) }
                }
                Text(t.name)
                    .font(.subheadline.weight(t.unread > 0 ? .semibold : .regular))
                    .lineLimit(1)
                Text("\(t.lastSender): \(t.preview)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 4) {
                Text(t.when).font(.caption2).foregroundStyle(.secondary)
                Badge(count: t.unread)
            }
        }
        .padding(.vertical, 2)
    }

    private func dmRow(_ d: DM) -> some View {
        HStack(spacing: 10) {
            Avatar(name: d.name, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text("direct message").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                Text(d.name).font(.subheadline.weight(d.unread > 0 ? .semibold : .regular)).lineLimit(1)
                Text(d.preview).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 4) {
                Text(d.when).font(.caption2).foregroundStyle(.secondary)
                Badge(count: d.unread, mention: true)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct BrowserC: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                ForEach(Fake.groups) { g in
                    Section {
                        ForEach(g.channels) { c in
                            HStack(spacing: 10) {
                                Image(systemName: c.mode == .forum ? "list.bullet.indent" : "number")
                                    .foregroundStyle(.secondary).frame(width: 18)
                                Text(c.name)
                                Spacer()
                                Badge(count: c.unread)
                            }
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Circle().fill(g.tint).frame(width: 8, height: 8)
                            Text(g.name)
                        }
                    }
                }
            }
            .navigationTitle("Browse")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Edit groups", systemImage: "folder.badge.gearshape") {}
                }
            }
        }
    }
}
