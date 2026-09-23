# macOS navigation shell

Type: prototype
Status: resolved
Blocked by: 06

## Question

What is the Mac window structure, given the iPhone shell?

Decide the column layout, whether groups live in a sidebar section or a separate rail, what the window's split behaviour is, whether multiple windows or tabs are supported, and which concepts from the iPhone shell map one-to-one versus diverge.

Prototype it and link the prototype from this ticket.

## Answer — built

**One window, two columns.** A sidebar holding the group rail and the channel list side by
side, and the conversation beside them. The iOS drawer exists because a phone has room for
one column at a time; a Mac window does not have that problem, so the same information is
laid out rather than stacked. `Mac/Sources` is its own shell over the shared model, not the
drawer with the gesture removed.

Settled with it:

- **The rail stays a rail.** Direct messages, then groups, then unfiled, then a plus — the
  phone's order, drawn narrower, with ⌘1/⌘2 and ⌘3–⌘9 mapped down it the way Slack numbers
  workspaces. Putting groups in a sidebar section instead would have cost the persistent
  unread pill per group, which is the whole reason the rail exists.
- **A forum's row opens its general chat.** Clicking a channel's name means "take me to the
  channel", and the conversation people mean by that is general chat — the unnamed topic on
  a server that has one, or the topic literally called `general chat`, which is what a
  server sends to a client that has not opted into the empty name. The store answers which
  one this channel has; guessing the empty name opened a blank conversation beside the real
  one. Its topics
  nest under a disclosure triangle — the most recent eight, then an "All N topics…" row that
  opens the channel's own page: every topic, who spoke last and when, a filter field, and a
  New Topic button. The page is also behind an All Topics button in the toolbar of any
  topic in the channel and in the row's context menu. A chat channel opens straight into
  its one conversation.
- **Selection is the model's destination**, shared with iOS and remembered across launches.
  The rail follows it: opening something from ⌘K or a notification switches the sidebar to
  the group that holds it.
- **One window, no tabs.** A chat client with two identical windows open is a question with
  no good answer. `Window`, not `WindowGroup`.
- **The composer is an `NSTextView`.** SwiftUI's `TextField` cannot be told that Return
  sends, cannot hand arrow keys to an autocomplete box, and cannot see an image on the
  pasteboard. Return sends, Shift-Return breaks the line, ↑↓ Tab and Return drive the
  `@` `#` `:` box, Escape closes the box and then the reply, a pasted screenshot or a dropped
  file uploads. Automatic capitalisation, spelling correction and inline prediction are off:
  a chat line is not a sentence and a markdown composer cannot have the system rewriting it.
- **Message actions are a hover bar and a context menu**, not the phone's long-press sheet:
  the realm's three most-used reactions, add reaction, reply, and a more menu. Hovering a
  reaction chip shows who, in a bubble drawn in the view — `.help()` never fired on a chip
  on macOS 26, and a popover would have taken keyboard focus from the composer.
- **An inline image expands in the window**, over a dimmed backdrop, at the size it was
  uploaded. The browser has to be signed in to show an upload at all, and a picture someone
  just posted is not worth leaving the conversation for. Escape, the close button, or a
  click on the backdrop dismisses; a button opens it in the browser for anyone who wants that.
- **The Mac keyboard and menu surface** the map left open is now built: File › New Message
  (⌘N), New Topic (⇧⌘N), New Group (⇧⌘G); Go › Jump to… (⌘K) and the sections;
  Conversation › Mark as Read (⇧⎋), Focus Composer (⇧⌘L); Settings (⌘,) with account and
  notification toggles; Sign Out in the app menu.
- **Notifications while running.** The event queue is live the whole time the app is, so a
  direct message or a mention posts a Notification Center banner unless that conversation is
  the one on screen, and clicking it opens the conversation. The dock badge counts direct
  messages and mentions only.

Lessons paid for along the way:

- **A `List(selection:)` deselect is ignored.** Clicking blank sidebar sets the selection to
  nil; an empty detail column is never what that click meant.
- **The sidebar column's `navigationTitle` does not render on macOS 26**, so the list carries
  its own section header.
- **Never sync SwiftUI state into an `NSTextView` by comparing against the view's string.**
  AppKit reports the selection moving before it reports the text changing, so an update that
  runs between the two sees a view one character ahead of the state. The coordinator tracks
  the last text both sides agreed on and pushes only genuine outside changes.
- **Driving the app from System Events lies about the space bar.** On the development Mac,
  `keystroke " "` arrives as key code 104, which AppKit drops before any text view sees it;
  an afternoon went into a "vanishing spaces" bug the composer never had. Send `key code 49`
  instead, and check `frontmost` before every keystroke — a second Zulip client on the same
  machine happily took the ones that missed.
