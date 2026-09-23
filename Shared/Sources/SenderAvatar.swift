import SwiftUI
import ZuluStore

/// A person's own picture, or their initials when there is no picture to show.
///
/// The initials are shown *instead of* the picture, never behind it: an avatar with any
/// transparency in it was letting a wheel of colour through from underneath.
struct SenderAvatar: View {
    let name: String
    var userID: Int?
    /// The message's own snapshot of the sender's avatar. Messages keep the URL they
    /// were sent with, so the live user record is preferred where there is one.
    var url: String?
    var size: CGFloat = 36

    @Environment(AppModel.self) private var model
    @State private var image: Image?

    private var source: String? {
        userID.flatMap { model.users[$0]?.avatarURL } ?? url
    }

    var body: some View {
        Group {
            if let image {
                image
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(.circle)
            } else {
                Avatar(name: name, size: size)
            }
        }
        .task(id: source) { await load() }
    }

    private func load() async {
        guard let source, !source.isEmpty else { return }
        // Gravatar and the realm's own uploads both arrive here; `imageData` decides
        // which of them may see the account's credentials.
        guard let data = await model.imageData(at: source) else { return }
        image = Platform.image(from: data)
    }
}
