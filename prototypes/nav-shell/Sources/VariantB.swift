// PROTOTYPE — throwaway.
// Variant B — "Native tabs": bottom tab bar sections the app, groups are a filter
// inside the Channels tab. No drawer, no gestures to learn, plain NavigationStack.
import SwiftUI

struct VariantB: View {
    static let name = "Native tabs"

    var body: some View {
        TabView {
            Tab("Channels", systemImage: "number") { ChannelsTabB() }
                .badge(Fake.groups.reduce(0) { $0 + $1.unread })
            Tab("DMs", systemImage: "bubble.left.and.bubble.right") { DMsTabB() }
                .badge(Fake.totalDMUnread)
            Tab("Mentions", systemImage: "at") { MentionsTabB() }
                .badge(Fake.totalMentions)
            Tab("You", systemImage: "person.crop.circle") { YouTabB() }
            Tab(role: .search) { SearchTabB() }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}

private struct ChannelsTabB: View {
    @State private var groupIndex = 0
    @State private var onlyUnread = false

    private var group: ChannelGroup { Fake.groups[groupIndex] }
    private var channels: [Channel] {
        onlyUnread ? group.channels.filter { $0.unread > 0 } : group.channels
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(channels) { c in
                    NavigationLink {
                        if c.mode == .forum {
                            TopicListB(channel: c)
                        } else {
                            MessageList(title: "#\(c.name)", subtitle: nil, messages: c.topics[0].messages)
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: c.mode == .forum ? "list.bullet.indent" : "number")
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.name).font(.body.weight(c.unread > 0 ? .semibold : .regular))
                                if c.mode == .forum {
                                    Text("\(c.topics.count) topics")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else if let t = c.topics.first {
                                    Text("\(t.lastSender): \(t.preview)")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 4)
                            Badge(count: c.mentions, mention: true)
                            if c.mentions == 0 { Badge(count: c.unread) }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(group.name)
            .safeAreaBar(edge: .top, spacing: 0) {
                ScrollView(.horizontal) {
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            ForEach(Array(Fake.groups.enumerated()), id: \.element.id) { i, g in
                                Button {
                                    withAnimation(.snappy) { groupIndex = i }
                                } label: {
                                    HStack(spacing: 6) {
                                        Circle().fill(g.tint).frame(width: 8, height: 8)
                                        Text(g.name).font(.subheadline.weight(.medium))
                                        Badge(count: g.unread, mention: g.mentions > 0)
                                    }
                                }
                                .buttonStyle(.glass(.regular.tint(i == groupIndex ? g.tint : nil).interactive()))
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                }
                .scrollIndicators(.hidden)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle("Unread only", isOn: $onlyUnread)
                        Button("Edit groups", systemImage: "folder.badge.gearshape") {}
                        Button("Browse all channels", systemImage: "square.grid.2x2") {}
                        Divider()
                        Button("New topic", systemImage: "square.and.pencil") {}
                        Button("New DM", systemImage: "person.badge.plus") {}
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }
}

private struct TopicListB: View {
    let channel: Channel
    var body: some View {
        List {
            ForEach(channel.topics) { t in
                NavigationLink {
                    MessageList(title: t.name, subtitle: "#\(channel.name)", messages: t.messages)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        UnreadDot(on: t.unread > 0).padding(.top, 6)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(t.name).font(.body.weight(t.unread > 0 ? .semibold : .regular)).lineLimit(1)
                            Text("\(t.lastSender): \(t.preview)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(t.when).font(.caption2).foregroundStyle(.secondary)
                            Badge(count: t.unread)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("#\(channel.name)")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { } label: { Image(systemName: "square.and.pencil") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Follow channel", systemImage: "bell") {}
                    Button("Mute channel", systemImage: "bell.slash") {}
                    Button("Mark all read", systemImage: "checkmark") {}
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
    }
}

private struct DMsTabB: View {
    var body: some View {
        NavigationStack {
            List(Fake.dms) { d in
                NavigationLink {
                    MessageList(title: d.name, subtitle: nil, messages: d.messages)
                } label: {
                    HStack(spacing: 12) {
                        Avatar(name: d.name, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.name).font(.body.weight(d.unread > 0 ? .semibold : .regular)).lineLimit(1)
                            Text(d.preview).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(d.when).font(.caption2).foregroundStyle(.secondary)
                            Badge(count: d.unread, mention: true)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Direct Messages")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { } label: { Image(systemName: "square.and.pencil") }
                }
            }
        }
    }
}

private struct MentionsTabB: View {
    private var mentioned: [(Channel, Topic)] {
        Fake.groups.flatMap(\.channels).flatMap { c in
            c.topics.filter { $0.name.contains("@") || $0.preview.contains("@") }.map { (c, $0) }
        }
    }
    var body: some View {
        NavigationStack {
            List(mentioned, id: \.1.id) { c, t in
                NavigationLink {
                    MessageList(title: t.name, subtitle: "#\(c.name)", messages: t.messages)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("#\(c.name)").font(.caption).foregroundStyle(.secondary)
                        Text(t.preview).font(.subheadline)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Mentions")
        }
    }
}

private struct SearchTabB: View {
    @State private var q = ""
    var body: some View {
        NavigationStack {
            List {
                Section("Recent") {
                    Label("is:unread", systemImage: "clock.arrow.circlepath")
                    Label("sender:theo", systemImage: "clock.arrow.circlepath")
                }
            }
            .navigationTitle("Search")
            .searchable(text: $q, prompt: "Messages, topics, people")
        }
    }
}

private struct YouTabB: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Avatar(name: Fake.me, size: 52)
                        VStack(alignment: .leading) {
                            Text(Fake.me).font(.headline)
                            Text("chat.futo.org").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Label("Notifications", systemImage: "bell")
                    Label("Channel groups", systemImage: "folder")
                    Label("Appearance", systemImage: "paintbrush")
                    Label("Account", systemImage: "person.crop.circle")
                }
            }
            .navigationTitle("You")
        }
    }
}
