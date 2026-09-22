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
