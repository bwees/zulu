import ImageIO
import SwiftUI
import UIKit

/// Realm custom emoji are frequently animated GIFs. `UIImage(data:)` keeps only the first
/// frame, which is why they showed up as stills.
enum AnimatedImage {

    /// Returns an animated `UIImage` when the data holds more than one frame, and an
    /// ordinary one otherwise, so callers do not have to care which they got.
    static func decode(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return UIImage(data: data)
        }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return UIImage(data: data) }

        var frames: [UIImage] = []
        var duration: Double = 0
        frames.reserveCapacity(count)

        for index in 0..<count {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            frames.append(UIImage(cgImage: cgImage))
            duration += frameDelay(source: source, index: index)
        }

        guard !frames.isEmpty else { return UIImage(data: data) }
        // A GIF claiming zero total duration would animate infinitely fast.
        return UIImage.animatedImage(with: frames, duration: duration > 0 ? duration : 1)
    }

    /// GIF delays come from one of two dictionaries, and browsers clamp implausibly small
    /// values rather than honouring them.
    private static func frameDelay(source: CGImageSource, index: Int) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
            as? [CFString: Any],
            let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else { return 0.1 }

        let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        let clamped = gif[kCGImagePropertyGIFDelayTime] as? Double
        let delay = unclamped ?? clamped ?? 0.1
        return delay < 0.011 ? 0.1 : delay
    }
}

/// SwiftUI's `Image` draws a single frame even when handed an animated `UIImage`, so the
/// animation has to go through a `UIImageView`, which plays one natively.
struct AnimatedImageView: UIViewRepresentable {
    let image: UIImage
    let size: CGFloat

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentHuggingPriority(.required, for: .vertical)
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {
        guard view.image !== image else { return }
        view.image = image
        if image.images != nil { view.startAnimating() }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIImageView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }
}
