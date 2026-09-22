# Polls

Type: grilling
Status: resolved
Blocked by: 11

## Question

How does Zulu render and take part in a poll?

Polls do not arrive as message content. `/poll` produces a message whose `content` is the
bare command text — which is exactly what Zulu shows today — and the real poll lives in the
message's `submessages` array, a separate wire protocol from the markdown pipeline. Nothing
in the store or the parser knows about it.

Decide:
- The submessage protocol: what `submessages` carries, how options and votes are encoded,
  and which events announce a new vote.
- How a poll is stored. It is per-message state that changes independently of the message,
  so it likely wants its own table rather than a column.
- What the poll looks like in a conversation, and how voting feels on a phone.
- Whether Zulu can *create* polls in v1 or only display and vote on them.
- Whether todo lists — the other widget built on the same protocol — come along for the ride.

This needs a research pass on the submessage protocol before the design questions can be
answered; neither the events nor the message-model research covered widgets.

Scope change: the effort originally ruled polls out of v1. The user has since asked for them.

## Research

`.scratch/zulu-client/research/22-poll-submessages.md`

**A poll is an append-only event log, not server-computed state.** `message.submessages[]`
holds `{id, message_id, sender_id, msg_type, content}` where `content` is a JSON *string*.
Submessage 0 is the widget definition; everything after it is an event replayed in `id`
order. The server never tallies a vote — the client does.

- Events: `new_option`, `question` (author only), `vote` with `+1`/`-1`. Option keys are
  `"<sender_id>,<idx>"`, with the literal `"canned"` in the sender slot for options that
  came from the `/poll` text. Votes are a set per option, so polls are multi-select.
- **Sending**: `POST /api/v1/submessage`. The route is real and both official mobile clients
  use it, but it is absent from the OpenAPI spec and the docs 404 — the subsystem is called
  experimental and carries no stability promise. Worth knowing before depending on it.
- **Zulu can create polls** by sending a message whose content starts with `/poll`; the
  server detects the slash command whatever the client. `widget_content` on `POST /messages`
  is *not* usable — it accepts only `"zform"`.
- **Permissions**: anyone who can read the message can vote and add options; only the sender
  may edit the question.
- **The message body must be suppressed entirely** for a widget message, the way zulip-flutter
  does. The server never rewrites `content`, so the `/poll` text would otherwise render as an
  ordinary paragraph under the poll.
- Two traps: the event names the id `submessage_id` while the array names it `id` — normalise
  at the API boundary or ordering breaks. And every Zulip client drops duplicate option *text*
  client-side, so Zulu must too or it will show options the web app hides.
- No feature-level gate on the wire format.

**Todo lists share the transport but not the shape** — the composite key is reversed and
`key` changes type between events. Separate code paths; zulip-flutter skipped todo entirely.

What is left to decide is the storage shape (the log is per-message state that changes
independently of the message) and what voting feels like on a phone.

## Answer — built

`ZuluPolls` is a separate target holding the whole protocol as pure, testable code: a
submessage log replays into a `Poll`. The server never tallies anything, so the fold is the
feature.

- **Storage**: a `submessage` table keyed on the submessage's own id, so re-applying an event
  is a no-op. `message.isWidget` is cached at save time so the body-or-poll decision costs no
  query and cannot flicker.
- **Rendering**: `MessageContent` picks between `PollView` and `MessageBody`. A widget
  message never renders `renderedContent` — the server leaves the literal `/poll` text there.
- **Voting** is optimistic, then reconciled by the `submessage` event coming back.
- 23 tests on the replay: vote and unvote, multi-select, duplicate option text from both
  sources, canned options, id order versus array order, malformed JSON, unknown event types,
  a non-author trying to edit the question, and todo/zform falling to `.unsupported`.

Verified against a real poll on zulip.futo.org: options, counts, and voter names all render.

Deliberately not built: **creating** a poll (the protocol side is free — send a message
starting with `/poll` — but it needs compose UI), and editing the question (the model and the
author check exist; there is no UI). `MAX_IDX = 1000` is not clamped client-side, so an
over-long poll surfaces the server's 400 as the poll's error line.
