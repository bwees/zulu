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

struct UnreadDot: View {
    let on: Bool
    var body: some View {
        Circle()
            .fill(on ? Color.accentColor : .clear)
            .frame(width: 8, height: 8)
    }
}

struct Avatar: View {
    let name: String
    var size: CGFloat = 36
    private var tint: Color {
        let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo]
        return palette[abs(name.hashValue) % palette.count]
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

struct MessageList: View {
    let title: String
    let subtitle: String?
    let messages: [Msg]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(messages) { m in
                        HStack(alignment: .top, spacing: 10) {
                            Avatar(name: m.sender)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(m.sender).font(.subheadline.weight(.semibold))
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
            Composer(placeholder: subtitle.map { "Message \($0)" } ?? "Message \(title)")
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let subtitle {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(title).font(.headline)
                        Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct Composer: View {
    let placeholder: String
    @State private var draft = ""
    var body: some View {
        HStack(spacing: 10) {
            Button { } label: { Image(systemName: "plus.circle.fill").font(.title2) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 18))
            Button { draft = "" } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                .buttonStyle(.plain)
                .disabled(draft.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(.bar)
    }
}
