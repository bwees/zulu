import SwiftUI

/// Turns off the status-bar tap that jumps a scroll view to the very top. In a
/// conversation that means leaping to the oldest message, which is never what was meant.
///
/// SwiftUI exposes no API for this, so the enclosing scroll view is found by walking up
/// the view hierarchy. Scoped to one view rather than set globally on `UIScrollView`,
/// which would also disable it in lists where it is useful.
struct DisablesScrollToTop: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { Probe() }
    func updateUIView(_ uiView: UIView, context: Context) {}

    private final class Probe: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            var candidate: UIView? = superview
            while let view = candidate {
                if let scrollView = view as? UIScrollView {
                    scrollView.scrollsToTop = false
                    return
                }
                candidate = view.superview
            }
        }
    }
}
