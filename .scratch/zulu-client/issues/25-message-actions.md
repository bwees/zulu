# Message actions, starting with reactions

Type: prototype
Status: resolved
Blocked by: 23

## Question

What happens when you long-press a message, and how do reactions look?

Nothing happens today. Reactions are stored — `ReactionRecord` is written from both the
message payload and `reaction` events — and then never drawn, and there is no way to add one.

Decide:
- **The long-press menu.** React, reply, copy text, copy link, edit, delete, move to another
  topic. Which of those belong in v1, which are destructive, and what the ordering is.
- **The quick-reaction row.** Discord and Slack both float a handful of emoji above the menu.
  Which emoji: most-used in this realm, this person's most-used, or a fixed set?
- **How a reaction renders** under a message: grouped chips with counts, who reacted, and
  what a tap versus a long-press on a chip does.
- **Picking an arbitrary emoji** — this is the same catalogue as
  [the compose autocomplete](23-compose-autocomplete.md), which is why it waits on that.
- Whether the reply action composes a Zulip quote-and-reply, given
  [we already parse that shape](06-iphone-navigation.md) back out.

Two facts already established by earlier research and worth carrying in:

- Reactions **group by `(reaction_type, emoji_code)`, never by `emoji_name`** — aliases share
  a code and would otherwise show as separate chips.
- The emoji a realm actually offers comes from `realm_emoji` plus the server's own unicode
  table; resolution order is active realm emoji → `:zulip:` → unicode → literal text.

## Answer — built

Reactions render as glass chips under a message, tinted when you are one of the reactors,
tap to toggle, long-press to see who. Every emoji resolves through the existing `ZuluEmoji`
catalogue, so realm custom emoji draw as their image. Grouping is by
`(reaction_type, emoji_code)` — never by name, or aliases would show as duplicate chips.

Long-press a message for a sheet: a quick-reaction row across the top, then Add Reaction,
Reply, Copy Text, Copy Link. A sheet rather than `.contextMenu`, because a context menu can
only hold menu items and the quick row is a strip of tappable emoji. The quick row's emoji
come from what this realm has actually reacted with, padded from a fixed set when the realm
has not reacted six distinct ways yet.

Reply emits real Zulip quote-and-reply markup — the same shape `foldQuotedReplies` parses
back — and the round trip is a test, so changing what the builder writes fails it.

### One conversation-wide observation, not one per message

The first build watched the reaction table per visible message. The chips never appeared,
and the reason is worth keeping: each row started with no reactions, its own query returned
a moment later, and **a lazy row that gains height after it has been measured is not
reliably re-laid-out**. The row was there, sized zero, forever. It only became visible when
an unrelated always-present label gave it non-zero height.

`MessageHistoryLoader` now owns a single observation for the whole conversation and passes
each message its groups as a plain value, so a row is never empty at the moment it is
measured. This is the same failure mode
[the scrollback research](../research/24-scrollback-without-jank.md) warns about under
"do not change a row's height after it has appeared", met from a different direction.

Not built: editing and deleting your own messages, and moving a message to another topic.
