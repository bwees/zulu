# Infinite scroll-back without jank

Research for Zulu (native SwiftUI Zulip client, iOS 27). Question: how do mature chat
clients prepend older messages without the list resizing and the scroll position jumping,
and what is the correct SwiftUI technique.

Date: 2026-09-22. Every claim below carries a source URL. Claims I could not source are
marked **INFERRED** or **UNDETERMINED**.

---

## 0. TL;DR

- No shipping chat client solves this with a plain top-down scroll view. Every one of them
  either inverts the list, or explicitly re-anchors on a remembered item across the mutation.
  Four of the five readable clients do the latter — which is exactly what SwiftUI's
  `scrollPosition(id:)` does for you.
- **The Discord placeholder theory is partly right but about the wrong list.** Discord's
  generic virtualized list does use *declared* heights plus a single fixed-height top spacer —
  no per-item skeletons — and it is undetermined whether the chat message list uses that
  component at all. The per-item "tombstone that fills in" design is Chrome's reference
  article, not a shipped chat client. §1.1.
- SwiftUI's answer is `.scrollPosition(id:)` + `.scrollTargetLayout()`, which anchors by
  *item identity*, not by offset. This is stated by an Apple Frameworks Engineer on the
  developer forums. `.defaultScrollAnchor` is a different, weaker mechanism and does not
  replace it.
- `.defaultScrollAnchor(.bottom)` already sets the `.sizeChanges` role to `.bottom`. Adding
  `.defaultScrollAnchor(.bottom, for: .sizeChanges)` changes nothing.
- The `proxy.scrollTo(previousOldestID, anchor: .top)` correction is the wrong shape of fix
  and should be deleted — and it anchors on the boundary item, which is the one item every
  other client deliberately avoids anchoring on (§1.8).
- iOS 27 adds no new scroll-anchoring API. The iOS 18 set is still the whole toolkit —
  verified against the shipping SDK, §2.0.

---

## 1. What Discord, Slack, and Telegram actually do

Tagging convention in this section: **[DOC]** = stated in an engineering post / talk transcript,
or read directly in open source. **[INF]** = reasoning from indirect evidence.

### 1.0 The consensus, up front

Across every client whose source is readable, scroll preservation across a prepend is done by
exactly one of three mechanisms. None of them is "let the scroll view work it out."

1. **Anchor item + offset delta.** Remember an item id and its position relative to the
   viewport before the mutation; after layout, recompute and shift the scroll offset by the
   delta. Used by Element (both generations), Telegram Desktop, Telegram Web, Discord's
   virtualized list, and Telegram-iOS on reload.
2. **Distance-from-bottom arithmetic.** Preserve `scrollHeight - scrollTop - clientHeight`.
   Only correct because older messages land above the viewport. Used by Signal Desktop.
3. **Structural inversion.** The list grows away from the anchored edge, so a prepend is
   arithmetically a no-op. Used by Telegram-iOS.

Two of these are the same thing SwiftUI's `scrollPosition(id:)` does for us. That is the
single most useful takeaway: **the SwiftUI API is not a workaround, it is the industry
mechanism, made declarative.**

