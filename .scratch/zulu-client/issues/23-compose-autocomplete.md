# Compose autocomplete, and the whole emoji set

Type: prototype
Status: open
Blocked by: 10

## Question

What does the suggestion box above the composer look like, and what feeds it?

Typing `#`, `:`, or `@` should open a box above the compose bar. Everything typed after the
trigger becomes the query; picking a result replaces the trigger and the query with the
right markup. One mechanism, three sources:

- `#` — channels, emitting `#**channel name**`
- `:` — emoji, emitting the shortcode
- `@` — people and user groups, emitting `@**Full Name**`

Decide:
- The abstraction. A source supplies matches for a query and the text to insert; the box,
  the trigger detection, and the keyboard handling are shared. What does a source have to
  provide, and can a fourth be added without touching the box?
- Trigger rules: what opens the box, what closes it, what happens at a word boundary, and
  whether a trigger mid-word counts.
- Ranking. Exact prefix first is obvious; whether recency or subscription state matters is not.
- How it behaves with the keyboard up on a small phone, and whether it is reachable one-handed.

**The emoji picker is the same problem seen from the other side** and should share the
catalogue. Today it lists a hardcoded handful of unicode emoji and no custom ones. It needs:

- Every unicode emoji, with names to search by. Zulip serves its own table at
  `server_emoji_data_url` from the register response — worth reading rather than shipping
  a copy that drifts from what the server accepts.
- **Realm custom emoji first**, since those are the ones people in a given organization
  actually reach for. They arrive in the register snapshot as `realm_emoji`.
- Search across both by name and alias.

## Research

`.scratch/zulu-client/research/23-emoji-and-autocomplete.md`

**The picker and `:` autocomplete are the same code.** zulip-flutter ranks emoji into nine
buckets with realm custom emoji at the top, which is exactly what this ticket asked for, and
that ranking serves both surfaces. Build one catalogue and two presentations of it.

- **The unicode table is free to fetch.** `server_emoji_data_url` (FL 140) points at
  `emoji_api.json` — no auth, CORS-open, ETag'd, 1883 codes and 3339 names under a single
  `code_to_names` key, with the canonical name at index 0. Fetch and cache it rather than
  shipping a copy.
- **`emoji_code` strips every `U+FE0F`** — `2764`, not `2764-fe0f`. Our existing unicode-span
  decoder should be checked against that.
- **Skin-tone variants do not exist in Zulip**, so the picker must not offer a skin selector.
- Resolution order is active realm emoji → `:zulip:` → unicode → literal text, and `:zulip:`
  is never in `realm_emoji` — it has to be synthesized.
- The composer always inserts `:name:`, never a code.

**Autocomplete ranking is two-stage** in both official clients: a match-quality bucket, then
a comparator within it. Flutter's integer-rank-plus-stable-sort is the cleaner of the two and
is the one to copy. For people the order is **subscription, then recency, then alphabetical** —
which answers the open question in this ticket.

**One trap that breaks silently:** channel and topic names containing `` ` > * & [ ] `` or `$$`
cannot be expressed in `#**...**` at all. Both official clients detect this and fall back to a
markdown link. Anything we build has to do the same or those channels become unmentionable.

Research §11.10 tabulates where web and flutter deliberately disagree — case sensitivity, bots
versus relevance, word matching, `can_mention_group` — and which side to follow. Worth reading
before the ranking is written.

Left undetermined: emoji **categories** have no documented API; the only server-side grouping
lives in a file Zulip's build scripts call internal. A picker with category tabs would have to
carry its own grouping.
