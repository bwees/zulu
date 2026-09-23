import ImageIO
import SwiftUI

/// Realm custom emoji are frequently animated GIFs or WebPs, decoded here into the frames
/// a caller can play.
///
/// Frames rather than a platform image view: an emoji inline in a paragraph has to be a
/// `Text`, which can only hold one still image, so the only way to animate one is to
/// rebuild the paragraph with a different frame each tick. Reactions then use the same
/// mechanism rather than a second one.
struct EmojiFrames: Equatable {
    let frames: [Image]
    let duration: Double

    var isAnimated: Bool { frames.count > 1 }

    func frame(at time: TimeInterval) -> Image {
        guard isAnimated, duration > 0 else { return frames[0] }
        let progress = time.truncatingRemainder(dividingBy: duration) / duration
        let index = min(Int(progress * Double(frames.count)), frames.count - 1)
        return frames[index]
    }

    /// The emoji is sized by telling SwiftUI how many pixels of source make one point,
    /// which costs nothing — redrawing each frame into a smaller bitmap would.
    static func decode(_ data: Data, height: CGFloat) -> EmojiFrames? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), height > 0 else {
            return nil
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }

        var images: [Image] = []
        var duration: Double = 0
        images.reserveCapacity(count)

        for index in 0..<count {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            images.append(
                Image(decorative: cgImage, scale: CGFloat(cgImage.height) / height)
            )
            duration += delay(source: source, index: index)
        }

        guard !images.isEmpty else { return nil }
        // A GIF claiming zero total duration would animate infinitely fast.
        return EmojiFrames(frames: images, duration: duration > 0 ? duration : 1)
    }

    /// GIF delays come from one of two dictionaries, and browsers clamp implausibly small
    /// values rather than honouring them.
    private static func delay(source: CGImageSource, index: Int) -> Double {
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

/// One emoji, playing if it has more than one frame.
struct AnimatedEmojiView: View {
    let frames: EmojiFrames

    /// Fast enough that nothing looks like a slideshow, slow enough that a wall of
    /// reactions is not redrawn at display rate.
    static let tick: TimeInterval = 1.0 / 15

    var body: some View {
        if frames.isAnimated {
            TimelineView(.periodic(from: .now, by: Self.tick)) { context in
                frames.frame(at: context.date.timeIntervalSinceReferenceDate)
            }
        } else {
            frames.frames[0]
        }
    }
}
