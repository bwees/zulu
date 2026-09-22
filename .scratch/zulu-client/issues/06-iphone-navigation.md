# iPhone navigation shell

Type: prototype
Status: resolved

## Question

What is the iPhone navigation structure — the thing that fixes the clunky official app?

Decide the shell: the Discord-equivalent rail of user-defined channel groups, the channel list, the DM section as its own space, and how a forum-mode channel's topic list and a chat-mode channel's message view both hang off it. Settle the gesture and tab vocabulary, where unread badges live, and how deep the stack ever gets.

Build a rough SwiftUI prototype via `/prototype` to react to. Link it from this ticket.

## Answer

**The drawer shell wins.** An edge rail of channel groups plus a channel list, sliding under a message pane that covers the full screen when closed — the Discord structure, kept.

Three shells were built and compared in the simulator: the drawer, a native bottom tab bar with groups as a filter, and a flat recency-sorted topic inbox. The two rejected shells are captured on the `prototype/nav-shell-variants` branch; `prototypes/nav-shell` on `main` now holds only the winner.

Settled with it:

- Stack depth is three at most — channel list → topic list → messages — with the drawer reachable from any of them via the leading toolbar button or an edge drag.
- DMs are a dedicated rail entry above the groups, swapping the drawer's list rather than pushing a screen.
- Unread counts sit on the rail (per group), on channel rows, and on topic rows; mentions are red, plain unreads grey.
- Forum-mode channels get a persistent floating **New topic** button; chat-mode channels go straight to the composer.
- The message pane must cover the safe areas completely when the drawer is closed — Liquid Glass bars sample whatever is behind them, so a drawer left mounted underneath bleeds through the header and footer.

Channel row iconography, decided alongside: `bubble.left.and.text.bubble.right` for forum channels, `number` for chat channels, with a `lock.fill` subicon for restricted channels.

Prototype: `prototypes/nav-shell` — run `prototypes/nav-shell/run.sh`.

## Follow-up: the drawer is hand-rolled

Surveyed the SwiftUI drawer package landscape before committing to custom code. Nothing credible exists: the popular results — `LGSideMenuController`, `kukushi/SideMenu`, `InteractiveSideMenu`, `AKSideMenu` — are all UIKit view controllers, and `Rideau`, `DrawerView`, and `UltraDrawerView` are bottom sheets, not side drawers. The only SwiftUI-native option found has two stars. A wrapper would also have to be taught Liquid Glass and iOS 27, which none of them know.

The drawer stays hand-rolled: roughly fifty lines of `ZStack`, offset, and a drag gesture.

Two layout rules came out of making it behave:

- **The message page draws its card as a background, never as a clip.** Clipping the content shaves the toolbar's glass controls against the rounded corner. The card is a `RoundedRectangle` behind the content instead.
- **That card ignores safe areas**, so the page runs the full height of the window under the status bar and home indicator rather than sitting in a letterboxed inset.
