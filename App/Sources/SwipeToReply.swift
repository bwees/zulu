import SwiftUI
import UIKit


extension View {
    func swipeToReply(perform reply: @escaping () -> Void) -> some View {
        modifier(SwipeToReply(reply: reply))
    }
}

/// Drag a message left to answer it, the way Signal and iMessage do.
///
/// Leftward only: a rightward drag anywhere in a conversation belongs to the drawer.
private struct SwipeToReply: ViewModifier {
    let reply: () -> Void

    @State private var offset: CGFloat = 0
    @State private var armed = false

    /// How far the row has to travel before releasing it counts as a reply.
    private static let trigger: CGFloat = 60
    /// Where the rubber band pulls back to, however hard the drag pushes.
    private static let limit: CGFloat = 84
    /// A drag this much more horizontal than vertical is a swipe, not a scroll.
    private static let horizontalBias: CGFloat = 1.4
    private static let badgeSide: CGFloat = 30
    private static let badgeInset: CGFloat = 14

    func body(content: Content) -> some View {
        ZStack(alignment: .trailing) {
            content.offset(x: -offset)
            indicator
        }
        .simultaneousGesture(drag)
    }

    /// Rides in from off the trailing edge as the row leaves, and fills in once the swipe
    /// is far enough that letting go will do something.
    private var indicator: some View {
        Image(systemName: "arrowshape.turn.up.left.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(armed ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .frame(width: Self.badgeSide, height: Self.badgeSide)
            .background(
                armed ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                in: Circle()
            )
            .padding(.trailing, Self.badgeInset)
            .scaleEffect(armed ? 1.1 : 1)
            .opacity(progress)
            .offset(x: max(0, Self.badgeSide + Self.badgeInset - offset))
            .animation(.snappy(duration: 0.18), value: armed)
            .allowsHitTesting(false)
    }

    private var progress: CGFloat { min(1, offset / Self.trigger) }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                let horizontal = -value.translation.width
                guard horizontal > 0,
                      horizontal > abs(value.translation.height) * Self.horizontalBias
                else { return }

                offset = Self.banded(horizontal)
                setArmed(offset >= Self.trigger)
            }
            .onEnded { _ in
                if armed { reply() }
                setArmed(false)
                withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) { offset = 0 }
            }
    }

    private func setArmed(_ value: Bool) {
        guard value != armed else { return }
        armed = value
        if value { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
    }

    /// Tracks the finger exactly as far as the trigger, then eases towards `limit` instead
    /// of stopping dead at it, so a hard swipe feels resisted rather than clamped.
    private static func banded(_ distance: CGFloat) -> CGFloat {
        guard distance > trigger else { return distance }
        let room = limit - trigger
        return trigger + room * (1 - exp(-(distance - trigger) / room))
    }
}
