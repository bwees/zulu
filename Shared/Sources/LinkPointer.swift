import SwiftUI

/// Marks the runs of a `Text` that are links, so the Mac can find them under the pointer.
struct LinkAttribute: TextAttribute {}

extension View {
    /// Selectable text shows an I-beam everywhere, links included. This puts the
    /// pointing hand back over the links.
    func linkPointer() -> some View {
        #if os(macOS)
        modifier(LinkPointer())
        #else
        self
        #endif
    }
}

#if os(macOS)
private final class LinkFrames: @unchecked Sendable {
    var rects: [CGRect] = []
}

/// Draws the text unchanged, noting where each link landed along the way.
private struct LinkFrameRecorder: TextRenderer {
    let frames: LinkFrames

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var rects: [CGRect] = []
        for line in layout {
            for run in line {
                if run[LinkAttribute.self] != nil {
                    rects.append(run.typographicBounds.rect)
                }
                context.draw(run)
            }
        }
        frames.rects = rects
    }
}

private struct LinkPointer: ViewModifier {
    @State private var frames = LinkFrames()
    @State private var overLink = false

    func body(content: Content) -> some View {
        content
            .textRenderer(LinkFrameRecorder(frames: frames))
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    overLink = frames.rects.contains { $0.contains(point) }
                case .ended:
                    overLink = false
                }
            }
            .pointerStyle(overLink ? .link : nil)
    }
}
#endif
