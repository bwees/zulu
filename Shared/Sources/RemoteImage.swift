import SwiftUI

/// Zulip's uploads need the account's credentials, and they must only ever be sent to
/// the realm itself — never to Gravatar, a preview host, or anything off-origin.
/// `AsyncImage` cannot do that, so images load through the signed-in client instead.
struct RemoteImage: View {
    let path: String
    var fullSize: String?
    var alt: String?
    /// Width over height, when Zulip told us. Reserving the right height before the
    /// bytes arrive is what stops the list reflowing under a scroll.
    var aspectRatio: Double?

    @Environment(AppModel.self) private var model
    #if os(macOS)
    @Environment(MacUIState.self) private var ui
    #endif
    @State private var image: Image?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                image
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else if failed {
                Label(alt ?? "Image", systemImage: "photo")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary)
                    .aspectRatio(aspectRatio ?? 4.0 / 3.0, contentMode: .fit)
                    .overlay { ProgressView() }
            }
        }
        .frame(maxWidth: 320, alignment: .leading)
        #if os(macOS)
        // A click expands the image in the window, at the size it was uploaded. The
        // pointer says so on the way in.
        .onHover { inside in
            guard image != nil else { return }
            inside ? NSCursor.pointingHand.push() : NSCursor.pop()
        }
        .onTapGesture {
            guard image != nil else { return }
            ui.viewingImage = MacImageViewerItem(
                preview: path, fullSize: fullSize, alt: alt, aspectRatio: aspectRatio
            )
        }
        #endif
        .task(id: path) {
            guard image == nil else { return }
            if let data = await model.imageData(at: path), let decoded = Platform.image(from: data) {
                image = decoded
            } else {
                failed = true
            }
        }
    }
}

extension RemoteImage {
    /// The full-size upload, resolved against the realm since the server hands out a
    /// realm-relative path. `nil` when the message carried no link, in which case there is
    /// nothing bigger to see.
    @MainActor
    var fullSizeURL: URL? {
        guard let fullSize, !fullSize.isEmpty else { return nil }
        return URL(string: fullSize, relativeTo: RealmContext.realmURL)?.absoluteURL
    }
}

/// Small in-memory cache so scrolling back does not refetch.
actor ImageCache {
    private var entries: [String: Data] = [:]
    private var order: [String] = []
    private let limit = 80

    func value(for key: String) -> Data? { entries[key] }

    func insert(_ data: Data, for key: String) {
        if entries[key] == nil { order.append(key) }
        entries[key] = data
        while order.count > limit {
            entries.removeValue(forKey: order.removeFirst())
        }
    }
}
