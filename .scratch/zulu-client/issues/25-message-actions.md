# Message actions, starting with reactions

Type: prototype
Status: open
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
