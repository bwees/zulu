import SwiftUI
import ZuluStore

struct UnreadDivider: View {
    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(.red.opacity(0.6)).frame(height: 1)
            Text("Unread").font(.caption2.weight(.semibold)).foregroundStyle(.red)
            Rectangle().fill(.red.opacity(0.6)).frame(height: 1)
        }
    }
}

struct MessageRow: View {
    let message: MessageRecord
    var startsGroup = true
    var reactions: [ReactionGroup] = []

    private static let avatarSize: CGFloat = 36

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if startsGroup {
                SenderAvatar(
                    name: message.senderName,
                    userID: message.senderID,
                    url: message.senderAvatar,
                    size: Self.avatarSize
                )
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
                MessageContent(message: message).messageActions(message, reactions: reactions)
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
