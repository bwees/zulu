import Foundation

/// An image a message showed inline, now asked for at full size.
struct ImageViewerItem: Identifiable, Equatable {
    let preview: String
    let fullSize: String?
    let alt: String?
    let aspectRatio: Double?

    var id: String { preview }

    /// The original where the message linked to one, else the preview itself.
    var source: String {
        if let fullSize, !fullSize.isEmpty { return fullSize }
        return preview
    }
}

/// An expanded image, with its bytes written to disk under the upload's own name. Sharing
/// the file hands over the picture itself; a link would need the realm's sign-in to open.
struct ViewedImage {
    let image: PlatformImage
    let file: URL

    private static let fallbackName = "image"

    fileprivate init?(data: Data, path: String) {
        guard let image = PlatformImage(data: data) else { return nil }
        let name = URL(string: path)?.lastPathComponent ?? ""
        let folder = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let file = folder.appending(path: name.isEmpty || name == "/" ? Self.fallbackName : name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: file)
        } catch {
            return nil
        }
        self.image = image
        self.file = file
    }

    func discard() {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }
}

extension AppModel {
    /// The original first; if that is not a picture the client can decode — a link to a
    /// page, say — the preview the message was already showing.
    func viewedImage(for item: ImageViewerItem) async -> ViewedImage? {
        for path in [item.source, item.preview] {
            if let data = await imageData(at: path), let viewed = ViewedImage(data: data, path: path) {
                return viewed
            }
        }
        return nil
    }
}
