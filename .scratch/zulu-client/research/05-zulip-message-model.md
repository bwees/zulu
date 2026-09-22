# Zulip message content model

Research for issue `05-zulip-message-model.md`. Sources are the official API docs at
`https://zulip.com/api/`, the help center at `https://zulip.com/help/`, and the
`zulip/zulip`, `zulip/zulip-flutter`, and `zulip/zulip-mobile` repositories.
Researched 2026-09-22 against current `main`.

"FL" below means Zulip server **feature level**, reported in `POST /api/v1/register`
as `zulip_feature_level`. Every version-gated claim names the level it landed at.

---

## 1. Answer up front

- **The topic field is `subject` on the wire.** Not `topic`. Confirmed by the
  get-messages schema and by zulip-flutter mapping its `topic` field with
  `@JsonKey(name: 'subject')`.
- **Render the server's HTML. Do not re-parse the markdown.** Zulip's markdown is
  server-authoritative; the only client-side markdown implementations that exist
  (web's `markdown.ts`) exist solely for optimistic local echo and are explicitly
  documented as a secondary approximation that the server's response overwrites.
  zulip-flutter — Zulip's own modern native client — parses `rendered_content`
  HTML into a custom widget AST with a `package:html` DOM parse. No WebView, no
  markdown re-parse. Details in §4.
- **Fetching is anchor-based, not cursor-based.** `anchor` + `num_before` +
  `num_after`, with `found_oldest` / `found_newest` as the only reliable
  end-of-range signals. Details in §6.
- **Uploaded files are fetched with an `Authorization: Basic base64(email:api_key)`
  header on same-origin `/user_uploads/...` URLs.** Details in §7.
- **Reactions are identified by `(reaction_type, emoji_code)`, never by
  `emoji_name`.** Details in §8.

---

## 2. The message object

Source: <https://zulip.com/api/get-messages>

| Field | Type | Presence | Notes |
|---|---|---|---|
| `id` | int | always | Sort key. Monotonic per server. |
| `sender_id` | int | always | |
| `sender_full_name` | string | always | |
| `sender_email` | string | always | The Zulip *API* email, not necessarily the real one — depends on `email_address_visibility`, a per-user setting since FL 163. |
| `sender_realm_str` | string | always | Unique only within a server. |
| `type` | string | always | `"stream"` or `"private"`. Note the message object still uses the old spellings even though the *send* parameter now prefers `"channel"` / `"direct"`. |
| `content` | string | always | Rendered HTML when `apply_markdown=true` (the default); raw markdown source when `false`. |
| `content_type` | string | always | `"text/html"` or `"text/x-markdown"`, matching `apply_markdown`. |
| `subject` | string | always | **The topic.** `""` for direct messages. |
| `timestamp` | int | always | UNIX seconds, UTC. |
| `client` | string | always | Name of the client that sent it. |
| `display_recipient` | string \| object[] | always | Channel name for stream messages; array of `{id, email, full_name, is_mirror_dummy}` for DMs. |
| `stream_id` | int | channel messages only | Absent on DMs. |
| `recipient_id` | int | always | Internal recipient-set id. Semantics for 1:1 DMs changed at FL 327 and again at FL 482. zulip-flutter ignores it outright: *"The `recipient_id` field in the API doesn't add any information, so we ignore it."* Do the same. |
| `avatar_url` | string \| null | key always present | Null when the client sent `client_gravatar=true` (default since FL 92) and the viewer can see the sender's real email — the client is expected to compute the Gravatar URL itself. |
| `is_me_message` | bool | always | True for `/me` status messages. See §5 for the rendering consequence. |
| `reactions` | object[] | always, may be empty | Chronological. See §8. |
| `submessages` | object[] | always, may be empty | Widgets (polls, todo lists). Separate wire protocol; out of v1 scope. |
| `topic_links` | object[] | always | `{text, url}` per entry — linkifier matches found in the topic. Was `subject_links` (plain strings) before FL 46 / Zulip 4.0. |
| `last_edit_timestamp` | int | only if content was edited | UNIX seconds. Narrowed at FL 365 / Zulip 10.0 to mean *content* edits only; `last_moved_timestamp` was added at the same level for channel/topic moves. |
| `edit_history` | object[] | absent if never edited, or if the realm hides edit history | See §3. |
| `flags` | string[] | always | See §3. |
| `match_content` | string | only with a `search` narrow operator | HTML with `<span class="highlight">` around hits. |
| `match_subject` | string | only with a `search` narrow operator | Same, for the topic. Wire name is still `match_subject`. |

`sender_short_name` was removed at FL 26 / Zulip 3.1. Do not expect it.

### Empty topics

Empty-string topics became valid at **FL 334 / Zulip 10.0**, gated on the client
sending `allow_empty_topic_name` on requests and declaring the `empty_topic_name`
client capability at register. At **FL 392** they display as "general chat"
(<https://zulip.com/help/general-chat-topic>). On older servers the sentinel is
the literal string `"(no topic)"`.

### Feature-level history worth tracking

From <https://zulip.com/api/changelog>:

- FL 26 (3.1) — `sender_short_name` removed.
- FL 46 (4.0) — `topic_links` replaces `subject_links`, shape changes to objects.
- FL 92 (5.0) — `client_gravatar` defaults to `true`.
- FL 118 (5.0) — `edit_history` gains `stream`, `topic`; `prev_subject` renamed `prev_topic`.
- FL 120 (5.0) — `GET /messages/{id}` added.
- FL 155 (6.0) — `include_anchor` added.
- FL 163 (7.0) — `email_address_visibility` becomes per-user.
- FL 177 (7.0) — `dm` / `dm-including` / `is:dm` replace `pm-with` / `is:private`.
- FL 224 (8.0) — `wildcard_mentioned` deprecated in favour of `stream_wildcard_mentioned` / `topic_wildcard_mentioned`.
- FL 248 (9.0) — `"channel"` accepted as a send `type`.
- FL 250 (9.0) — `channel` / `channels` narrow operators alias `stream` / `streams`.
- FL 284 (10.0) — `prev_rendered_content_version` removed from edit history.
- FL 300 (10.0) — `message_ids` param on `GET /messages`.
- FL 328 (10.0) — nested `user` object removed from reactions.
- FL 334 (10.0) — empty topic names.
- FL 365 (10.0) — `last_moved_timestamp` added.
- FL 445 (12.0) — `anchor_date` param and `date` anchor value.

---

## 3. Flags and edit history

### `flags`

Source: <https://zulip.com/api/update-message-flags> (§"Available flags"), cross-checked
against zulip-flutter's `MessageFlag` enum in `lib/api/model/model.dart`.

| Flag | Meaning |
|---|---|
| `read` | User has read it. |
| `starred` | User has starred it. |
| `collapsed` | User has collapsed it. |
| `mentioned` | Personal mention of the current user. |
| `stream_wildcard_mentioned` | `@**all**` / `@**channel**`. Added FL 224. |
| `topic_wildcard_mentioned` | `@**topic**`. Added FL 224. |
| `wildcard_mentioned` | **Deprecated at FL 224.** Combined both above. Still arrives from older servers. |
| `has_alert_word` | Matches one of the user's alert words. |
| `historical` | The message entered the user's history after the fact (subscribed to a channel later) rather than being delivered live. |
| `hide_link_previews` | User has hidden auto previews on this message. |

The list is open-ended. zulip-flutter carries a synthetic `unknown` bucket with the
comment *"Unrecognized flags won't roundtrip"*. Store unknown flags as opaque strings
rather than dropping them.

**Updating flags:**

- `POST /api/v1/messages/flags` — `messages` (int[]), `op` (`add`/`remove`), `flag`.
  Response echoes `messages`, and when removing `read`, an
  `ignored_because_not_subscribed_channels` list.
  <https://zulip.com/api/update-message-flags>
- `POST /api/v1/messages/flags/narrow` — range update without an explicit id list.
  Params `anchor`, `include_anchor` (default true), `num_before`, `num_after`,
  `narrow`, `op`, `flag`. Response: `processed_count`, `updated_count`,
  `first_processed_id`, `last_processed_id`, `found_oldest`, `found_newest`.
  This is the "mark all as read" primitive.
  <https://zulip.com/api/update-message-flags-for-narrow>
- Live updates arrive as the `update_message_flags` event: `op`, `messages`, `flag`.
  New messages arrive on the `message` event with their `flags` array already
  populated — **read that array**, do not assume new means unread. Self-sent
  messages and muted-user messages can arrive already read.
  <https://zulip.com/api/get-events>

### `edit_history`

Entries embedded on a message are *diffs*, not snapshots:

| Field | Presence |
|---|---|
| `user_id` (int \| null) | always; null only for pre-March-2017 edits |
| `timestamp` (int) | always |
| `prev_content`, `prev_rendered_content` | only if content changed |
| `prev_stream` (int) | only if the channel changed (FL 1) |
| `stream` (int) | only if the channel changed (FL 118) |
| `prev_topic` (string) | only if the topic changed; renamed from `prev_subject` at FL 118 |
| `topic` (string) | only if the topic changed (FL 118) |

`prev_rendered_content_version` was removed at FL 284.

`GET /api/v1/messages/{message_id}/history` returns a richer `message_history` array —
full point-in-time snapshots with `content`, `rendered_content`, `topic`,
`content_html_diff` (server-rendered diff HTML) alongside the same `prev_*` fields.
<https://zulip.com/api/get-message-history>

The `edit_history` key is omitted entirely when the message was never edited, **or**
when the realm hides edit history from this viewer. The realm setting was the boolean
`realm_allow_edit_history`; at **FL 358** it was replaced by the integer
`message_edit_history_visibility_policy` with levels None / Moves-only / All, with the
old boolean kept as a derived legacy value.
<https://zulip.com/help/restrict-message-edit-history-access>

> **Unresolved:** the exact integer values of
> `message_edit_history_visibility_policy` were not confirmed from a fetchable primary
> doc. Would require reading `zerver/models/realms.py`. Not needed for v1, since
> edit-history UI is explicitly out of scope per the project map.

---

## 4. Render the server HTML, don't re-parse markdown

This is the decisive finding for the client architecture.

### What Zulip itself says

`zulip/zulip` `docs/subsystems/markdown.md`:

> The backend implementation ... is used to authoritatively render messages to HTML.
> The frontend implementation is in JavaScript, based on marked.js (`web/src/echo.ts`)
> ... used to preview and locally echo messages ... Those frontend renderings are only
> shown to the sender ... and are (ideally) identical to the backend rendering.

and, on divergence:

> the frontend will discover this when the backend returns the newly sent message, and
> will update the HTML based on the authoritative backend rendering.

`docs/subsystems/sending-messages.md` makes the intent explicit: the second markdown
implementation exists *only* because of local echo.

### What zulip-flutter does

`zulip-flutter` is Zulip's current official native client (it replaced zulip-mobile in
2025), so its choice is the directly relevant precedent.

- `lib/model/content.dart` imports `package:html` (a Dart HTML5 parser) and walks the
  **HTML DOM** of the message content into a custom AST: `ZulipContent`,
  `BlockContentNode`, `InlineContentNode`. Doc comment on `ZulipContent`:
  *"A complete parse tree for a Zulip message's content ... parsed representation for
  an entire value of `Message.content`, `Stream.renderedDescription`, or other text
  from a Zulip server that comes in the same Zulip HTML format."*
- `lib/widgets/content.dart` renders that AST through a widget-tree switch. **No
  WebView. No markdown re-parse.**
- Unknown HTML is absorbed by an `UnimplementedNode` mixin
  (`content.dart`, with `UnimplementedBlockContentNode` /
  `UnimplementedInlineContentNode` used at roughly 30 call sites). The widget layer
  renders these *visibly* as red inline markup showing the raw `outerHtml`, with the
  stated rationale of keeping the demos honest rather than silently dropping content.
- There is **no `zulipFeatureLevel` branching inside the content parser**. Drift in the
  server's HTML shape across versions is absorbed entirely by the
  `UnimplementedNode` fallback.

Source: <https://github.com/zulip/zulip-flutter> —
`lib/model/content.dart`, `lib/widgets/content.dart`.

> **Unresolved:** no prose ADR or design doc in the zulip-flutter repo explains the
> "HTML AST, not WebView, not markdown" decision. It is inferred from the code
> structure and from the server docs above.

### What zulip-mobile did

The legacy React Native client used a WebView and interpolated the server HTML
directly: `src/webview/MessageList.js` uses `react-native-webview`, and
`src/webview/html/message.js` splices `message.content` into the page through the
raw/unescaped template marker in `src/webview/html/template.js`. It never re-parsed
markdown either.

### Implication for Zulu

1. Fetch with `apply_markdown=true` (the default) and parse the returned HTML into a
   Swift content AST, mirroring zulip-flutter's node model.
2. Build an explicit `unimplemented(rawHTML)` node from day one. There is no
   feature-level-to-HTML-shape table maintained anywhere in code — only in the
   changelog prose of `api_docs/message-formatting.md`
   (<https://zulip.com/api/message-formatting>), which is the thing to watch for
   HTML-shape changes (e.g. `data-code-language` added at FL 33; global-time
   ISO-8601-only as of FL 503).
3. `POST /api/v1/render-message` is the sanctioned way to get current server HTML for
   arbitrary markdown — useful for compose preview without reimplementing anything.
4. If optimistic local echo is wanted, it needs a *separate*, deliberately partial
   markdown renderer plus a "defer to the server when unsure" gate, exactly like
   web's `contains_backend_only_syntax()` in `web/src/markdown.ts`, and a
   reconcile-on-response step (`web/src/echo.ts` `process_from_server` matches by
   `local_id` and overwrites the local HTML when it differs). That is a v1 scope
   decision, not a rendering-architecture decision.

---

## 5. The markdown dialect and the HTML it produces

The client pattern-matches this HTML, so the exact classes matter. Source:
`zulip/zulip` `zerver/lib/markdown/__init__.py`, `zerver/lib/markdown/fenced_code.py`,
`zerver/lib/mention.py`, plus <https://zulip.com/api/message-formatting>.

### Mentions

| Syntax | HTML |
|---|---|
| `@**Full Name**` | `<span class="user-mention" data-user-id="31">@Full Name</span>` |
| `@**Full Name\|31**` | same, disambiguated by id |
| `@_**Full Name**` (silent) | `<span class="user-mention silent" data-user-id="31">Full Name</span>` — no `@` in the text |
| `@**all**` / `@**everyone**` / `@**stream**` / `@**channel**` | `<span class="user-mention channel-wildcard-mention" data-user-id="*">@channel</span>` — the literal string `*` |
| `@**topic**` | `<span class="topic-mention">@topic</span>` — **no `data-user-id` at all** |
| `@*group-name*` | `<span class="user-group-mention" data-user-group-id="17">@group-name</span>` |
| `@_*group-name*` | `<span class="user-group-mention silent" data-user-group-id="17">group-name</span>` |

`channel` as a wildcard keyword landed at FL 247; older servers only accept
`all` / `everyone` / `stream`. Parse all spellings regardless.

Quoting a message auto-rewrites mentions to their silent form server-side
(`BlockQuoteProcessor.clean()`). Deactivated users and groups are silenced
automatically even without the `_`.

### Channel, topic, and message links

| Syntax | class | href | rendered text |
|---|---|---|---|
| `#**channel name**` | `stream` | `/#narrow/channel/{id}-{slug}` | `#channel name` |
| `#**channel>topic**` | `stream-topic` | `/#narrow/channel/{id}-{slug}/topic/{slug}` | `#channel > topic` |
| `#**channel>topic@123**` | `message-link` (FL 319+) | `.../near/123` | `#channel > topic @ 💬` |

`stream` and `stream-topic` carry `data-stream-id`; **`message-link` does not** — an
asymmetry to handle. If a channel or topic name contains `` ` ``, `>`, `*`, `&`,
`[`, `]`, or `$$`, the composer falls back to a plain `[label](url)` with no special
class. An empty topic renders as `<em>{fallback name}</em>`.

### Emoji

- Unicode: `<span aria-label="smiling face" class="emoji emoji-1f600" role="img" title="smiling face">:smiling_face:</span>` — codepoint is lowercase hex.
- Realm emoji: `<img alt=":name:" class="emoji" title="name" src="...">`.
- `:zulip:` is a hardcoded special case rendered as an `<img>` from a static path — the only such name.
- Emoticon translation (`:)` → `:smile:`) is a per-user compose setting; the output HTML is indistinguishable from a typed `:smile:`.

### Spoilers

```` ```spoiler Header ... ``` ```` produces:

```html
<div class="spoiler-block">
  <div class="spoiler-header"><!-- header, itself markdown-rendered --></div>
  <div class="spoiler-content" aria-hidden="true"><!-- body --></div>
</div>
```

The show/hide toggle is client chrome, not encoded in the HTML.

### Code, quote, math

- Highlighted code: `<div class="codehilite" data-code-language="Python"><pre><span></span><code class="language-python">...</code></pre></div>`. `data-code-language` carries the **canonical Pygments lexer name**, not the alias the user typed. Line numbering is off, so there is no `<table>` wrapper.
- The copy button and "open in playground" are client chrome, absent from the API HTML.
- ```` ```quote ```` simply re-prefixes every line with `> ` and reruns the pipeline — the output is a plain `<blockquote>`.
- Math: `$$formula$$` inline, ```` ```math ```` for blocks. Rendered by KaTeX into raw KaTeX HTML — `<span class="katex">...<annotation encoding="application/x-tex">{source}</annotation>...</span>`. The `annotation` node is the reliable place to recover the original LaTeX source, which is what Zulip's own `change_katex_to_raw_latex` does. Errors render as `<span class="tex-error">$$original$$</span>`.

**Practical note for SwiftUI:** the `annotation` element means the client can extract
the TeX source and hand it to a native math renderer instead of trying to reproduce
KaTeX's span soup.

### Quote-and-reply

This is **client-generated compose text**, not server markup. The shape the official
clients generate (`web/src/compose_reply.ts`):

```
@_**Iago|5** [said](https://server/#narrow/.../near/12345) in #**channel>topic**:
```quote
message content
```
```

The link is an absolute URL. The fence length is widened dynamically
(`get_unused_fence`) so it cannot collide with fences already inside the quoted text —
worth copying, since a naive three-backtick fence breaks on quoted code blocks.

### Everything else

- **Linkifiers**: `GET /api/v1/realm/linkifiers` → `{pattern (RE2, named groups), url_template (RFC 6570)}`. Servers below FL 176 use `realm_filters` with `url_format_string`. **The client must declare the `linkifier_url_template` client capability in `POST /register`**, or `realm_linkifiers` comes back empty on current servers. Output HTML is a plain `<a href>` with no distinguishing class — matching is server-side, so a rendering client needs none of this except to display the realm's linkifier config.
- **Global times**: `<time:2024-08-06T17:00:00+01:00>` → `<time datetime="2024-08-06T16:00:00Z">2024-08-06T17:00:00+01:00</time>`. The text content is the author's literal input; render from the `datetime` attribute in the viewer's timezone. Invalid input degrades to escaped literal text with no `<time>` tag.
- **`/me` messages**: not a markdown transform. `is_me_message` is true when the raw content starts with `/me `, and the prefix `<p>/me ` is left **in** the rendered HTML. The client must strip `<p>/me ` from the first paragraph and splice in the sender's name (this is what `web/src/message_list_view.ts` does). No CSS class marks it.
- **Tables**: stock python-markdown `tables` extension — GFM pipe tables, alignment via inline `style="text-align:..."`.
- **Task lists (`- [x]`) are NOT supported.** A grep of the markdown source found nothing. Zulip's checklist feature is the separate `/todo` widget, which rides on `submessages`, not markdown.
- **Inline images**: `<div class="message_inline_image"><a href="..." title="..." data-id="..."><img src="..."></a></div>`. Before the thumbnailing worker runs, the `<img>` carries `class="image-loading-placeholder"`, `data-original-dimensions="{w}x{h}"`, and `data-original-content-type`.
- **Video**: `<div class="message_inline_image message_inline_video">` wrapping `<video preload="metadata" src="...">`.
- **YouTube**: `<div class="youtube-video message_inline_image"><a href="..." data-id="{yt_id}"><img src="{thumbnail}"></a></div>`.
- **Link previews (OpenGraph)**: a *different* structure — `<div class="message_embed">` with `message_embed_image` / `message_embed_title` / `message_embed_description`. Do not conflate with `message_inline_image`.
- At most 24 inline previews per message.

> **Caveats flagged by the research:** `docs/subsystems/markdown.md` self-describes as
> inaccurate in places. The Vimeo class was not confirmed as distinct from the generic
> `embed-video` oEmbed path. Audio/HEIC transcoding attributes come from the API doc
> only, not from a source grep. The pre-FL-319 rendering of `#**channel>topic@123**`
> is inferred, not confirmed.

---

## 6. Fetching and backfill

Source: <https://zulip.com/api/get-messages>

### Request

| Param | Notes |
|---|---|
| `anchor` | A numeric message id, or `"newest"`, `"oldest"`, `"first_unread"`, or (FL 445) `"date"` paired with `anchor_date` (ISO 8601). Required unless `message_ids` is used. |
| `include_anchor` | bool, default `true` (FL 155). Whether the anchor message itself counts toward the before/after budgets and is returned. |
| `num_before` / `num_after` | Counts of messages older / newer than the anchor. Required unless `message_ids` is used. Capped at 5000. |
| `narrow` | JSON array. Each element is `{"operator": ..., "operand": ..., "negated": bool}`; the legacy two-element `["operator", "operand"]` form is still accepted. Default `[]`. |
| `client_gravatar` | bool, default `true` since FL 92. When true the server may return `avatar_url: null` and expect the client to compute the Gravatar URL. |
| `apply_markdown` | bool, default `true`. When `false`, `content` is raw markdown and `content_type` becomes `text/x-markdown`. |
| `message_ids` | int[] (FL 300). Fetch an explicit set. **Mutually exclusive** with anchor-based pagination. This is the bulk-fetch-by-id facility — there is no separate endpoint. |
| `allow_empty_topic_name` | bool, default `false` (FL 334). |
| `use_first_unread_anchor` | **Deprecated since FL 1.** Use `anchor: "first_unread"`. |

### Response

`anchor` (resolved), `found_anchor`, `found_newest`, `found_oldest`,
`history_limited`, `messages` (ascending by `id`).

`history_limited` means the oldest end was truncated by the realm's message-retention
policy or plan limits — it is *not* the true start of history, and is a distinct
condition from `found_oldest`.

### Backfill algorithm

- **Initial load**: `anchor="newest"`, `num_before=N`, `num_after=0`.
- **Scroll back**: `anchor=<lowest id held>`, `include_anchor=false`, `num_before=N`, `num_after=0`. Stop on `found_oldest=true`, or on `history_limited=true` (nothing older is retrievable, though more once existed).
- **Catch up / fill a gap forward**: `anchor=<highest id held>`, `include_anchor=false`, `num_before=0`, `num_after=N`. Stop on `found_newest=true`.
- **Jump to a message**: `anchor=<target id>`, both `num_before` and `num_after` > 0, `include_anchor=true`.
- **End detection must use `found_oldest` / `found_newest`, never an empty `messages` array.** A narrow with no matches returns both flags true and zero messages, which is not the same condition.

### Narrow operators

Sources: <https://zulip.com/api/construct-narrow>,
<https://zulip.com/help/search-for-messages>, plus the changelog.

- `channel` (int id or name) — alias for `stream` since FL 250. `channels` / `streams` for the plural forms (e.g. `channels:public`); `channels:archived` added FL 489.
- `topic` — string. Empty string valid once `allow_empty_topic_name` / FL 334 applies.
- `sender` — email or user id.
- `dm` — user id or JSON list of user ids for a group DM. Replaced `pm-with` at FL 177.
- `dm-including` — user id; matches any DM conversation including that user. FL 177.
- `is:dm` (replaced `is:private` at FL 177), `is:unread`, `is:starred`, `is:mentioned`, `is:alerted`, `is:resolved`, `is:followed` (FL 265), `is:muted` (FL 366).
- `has:link`, `has:image`, `has:attachment`, `has:reaction` (FL 249).
- `near` — a message id. **Display hint only; it does not change which messages match server-side.**
- `with` — a message id (FL 271). The permanent-link operator: it keeps resolving to the right conversation through topic moves and renames. This is what a "link to this message" feature should emit.
- `id`, `search`, `mentions` (FL 446).
- Any operator can carry `"negated": true`.

> **Unresolved:** the complete `is:` / `has:` enumeration above is reconstructed from
> partial fetches of `construct-narrow` plus the help center and changelog, not from a
> single verbatim capture of that page. Re-verify before relying on exhaustiveness.

### Single-message endpoints

- `GET /api/v1/messages/{message_id}` (FL 120). Params `apply_markdown`, `allow_empty_topic_name`. Returns the message object plus `raw_content`. <https://zulip.com/api/get-message>
- `GET /api/v1/messages/{message_id}/history`. See §3.

---

## 7. Composing, editing, uploads

### Send

`POST /api/v1/messages` — <https://zulip.com/api/send-message>

| Param | Notes |
|---|---|
| `type` | `"channel"` (FL 248) or legacy `"stream"`; `"direct"` (FL 174) or legacy `"private"`. Pick based on `zulip_feature_level`. |
| `to` | Channel: name string or integer channel id. DM: a JSON list of user ids (preferred) or emails. |
| `topic` | Required for channel messages. `subject` is the deprecated alias. |
| `content` | Markdown source. Max length in `max_message_length` from `POST /register`. |
| `queue_id` + `local_id` | Both or neither. Used to correlate the resulting `message` event with an optimistically echoed local message. |
| `read_by_sender` | bool (FL 236). Whether the message is immediately read for the sender. The server uses a heuristic when omitted. |

### Edit and delete

`PATCH /api/v1/messages/{message_id}` — <https://zulip.com/api/update-message>

- `content`, `topic` (legacy alias `subject`), `stream_id` (move to another channel).
- `propagate_mode`: `change_one` (default), `change_later`, `change_all`.
- `send_notification_to_old_thread` (default `false`), `send_notification_to_new_thread` (default `true`).
- `prev_content_sha256` — optimistic-concurrency guard, Zulip 11.0+.
- Time limits live in realm settings: `message_content_edit_limit_seconds`, `move_messages_within_stream_limit_seconds`, `move_messages_between_streams_limit_seconds`. Permissions live in group settings: `allow_message_editing`, `can_resolve_topics_group`, `can_move_messages_between_topics_group`, `can_move_messages_between_channels_group`.

`DELETE /api/v1/messages/{message_id}` — <https://zulip.com/api/delete-message>. No body
params. Governed by `realm_can_delete_any_message_group` /
`realm_can_delete_own_message_group` and `realm_message_content_delete_limit_seconds`.
Before FL 281, only admins could delete at all.

### Upload

`POST /api/v1/user_uploads` — <https://zulip.com/api/upload-file>

- The **multipart field name does not matter**: the server does
  `[user_file] = request.FILES.values()` in `zerver/views/upload.py`, erroring only on
  zero or more than one file. The OpenAPI schema calls it `filename`; zulip-flutter
  sends `http.MultipartFile('file', ...)` (`lib/api/core.dart`).
- Response: `{"uri": ..., "url": ..., "filename": ..., "result": "success", "msg": ""}`.
  `url` was added at **FL 272 / Zulip 9.0**; `uri` is the deprecated alias kept for
  compatibility and is what zulip-flutter still deserializes. **Read `url`, fall back
  to `uri`.** `filename` (the stored name, which may differ from the URL basename due
  to escaping) was added at FL 285.
- Path shape: `/user_uploads/<realm_id>/<xx>/<random>/<filename>`.
- Embed it in message content as ordinary markdown: `[filename](/user_uploads/...)`.
  Images use `![alt](/user_uploads/...)`, which only works for already-uploaded files,
  not arbitrary external URLs.
- Size limit: `max_file_upload_size_mib` (MiB) from `POST /register`; live-updated via
  the `realm/update_dict` event since FL 306. Note the field has **no `realm_` prefix**
  despite being a realm setting. Cloud Free caps at 10 MB/file, Standard/Plus at 1 GB.
- Resumable uploads for large files: `/api/v1/tus` (tus.io protocol), FL 296. There is
  **no client-facing presigned-S3 flow** — S3 signing in `zerver/lib/upload/s3.py` is
  server-internal and only used when *serving* files.
- Thumbnail readiness polling: `GET /api/v1/thumbnail/status/{realm_id_str}/{filename}`
  → `{has_thumbnail: bool}`, FL 479.

### Authenticated media fetching

There is no realm setting literally called "authenticated file access". The actual
mechanism is a dual-URL design, always on, with no feature gate:

**Family 1 — bare `/user_uploads/<realm_id>/<filename>`** (also `/user_uploads/download/...`
and `/user_uploads/thumbnail/.../<format>`). Deliberately registered *outside* `/api/v1/`
so one URL works for both web and API clients. `zerver/lib/rest.py` resolves auth in
priority order:

1. `Authorization` header — HTTP Basic, `base64(email + ":" + api_key)`.
2. `?api_key=<key>` query param. The server comment says this exists as a workaround
   because React Native could not set Basic-auth headers — a legacy path for
   zulip-mobile, not the preferred route.
3. Browser session cookie (CSRF-protected).
4. Anonymous, only if the realm has public web access for that route.

**Family 2 — signed temporary URL.** `GET /api/v1/user_uploads/{realm_id_str}/{filename}`
returns `{"url": "/user_uploads/temporary/<token>/<filename>"}`. The token is valid for
roughly 60 seconds (`SIGNED_ACCESS_TOKEN_VALIDITY_IN_SECONDS`), needs no auth, and must
be consumed immediately. Available since FL 1.

**What zulip-flutter does** (`lib/widgets/image.dart`, `RealmContentNetworkImage`) — and
what Zulu should do:

```dart
headers: {
  if (src.origin == account.realmUrl.origin)
    ...authHeader(email: account.email, apiKey: account.apiKey),
  ...userAgentHeader(),
}
```

The origin check is the important part: it attaches credentials **only** when the image
URL is same-origin with the realm, so an avatar hosted on Gravatar or an inline preview
from a third party never receives the API key. In Swift this is a `URLSession` with a
custom `URLRequest` per image, which rules out plain `AsyncImage` for realm-hosted
media.

### Attachment management

- `GET /api/v1/attachments` → `{attachments: [{id, name, path_id, size, create_time, message_ids}], upload_space_used}`. `message_ids` replaced the older `messages` array of `{id, date_sent}` objects at FL 472. `create_time` is seconds since epoch as of FL 443 (milliseconds before that).
- `DELETE /api/v1/attachments/{attachment_id}`.
- Files referenced by a message are auto-deleted when the last referencing message is deleted; orphaned uploads expire after a few weeks.

> **Unresolved:** no public API field exposes the realm's storage *quota*; only
> `upload_space_used` (usage) is available.

---

## 8. Reactions and emoji identity

Endpoints: `POST` / `DELETE /api/v1/messages/{message_id}/reactions` —
<https://zulip.com/api/add-reaction>, <https://zulip.com/api/remove-reaction>

Params: `emoji_name` (required on add), `emoji_code`, `reaction_type`. Since FL 2,
`reaction_type` is optional even for custom emoji; it defaults to `unicode_emoji`.
Sending a duplicate returns `code: "REACTION_ALREADY_EXISTS"` (Zulip 8.0+).

### The three reaction types

| `reaction_type` | What `emoji_code` holds |
|---|---|
| `unicode_emoji` | Dash-joined lowercase hex codepoints, e.g. `1f419` for octopus. |
| `realm_emoji` | The custom emoji's numeric id as a string — the same key used in the `realm_emoji` map. |
| `zulip_extra_emoji` | The literal name, currently only `"zulip"`. zulip-flutter does not even branch on the code value here; it resolves to a constant `kZulipEmojiUrl`. |

### Reaction object

On a message and in the `reaction` event: `emoji_name`, `emoji_code`, `reaction_type`,
`user_id`. The nested `user` object (`id`, `email`, `full_name`, `is_mirror_dummy`) was
deprecated when `user_id` arrived at FL 2 and **removed at FL 328 / Zulip 10.0**.

The `reaction` event carries `id`, `type`, `op` (`add` / `remove`), `message_id`,
`emoji_name`, `emoji_code`, `reaction_type`, `user_id`.
<https://zulip.com/api/get-events>

### Grouping key — group by code, not name

zulip-flutter's `lib/api/model/reaction.dart` states it directly: the server keys a
reaction on *user, message, reaction type, and emoji code* — `emoji_name` is not part
of the identity. Multiple names alias the same Unicode emoji (`:angry:` and
`:angry_face:`), and older clients may have submitted a non-canonical alias, so
**a reaction chip must aggregate on `(reaction_type, emoji_code)`** and pick a display
name rather than grouping on `emoji_name`. Getting this wrong produces duplicate chips
for the same emoji.

### Resolving an emoji to something displayable

- **Realm emoji**: the `realm_emoji` map in the `POST /register` response, keyed by id →
  `{id, name, source_url, still_url, deactivated, author_id}`. `still_url` is non-null
  only for animated emoji and provides the static fallback. Also available at
  `GET /api/v1/realm/emoji` (<https://zulip.com/api/get-custom-emoji>).
- **Unicode name ↔ codepoint table**: the register response carries
  **`server_emoji_data_url`**. Per <https://zulip.com/api/message-formatting>, it
  "contains the server's mapping between Unicode codepoints and emoji names". It is a
  URL to fetch — pointing at a generated static asset
  (`static/generated/emoji/emoji_codes.json`, built by `tools/setup/emoji/build_emoji`
  from the iamcal dataset) — **not a fixed `/api/v1/` path**, so it varies per
  deployment. Fetch it per account after register rather than bundling a table as
  source of truth; a bundled copy is only reasonable as an offline first-run fallback.
  The older `static/generated/emoji/name_to_codepoint.json` that zulip-mobile once used
  is a stale leftover — do not use it.
- **zulip-flutter's implementation** (`lib/model/store.dart`, `lib/model/emoji.dart`,
  `lib/api/model/initial_snapshot.dart`): on startup it fires an unawaited
  `updateMachine.fetchEmojiData(initialSnapshot.serverEmojiDataUrl)`;
  `setServerEmojiData` stores a `Map<String, List<String>>` of codepoint-hex → alias
  names; `tryParseEmojiCodeToUnicode` turns the dash-joined hex into a Dart string; and
  `emojiDisplayFor({emojiType, emojiCode, emojiName})` switches on the reaction type —
  Unicode to a literal glyph, realm to an image, zulip_extra to the fixed URL — falling
  back to a plain `:name:` text display when resolution fails. That fallback is worth
  copying.

> **Unresolved:** the feature level at which `server_emoji_data_url` was introduced.
> No worked multi-codepoint example (flags, skin tones, ZWJ sequences) appears in the
> primary docs — the dash-joined-per-codepoint rule is stated generally but not
> demonstrated, so verify against a real server before trusting it for composite
> emoji. No per-message cap on distinct reactions was found.

---

## 9. What this means for Zulu

Design consequences that follow directly from the above, for the store and rendering layers:

1. **Store `content` (HTML) as the canonical body.** Keep the raw markdown only when
   explicitly fetched for an edit (`raw_content` from `GET /messages/{id}`, or
   `apply_markdown=false`). Do not attempt to reconstruct markdown from HTML.
2. **Column name `subject`, or map it explicitly.** The wire name will otherwise leak
   into the schema as a surprise.
3. **Parse HTML to a Swift content AST with an explicit `unimplemented` node.** Server
   HTML shape is versioned and there is no machine-readable compatibility table.
4. **Persist `flags` as an open set of strings.** New flags arrive with new server
   versions.
5. **Backfill state per narrow needs `found_oldest`, `found_newest`, and
   `history_limited` persisted**, not just the id range held — the range alone cannot
   distinguish "no more" from "not fetched yet".
6. **Realm-hosted media needs a custom `URLSession` image loader** with a same-origin
   check before attaching the Basic auth header. `AsyncImage` will not do.
7. **Reaction aggregation keys on `(reaction_type, emoji_code)`.**
8. **Fetch `server_emoji_data_url` once per account** and cache it in the store;
   `realm_emoji` comes from register and updates via events.
