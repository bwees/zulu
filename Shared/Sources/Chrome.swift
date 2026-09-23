import ZuluSync
import SwiftUI

struct EmptyStateView: View {
    let text: String
    var body: some View {
        VStack {
            Spacer()
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
            Spacer()
        }
        .navigationTitle("Zulu")
        .inlineNavigationTitle()
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
    var cutout: Color = Platform.grey(light: 0.95, dark: 0.11)

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