Note also what nobody does: none of the web clients uses `flex-direction: column-reverse`, and
the ones that manage offsets in code explicitly *disable* the browser's own scroll anchoring
(`overflow-anchor: none`) so it does not fight them — Element
([`_RoomView.pcss`](https://github.com/element-hq/element-web/blob/develop/apps/web/res/css/structures/_RoomView.pcss))
and Telegram Web
([`MessageList.scss`](https://github.com/Ajaxy/telegram-tt/blob/master/src/components/middle/MessageList.scss)).

### 1.1 Discord — the placeholder hypothesis, tested

**Verdict: partly right, but not about the message list, and not "skeletons that fill in."**

Discord has published **no** engineering post about the web message list. What exists:

- [How Discord achieves native iOS performance with React Native](https://discord.com/blog/how-discord-achieves-native-ios-performance-with-react-native)
  — **[DOC]** React Native's `FlatList`/`SectionList` "are very expensive and their
  virtualization is not yet fully optimized"; "after a `<FlatList>` mounts, it eventually
  renders all its rows slowly every frame"; ~2000 views mounted on large servers. Their fix
  was a custom `<FastList>` built by **porting their web list component** — "replaced
  `<Scroller>` with `<ScrollerView>` and `<div>` with `<View>` and dropped it in. It worked!"
  This is about **channel and member lists**, not the message list.
- [Supercharging Discord Mobile](https://discord.com/blog/supercharging-discord-mobile-our-journey-to-a-faster-app)
  — **[DOC]** the mobile **chat list** "was already fully native and only uses JavaScript to
  fetch message data". The **channel list** moved off Shopify FlashList to their own
  "FastestList", "a native virtualized list, aka Android RecyclerView under the hood, not a
  ScrollView", combined with **"View Portaling" to render placeholders and eliminate
  'blanking'**. *This is the only Discord-documented placeholder mechanism, and it is the
  Android channel list.*

Reading the shipped web bundle (the beautified production entry chunk mirrored at
[Discord-Datamining/current.js](https://raw.githubusercontent.com/Discord-Datamining/Discord-Datamining/master/current.js)
— **[DOC, with the caveat that it is minified, renamed, and third-party mirrored]**):

**The generic virtualized `List` component:**

- Props include `sections`, `sectionHeight`, `rowHeight`, `footerHeight`, `renderRow`,
  `getAnchorId`, `chunkSize` (default 256).
- **Heights are declared, never measured.** `sectionHeight` / `rowHeight` are a number or a
  function `(section, row) => px`; the model sets `uniform = typeof rowHeight === "number"` and
  sums declared heights. There is no `ResizeObserver` row measurement.
- **One spacer, not per-item skeletons.** The renderer emits a single
  `<div aria-hidden style={{height: spacerTop}} key="---list-spacer-top">` above the visible
  window, inside an element with `style={{height: totalHeight}}`.
- **Anchor + offset correction.** Each render it finds the first item whose
  `offsetTop >= scrollTop` and stores `{id: anchorId, section, row, scrollOffset: offsetTop - scrollTop}`.
  A `useLayoutEffect` keyed on `totalHeight` re-validates the anchor (trying `row`, `row-1`,
  `row+1`) and sets `scrollerNode.scrollTop = newOffsetTop - anchor.scrollOffset`.
- Concrete call site (DM list) passes literal constants: `44`, `40`, `50`, `25`, `67`, `428`.

**Discord's message store (`ChannelMessages`):** `hasMoreBefore`, `hasMoreAfter`,
**`loadingMore`**, `jumpTargetId`, `jumpSequenceId`, plus `_before` / `_after` caches.
Re-entrancy is prevented at the store: `loadStart()` sets `loadingMore: true`;
`LOAD_MESSAGES_FAILURE` resets it. `TRUNCATE_MESSAGES` (with `truncateTop`/`truncateBottom`)
pushes trimmed messages into those caches so scrolling back is served from memory. Fetches are
`GET /channels/{id}/messages` with `before`/`after`/`around`/`limit`.

**What could not be determined:** whether the chat message list uses that generic component at
all. The chat view lives in a lazily-loaded chunk absent from the entry bundle —
`data-list-id="chat-messages"`, `scrollerInner`, and any `getAnchorId` call site are all
missing. **[UNDETERMINED.]** Declared heights for arbitrary rich message content seems
implausible **[INF]**, which suggests the chat list is a plain non-windowed scroller over the
~50-100 loaded messages with `_before`/`_after` truncation as the memory bound — unverified.

**Where the "tombstone" idea actually comes from:** Google's reference article
[Complexities of an infinite scroller](https://developer.chrome.com/blog/infinite-scroller)
— **[DOC]** it defines a **tombstone** as "a placeholder that will get replaced by the item
with actual content once the data has arrived", recycles DOM with a transformed sentinel
holding the runway height, and corrects position by assuming "every item above is the same size
as a tombstone." That is the design the hypothesis describes. It is Chrome's article, not
Discord's, and it exists to solve a problem (DOM node cost at 10k+ items) that we do not have.

### 1.2 Slack — effectively undocumented on this question

- [Making Slack Faster By Being Lazy](https://slack.engineering/making-slack-faster-by-being-lazy/)
  — **[DOC]** history fetched per active channel; "older messages can always be fetched as the
  user scrolls back through history"; page size settled at **42 messages** — "42 messages covers
  a reasonable amount of conversation without going overboard, and is enough to fill the view on
  a large monitor."
- [Part 2](https://slack.engineering/making-slack-faster-by-being-lazy-part-2/) — **[DOC]**
  deferring history meant "the client no longer had a complete data model at load time", which
  broke auto-scroll to oldest unread, the "new messages" divider, and mark-as-read. No mechanism
  described.
- [When a rewrite isn't: rebuilding Slack on the desktop](https://slack.engineering/rebuilding-slack-on-the-desktop/)
  — **[DOC]** the message pane shipped incrementally as modern React. No scrolling internals.
- **Most useful Slack source:** Jenna Zeigen, "Several Components are Rendering: Client
  Performance at Slack-Scale", QCon New York 2023
  ([InfoQ transcript](https://www.infoq.com/presentations/slack-front-performance/)) —
  **[DOC]** "We want to try *re*virtualizing the sidebar, this technique, which is to only
  render what's going to be on the screen with a little bit of buffering to try and allow for
  smooth scrolling, actually had a tradeoff for scroll speed and performance." **Slack had
  virtualization and removed it** because windowing hurt perceived scroll smoothness. The talk's
  analysis is about the **sidebar**, not the message list.
- **[DOC, reverse-engineering]** Slack's DOM uses `[data-qa="message_list"]` and
  `.c-virtual_list__scroll_container`, visible in third-party scripts such as
  [hoodoer/JS-Tap](https://github.com/hoodoer/JS-Tap/blob/main/plugins/slack/main.js) and
  [slack-channels-grouping](https://github.com/yamadashy/slack-channels-grouping/blob/master/app/scripts/content/dom-constants.ts).
  The component is *named* "virtual_list"; per the QCon talk the windowing behind that name was
  at least partly disabled.

**Slack's message-list anchoring mechanism is not public. [UNDETERMINED.]** Treat Slack as an
unusable reference here. The one transferable datum is the page size — 42, chosen to "fill the
view on a large monitor" — which suggests our 50 is reasonable.

### 1.3 Telegram — three open clients, three different answers

#### Telegram-iOS: inverted, dynamic heights, faked content size

Files: [`Display/Source/ListView.swift`](https://github.com/TelegramMessenger/Telegram-iOS/blob/master/submodules/Display/Source/ListView.swift),
[`ListViewIntermediateState.swift`](https://github.com/TelegramMessenger/Telegram-iOS/blob/master/submodules/Display/Source/ListViewIntermediateState.swift),
[`TelegramUI/Sources/ChatHistoryListNode.swift`](https://github.com/TelegramMessenger/Telegram-iOS/blob/master/submodules/TelegramUI/Sources/ChatHistoryListNode.swift).

**Inverted: yes, by 180° rotation. [DOC]** `ListView` has `public final var rotated = false`;
`ChatHistoryListNode.init` does:

```swift
self.listView.rotated = rotated
if rotated {
    self.transform = CATransform3DMakeRotation(CGFloat(Double.pi), 0.0, 0.0, 1.0)
}
```

Every item node is counter-rotated. Item index 0 is the **newest** message and sits at the
visual bottom; `scrollToItem` positions default to `self.rotated ? .bottom(0.0) : .top(0.0)`.
Corroborated by [Source Code Walkthrough of Telegram-iOS Part 6](https://hubo.dev/2020-06-22-source-code-walkthrough-of-telegram-ios-part-6/).
Consequence: loading older history appends at the far end, away from the anchored edge, so in
the common case nothing moves. **[INF from the geometry, but direct.]**

**Heights: fully dynamic, measured per node, never precomputed. [DOC]** `nodeForItem` produces
`ListViewItemNodeLayout(contentSize:insets:)` from each item's async layout. No estimate table,
no total-height precomputation. Note the contrast with SwiftUI, which *does* estimate.

**The scroller is faked — this is the notable trick. [DOC]**

```swift
self.infiniteScrollSize = 10000.0
self.scroller.contentSize = CGSize(width: 0.0, height: infiniteScrollSize * 2.0)
```

In `updateScroller(transition:)`, a real `contentSize = completeHeight` is set only when **both**
ends are loaded (`topItemFound && bottomItemFound`). Otherwise `contentSize` stays a synthetic
20,000 pt and `contentOffset` is re-centred:

```swift
} else {
    self.scroller.contentSize = CGSize(width: self.visibleSize.width, height: infiniteScrollSize * 2.0)
    if abs(self.scroller.contentOffset.y - infiniteScrollSize) > infiniteScrollSize / 2.0 {
        self.lastContentOffset = CGPoint(x: 0.0, y: infiniteScrollSize)
        self.scroller.contentOffset = self.lastContentOffset
    }
```

The `UIScrollView` is a gesture and inertia source only; real geometry lives in
`itemNodes[].apparentFrame`. That is why Telegram's scrollbar thumb behaves oddly mid-history —
there is no true content height to represent. Worth noting because it is the same insight as
FluidGroup's 100-million-point virtual space (§2.9): *decouple the scroll view's content size
from the data.*

**Anchoring across a reload: `stationaryItemRange`. [DOC]**

```swift
if let (index, boundary) = stationaryItemRange {
    state.setupStationaryOffset(index, boundary: boundary, frames: previousFrames)
}
```

`setupStationaryOffset` records a pre-existing node's `(nodeIndex, frame.minY)`; `replayOperations`
then shifts every node's frame by the delta:

```swift
let offset = previousFrame.frame.minY - itemNode.frame.minY
if abs(offset) > CGFloat.ulpOfOne {
    for itemNode in self.itemNodes { var frame = itemNode.frame; frame.origin.y += offset; itemNode.updateFrame(...) }
}
```

`PreparedChatHistoryViewTransition` sets `stationaryItemRange = (0, Int.max)` for `.Reload` and
`.HoleReload`; ordinary `.InteractiveChanges` do not need it because inversion already covers
them.

**Placeholders: no. [DOC]** `ListViewTempItemNode` exists only for
`InsertDisappearingPlaceholder` — a spacer standing in for a node animating out during deletion.
No skeletons for unloaded ranges.

**Load-more trigger and re-entrancy. [DOC]** `displayedItemRangeChanged` computes
`mathesFirst = loaded.firstIndex <= 5` and `mathesLast = loaded.lastIndex >= filteredEntries.count - 5`:

```swift
} else if mathesLast {
    let locationInput: ChatHistoryLocation = .Navigation(index: .message(firstEntry.index), ...)
    if historyView.originalView.earlierId != nil {
        if self.chatHistoryLocationValue?.content != locationInput {
            self.chatHistoryLocationValue = ChatHistoryLocationInput(content: locationInput, id: self.takeNextHistoryLocationId())
        }
    }
```

Three layers of re-entrancy protection: **value equality on the location input**, a monotonic
request id, and a `ListViewTransactionQueue` that serialises every mutation so two can never
interleave. Note it triggers on **index proximity (within 5 entries of the end)**, not on a
pixel offset — the same conclusion §3 reaches for SwiftUI.

#### Telegram Desktop: normal order, no virtualization, anchor item + offset

Files: [`history_widget.cpp`](https://github.com/telegramdesktop/tdesktop/blob/dev/Telegram/SourceFiles/history/history_widget.cpp),
[`history_inner_widget.cpp`](https://github.com/telegramdesktop/tdesktop/blob/dev/Telegram/SourceFiles/history/history_inner_widget.cpp),
[`history.cpp`](https://github.com/telegramdesktop/tdesktop/blob/dev/Telegram/SourceFiles/history/history.cpp).

- **Not inverted, not virtualized. [DOC]** `HistoryInner::updateSize()` sets the widget height
  from `historyHeight()`; every loaded message is laid out and only *painting* is clipped.
- **Anchor = `History::scrollTopItem` + `scrollTopOffset`. [DOC]** On every
  `visibleAreaUpdated(top, bottom)`:
  ```cpp
  // if history has pending resize events we should not update scrollTopItem
  if (hasPendingResizedItems()) return;
  _history->countScrollState(top - htop);
  ```
  Restoration reconstructs an absolute offset from the anchor item:
  ```cpp
  return htop + _history->scrollTopItem->block()->y()
       + _history->scrollTopItem->y() + _history->scrollTopOffset;
  ```
  Note the guard: **do not re-sample the anchor while a relayout is pending.** That is the
  direct analogue of our `isApplyingUpdate` flag in §5.2.
- **Load-more trigger. [DOC]**
  ```cpp
  if (scrollTop + kPreloadHeightsCount * scrollHeight >= scrollTopMax) loadMessagesDown();
  if (scrollTop <= kPreloadHeightsCount * scrollHeight) loadMessages();
  ```
  Guarded by early return on `_firstLoadRequest || _delayedShowAtRequest || _scroll->isHidden()
  || !_peer || !_historyInited`, and suppressed entirely while `_scrollToAnimation.animating()`.
- Even with all that, it still has open jump bugs:
  [tdesktop#10081](https://github.com/telegramdesktop/tdesktop/issues/10081),
  [tdesktop#25757](https://github.com/telegramdesktop/tdesktop/issues/25757).

#### Telegram Web (WebZ / telegram-tt): normal order, JS anchor delta

[`src/components/middle/MessageList.tsx`](https://github.com/Ajaxy/telegram-tt/blob/master/src/components/middle/MessageList.tsx)
— **[DOC]**:

```ts
const preservedItemElements = listItemElementsRef.current
  .filter((element) => renderMessageIdSet.has(Number(element.dataset.messageId)));
// We avoid the very first item as it may be a partly-loaded album
// and also because it may be removed when messages limit is reached
const anchor = preservedItemElements[1] || preservedItemElements[0];
anchorIdRef.current = anchor.id;
anchorTopRef.current = anchor.getBoundingClientRect().top;
// ... later:
newScrollTop = scrollTop + (newAnchorTop - (anchorTopRef.current || 0));
```

Note the comment: **do not anchor on the boundary item**, because it is the one most likely to
be replaced or trimmed. Same lesson as Element's `isValidAnchorItem` below, and directly
relevant to us (§5.3).

Windowing is by data slice, not DOM: `MESSAGE_LIST_SLICE = isBigScreen ? 60 : 40`,
`MESSAGE_LIST_VIEWPORT_LIMIT = MESSAGE_LIST_SLICE * 2`
([config.ts](https://github.com/Ajaxy/telegram-tt/blob/master/src/config.ts)).

### 1.4 Element / Matrix — the best-documented implementation anywhere

Worth reading even though it is React, because the comments name the failure each decision
prevents.

#### Legacy `ScrollPanel`

[`src/components/structures/ScrollPanel.tsx`](https://github.com/matrix-org/matrix-react-sdk/blob/develop/src/components/structures/ScrollPanel.tsx).
Its header comment is the clearest statement of the problem I found — **[DOC]**:

> The saved 'scrollState' can exist in one of two states:
> - **stuckAtBottom**: … the viewport is scrolled down as far as it can be. When the children
>   are updated, the scroll position will be updated to ensure it is still at the bottom.
> - **fixed**, in which the viewport is conceptually tied at a specific scroll offset. We don't
>   save the absolute scroll offset, because that would be affected by window width, zoom level,
>   amount of scrollback, etc. Instead, **we save an identifier for the last fully-visible
>   message, and the number of pixels the window was scrolled below it** — which is hopefully
>   near enough.

Mechanics **[all DOC]**:

- Children carry `data-scroll-tokens`; `saveScrollState()` walks bottom-up and records
  `{trackedNode, trackedScrollToken, bottomOffset, pixelOffset}`.
- **Height quantisation**: `PAGE_SIZE = 400`;
  `minListHeight = Math.ceil(contentHeight / PAGE_SIZE) * PAGE_SIZE`, so the list height changes
  in 400px steps rather than on every content change.
- **Correct by a relative scroll, never an absolute one:**
  ```ts
  const oldTop = trackedNode.offsetTop;
  itemlist.style.height = newHeight;
  const newTop = trackedNode.offsetTop;
  // important to scroll by a relative amount as reading scrollTop and then setting it
  // might yield out of date values and cause a jump when setting it
  sn.scrollBy(0, newTop - oldTop);
  ```
- **Fill trigger**: backward when `sn.scrollTop - firstTile.offsetTop < sn.clientHeight`
  (one screen from the top of the first tile); forward when
  `sn.scrollHeight - sn.scrollTop < sn.clientHeight * 2`.
- **Re-entrancy**: `pendingFillRequests: Record<"b"|"f", boolean|null>` per direction, set
  *before* calling `onFillRequest` because "onFillRequest can end up calling us recursively (via
  onScroll events)", plus an `isFilling` / `fillRequestWhileRunning` chain flag and a re-check
  afterwards. Plus a deliberate 1 ms defer: *"wait 1ms before paginating, because otherwise this
  will block the scroll event handler for +700ms if messages are already cached in memory. This
  would cause jumping to happen on Chrome/macOS."*
- **Unfilling** with `UNPAGINATION_PADDING = 6000` px of slack and a 200 ms debounce, so trimming
  cannot immediately re-trigger pagination.
- History: [Improved scrolling & pagination PR #2676](https://github.com/matrix-org/matrix-react-sdk/pull/2676/files),
  [element-web#2646 "Scrolling jumps"](https://github.com/element-hq/element-web/issues/2646).

#### New `TimelineView` (2026, TanStack Virtual)

[`packages/shared-components/src/room/timeline/TimelineView/TimelineView.tsx`](https://github.com/element-hq/element-web/blob/develop/packages/shared-components/src/room/timeline/TimelineView/TimelineView.tsx).
The file comment, **[DOC]**:

> The hard part of a chat timeline is holding the scroll position steady while the list changes
> underneath the reader. …
> - **Older history arrives at the top.** `anchorTo: "end"` makes TanStack remember which row
>   the user is looking at and, once the new rows are inserted above it, adjust the scroll
>   position by the height that was added so that row stays exactly where it was on screen. It
>   does this before the browser paints, so the shift is never visible.
> - `isValidAnchorItem` stops it picking a loading spinner as that remembered row: the spinner
>   is replaced by the messages it was waiting for, so afterwards there is no such row left to
>   line up against and the timeline would lurch to the top instead.
> - **New messages arrive at the bottom.** `followOnAppend` scrolls down…, but only when we are
>   already at the live end and not jumping somewhere else.
> - **Jumping to a particular message** looks up how far down that message sits and scrolls
>   straight to that position. We avoid TanStack's `scrollToIndex`, which keeps steering towards
>   a row *number*: if history loads while it is doing that, every row shifts down and it follows
>   the wrong one to the top.

```ts
const ESTIMATED_ITEM_HEIGHT = 48;   // seed for unmeasured rows; real heights cached by key
const OVERSCAN = 16;                // a COUNT, not px
const AT_BOTTOM_THRESHOLD_PX = 4;
const REVEAL_TIMEOUT_MS = 1000;

useVirtualizer({
  count: items.length,
  estimateSize: () => ESTIMATED_ITEM_HEIGHT,
  getItemKey,                       // event id — stable identity is what makes anchoring possible
  overscan: OVERSCAN,
  anchorTo: "end",
  isValidAnchorItem,                // local @tanstack/virtual-core patch, pending upstream
  scrollEndThreshold: AT_BOTTOM_THRESHOLD_PX,
  followOnAppend: snapshot.atLiveEnd && snapshot.pendingAnchor === null,
  directDomUpdates: true,
  onChange: reportVisibleState,
});
```

Four decisions that transfer directly to us **[all DOC]**:

1. **Loading spinners are ordinary list rows** (`kind: "loading"`, keys `BACKWARD_LOADING_KEY` /
   `FORWARD_LOADING_KEY`) "so showing or hiding one is just another change to the list that the
   scroll anchoring already knows how to absorb" — **and are excluded from anchor candidacy.**
2. **First paint is hidden behind a spinner** for up to 1000 ms while rows are measured and the
   target scroll settles, so the user never sees the list shuffle.
3. **`directDomUpdates: true`** — "measuring a row and moving it happen in the same frame
   (splitting them across two caused a visible stutter)."
4. **Load-more re-entrancy is an edge token, not a boolean:**
   ```ts
   if (firstRenderedIndex === 0) {
       const token = `${itemCount}:${visibleRange ? visibleRange.startIndex : 0}`;
       if (startEdgeTokenRef.current !== token) { startEdgeTokenRef.current = token; vm.onStartReached(); }
   } else { startEdgeTokenRef.current = ""; }
   ```
   "Reached the start" fires once per distinct (item count, visible start) pair, so it re-arms
   when the list actually changes but never loops. This is strictly better than a boolean
   in-flight flag, because it also survives a fetch that returns nothing.

Acknowledged gap in-source: "`overscan` counts rows rather than pixels, so how far it actually
reaches beyond the viewport varies with how tall those rows happen to be."

### 1.5 Signal Desktop — the cheapest thing that works

Files: [`Timeline.dom.tsx`](https://github.com/signalapp/Signal-Desktop/blob/main/ts/components/conversation/Timeline.dom.tsx),
[`timelineUtil.std.ts`](https://github.com/signalapp/Signal-Desktop/blob/main/ts/util/timelineUtil.std.ts),
[`scrollUtil.std.ts`](https://github.com/signalapp/Signal-Desktop/blob/main/ts/util/scrollUtil.std.ts).

- **Normal order, no virtualization at all. [DOC]**
  `.module-timeline__messages { display: flex; flex-direction: column; justify-content: flex-end; }`
  and a plain `for` loop rendering every loaded item. Signal used to use
  react-virtualized/`CellMeasurer` and **moved off it**.
- **Distance-from-bottom, with an explicit anchor enum. [DOC]**
  ```ts
  export enum ScrollAnchor { ChangeNothing, ScrollToBottom, ScrollToIndex, ScrollToUnreadIndicator, Top, Bottom }
  case TimelineMessageLoadingState.LoadingOlderMessages: return ScrollAnchor.Bottom;
  case TimelineMessageLoadingState.LoadingNewerMessages: return ScrollAnchor.Top;
  ```
  ```ts
  export const getScrollBottom = (el) => el.scrollHeight - el.scrollTop - el.clientHeight;
  export function setScrollBottom(el, newScrollBottom) {
    el.scrollTop = el.scrollHeight - newScrollBottom - el.clientHeight;
  }
  ```
  Snapshotted in `getSnapshotBeforeUpdate`, restored in `componentDidUpdate`.
- **Signal is the one client that deliberately *uses* browser scroll anchoring. [DOC]**
  Every message opts out; a 1px `::after` sentinel at the bottom opts in, pinning to the live
  end. Viable only because Signal Desktop ships Chromium.
- **Load-more via `IntersectionObserver`, not scroll events. [DOC]** — chosen because "it's
  usually faster to use an `IntersectionObserver` instead of a scroll event". Older history:
  ```ts
  if (!messageLoadingState && !haveOldest &&
      oldestPartiallyVisibleMessageId && oldestPartiallyVisibleMessageId === items[0]?.id) {
    loadOlderMessages(id, oldestPartiallyVisibleMessageId);
  }
  ```
  Re-entrancy is the redux-held `messageLoadingState`, checked in both branches *and*
  short-circuiting the anchor computation
  (`if (props.messageLoadingState || !props.items.length) return ScrollAnchor.ChangeNothing`),
  plus a `#scrollerLock` guarding restoration while the user is interacting.

Note: **visibility of the oldest item is the trigger**, not an offset threshold. Same conclusion
as §3.

### 1.6 Browser primitives, for completeness

- **`overflow-anchor` / CSS Scroll Anchoring**
  ([spec](https://drafts.csswg.org/css-scroll-anchoring-1/),
  [MDN](https://developer.mozilla.org/en-US/docs/Web/CSS/overflow-anchor)).
  **[DOC, [caniuse](https://caniuse.com/css-overflow-anchor)]**: Chrome 56+, Edge 79+, Firefox 66+.
  **Safari: not supported in any shipped version, desktop or iOS — Technology Preview only.**
  Irrelevant to us directly, but the reason web chat clients hand-roll anchoring.
- **`flex-direction: column-reverse`** — the classic web inversion trick. Long-standing browser
  bugs: [Mozilla 1042151](https://bugzilla.mozilla.org/show_bug.cgi?id=1042151),
  [flexbugs #108](https://github.com/philipwalton/flexbugs/issues/108),
  [fluentui #30132](https://github.com/microsoft/fluentui/issues/30132),
  [radix-ui/primitives #2657](https://github.com/radix-ui/primitives/issues/2657),
  [RocketChat #24700](https://github.com/RocketChat/Rocket.Chat/issues/24700).
  **None of the five clients above uses it.**
- [`@virtuoso.dev/message-list`](https://virtuoso.dev/virtuoso-message-list/tutorial/loading-older-messages/)
  — **[DOC]** the author's framing is that generic `Virtuoso`'s `firstItemIndex` prepend
  bookkeeping "is kind of convoluted and causes complications", so the message-list variant
  exposes `scrollModifier: 'prepend'` that preserves position automatically. Useful as an API
  shape reference.

### 1.7 Comparison

| | Inverted? | Item heights | Placeholders | Position preserved by | Load-more trigger | Re-entrancy guard |
|---|---|---|---|---|---|---|
| **Discord (generic list)** | No | **Declared**, never measured | One top spacer div; no skeletons | Anchor id + `scrollOffset`, layout effect on `totalHeight` | *(chat chunk unreadable)* | Store-level `loadingMore` |
| **Discord (chat list)** | — | **Unknown** | **Unknown** | **Unknown** | **Unknown** | `loadingMore` on `ChannelMessages` |
| **Slack** | No [INF] | Unknown | Unknown | **Not public** | Unknown (42-msg pages) | Unknown |
| **Telegram-iOS** | **Yes**, 180° `CATransform3D` | Fully dynamic; fake 20,000 pt `contentSize` until both ends loaded | No | Inversion + `stationaryItemRange` frame delta on reload | Within 5 entries of either end | Location-value equality + monotonic id + transaction queue |
| **Telegram Desktop** | No | All loaded items laid out | No | `scrollTopItem` + `scrollTopOffset` | `kPreloadHeightsCount` screens from either edge | Early return on pending requests; skipped while animating |
| **Telegram Web** | No | DOM-measured | No | Anchor element (**2nd** preserved item) rect delta | Slice-based, 40/60, limit 2× | Reducer-side; `overflow-anchor: none` |
| **Element (legacy)** | No | Measured; height quantised to 400px pages | No | `data-scroll-tokens` + offsets, relative `scrollBy` | 1 screen above / 2 below | Per-direction pending flags + chain flag + 1 ms defer |
| **Element (new)** | No | 48px estimate → measured, cached by event id | Spinners are real rows, excluded from anchoring | TanStack `anchorTo: "end"` + `isValidAnchorItem`, pre-paint | First/last rendered index hits 0 / count-1 | **Edge token** `${itemCount}:${visibleStart}` |
| **Signal Desktop** | No (`column` + `flex-end`) | All loaded items in DOM | No | `scrollBottom` snapshot/restore | IntersectionObserver: oldest visible == `items[0]` | Redux `messageLoadingState` + `#scrollerLock` |

### 1.8 What this means for Zulu

Five things transfer directly, and they all point the same way as the SwiftUI research below:

1. **Anchor on an item, never on an offset.** Four of five clients do exactly what
   `scrollPosition(id:)` does. Our `proxy.scrollTo` correction is the "adjust contentOffset
   afterwards" approach that FluidGroup explicitly documents as fragile.
2. **Never anchor on the boundary item.** Telegram Web skips the first preserved element
   ("it may be a partly-loaded album and also because it may be removed"); Element's
   `isValidAnchorItem` excludes the loading spinner because "the spinner is replaced by the
   messages it was waiting for … and the timeline would lurch to the top instead." If we anchor
   on the message we just prepended *before*, we have picked exactly the wrong item.
3. **Trigger on item visibility, not on a pixel threshold.** Signal uses IntersectionObserver on
   the oldest item; Telegram-iOS uses index-within-5-of-the-end; Element uses first-rendered-index
   reaching 0. Nobody keys pagination off a raw offset.
4. **Guard re-entrancy in the data layer, with more than one flag.** Discord and Signal use a
   store-level loading enum; Telegram-iOS uses value equality plus a serialising queue; Element
   uses an edge token that re-arms on real change. Element's token is the most robust — it
   survives a fetch that returns zero new messages, where a boolean would immediately re-fire.
5. **Nobody renders per-message skeletons for unloaded history.** The one placeholder mechanism
   Discord documents is Android channel-list "View Portaling", and the tombstone design the
   hypothesis describes is Chrome's reference article, not a shipped chat client. A single
   loading row at the edge is the universal pattern.


---

## 2. The correct SwiftUI technique on iOS 18+ / 26 / 27

### 2.0 First: what iOS 27 adds (nothing)

I grepped the shipping iOS 27 SDK's SwiftUI module interface directly:

```
/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/
  iPhoneOS27.0.sdk/System/Library/Frameworks/SwiftUI.framework/Modules/
  SwiftUI.swiftmodule/arm64e-apple-ios.swiftinterface
```

- 177 symbols marked `@available(iOS 26, ...)`, 124 marked `@available(iOS 27, ...)`.
- **None of them is a scroll-anchoring or scroll-position API.** The only scroll-adjacent
  iOS 26 additions are `ScrollEdgeEffectStyle` / `scrollEdgeEffectStyle(_:for:)` /
  `scrollEdgeEffectHidden(_:for:)` (Liquid Glass cosmetics) and `accessibilityScrollStatus`.
  The iOS 27 additions are documents, drag & drop, reordering (`reorderable()`,
  `reorderContainer(...)`), toolbar overflow, and navigation transitions.

**Conclusion: the iOS 18 (WWDC24) scroll APIs are still the state of the art in iOS 27.**
There is no newer anchoring primitive waiting for us. (Primary source: the SDK itself.)

WWDC26 did ship a session dedicated to this problem space —
["Dive into lazy stacks and scrolling with SwiftUI", WWDC26 session 321](https://developer.apple.com/videos/play/wwdc2026/321/)
— but it explains the existing mechanism rather than adding API. It is the single most useful
document for our problem and is quoted throughout below.

### 2.1 Exact API names and availability

Availability taken from the Apple docs JSON and cross-checked against the iOS 27 SDK
`.swiftinterface`.

| API | Signature | Introduced |
|---|---|---|
| [`defaultScrollAnchor(_:)`](https://developer.apple.com/documentation/swiftui/view/defaultscrollanchor(_:)) | `func defaultScrollAnchor(_ anchor: UnitPoint?) -> some View` | iOS 17.0 / macOS 14.0 |
| [`defaultScrollAnchor(_:for:)`](https://developer.apple.com/documentation/swiftui/view/defaultscrollanchor(_:for:)) | `func defaultScrollAnchor(_ anchor: UnitPoint?, for role: ScrollAnchorRole) -> some View` | iOS 18.0 / macOS 15.0 |
| [`ScrollAnchorRole`](https://developer.apple.com/documentation/swiftui/scrollanchorrole) | `struct ScrollAnchorRole` with static vars `.sizeChanges`, `.alignment`, `.initialOffset` | iOS 18.0 |
| [`scrollPosition(id:anchor:)`](https://developer.apple.com/documentation/swiftui/view/scrollposition(id:anchor:)) | `func scrollPosition(id: Binding<(some Hashable)?>, anchor: UnitPoint? = nil) -> some View` | iOS 17.0 |
| [`scrollPosition(_:anchor:)`](https://developer.apple.com/documentation/swiftui/view/scrollposition(_:anchor:)) | `func scrollPosition(_ position: Binding<ScrollPosition>, anchor: UnitPoint? = nil) -> some View` | iOS 18.0 |
| [`ScrollPosition`](https://developer.apple.com/documentation/swiftui/scrollposition) | `struct ScrollPosition`; `scrollTo(id:anchor:)`, `scrollTo(edge:)`, `scrollTo(y:)`, `viewID(type:)` | iOS 18.0 |
| [`ScrollPosition.isPositionedByUser`](https://developer.apple.com/documentation/swiftui/scrollposition/ispositionedbyuser) | `var isPositionedByUser: Bool { get set }` | iOS 18.0 |
| [`scrollTargetLayout(isEnabled:)`](https://developer.apple.com/documentation/swiftui/view/scrolltargetlayout(isenabled:)) | `func scrollTargetLayout(isEnabled: Bool = true) -> some View` | iOS 17.0 |
| [`onScrollGeometryChange(for:of:action:)`](https://developer.apple.com/documentation/swiftui/view/onscrollgeometrychange(for:of:action:)) | `func onScrollGeometryChange<T: Equatable>(for: T.Type, of: (ScrollGeometry) -> T, action: (T, T) -> Void) -> some View` | iOS 18.0 |
| `onScrollTargetVisibilityChange(idType:threshold:_:)` | `func onScrollTargetVisibilityChange<ID: Hashable>(idType: ID.Type, threshold: Double = 0.5, _ action: @escaping ([ID]) -> Void) -> some View` | iOS 18.0 (verified in SDK interface) |
| `onScrollVisibilityChange(threshold:_:)` | `func onScrollVisibilityChange(threshold: Double = 0.5, _ action: @escaping (Bool) -> Void) -> some View` | iOS 18.0 (SDK) |
| `onScrollPhaseChange(_:)` | takes `(oldPhase: ScrollPhase, newPhase: ScrollPhase)` or a 3-arg form with `ScrollPhaseChangeContext` | iOS 18.0 (SDK) |
| `ScrollPhase` | `enum ScrollPhase { case idle, tracking, interacting, decelerating, animating }` + `var isScrolling: Bool` | iOS 18.0 (SDK, in SwiftUICore) |
| `ScrollGeometry` | `contentOffset`, `contentSize`, `contentInsets`, `containerSize`, `visibleRect`, `bounds` | iOS 18.0 |

### 2.2 `.defaultScrollAnchor(_:for:)` and `ScrollAnchorRole` — exactly what `.sizeChanges` does

Apple's own text, from the [`ScrollAnchorRole` overview](https://developer.apple.com/documentation/swiftui/scrollanchorrole):

> You can associate a `UnitPoint` to a `ScrollView` using the `defaultScrollAnchor(_:)`
> modifier. By default, the system uses this point for different kinds of behaviors
> including:
> - Where the scroll view should initially be scrolled
> - How the scroll view should handle content size or container size changes
> - How the scroll view should align content smaller than its container size
>
> You can further customize this behavior by assigning different unit points for these
> different roles.

Per-role text, verbatim from the docs:

- [`.sizeChanges`](https://developer.apple.com/documentation/swiftui/scrollanchorrole/sizechanges):
  "The role that influences how a scroll view should adjust its **content offset** when the
  scroll view's **content or container size changes**."
- [`.alignment`](https://developer.apple.com/documentation/swiftui/scrollanchorrole/alignment):
  "The role that influences how a scroll view should align its content when the size of its
  content is **smaller than the container size**."
- [`.initialOffset`](https://developer.apple.com/documentation/swiftui/scrollanchorrole/initialoffset):
  "The role that influences where a scroll view should be **initially** scrolled."

The [`defaultScrollAnchor(_:for:)` discussion](https://developer.apple.com/documentation/swiftui/view/defaultscrollanchor(_:for:))
spells out the composition rule:

> For example, you can use the `defaultScrollAnchor(_:)` modifier to provide a value of
> `bottom` as the anchor for all cases and then opt out of certain cases by providing a
> different value for them.

```swift
ScrollView { LazyVStack { ForEach(items) { ItemView($0) } } }
.defaultScrollAnchor(.bottom)
.defaultScrollAnchor(.topLeading, for: .alignment)
```

**Therefore, for Zulu specifically:** `.defaultScrollAnchor(.bottom)` — which we already have
— *already* sets `.sizeChanges` to `.bottom`. Writing
`.defaultScrollAnchor(.bottom, for: .sizeChanges)` is a no-op on top of it. This is documented,
not inferred.

**Why bottom size-change anchoring is not sufficient on its own (INFERRED):**

1. It anchors a content *edge*, not an *item*. It says "keep the distance from the bottom of
   content constant." That gives the right answer only if the content grows in one atomic
   step, entirely above the viewport. With `LazyVStack` neither is true: prepended rows are
   measured incrementally as they materialise, and the stack's *estimate* of the unmeasured
   space keeps getting revised (see §2.6). Each revision is another content-size change.
2. It is directionally wrong for the other half of chat. Bottom size-change anchoring also
   drags the viewport when content grows *below* — a newly arrived message, a composer that
   grew a line, the keyboard's inset. That is desirable at the bottom of the conversation and
   wrong when the user is reading history.
3. `ScrollAnchorRole` is documented in terms of `contentOffset`, and the WWDC26 session says
   the lazy stack's content offset is an estimate (§2.6). Anchoring a *estimated* offset
   edge is structurally weaker than anchoring a real, measured item.

I could not find an Apple statement that `.defaultScrollAnchor(.bottom)` alone is sufficient
for prepending. Several blog posts assert it is; none of them is a primary source, and the
open forum threads in §2.4 are evidence that it is not. **UNDETERMINED / contested.**

### 2.3 `ScrollPosition` and `scrollPosition(id:anchor:)` — the actual anchoring mechanism

This is the part that matters. From the
[`scrollPosition(id:anchor:)` discussion](https://developer.apple.com/documentation/swiftui/view/scrollposition(id:anchor:)):

> SwiftUI will attempt to keep the view with the identity specified in the provided binding
> visible **when events occur that might cause it to be scrolled out of view by the system**.
> Some examples of these include:
> - **The data backing the content of a scroll view is re-ordered.**
> - The size of the scroll view changes, like when a window is resized on macOS or during a
>   rotation on iOS.
> - The scroll view initially lays out its content defaulting to the top most view, but the
>   binding has a different view's identity.

The same paragraph appears in the [`ScrollPosition` overview](https://developer.apple.com/documentation/swiftui/scrollposition)
for the iOS 18 `scrollPosition(_:anchor:)` form.

And critically, the anchor parameter has *two* jobs:

> You can provide an anchor to this modifier to both:
> - Influence which view the system chooses as the view whose identity value will update the
>   providing binding as the scroll view scrolls.
> - Control the alignment of the view when scrolling to a view when writing a new binding value.

So `anchor: .top` means "track the top-most visible view, and align to its top when writing."

#### Primary source: Apple Frameworks Engineer, forums thread 731271

Thread: ["Keep ScrollView position when adding items on the top"](https://developer.apple.com/forums/thread/731271).
Reply from an author labelled **Frameworks Engineer** (Apple), verbatim:

> The new scrollPosition modifier can help you. It associated a binding to an identifier with
> the scroll view. When changes to the scroll view occur like items being added or the scroll
> view changing its containing size, it will attempt to keep the currently scrolled item in
> the same relative position as before the change. **The docs on the website have some
> incorrect information** but here's an example to hopefully get you started.

The shape of their example:

```swift
struct ContentView: View {
    @State var data: [String] = (0 ..< 25).map { String($0) }
    @State var dataID: String?

    var body: some View {
        ScrollView {
            VStack {
                Text("Header")
                LazyVStack {
                    ForEach(data, id: \.self) { item in
                        Color.red.frame(width: 100, height: 100)
                            .overlay { Text("\(item)").padding().background() }
                    }
                }
                .scrollTargetLayout()     // <- required
            }
        }
        .scrollPosition(id: $dataID)      // <- required
        .safeAreaInset(edge: .bottom) { /* prepend / append / remove buttons */ }
    }
}
```

Two non-obvious requirements from that example:

1. **`.scrollTargetLayout()` goes on the `LazyVStack`**, not the `ScrollView`. Without it the
   scroll view has no scroll targets and `scrollPosition(id:)` does nothing. Apple's
   [`scrollTargetLayout` docs](https://developer.apple.com/documentation/swiftui/view/scrolltargetlayout(isenabled:))
   say to "apply this modifier to layout containers like `LazyHStack` or `VStack` within a
   `ScrollView`."
2. **You do not write to the binding on prepend.** You leave `dataID` alone; SwiftUI keeps the
   view with that id in the same relative position across the data change. This is the
   opposite of the `proxy.scrollTo(previousOldestID, anchor: .top)` correction we currently do.

#### Known limitation: batch prepend

The same forum thread reports that when many items are inserted at the top **in one
`insert(contentsOf:at:)`**, scroll behaviour becomes erratic even though `dataID` is
unchanged; inserting items individually was reported as a workaround
([thread 731271](https://developer.apple.com/forums/thread/731271)). This matters directly —
we prepend 50 at once. Treat it as a thing to test on device, not as settled.

#### Related unresolved threads (evidence this is still not fully solved)

- ["SwiftUI ScrollView maintain position on new page load"](https://developer.apple.com/forums/thread/740490)
  — chat view using `.defaultScrollAnchor(.bottom)` + `.scrollPosition(id: $scrolledId, anchor: .top)`
  + `.scrollTargetLayout()` still jumps to top on page load. **0 replies**, ~1.4k views.
  Their setup is almost exactly ours.
- ["How do I maintain a stable scroll position when inserting items above in a ScrollView?"](https://developer.apple.com/forums/thread/781282)
  — April 2025. **0 replies.** The author reports that `.scaleEffect(y: -1)` inversion broke
  x-position and context menus, `.onScrollGeometryChange` disabled the user scroll gesture, and
  pre-setting `scrollPosition` before the update had no effect.
- ["SwiftUI bottom-first List (inverted)"](https://developer.apple.com/forums/thread/681833)
  — feedback **FB9148104** filed requesting a real `.scrollDirection(.inverted)` API. Still no
  such API in the iOS 27 SDK (verified, §2.0).

### 2.4 `isPositionedByUser`

[Docs](https://developer.apple.com/documentation/swiftui/scrollposition/ispositionedbyuser),
iOS 18+:

> Whether the scroll view has been positioned by the user.
>
> You can write to this property to control whether the scroll view acts as if it has been
> positioned by the user. If the position had a non-nil edge / point value, that value will
> become nil when setting this property to true.

Read it to distinguish "the user dragged here" from "the system put us here" — which is the
exact distinction we need for the keyboard case in §3. It is *not* a scroll-anchoring
mechanism.

Note the related property behaviour from
[Nil Coalescing's write-up](https://nilcoalescing.com/blog/ModernSwiftUIAPIsForProgrammaticScrolling/):
`ScrollPosition`'s `edge` / `point` / `x` / `y` reflect programmatic scroll values and become
`nil` once the user interacts; `viewID` / `viewID(type:)` are the only members that track
position during manual scrolling.

### 2.5 `List` + `.scrollPosition` versus `ScrollView` + `LazyVStack`

**`.scrollPosition` does not work with `List`.**

- `scrollTargetLayout()` is documented for "layout containers like `LazyHStack` or `VStack`
  within a `ScrollView`" — [Apple docs](https://developer.apple.com/documentation/swiftui/view/scrolltargetlayout(isenabled:)).
  There is no `List` equivalent.
- [fatbobman, "The Evolution of SwiftUI Scroll Control APIs"](https://fatbobman.com/en/posts/the-evolution-of-swiftui-scroll-control-apis/):
  the new scroll control APIs do not support `List` as of iOS 18, which limits their range.
- Forum report: ["SwiftUI List .scrollPosition not working"](https://developer.apple.com/forums/thread/770682).
- Consequence: with `List` you are back to `ScrollViewReader` + `proxy.scrollTo`, which is the
  thing that is already failing us.

Counterpoint in `List`'s favour: `List` is `UICollectionView`-backed and does not suffer the
LazyVStack height-estimation problem in the same way — see
[fatbobman, "List or LazyVStack — Choosing the Right Lazy Container"](https://fatbobman.com/en/posts/list-or-lazyvstack/).
But it gives up the only anchoring API that actually works. **For a chat transcript,
`ScrollView` + `LazyVStack` + `.scrollTargetLayout()` + `.scrollPosition(id:)` is the right
container.**

### 2.6 Why `LazyVStack` misbehaves at all — the estimation mechanism

This is the piece that explains our symptom, and it is documented, verbatim, in
[WWDC26 session 321, "Dive into lazy stacks and scrolling with SwiftUI"](https://developer.apple.com/videos/play/wwdc2026/321/):

> Since a `LazyVStack` doesn't load all of its views, the height of the subviews that are
> off-screen are estimated. This estimated height is based on the **average size of views that
> have been placed before**, and the estimated number of remaining subviews.

> Since the height of the `LazyVStack` is estimated and not precise, it can **change during
> scrolling** as the lazy stack learns more about the layout of new views scrolled onto
> screen.

> The lazy stack and the embedding scroll view **coordinate the position and content offset**.
> That way, when the estimations are updated, the **relative position of the visible subviews
> in the scroll view doesn't change**.

And the walk-through of an orientation change, which is the closest thing in the session to our
prepend case:

> During the orientation change, the lazy stack will keep the StepView for step 4, the topmost
> visible view, **anchored**. The `LazyVStack` isn't yet aware of the exact layout changes in
> the first few StepViews, since they aren't loaded. But when scrolling all the way back up,
> the lazy stack must align to the top of the scroll view. This means it must **correct the
> estimated space above the visible region along the way**. It will update the content offset
> of the `ScrollView` with the same amount, such that the content offset at the top is zero as
> well.

Two consequences, both stated by Apple:

> **Avoid using the absolute content size or content offset with lazy stacks, since these are
> estimated and unstable.**

> Instead, it's better to use the **relative positions of subviews in the visible region** of
> the scroll view.

The session also lists the failure modes that produce jank
(as catalogued in [The Swift Dev's write-up of the session](https://www.theswift.dev/posts/fix-swiftui-lazy-stack-jank-before-you-switch-to-list/)):

1. "The stack is estimating off-screen sizes, and your code assumes those sizes are exact."
2. A row does not have a stable identity.
3. "A row resolves to a dynamic number of immediate subviews" — i.e. a `ForEach` body that
   conditionally yields 0 or 1 views. Filter at the data layer instead.
4. "Important row state lives in a view that the lazy stack is allowed to discard."

Plus, from the session transcript, the `onAppear` anti-pattern:

> But, loading everything in `onAppear` for each view is not a good idea. [...] The size and
> large parts of the view's contents completely change after it's placed. The work that
> prefetching has done earlier will be thrown away, and has to be re-done when the view
> appears. The lazy stack may also load more views than needed, and scrolling can be affected.

Recommended instead: initialise row state in the row's `init`, not `onAppear`:

```swift
struct StepView: View {
    @State var viewModel: StepViewModel
    init(id: Step.ID) { _viewModel = State(initialValue: StepViewModel(id: id)) }
    var body: some View { /* ... */ }
}
```

### 2.7 Do estimated / fixed row heights matter for `LazyVStack`?

Yes, but not in the way "give every row a fixed height" implies.

- **There is no estimated-height API.** SwiftUI has no `LazyVStack` analogue of
  `UITableView.estimatedRowHeight`. The estimate is computed internally from the running
  average of already-placed subviews (WWDC26 321, quoted above). You cannot supply it. Verified
  against the iOS 27 SDK interface: `LazyVStack` takes only `alignment`, `spacing`,
  `pinnedViews`.
- **The cost of bad estimates is real.** When subview heights vary a lot, large jumps can show
  blank content, and the scroll indicator visibly resizes as estimates settle
  ([fatbobman, "List or LazyVStack"](https://fatbobman.com/en/posts/list-or-lazyvstack/)).
  Message bubbles vary enormously in height, so our estimates will be poor by construction.
- **Fixed heights are Apple's advice only for the cross axis.** From WWDC26 321: for a
  `LazyHStack` "the best solution is to fix the view heights. For example, for text, you can
  set a line limit, and reserve space for shorter text." That is about the *non-lazy* axis.
  There is no equivalent recommendation for the main axis of a `LazyVStack`, and forcing chat
  bubbles to a fixed height is obviously not acceptable.
- **The historical bug is fixed.** ["Content with variable height in a LazyVStack inside a
  ScrollView causes stuttering / jumping"](https://developer.apple.com/forums/thread/685461)
  was confirmed resolved by the reporter in iOS 17.4.
- **But a live iOS 26 regression exists.**
  ["ScrollView + LazyVStack + dynamic height views cause scroll glitches on iOS 26"](https://developer.apple.com/forums/thread/805306):
  fixed-height rows behave; variable-height rows jump when the keyboard appears or disappears,
  or when scrolling with the keyboard up. Not reproducible on iOS 18. Repro project at
  https://github.com/Sawyer-815/infinite-scroll. Apple DTS Engineer (Albert Pascual) asked for
  a Feedback; filed as **FB20979569**; still reproducing on Xcode 26.1 beta 3, second reporter
  in December 2025. **I could not determine whether this is fixed in iOS 27 — test it.**
  This is a chat app with variable-height rows and a keyboard, so this bug is squarely on our
  path.

### 2.8 The inverted-scroll trick — is it still needed?

**What it is.** Rotate the scroll container 180° and rotate every row back, so that "top of
content" is visually the bottom. Growth then happens at the *end* of the content, where every
scroll view already behaves correctly.

```swift
// the classic form
ScrollView { LazyVStack { ForEach(messages.reversed()) { MessageRow($0).flippedUpsideDown() } } }
  .flippedUpsideDown()

extension View {
  func flippedUpsideDown() -> some View {
    self.rotationEffect(.radians(.pi)).scaleEffect(x: -1, y: 1, anchor: .center)
  }
}
```

Source for the pattern: [Swift with Vincent, "Building the inverted scroll of a messaging app"](https://www.swiftwithvincent.com/blog/building-the-inverted-scroll-of-a-messaging-app).

**Is it still needed in SwiftUI?** My read: **no, and you should not use it.** Evidence:

- Documented downsides, from [forums thread 681833](https://developer.apple.com/forums/thread/681833):
  navigation bar jumping, pull-to-refresh inverted, scroll indicator pointing the wrong way,
  and the code cost of flipping every row back. The thread's conclusion is that these
  workarounds do not work well in practice, hence FB9148104 asking for a real API.
- [Forums thread 781282](https://developer.apple.com/forums/thread/781282) (April 2025): the
  reporter tried `.scaleEffect(y: -1)` and it "broke x-position and context menus."
- [`contextMenu` does not recognize `scaleEffect`](https://developer.apple.com/forums/thread/765290)
  — an iOS 18 regression that breaks long-press menus on flipped rows. We need message action
  menus, so this is disqualifying on its own.
- [iOS 26 beta breaks scroll/gesture in SwiftUI chat that worked in iOS 18](https://developer.apple.com/forums/thread/794212)
  — inverted `ScrollView` + `rotationEffect(.degrees(180))` + `simultaneousGesture` produced
  broken or jittery scrolling through beta 9. Partial workaround: pass an explicit
  `mask: .subviews` to `simultaneousGesture`. **No official resolution.**
- WWDC26 321 warns generally against "transforms that move views outside their original
  frame (they'll disappear)" in lazy stacks
  ([session 321](https://developer.apple.com/videos/play/wwdc2026/321/)).
- Accessibility: VoiceOver reading order and the scroll status follow the rotated geometry.
  I did not find a primary source quantifying this — **UNDETERMINED**, but it is a known
  consequence of geometric inversion.

**However** — and this is the important qualifier — the inversion trick *is* still the
production approach in UIKit-backed SwiftUI chat libraries, applied to a `UITableView` rather
than a SwiftUI `ScrollView`. See §2.9.

### 2.9 What real open-source SwiftUI chat clients actually ship

Both of the serious ones **abandon `ScrollView` + `LazyVStack` entirely** and wrap UIKit.
That is itself a finding.

#### exyte/Chat — `UITableView` + transform inversion + anchor-item offset math

Source: [`Sources/ExyteChat/Views/UIList.swift`](https://github.com/exyte/Chat/blob/main/Sources/ExyteChat/Views/UIList.swift)
(read directly from `raw.githubusercontent.com`).

Inversion, at line 57:

```swift
tableView.transform = CGAffineTransform(rotationAngle: (type == .conversation ? .pi : 0))
```

and each cell is counter-rotated in SwiftUI:

```swift
content().rotationEffect(Angle(degrees: (type == .conversation ? 180 : 0)))
```

`showsVerticalScrollIndicator = false` (line 59) — they hide the indicator rather than fight
its inverted direction.

**The prepend algorithm**, `performInsertPreservingOffset`, is the canonical "anchor item +
rect delta" technique and is worth reading in full because it is exactly what SwiftUI's
`scrollPosition(id:)` does for you:

```swift
let visibleIndexPaths = tableView.indexPathsForVisibleRows ?? []
guard let firstVisibleIndexPath = visibleIndexPaths.first(where: { $0 != oldIndicatorIP }),
      let preservedVisibleRect = tableView.rectForRow(at: firstVisibleIndexPath) as CGRect?
else { return }

let preservedVisibleMessageID = /* id of that row */
let preservedOffset = tableView.contentOffset.y

coordinator.sections = sections
CATransaction.setDisableActions(true)
tableView.reloadData()
tableView.layoutIfNeeded()

guard let newIndexPath = indexPath(for: preservedVisibleMessageID, in: sections, ...) else { return }
let newRectForCell = tableView.rectForRow(at: newIndexPath)
let newOffset = preservedOffset + (newRectForCell.minY - preservedVisibleRect.minY)
tableView.setContentOffset(CGPoint(x: 0, y: newOffset), animated: false)
```

Note: capture **an item id and its rect**, force a synchronous layout, then correct the offset
by the *delta of that item's rect*, all with implicit animations disabled. Not by the measured
height of the inserted batch.

Their re-entrancy guard,
[`UIList+Pagination.swift`](https://github.com/exyte/Chat/blob/main/Sources/ExyteChat/Views/UIList%2BPagination.swift):

```swift
final class PaginationState: ObservableObject {
    @Published var olderInProgress = false
    @Published var newerInProgress = false
}
```

and the trigger, in `willDisplay`
([UIList.swift](https://github.com/exyte/Chat/blob/main/Sources/ExyteChat/Views/UIList.swift)):

```swift
func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
    if updateInProgress { return }
    ...
    if !paginationState.olderInProgress,
       let messageID = olderPaginationTargetMessageID,
       message.id == messageID,                       // identity, not offset
       let handler = chatParams.olderMessagesPaginationHandler,
       handler.hasMoreToLoad,
       case .cellIndex(_) = handler.triggerType {
        performOlderPagination(tableView)
    }
}
```

Four independent guards: `updateInProgress`, `olderInProgress`, `hasMoreToLoad`, and the
trigger keyed to a **specific message id** rather than a position. Their alternative
`.pixels` trigger mode does use `scrollViewDidScroll` and `contentOffset`, but still behind
`!updateInProgress && !olderInProgress && hasMoreToLoad`.

#### FluidGroup/swiftui-messaging-ui — `UICollectionView` with a virtual content space

Source: [README](https://github.com/FluidGroup/swiftui-messaging-ui) and
[TiledView-Architecture.md](https://github.com/FluidGroup/swiftui-messaging-ui/blob/main/Sources/MessagingUI/Documentation.docc/TiledView-Architecture.md).
Requires iOS 17+, Swift 6, Xcode 26. Active as of December 2025.

Their statement of the problem, verbatim from the README:

> Standard SwiftUI `List` and `ScrollView` cause **scroll position jumps** when prepending
> items.
>
> A common workaround is adjusting `contentOffset` after prepending. However, this requires:
> precise timing of when prepend operations complete; exact knowledge of inserted content
> height before layout; careful handling when multiple operations occur together (prepend +
> update + remove). In practice, this approach breaks easily with complex data flows.

Their fix is to make the offset never need correcting: lay items out in a 100,000,000-point
virtual space with the initial content anchored at y = 50,000,000. Prepending writes new items
at *negative-going* y values above the anchor and **leaves every existing item's y and the
`contentOffset` untouched**:

```
Before:                          After:
Item 0   y=50000000              New Item  y=49999900
Item 1   y=50000100              Item 0    y=50000000 (unchanged)
Item 2   y=50000200              Item 1    y=50000100 (unchanged)
                                 Item 2    y=50000200 (unchanged)

contentOffset: unchanged
```

Their loader triggers: "**onPrepend**: Called when the user scrolls near the top (within
100pt)" / "**onAppend**: ... near the bottom (within 100pt)"
([Bidirectional-Loading.md](https://github.com/FluidGroup/swiftui-messaging-ui/blob/main/Sources/MessagingUI/Documentation.docc/Bidirectional-Loading.md)).
Same doc argues for **window-based (offset/limit) pagination over cursor-based** because
cursors suffer timestamp collisions and unstable sort order — relevant to us since Zulip's
`anchor` + `num_before`/`num_after` is cursor-shaped.

A fork of this library exists under `bwees-forks/swiftui-messaging-ui`, so it may already be on
our radar.

#### The 2019 ProcessOne attempt, for contrast

[Writing a Custom Scroll View with SwiftUI in a chat application](https://www.process-one.net/blog/writing-a-custom-scroll-view-with-swiftui-in-a-chat-application/)
(Oct 2019) hand-rolled the whole thing with `GeometryReader`, a `PreferenceKey` for content
height, manual offset arithmetic and a `DragGesture`. Historical interest only — this is what
you end up with if you refuse both UIKit and the modern anchoring APIs.

---

## 3. Stopping the fetch from firing repeatedly

The rule from Apple is unambiguous. WWDC26 session 321, on a button that shows/hides based on
scroll depth:

> Here, I'm using an `.onScrollGeometryChange` on my scroll view to get the absolute content
> offset. [...] This works, but since the **content offset of a lazy stack is estimated**, the
> exact position where the button disappears can change when the estimations change. Instead,
> it's better to use the **relative positions of subviews in the visible region** of the scroll
> view. One way to do that, is to use the `.onScrollTargetVisibilityChange` modifier.

So: **the idiomatic trigger for "user scrolled near the top" is item visibility, not content
offset.** Three layers, in order of preference:

### 3.1 Trigger on visibility of a specific item

```swift
.onScrollTargetVisibilityChange(idType: Message.ID.self, threshold: 0.5) { visibleIDs in
    guard let oldest = messages.first?.id, visibleIDs.contains(oldest) else { return }
    loader.loadOlder()
}
```

`onScrollTargetVisibilityChange(idType:threshold:_:)`, iOS 18+, requires `.scrollTargetLayout()`
and explicit ids. Signature verified in the iOS 27 SDK interface. Apple's own example from
session 321:

```swift
.onScrollTargetVisibilityChange(idType: Step.ID.self, threshold: 0.8) { visibleIDs in
    isScrollToShowcaseVisible = shouldShowScrollButton(visibleIDs: visibleIDs)
}
```

The alternative Apple shows in the same session is a sentinel view at the end of the `ForEach`
with `.onAppear`:

```swift
if !pager.atEnd {
    ProgressView().progressViewStyle(.circular)
        .onAppear { pager.fetchPage() }
}
```

For us that becomes a sentinel at the *start* of the stack. It is simpler, and it doubles as
the loading indicator. Note it fires on *appear*, so it is not keyboard-sensitive the way an
offset threshold is — the keyboard changes `contentOffset` but does not make an off-screen
sentinel appear. **INFERRED**, but it follows directly from the mechanism.

This is exactly what exyte/Chat does with its identity-keyed `willDisplay` trigger (§2.9), and
what FluidGroup does with `.prependLoader()`.

### 3.2 An explicit in-flight guard in the loader, not in the view

Both shipping libraries have one. exyte:

```swift
final class PaginationState: ObservableObject {
    @Published var olderInProgress = false
    @Published var newerInProgress = false
}
```

checked as `if !paginationState.olderInProgress, ..., handler.hasMoreToLoad`, plus a separate
`if updateInProgress { return }` that suppresses triggers while the table is mid-mutation.
FluidGroup's window-based store guards with `var hasMore: Bool { windowStart > 0 }` and
`guard hasMore else { return }`.

Per our own CLAUDE.md, this state belongs in a manager/loader class, not scattered as
`@State` in the view. Minimum set:

- `isLoadingOlder` — set true synchronously on trigger, cleared in a `defer` after the
  prepend lands.
- `hasMoreOlder` — set from Zulip's `found_oldest` in the `/messages` response.
- `isApplyingUpdate` — true while the prepend is being applied to the array, suppressing all
  triggers for that window.

### 3.3 Distinguishing user scroll from system repositioning

The keyboard case. Two tools:

- `ScrollPosition.isPositionedByUser` (iOS 18+) — "Whether the scroll view has been positioned
  by the user." [Docs](https://developer.apple.com/documentation/swiftui/scrollposition/ispositionedbyuser).
  Gate the fetch on it being `true`.
- `onScrollPhaseChange(_:)` with `ScrollPhase` (iOS 18+, SDK-verified cases:
  `.idle`, `.tracking`, `.interacting`, `.decelerating`, `.animating`, plus
  `var isScrolling: Bool`). A keyboard-driven inset change is not `.tracking` or
  `.decelerating`. Gating on `phase.isScrolling` filters system repositioning.

Combining 3.1 + 3.2 + 3.3: the fetch fires only when (a) the oldest loaded message became
visible, (b) the user is the one who scrolled, and (c) no load is in flight and more history
exists. None of those three conditions is "content offset changed."

**Do not** use `.onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y < N }` as the
trigger. It is the pattern Apple explicitly argues against for lazy stacks, and it is the one
that the keyboard will re-fire.

---

## 4. Do placeholders help in SwiftUI?

**Short answer: no. Do not build fixed-height skeleton rows for this.** In SwiftUI the
placeholder idea solves a problem SwiftUI does not have, and creates two it does.

Reasoning, each step sourced:

1. **The jump is not caused by not knowing the height.** SwiftUI's fix anchors an *item*, not
   an offset: "it will attempt to keep the currently scrolled item in the same relative
   position as before the change" (Apple Frameworks Engineer,
   [thread 731271](https://developer.apple.com/forums/thread/731271)). Once anchoring works,
   the height of what arrives above is irrelevant — it can be anything. A placeholder that
   pre-reserves the right height buys nothing that the anchor does not already give.

2. **`LazyVStack` will not lay the placeholders out anyway.** "Since a `LazyVStack` doesn't
   load all of its views, the height of the subviews that are off-screen are estimated"
   (WWDC26 321). Fifty skeleton rows prepended above the viewport are off-screen, so they are
   never measured; they only feed the running-average estimate. A fixed-height placeholder
   therefore does not reserve real space — it perturbs the estimator. Worse, if the skeleton
   height differs from the real bubble height, the average is now *wrong*, which is failure
   mode #1 in the session's list.

3. **The swap is a second mutation.** Replacing a placeholder with real content changes the row
   identity (or the row's height, if you keep the id). WWDC26 321 is explicit that changing a
   row's layout after it is placed is the thing to avoid: "the size and large parts of the
   view's contents completely change after it's placed. The work that prefetching has done
   earlier will be thrown away." You would then need the anchoring to hold across the swap too
   — i.e. you have paid for a second opportunity to jump.

4. **Non-determinism.** If the placeholder count differs from the real message count returned,
   the `ForEach` row count changes twice, which is failure mode #3 ("a row resolves to a
   dynamic number of immediate subviews"). You would have to know the count before fetching.

**Where a placeholder *does* belong:** a single, fixed-height loading row pinned at the top of
the stack, present only while `isLoadingOlder` is true — the sentinel from §3.1. That is one
row, its height is constant while it is visible, and both shipping libraries do exactly this
(exyte's `FooterView` gated on `paginationState.olderInProgress`; FluidGroup's
`.prependLoader(...) { ProgressView() }`). It is a spinner, not a skeleton of the incoming
content.

**If we nevertheless wanted skeletons** (e.g. product wants shimmer instead of a spinner), the
only way to avoid a second jump would be: keep a stable id per skeleton slot, replace the
skeleton's *content* in place while keeping the id, and rely on `scrollPosition(id:)` anchored
on a real message *below* the swapped region so the swap happens entirely above the anchor.
**INFERRED, untested, and not recommended.**

---

## 5. Recommended approach for Zulu

### 5.1 Change the container

```swift
ScrollView {
    LazyVStack(spacing: 0) {
        if loader.isLoadingOlder {
            ProgressView()
                .frame(height: 44)          // constant while visible
        }
        ForEach(messages) { message in
            MessageRow(message: message)
                .id(message.id)             // stable, model-level id (Zulip message id)
        }
    }
    .scrollTargetLayout()                   // REQUIRED, on the stack, not the ScrollView
}
.scrollPosition(id: $anchoredMessageID, anchor: .top)
.defaultScrollAnchor(.bottom)
.defaultScrollAnchor(.topLeading, for: .alignment)
.onScrollTargetVisibilityChange(idType: Message.ID.self, threshold: 0.1) { visibleIDs in
    loader.noteVisible(visibleIDs)
}
.onScrollPhaseChange { _, phase in loader.noteScrollPhase(phase) }
```

Concretely, relative to what we have now:

1. **Delete `ScrollViewReader` and every `proxy.scrollTo(previousOldestID, anchor: .top)`
   correction after a fetch.** That is a post-hoc offset correction, the exact class of fix
   FluidGroup documents as fragile, and it fights the anchoring mechanism. Keep `scrollTo`
   only for deliberate, user-initiated jumps ("jump to latest", "jump to first unread") — and
   prefer `ScrollPosition.scrollTo(id:anchor:)` / `.scrollTo(edge: .bottom)` over the
   `ScrollViewReader` proxy, since `ScrollPosition` is the same object that holds the anchor.

2. **Add `.scrollTargetLayout()` to the `LazyVStack`** and `.scrollPosition(id:$anchoredMessageID, anchor: .top)`
   to the `ScrollView`. Do not write to `anchoredMessageID` during a prepend — let SwiftUI hold it.

3. **Keep `.defaultScrollAnchor(.bottom)`.** It gives initial-position-at-bottom and
   bottom-following for new incoming messages. Do **not** add
   `.defaultScrollAnchor(.bottom, for: .sizeChanges)` — documented no-op on top of it.
   Consider `.defaultScrollAnchor(.topLeading, for: .alignment)` so a short/empty conversation
   or an error state pins to the top instead of floating at the bottom (Apple's own example).

4. **Ensure row identity is the Zulip message id**, never an array index and never a value that
   changes when the message is edited or a reaction lands. WWDC26 321 lists unstable identity as
   a primary cause of lazy-stack jank.

5. **Do not conditionally yield zero views from the `ForEach` body.** Filter muted topics /
   deleted messages in the data layer before the array reaches `ForEach` (WWDC26 321, failure
   mode #3).

6. **Build row view models in the row's `init`, not in `.onAppear`**, and do not change a row's
   height after it has appeared. Height-changing images should be given an aspect-ratio-reserved
   frame up front.

7. **Give the loading row no `.id`.** `onScrollTargetVisibilityChange(idType: Message.ID.self, ...)`
   filters to ids of the declared type, so a differently-typed id would simply be ignored — but a
   row that appears and disappears inside the `ForEach`'s stack is also a changing subview count,
   which is WWDC26 321's failure mode #3. Keeping the spinner outside the `ForEach` and unidentified
   is the safer shape. **INFERRED.**

### 5.2 Move load-more state into a loader class

Per our CLAUDE.md rule about complex UI state belonging in a manager class. Shape:

```swift
@Observable
final class MessageHistoryLoader {
    private(set) var messages: [Message] = []
    private(set) var isLoadingOlder = false
    private(set) var hasMoreOlder = true
    private var isApplyingUpdate = false
    private var lastPhase: ScrollPhase = .idle

    func noteVisible(_ ids: [Message.ID]) {
        guard lastPhase.isScrolling else { return }        // user-driven only
        guard let oldest = messages.first?.id, ids.contains(oldest) else { return }
        Task { await loadOlder() }
    }

    func loadOlder() async {
        guard hasMoreOlder, !isLoadingOlder, !isApplyingUpdate else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        let page = await api.messages(anchor: .id(messages.first?.id), numBefore: 50, numAfter: 0)
        hasMoreOlder = !page.foundOldest                   // from Zulip's found_oldest
        isApplyingUpdate = true
        messages.insert(contentsOf: page.messages, at: 0)
        isApplyingUpdate = false
    }
}
```

The trigger is item visibility + scroll phase; the guards are `hasMoreOlder`,
`isLoadingOlder`, `isApplyingUpdate`. No content-offset threshold anywhere, so the keyboard
cannot re-fire it.

**Consider Element's edge token instead of the boolean** (§1.4). Their guard fires
`onStartReached` once per distinct `(itemCount, visibleStartIndex)` pair and re-arms only when
the list actually changed:

```swift
private var startEdgeToken = ""

func noteVisible(_ ids: [Message.ID]) {
    guard lastPhase.isScrolling, let oldest = messages.first?.id else { startEdgeToken = ""; return }
    guard ids.contains(oldest) else { startEdgeToken = ""; return }
    let token = "\(messages.count):\(oldest)"
    guard token != startEdgeToken else { return }
    startEdgeToken = token
    Task { await loadOlder() }
}
```

This is strictly stronger than an in-flight boolean, because it also survives a fetch that
returns zero new messages — where a boolean clears and immediately re-fires while the oldest
item is still on screen. Keep `isLoadingOlder` as well; the two guard different failures.

### 5.3 Things to verify on device before committing

0. **Which item ends up as the anchor.** `.scrollPosition(id:$anchoredMessageID, anchor: .top)`
   tracks the *top-most visible* view. At the moment the fetch fires, the top-most visible view
   is the oldest loaded message — i.e. precisely the boundary item that Telegram Web skips
   ("it may be a partly-loaded album and also because it may be removed") and that Element's
   `isValidAnchorItem` exists to exclude (§1.8). Watch for this: if the anchor lands on the
   loading spinner or on the message that gets re-identified by the merge, the list will lurch.
   Mitigations, in order: keep the spinner outside the `ForEach` so it is never a scroll target;
   make sure the prepended page does not re-create the existing boundary message with a new
   identity; and if it still misbehaves, fire the fetch slightly earlier (threshold on the
   *second* or third oldest message) so the anchor is a stable interior row.
1. **Batch prepend of 50.** [Forum thread 731271](https://developer.apple.com/forums/thread/731271)
   reports `scrollPosition(id:)` misbehaving on a single large `insert(contentsOf:at:)`, with
   individual inserts as a workaround. If a 50-at-once insert jumps, try inserting in chunks,
   or inserting inside a single `withAnimation(nil)` / `Transaction(animation: nil)`.
2. **The iOS 26 keyboard + variable-height regression, FB20979569**
   ([thread 805306](https://developer.apple.com/forums/thread/805306), repro at
   https://github.com/Sawyer-815/infinite-scroll). Unknown whether iOS 27 fixes it. If it
   reproduces on iOS 27, the SwiftUI-native path may not be viable and §5.4 becomes the plan.
3. Put the composer in `.safeAreaInset(edge: .bottom)` rather than an overlay, so keyboard
   avoidance goes through the scroll view's content insets rather than moving the whole view.

### 5.4 Fallback if the native path does not hold

Both credible open-source SwiftUI chat implementations wrap UIKit, so this is a respectable
retreat, not a defeat:

- **FluidGroup/swiftui-messaging-ui** — `UICollectionView` + virtual content space; prepending
  never touches `contentOffset` at all. iOS 17+. We already have a fork.
- **exyte/Chat** — `UITableView` + `CGAffineTransform(rotationAngle: .pi)` inversion +
  `performInsertPreservingOffset`. More opinionated about the whole chat UI.
- Or write a thin `UIViewRepresentable` over `UICollectionView` using
  `UICollectionViewCompositionalLayout` and the anchor-item-rect-delta algorithm from §2.9.

Do **not** fall back to the SwiftUI `rotationEffect(.pi)` inversion trick — §2.8 has three
separate open regressions against it (context menus, gestures on iOS 26, lazy-stack transform
warnings).

---

## 6. What I could not determine

On the client half:

- **Whether Discord's web chat message list is virtualized at all**, and whether it uses the
  generic `List` component described in §1.1. That view lives in a lazily-loaded chunk absent
  from the mirrored entry bundle — no `data-list-id="chat-messages"`, no `scrollerInner`, no
  `getAnchorId` call site. So the placeholder hypothesis is neither confirmed nor refuted for
  the message list specifically; it is confirmed (in the "declared heights + one spacer" form,
  not the "per-item skeleton" form) for Discord's generic list component.
- **Discord's scroll-back page size.** `30` appears for jump-to-present; the backfill-on-scroll
  constant was not locatable.
- **Anything about Slack's message-list scroll preservation.** Page sizes and general React
  performance work are public; the anchoring mechanism is not.
- Telegram Web K (`morethanwords/tweb`) was not examined — only Web Z (`Ajaxy/telegram-tt`).

On the SwiftUI half:

- Whether **FB20979569** (iOS 26 LazyVStack + keyboard + variable heights) is fixed in iOS 27.
  No public statement either way; last public data point is December 2025, still reproducing.
- Whether `.defaultScrollAnchor(.bottom)` alone is *ever* sufficient for a clean prepend.
  Secondary blogs assert yes; Apple never says so, and forum threads
  [740490](https://developer.apple.com/forums/thread/740490) and
  [781282](https://developer.apple.com/forums/thread/781282) show it failing in configurations
  close to ours. Contested.
- The precise ordering guarantees between a data mutation and `scrollPosition(id:)`
  re-anchoring — i.e. whether a prepend must be applied in a specific transaction for the
  anchor to hold. Not documented; the Frameworks Engineer's example does not address it.
- Whether VoiceOver ordering degrades measurably under the 180° inversion trick. No primary
  source found.
- Whether `.scrollPosition(id:)` will ever support `List`. Apple has not commented;
  `scrollTargetLayout` still has no `List` form in the iOS 27 SDK.


---

## Applied

Implemented in `ConversationView` and `MessageHistoryLoader`: item-identity anchoring via
`.scrollPosition(id:)` + `.scrollTargetLayout()`, the post-hoc `proxy.scrollTo` correction
deleted, the fetch triggered by `onScrollTargetVisibilityChange` gated on `ScrollPhase`, and
history state moved out of the view into a loader class. Images additionally reserve their
height from `data-original-dimensions`, so a loading image no longer reflows the list.
