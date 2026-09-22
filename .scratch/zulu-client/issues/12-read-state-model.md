# Read and unread state

Type: grilling
Status: resolved
Blocked by: 02, 11

## Question

How is unread state computed, displayed, and propagated?

Decide:
- Where unread counts come from: the register snapshot, local derivation, or both, and how they stay reconciled.
- What marking-as-read means per render mode — scrolling a chat channel versus opening a forum thread.
- How the mark-read call is batched and what happens when it fails offline.
- How badge counts roll up from topic to channel to group to app icon.
- The muted-topic and muted-channel interaction with every count above.
- How reading on one device clears a pending or delivered notification on another.

## Answer

**Unread is the server's, not ours.** It lives in its own `unread` table seeded from
`unread_msgs` in the register snapshot, not derived from locally-stored messages. That
matters because the server knows about unread messages this device has never fetched —
on a real account it reported 418 unread across three channels the client had barely
touched — and because a message read on another device has to stop being unread here.

- **Counts come from `unread`.** Channel, topic, DM, and group rollups are all one query
  against it. `mentions` from the snapshot marks the rows that deserve a red badge.
- **Marking read is propagated.** `POST /messages/flags` with `op: add`, `flag: read`.
  Before this it was written locally and never sent, so unread state never left the device.
- **Only what was actually seen is marked.** `ReadTracker` collects ids as rows appear and
  flushes after 600ms, so a fast scroll is one request and opening a conversation no longer
  declares the whole thing read.
- **`update_message_flags` clears rows** when another device reads something.

Still open, and deliberately so:

- **`old_unreads_missing` is decoded but unused.** Past 50,000 unreads the server stops
  reporting, and the UI says nothing.
- **Muted channels and topics are counted.** Zulip's own `count` excludes them; ours does not.
- **No fetch-gap tracking.** History is fetched per conversation on first open with no record
  of which ranges are held, so scroll-back cannot know what to ask for. This is the last
  piece of [the store schema](11-local-store-schema.md) and blocks backfill on scroll.
