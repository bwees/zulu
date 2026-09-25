import SwiftUI

/// The image over the whole screen, at the size it was uploaded. Pinch or double-tap to
/// zoom, tap to hide the controls, swipe down to put it back in the conversation.
struct ImageViewer: View {
    let item: ImageViewerItem

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var viewed: ViewedImage?
    @State private var failed = false
    @State private var zoomed = false
    @State private var controlsHidden = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let viewed {
                ZoomableImage(image: viewed.image, zoomed: $zoomed) {
                    withAnimation(.easeOut(duration: 0.15)) { controlsHidden.toggle() }
                }
                .ignoresSafeArea()
            } else if failed {
                Label(item.alt ?? "This image could not be loaded.", systemImage: "photo")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding()
            } else {
                ProgressView().controlSize(.large).tint(.white)
            }
        }
        .overlay(alignment: .top) {
            if !controlsHidden { controls }
        }
        .overlay(alignment: .bottom) {
            if !controlsHidden, let alt = item.alt, !alt.isEmpty, alt != item.preview {
                Text(alt)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
        .statusBarHidden(controlsHidden)
        // A drag across a zoomed picture pans it; only at full view does it mean "close".
        .interactiveDismissDisabled(zoomed)
        .presentationBackground(.clear)
        .task(id: item.source) {
            viewed = await model.viewedImage(for: item)
            failed = viewed == nil
        }
        .onDisappear { viewed?.discard() }
    }

    private var controls: some View {
        HStack {
            Button("Close", systemImage: "xmark") { dismiss() }
            Spacer()
            if let viewed {
                ShareLink(
                    item: viewed.file,
                    preview: SharePreview(viewed.file.lastPathComponent, image: Image(uiImage: viewed.image))
                ) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        }
        .labelStyle(.iconOnly)
        .font(.body.weight(.semibold))
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .padding(.horizontal)
    }
}

/// A picture that fits the screen, and can be pinched or double-tapped in and panned
/// around once it is.
private struct ZoomableImage: View {
    let image: UIImage
    @Binding var zoomed: Bool
    let onTap: () -> Void

    @State private var zoom = ZoomState()

    var body: some View {
        GeometryReader { proxy in
            let frame = ZoomState.Frame(image: image.size, container: proxy.size)
            Image(uiImage: image)
                .resizable()
                .frame(width: frame.fitted.width, height: frame.fitted.height)
                .scaleEffect(zoom.scale)
                .offset(zoom.offset)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { point in
                    withAnimation(.snappy) { zoom.toggle(at: point, in: frame) }
                }
                .onTapGesture(perform: onTap)
                .gesture(
                    MagnifyGesture()
                        .onChanged { zoom.magnify(by: $0.magnification, in: frame) }
                        .onEnded { _ in withAnimation(.snappy) { zoom.settle(in: frame) } }
                )
                .gesture(
                    DragGesture()
                        .onChanged { zoom.pan(by: $0.translation, in: frame) }
                        .onEnded { _ in zoom.settle(in: frame) },
                    // Left off at full view, so a swipe down reaches the dismiss gesture.
                    including: zoom.isZoomed ? .all : .subviews
                )
        }
        .onChange(of: zoom.isZoomed) { _, isZoomed in zoomed = isZoomed }
    }
}

/// How far in a picture is zoomed and where it has been panned to, kept inside the
/// bounds that leave no empty space showing past the picture's edges.
struct ZoomState {
    static let doubleTapScale: CGFloat = 2.5
    static let maxScale: CGFloat = 5

    struct Frame {
        let fitted: CGSize
        let container: CGSize

        init(image: CGSize, container: CGSize) {
            self.container = container
            guard image.width > 0, image.height > 0 else {
                fitted = container
                return
            }
            let fit = min(container.width / image.width, container.height / image.height)
            fitted = CGSize(width: image.width * fit, height: image.height * fit)
        }
    }

    private(set) var scale: CGFloat = 1
    private(set) var offset: CGSize = .zero
    private var settledScale: CGFloat = 1
    private var settledOffset: CGSize = .zero

    var isZoomed: Bool { scale > 1 }

    /// Past the limits while the fingers are down, so the pinch feels elastic; `settle`
    /// brings it back.
    mutating func magnify(by factor: CGFloat, in frame: Frame) {
        scale = settledScale * factor
        offset = clamp(settledOffset, scale: scale, in: frame)
    }

    mutating func pan(by translation: CGSize, in frame: Frame) {
        let moved = CGSize(
            width: settledOffset.width + translation.width,
            height: settledOffset.height + translation.height
        )
        offset = clamp(moved, scale: scale, in: frame)
    }

    mutating func settle(in frame: Frame) {
        scale = min(max(scale, 1), Self.maxScale)
        offset = clamp(offset, scale: scale, in: frame)
        settledScale = scale
        settledOffset = offset
    }

    /// In toward the tapped point, or back out to the whole picture.
    mutating func toggle(at point: CGPoint, in frame: Frame) {
        if isZoomed {
            scale = 1
            offset = .zero
        } else {
            scale = Self.doubleTapScale
            let fromCenter = CGSize(
                width: frame.container.width / 2 - point.x,
                height: frame.container.height / 2 - point.y
            )
            offset = clamp(
                CGSize(width: fromCenter.width * (scale - 1), height: fromCenter.height * (scale - 1)),
                scale: scale, in: frame
            )
        }
        settledScale = scale
        settledOffset = offset
    }

    private func clamp(_ offset: CGSize, scale: CGFloat, in frame: Frame) -> CGSize {
        let limit = CGSize(
            width: max(0, (frame.fitted.width * scale - frame.container.width) / 2),
            height: max(0, (frame.fitted.height * scale - frame.container.height) / 2)
        )
        return CGSize(
            width: min(max(offset.width, -limit.width), limit.width),
            height: min(max(offset.height, -limit.height), limit.height)
        )
    }
}
