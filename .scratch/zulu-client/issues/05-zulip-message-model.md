# Zulip message content model

Type: research
Status: resolved

## Question

What is in a Zulip message, and what does rendering and composing one require?

Find:
- The message object's fields, including `content` vs `rendered_content`, flags, `edit_history`, and the topic field's actual name on the wire.
- Zulip's markdown dialect: what it supports beyond CommonMark — mentions, channel links, topic links, emoji, spoilers, code blocks with syntax highlighting, LaTeX, quote-reply syntax.
- Whether a native client should render the server's HTML or re-parse the markdown source, and what the official clients do.
- Upload flow: `/user_uploads`, the returned URI, how it is embedded in message content, and how authenticated media fetching works.
- Reactions: emoji identity across unicode, realm emoji, and zulip extra emoji.
- Message fetching and backfill: `/messages` anchors, narrows, and `num_before`/`num_after` semantics.

## Research output

`.scratch/zulu-client/research/05-zulip-message-model.md`

## Answer

**Render the server's HTML; do not re-parse markdown.** zulip-flutter — Zulip's own current native client — parses `rendered_content` into a custom AST and renders that as a widget tree, with an `UnimplementedNode` fallback absorbing cross-version HTML drift instead of feature-level branching. Zulip's docs state the backend markdown is authoritative and the web client's markdown exists only for local echo. Zulu does the same: parse the server HTML into native views, no WebView.

Other findings that bind the store and the UI:

- **The topic field is `subject` on the wire**, not `topic`.
- Fetching is anchor-based with `num_before`/`num_after`; end of range is `found_oldest`/`found_newest`, never an empty array, and `history_limited` is a distinct "retention cut this off" signal.
- Media needs `Authorization: Basic base64(email:api_key)` on same-origin `/user_uploads/…` requests only — the origin check keeps the key away from Gravatar and preview hosts. Plain `AsyncImage` is ruled out.
- Reactions group by `(reaction_type, emoji_code)`, never `emoji_name`, or aliases produce duplicate chips. The emoji table comes from `server_emoji_data_url` in the register response.

Full findings: `.scratch/zulu-client/research/05-zulip-message-model.md`
