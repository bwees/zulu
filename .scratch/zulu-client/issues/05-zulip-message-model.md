# Zulip message content model

Type: research
Status: claimed

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
