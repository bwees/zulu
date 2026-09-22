// PROTOTYPE — throwaway. Small pieces every shell needs; deliberately not a shared layout.
import SwiftUI

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
    let mode: ChannelMode
    var restricted = false
    var size: CGFloat = 15

    private var symbol: String {
        switch mode {
        case .forum: "bubble.left.and.text.bubble.right"
        case .chat: "number"
        }
    }

    /// The colour the icon sits on, so the lock's bubble reads as a hole punched
    /// through the glyph rather than a disc floating over it.
    var cutout: Color = Color(.systemGroupedBackground)

    var body: some View {
        Image(systemName: symbol)
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

struct UnreadDot: View {
    let on: Bool
    var body: some View {
        Circle()
            .fill(on ? Color.accentColor : .clear)
            .frame(width: 8, height: 8)
    }
}

struct PresenceDot: View {
    let presence: Presence
    var size: CGFloat = 12
    /// The colour behind the dot, so the ring reads as a hole rather than a halo.
    var cutout: Color = Color(.systemBackground)

    var body: some View {
        Circle()
            .fill(presence.hollow ? AnyShapeStyle(.clear) : AnyShapeStyle(presence.tint))
            .overlay {
                if presence.hollow {
                    Circle().strokeBorder(presence.tint, lineWidth: size * 0.26)
                }
            }
            .frame(width: size, height: size)
            .padding(size * 0.2)
            .background(cutout, in: Circle())
    }
}

struct Avatar: View {
    let name: String
    var size: CGFloat = 36
    var presence: Presence?
    var cutout: Color = Color(.systemBackground)

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
            .overlay(alignment: .bottomTrailing) {
                if let presence {
                    PresenceDot(presence: presence, size: size * 0.34, cutout: cutout)
                        .offset(x: size * 0.08, y: size * 0.08)
                }
            }
    }
}

struct UserSheet: View {
    let user: User
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Avatar(name: user.name, size: 96, presence: user.presence,
                           cutout: Color(.systemGroupedBackground))
                        .padding(.top, 8)

                    VStack(spacing: 4) {
                        Text(user.name).font(.title2.weight(.semibold))
                        HStack(spacing: 6) {
                            PresenceDot(presence: user.presence, size: 8,
                                        cutout: Color(.systemGroupedBackground))
                            Text(user.presence.label).font(.subheadline).foregroundStyle(.secondary)
                            if let last = user.lastActive {
                                Text("· \(last)").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }

                    if user.statusText != nil || user.statusEmoji != nil {
                        HStack(spacing: 8) {
                            if let emoji = user.statusEmoji { Text(emoji) }
                            if let text = user.statusText { Text(text) }
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .glassEffect(.regular, in: .capsule)
                    }

                    VStack(spacing: 0) {
                        detailRow("Role", user.role, systemImage: "person.badge.shield.checkmark")
                        if let pronouns = user.pronouns {
                            Divider().padding(.leading, 46)
                            detailRow("Pronouns", pronouns, systemImage: "text.quote")
                        }
                        if let localTime = user.localTime {
                            Divider().padding(.leading, 46)
                            detailRow("Local time", localTime, systemImage: "clock")
                        }
                    }
                    .background(Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 14))
                    .padding(.top, 4)

                    HStack(spacing: 10) {
                        Button { } label: {
                            Label("Message", systemImage: "bubble.left")
                                .frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        .buttonStyle(.glassProminent)
                        Button { } label: {
                            Image(systemName: "bell.slash").padding(.vertical, 6).padding(.horizontal, 4)
                        }
                        .buttonStyle(.glass)
                    }
                    .padding(.top, 2)
                }
                .padding(.horizontal, 16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func detailRow(_ label: String, _ value: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(.secondary).frame(width: 22)
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }
}

struct MessageList: View {
    let title: String
    let subtitle: String?
    let messages: [Msg]
    /// Set for a one-to-one DM, so the header can carry presence and status.
    var headerUser: User?

    @State private var inspecting: User?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(messages) { m in
                        HStack(alignment: .top, spacing: 10) {
                            Button { inspecting = Fake.user(m.sender) } label: {
                                Avatar(name: m.sender, presence: Fake.user(m.sender).presence)
                            }
                            .buttonStyle(.plain)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(m.sender).font(.subheadline.weight(.semibold))
                                    if let emoji = Fake.user(m.sender).statusEmoji {
                                        Text(emoji).font(.caption2)
                                    }
                                    Text(m.when).font(.caption).foregroundStyle(.secondary)
                                }
                                Text(m.body).font(.body)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .safeAreaBar(edge: .bottom) {
                Composer(placeholder: subtitle.map { "Message \($0)" } ?? "Message \(title)")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let headerUser {
                ToolbarItem(placement: .principal) {
                    Button { inspecting = headerUser } label: {
                        HStack(spacing: 8) {
                            Avatar(name: headerUser.name, size: 28, presence: headerUser.presence)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(headerUser.name).font(.headline)
                                Text(statusLine(headerUser))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            } else if let subtitle {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(title).font(.headline)
                        Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .sheet(item: $inspecting) { UserSheet(user: $0) }
    }

    private func statusLine(_ user: User) -> String {
        var parts: [String] = []
        if let emoji = user.statusEmoji { parts.append(emoji) }
        if let text = user.statusText { parts.append(text) }
        if parts.isEmpty { parts.append(user.presence.label) }
        if let last = user.lastActive, user.presence.hollow { parts.append("· \(last)") }
        return parts.joined(separator: " ")
    }
}

struct Composer: View {
    let placeholder: String
    @State private var draft = ""
    var body: some View {
        HStack(spacing: 10) {
            Button { } label: { Image(systemName: "plus").font(.body.weight(.semibold)) }
                .buttonStyle(.glass)
            TextField(placeholder, text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
            Button { draft = "" } label: { Image(systemName: "arrow.up").font(.body.weight(.semibold)) }
                .buttonStyle(.glassProminent)
                .disabled(draft.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
