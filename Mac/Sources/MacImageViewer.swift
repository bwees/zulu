import AppKit
import SwiftUI

/// The image over the whole window, at the size it was uploaded, scaled to fit.
///
/// Drawn in the window rather than handed to the browser: the browser has to be signed
/// in to show an upload at all, and a picture someone just posted is not worth leaving
/// the conversation for. Escape, the close button, or a click on the backdrop dismisses.
struct MacImageViewer: View {
    let item: ImageViewerItem
    let dismiss: () -> Void

    @Environment(AppModel.self) private var model
    @State private var image: Image?
    @State private var failed = false
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.84)
                .ignoresSafeArea()
                .onTapGesture(perform: dismiss)

            VStack(spacing: 12) {
                Group {
                    if let image {
                        image
                            .resizable()
                            .scaledToFit()
                            .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
                    } else if failed {
                        Label(item.alt ?? "This image could not be loaded.", systemImage: "photo")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.8))
                    } else {
                        ProgressView().controlSize(.large).tint(.white)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Clicking the picture itself is not a request to close it.
                .onTapGesture {}

                if let alt = item.alt, !alt.isEmpty, alt != item.preview {
                    Text(alt)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(40)
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 8) {
                if let url = URL(string: item.source, relativeTo: RealmContext.realmURL)?.absoluteURL {
                    control("safari", help: "Open in Browser") { NSWorkspace.shared.open(url) }
                }
                control("xmark", help: "Close  ⎋", action: dismiss)
            }
            .padding(16)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onExitCommand(perform: dismiss)
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .onAppear { focused = true }
        .task(id: item.source) { await load() }
    }

    private func control(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(.white.opacity(0.16), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// The original first; if that is not a picture the client can decode — a link to a
    /// page, say — the preview it was already showing.
    private func load() async {
        for path in [item.source, item.preview] where image == nil {
            if let data = await model.imageData(at: path), let decoded = Platform.image(from: data) {
                image = decoded
                return
            }
        }
        failed = true
    }
}
