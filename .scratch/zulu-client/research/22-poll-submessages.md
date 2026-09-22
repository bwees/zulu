# Zulip submessages and the widget protocol (polls, todo lists)

Research for issue [`22-poll-support.md`](../issues/22-poll-support.md). Sources are the
`zulip/zulip` server source on `main`, the official API docs at `https://zulip.com/api/`,
the help center at `https://zulip.com/help/`, and the `zulip/zulip-flutter` and
`zulip/zulip-mobile` repositories. Researched 2026-09-22.

"FL" means Zulip server **feature level**, reported by `POST /api/v1/register` as
`zulip_feature_level`.

---

## 1. Answer up front

- **Polls are a peer-to-peer event log, not server-computed state.** The server stores an
  ordered list of opaque JSON blobs (`SubMessage` rows) and broadcasts each new one. It
  never tallies a vote. Every client replays the log from scratch to get the current poll.
- **Zulu can create polls.** Not via an API parameter — by sending an ordinary message whose
  `content` starts with `/poll`. The server detects the slash command post-save and creates
  the widget itself. Nothing is bot-gated.
- **`widget_content` on `POST /messages` is useless to us.** The server's validator accepts
  exactly one `widget_type` — `"zform"` — and rejects `"poll"` and `"todo"` outright. §7.
- **Voting is `POST /api/v1/submessage`.** Undocumented in the OpenAPI spec but a real,
  stable REST route that zulip-flutter and zulip-mobile both call. §6.
- **The message body must be suppressed wholesale.** The server leaves the literal
  `/poll ...` text in `content` and renders it as an ordinary paragraph. Every Zulip client
  throws the rendered HTML away and renders the widget in its place. §8.
- **Two key encodings, and they are reversed between poll and todo.** Poll option keys are
  `"<sender_id>,<idx>"`; todo task keys are `"<idx>,<sender_id>"`. Initial options/tasks use
  the literal string `"canned"` in the sender position. §4.2, §5.2.
- **Essentially no feature gating.** One changelog entry at FL 354, unrelated to the wire
  format. §9.

---

## 2. The `submessages` array on a message

Source: <https://zulip.com/api/get-messages>, and
[`zerver/models/messages.py`](https://raw.githubusercontent.com/zulip/zulip/main/zerver/models/messages.py).

```python
class AbstractSubMessage(models.Model):
    sender = models.ForeignKey(UserProfile, on_delete=CASCADE)
    msg_type = models.TextField()
    content = models.TextField()

class SubMessage(AbstractSubMessage):
    message = models.ForeignKey(Message, on_delete=CASCADE)

    @staticmethod
    def get_raw_db_rows(needed_ids: list[int]) -> list[dict[str, Any]]:
        fields = ["id", "message_id", "sender_id", "msg_type", "content"]
        query = SubMessage.objects.filter(message_id__in=needed_ids).values(*fields)
        query = query.order_by("message_id", "id")
        return list(query)
```

The API-visible shape, from the OpenAPI spec that generates
<https://zulip.com/api/get-messages> (`additionalProperties: false`):

| Field | Type | Meaning |
|---|---|---|
| `id` | int | The submessage's own id. **Monotonic. This is the ordering key.** |
| `message_id` | int | Parent message. |
| `sender_id` | int | Who added this submessage. Not necessarily the message sender. |
| `msg_type` | string | Free text in the DB. In practice always `"widget"`. |
| `content` | string | **A JSON string**, not an object. Schema depends on position. |

The array is documented only as "Data used for certain experimental Zulip integrations."
`msg_type` has **no documented enum** — the docs and the OpenAPI spec only ever show the
example value `"widget"`. The server writes `msg_type="widget"` for the initial widget row
([`widget.py`](https://raw.githubusercontent.com/zulip/zulip/main/zerver/lib/widget.py)) and
otherwise echoes back whatever string the client POSTed. `get_widget_type()` filters on
`msg_type="widget"`, so anything else is dead weight.

Both `GET /messages` and the `message` event carry a fully populated `submessages` array —
`sew_messages_and_submessages` in
[`zerver/lib/message_cache.py`](https://raw.githubusercontent.com/zulip/zulip/main/zerver/lib/message_cache.py)
attaches them on fetch, and `do_widget_post_save_actions` attaches them to the outgoing
`message` event for a brand-new poll. There is no separate "fetch the poll" call.

---

## 3. The widget protocol

Two positions in the log, with two different schemas.

### 3.1 Submessage 0 — the widget definition

The lowest-`id` submessage declares the widget. Its `content` parses to:

```json
{"widget_type": "poll", "extra_data": {"question": "...", "options": ["..."]}}
```

Built verbatim by
[`zerver/lib/widget.py`](https://raw.githubusercontent.com/zulip/zulip/main/zerver/lib/widget.py):

```python
if widget_type:
    content = dict(widget_type=widget_type, extra_data=extra_data)
    submessage = SubMessage(
        sender_id=sender_id, message_id=message_id,
        msg_type="widget", content=json.dumps(content),
    )
    submessage.save()
```

`widget_type` values that exist, from
[`web/src/widget_schema.ts`](https://raw.githubusercontent.com/zulip/zulip/main/web/src/widget_schema.ts):

```ts
export const any_widget_data_schema = z.discriminatedUnion("widget_type", [
    z.object({widget_type: z.literal("poll"), extra_data: poll_widget_extra_data_schema}),
    z.object({widget_type: z.literal("zform"), extra_data: z.nullable(zform_widget_extra_data_schema)}),
    z.object({widget_type: z.literal("todo"), extra_data: z.nullable(todo_widget_extra_data_schema)}),
]);
```

- `"poll"` and `"todo"` — created by slash command.
- `"zform"` — a bot-interaction demo (a "choices" button list). zulip-flutter's comment calls
  it "more a demo than a real feature"
  ([`lib/api/model/submessage.dart`](https://raw.githubusercontent.com/zulip/zulip-flutter/main/lib/api/model/submessage.dart)).

**The definition must come from the message's own sender.** The web client refuses otherwise
([`web/src/submessage.ts`](https://raw.githubusercontent.com/zulip/zulip/main/web/src/submessage.ts)):

```ts
if (widget_event.sender_id !== message.sender_id) {
    blueslip.warn(`User ${widget_event.sender_id} tried to hijack message ${message.id}`);
    return;
}
```

### 3.2 Submessages 1..n — the events

Every later submessage's `content` parses to `{"type": "<event name>", ...}`. The type space
depends on the widget declared in submessage 0. Schemas below.

### 3.3 Applying the log

`get_message_events` in
[`web/src/submessage.ts`](https://raw.githubusercontent.com/zulip/zulip/main/web/src/submessage.ts):

```ts
message.submessages.sort((m1, m2) => m1.id - m2.id);
```

then `const [widget_event, ...inbound_events] = events;`. Sort by `id`, take the head as the
definition, fold the tail in order. `if (message.locally_echoed) return undefined;` — skip
submessage processing on locally-echoed messages entirely.

zulip-flutter does the same in `Poll.fromSubmessages`, then folds each remaining submessage
through `_applyEvent`.

---

## 4. Poll payloads

### 4.1 `extra_data`

[`zerver/lib/widget.py`](https://raw.githubusercontent.com/zulip/zulip/main/zerver/lib/widget.py):

```python
@dataclass
class PollData:
    question: str
    options: list[str]
```

Parsed from the message text: first line after `/poll` is the question, each subsequent
non-empty line is an option, with one leading `-` or `*` list marker stripped
(`re.sub(r"(\s*[-*]?\s*)", "", line.strip(), count=1)`). Both fields are `z.optional` on the
client ([`web/src/poll_data.ts`](https://raw.githubusercontent.com/zulip/zulip/main/web/src/poll_data.ts)),
and zulip-flutter defaults them to `""` and `[]`. Treat both as possibly missing.

A full submessage-0 `content` for `/poll What did you drink this morning?\nMilk\nTea\nCoffee`:

```json
{"widget_type":"poll","extra_data":{"question":"What did you drink this morning?","options":["Milk","Tea","Coffee"]}}
```

### 4.2 The three poll events

Zod schemas, verbatim from
[`web/src/poll_data.ts`](https://raw.githubusercontent.com/zulip/zulip/main/web/src/poll_data.ts):

```ts
export const new_option_schema = z.object({
    type: z.literal("new_option"),
    idx: z.number(),
    option: z.string(),
});

export const question_schema = z.object({
    type: z.literal("question"),
    question: z.string(),
});

export const vote_schema = z.object({
    type: z.literal("vote"),
    key: z.string(),
    vote: z.number(),
});
```

Server-side validation, verbatim from
[`zerver/lib/validator.py`](https://raw.githubusercontent.com/zulip/zulip/main/zerver/lib/validator.py)
(`validate_poll_data`) — this is the authoritative contract, and it is `check_dict_only`, so
**extra keys are rejected**:

| `type` | Keys | Server checks |
|---|---|---|
| `"vote"` | `key` (string), `vote` (int) | `check_int_in([1, -1])` |
| `"question"` | `question` (string) | **author only** — `"You can't edit a question unless you are the author."` |
| `"new_option"` | `option` (string), `idx` (int) | `check_int_range(0, MAX_IDX)`, `MAX_IDX = 1000` |

Any other `type` → `ValidationError(f"Unknown type for poll data: {poll_data['type']}")`.

Concrete payloads (the `content` string sent to and received from the server):

```json
{"type":"new_option","idx":1,"option":"Orange juice"}
{"type":"question","question":"What are you drinking RIGHT NOW?"}
{"type":"vote","key":"58,1","vote":1}
{"type":"vote","key":"canned,0","vote":-1}
```

### 4.3 Option keys — `"<sender_id>,<idx>"`

An option is identified by the pair (who added it, their local index). From
[`web/src/poll_data.ts`](https://raw.githubusercontent.com/zulip/zulip/main/web/src/poll_data.ts):

```ts
const key = `${sender_id},${idx}`;
```

Options from `extra_data` are seeded with the **literal string `"canned"`** in the sender
position:

```ts
for (const [i, option] of options.entries()) {
    this.handle_new_option_event("canned", {idx: i, option, type: "new_option"});
}
```

So a three-option `/poll` yields keys `canned,0`, `canned,1`, `canned,2`. zulip-flutter
reimplements this in Dart with the same constant:

```dart
static PollOptionKey optionKey({required int? senderId, required int idx}) =>
  // "canned" is a canonical constant coined by the web client:
  //   https://github.com/zulip/zulip/blob/40f59a05c/web/shared/src/poll_data.ts#L238
  '${senderId ?? 'canned'},$idx';
```

**`idx` is client-local, not global.** Each client keeps `my_idx = 1` and increments after
use, so the first option a user adds gets `idx: 1` and key `"<their id>,1"` — which is
exactly the `"58,1"` in the official docs' example. `idx` is never reconciled with other
users' `idx` values; collisions are impossible because the key pairs it with `sender_id`.
Resync on multi-device: `if (sender_id === this.me && this.my_idx <= idx) this.my_idx = idx + 1;`

### 4.4 Vote semantics

Votes are a **set per option, and a user may vote for several options** — it is checkboxes,
not radio buttons. `vote: 1` adds the sender to the option's voter set, `vote: -1` removes:

```ts
if (vote === 1) { votes.set(sender_id, 1); } else { votes.delete(sender_id); }
```

The *sender* of the vote submessage is the voter. The payload carries no user id; the server
attributes it from the authenticated user. Toggling is computed client-side before sending:

```ts
vote_event(key: string): Vote {
    let vote = 1;
    assert(this.key_to_option.has(key), `option key not found: ${key}`);
    if (this.key_to_option.get(key)!.votes.get(this.me)) { vote = -1; }
    return {type: "vote", key, vote};
}
```

Because it is a set keyed by sender, a duplicate `vote: 1` is idempotent and a `vote: -1` for
a vote you never cast is a no-op. Neither is an error.

### 4.5 Client-side rules with no server enforcement

- **Duplicate option text is dropped.** `/poll` itself can produce duplicates (no server
  validation), so the clients suppress them on replay: web's `is_option_present`, flutter's
  `_existingOptionTexts`. Match this or Zulu will show options the web app hides.
- **Votes for an unknown key are dropped, not errors.** `report_error_function("unknown key
  for poll: " + key)` and flutter's debug-log-and-return.
- **A `question` event from a non-author is dropped.** Both clients re-check client-side even
  though the server also rejects it.
- `MAX_IDX = 1000` is enforced on both sides.

---

## 5. Todo payloads

### 5.1 `extra_data`

[`zerver/lib/widget.py`](https://raw.githubusercontent.com/zulip/zulip/main/zerver/lib/widget.py):

```python
@dataclass
class TodoTaskData:
    task: str
    desc: str

@dataclass
class TodoData:
    task_list_title: str
    tasks: list[TodoTaskData]
```

First line after `/todo` is `task_list_title`; each later line is a task, split on the **first
`": "`** into `task` and `desc` (`desc` is `""` if absent). So
`/todo Today's tasks\nTask 1: This is the first task.\nLast task` gives:

```json
{"widget_type":"todo","extra_data":{"task_list_title":"Today's tasks","tasks":[{"task":"Task 1","desc":"This is the first task."},{"task":"Last task","desc":""}]}}
```

### 5.2 The three todo events

From `validate_todo_data` in
[`zerver/lib/validator.py`](https://raw.githubusercontent.com/zulip/zulip/main/zerver/lib/validator.py)
and [`web/src/todo_data.ts`](https://raw.githubusercontent.com/zulip/zulip/main/web/src/todo_data.ts):

| `type` | Keys | Server checks |
|---|---|---|
| `"new_task"` | `key` (**int**), `task` (str), `desc` (str), `completed` (bool) | `check_int_range(0, MAX_IDX)` |
| `"strike"` | `key` (**string**) | — |
| `"new_task_list_title"` | `title` (str) | **author only** |

```json
{"type":"new_task","key":2,"task":"Buy milk","desc":"2%","completed":false}
{"type":"strike","key":"2,58"}
{"type":"new_task_list_title","title":"This week"}
```

**Two traps here, both confirmed in source.**

1. `key` means different things on the two events. On `new_task` it is the raw `idx` (an int);
   on `strike` it is the composite key (a string). The code comments say so: *"For legacy
   reasons, the inbound idx is called key in the event."*
2. **The composite key is `idx` first, the reverse of polls:**
   ```ts
   const key = idx + "," + sender_id;
   ```
   So a poll option is `"58,1"` but a todo task is `"1,58"`, and initial tasks are `"0,canned"`
   rather than `"canned,0"`. Two separate code paths; do not share one key helper.

Also: web's todo pre-increments (`this.my_idx += 1; ... key: this.my_idx`) where poll
post-increments, so the first user-added task gets `key: 2` while the first user-added poll
option gets `idx: 1`. Harmless, but do not assume the sequences match.

`strike` toggles the task's `completed` flag. Any reader may `new_task` and `strike`.

---

## 6. Sending a submessage

**`POST /api/v1/submessage`** (also reachable as `/json/submessage` for session auth).
Route, from
[`zproject/urls.py`](https://raw.githubusercontent.com/zulip/zulip/main/zproject/urls.py)
line 444, inside `v1_api_and_json_patterns`:

```python
rest_path("submessage", POST=process_submessage),
```

Parameters, from
[`zerver/views/submessage.py`](https://raw.githubusercontent.com/zulip/zulip/main/zerver/views/submessage.py):

| Param | Type | Value |
|---|---|---|
| `message_id` | int | The poll message. |
| `msg_type` | string | `"widget"`. Not validated — echoed into the event verbatim. |
| `content` | string | The JSON-encoded event object from §4.2 / §5.2. |

The web client's exact request
([`web/src/submessage.ts`](https://raw.githubusercontent.com/zulip/zulip/main/web/src/submessage.ts)):

```ts
void channel.post({
    url: "/json/submessage",
    data: {message_id, msg_type: opts.msg_type, content: JSON.stringify(opts.data)},
});
```

zulip-flutter's route
([`lib/api/route/submessage.dart`](https://raw.githubusercontent.com/zulip/zulip-flutter/main/lib/api/route/submessage.dart)):

```dart
return connection.post('sendSubmessage', (_) {}, 'submessage', {
  'message_id': messageId,
  'msg_type': RawParameter(submessageType.toJson()),
  'content': content,
});
```

zulip-mobile's ([`src/api/submessages/sendSubmessage.js`](https://github.com/zulip/zulip-mobile/blob/main/src/api/submessages/sendSubmessage.js)):

```js
apiPost(auth, 'submessage', {message_id: messageId, msg_type: 'widget', content});
```

### 6.1 Permissions — a third-party client may vote

`process_submessage` does exactly three checks:

```python
message = access_message(user_profile, message_id, lock_message=True, is_modifying_message=True)
verify_submessage_sender(message_id=..., message_sender_id=..., submessage_sender_id=...)
...
is_widget_author = message.sender_id == user_profile.id
if widget_type == "poll":  validate_poll_data(poll_data=widget_data, is_widget_author=is_widget_author)
if widget_type == "todo":  validate_todo_data(todo_data=widget_data, is_widget_author=is_widget_author)
```

`verify_submessage_sender`, from
[`zerver/actions/submessage.py`](https://raw.githubusercontent.com/zulip/zulip/main/zerver/actions/submessage.py):

```python
"""Even though our submessage architecture is geared toward
collaboration among all message readers, we still enforce
the first person to attach a submessage to the message
must be the original sender of the message.
"""
if message_sender_id == submessage_sender_id:
    return
if SubMessage.objects.filter(message_id=message_id, sender_id=message_sender_id).exists():
    return
raise JsonableError(_("You cannot attach a submessage to this message."))
```

For any `/poll` message this second branch always passes, because the server itself created
submessage 0 with `sender_id = message.sender_id`. So:

- **Anyone who can read the message may vote and add options.** No role, no bot flag, no
  subscription-to-the-widget concept.
- **Only the message sender may send `question` / `new_task_list_title`.**
- The check exists to stop someone attaching a widget to a *plain* message that has none.

### 6.2 Side effect worth knowing

`do_add_submessage` can silently change the user's topic visibility policy — voting counts as
"participation" for `automatically_follow_topics_policy` and
`automatically_unmute_topics_in_muted_streams_policy`. A vote from Zulu can make the user
start following a topic. Not an error, but do not be surprised by the resulting
`user_topic` event.

---

## 7. `widget_content` on `POST /messages` — cannot create polls

It is a real parameter on `send_message_backend` and is **not** bot-restricted (no
`sender.is_bot` or `can_forge_sender` gate anywhere near it), but it is marked
`documentation_status=DOCUMENTATION_PENDING` and appears nowhere in the API docs or the
OpenAPI spec (`grep widget_content zulip.yaml` → zero hits across 31,902 lines).

It is also useless for our purpose. `check_message` calls `check_widget_content`
([`zerver/lib/validator.py`](https://raw.githubusercontent.com/zulip/zulip/main/zerver/lib/validator.py)),
whose full accept-list is:

```python
    if widget_type == "zform":
        if "type" not in extra_data:
            raise ValidationError("zform is missing type field")
        if extra_data["type"] == "choices":
            ...
            return widget_content
        raise ValidationError("unknown zform type: " + extra_data["type"])

    raise ValidationError("unknown widget type: " + widget_type)
```

`{"widget_type": "poll", ...}` is rejected with `"unknown widget type: poll"`. **Polls and
todo lists can only be created through the slash-command path.**

---

## 8. How `/poll` becomes a widget, and what `content` looks like

Detection happens post-save on **every** message, regardless of sending client
([`zerver/lib/widget.py`](https://raw.githubusercontent.com/zulip/zulip/main/zerver/lib/widget.py)):

```python
def get_widget_data(content: str) -> tuple[str | None, Any]:
    valid_widget_types = ["poll", "todo"]
    tokens = re.split(r"\s+|\n+", content)
    if tokens[0].startswith("/"):
        widget_type = tokens[0].removeprefix("/")
        if widget_type in valid_widget_types:
            remaining_content = content.replace(tokens[0], "", 1)
            extra_data = get_extra_data_from_widget_type(remaining_content, widget_type)
            return widget_type, asdict(extra_data)
    return None, None
```

Only the **first whitespace-delimited token** is inspected and it must be exactly `/poll` or
`/todo`. So **Zulu creates a poll by calling `POST /api/v1/messages` with ordinary
`content`**:

```
/poll What did you drink this morning?
Milk
Tea
Coffee
```

`/poll` alone with no body is valid — it produces `question: ""`, `options: []`, and the web
app opens an inline editor. Options can always be added later by anyone, so a create flow
that sends only the question is legitimate.

### What the message body contains

**The server does not modify `content`.** `widget.py` never touches `message.content`, and
grepping
[`zerver/lib/markdown/__init__.py`](https://raw.githubusercontent.com/zulip/zulip/main/zerver/lib/markdown/__init__.py)
for `poll` / `widget` / `todo` returns nothing. The slash command is rendered as an ordinary
paragraph, roughly:

```html
<p>/poll What did you drink this morning?<br>\nMilk<br>\nTea<br>\nCoffee</p>
```

This is what Zulu shows today. Every Zulip client discards it:

- **web** replaces the node outright
  ([`web/src/widgetize.ts`](https://raw.githubusercontent.com/zulip/zulip/main/web/src/widgetize.ts)):
  ```ts
  const $content_holder = $row.find(".message_content");
  $content_holder.empty().append($widget_elem);
  ```
- **zulip-flutter** never parses the HTML at all
  ([`lib/model/content.dart`](https://raw.githubusercontent.com/zulip/zulip-flutter/main/lib/model/content.dart)):
  ```dart
  ZulipMessageContent parseMessageContent(Message message) {
    final poll = message.poll;
    if (poll != null) return PollContent(poll);
    return parseContent(message.content);
  }
  ```

**Rule for Zulu: if submessage 0 declares a widget we support, do not render
`rendered_content` for that message at all.** Do not try to strip the first line — the
mapping from content back to `extra_data` is lossy (list markers stripped, `": "` splitting,
duplicate options suppressed) and `extra_data` is the source of truth.

Notably, `extra_data` is a **snapshot taken at send time**. Editing the message text later
does not re-derive the widget; the widget only changes through submessage events.

---

## 9. The `submessage` event

Documented at <https://zulip.com/api/get-events>, defined as `SubmessageEvent` in
[`zerver/lib/event_types.py`](https://raw.githubusercontent.com/zulip/zulip/main/zerver/lib/event_types.py):

```python
class SubmessageEvent(BaseEvent):
    type: Literal["submessage"] = "submessage"
    message_id: int
    submessage_id: int
    sender_id: int
    msg_type: str
    content: str
```

Verbatim example from the OpenAPI spec:

```json
{
  "type": "submessage",
  "msg_type": "widget",
  "message_id": 970461,
  "submessage_id": 4737,
  "sender_id": 58,
  "content": "{\"type\":\"vote\",\"key\":\"58,1\",\"vote\":1}",
  "id": 28
}
```

The doc string calls it: *"Event sent when a submessage is added to a message. Submessages are
an **experimental** API used for widgets such as the `/poll` widget in Zulip."*

**Naming trap:** the event's `id` is the **event queue id**, and the submessage's own id is
`submessage_id`. The `submessages[]` array on a message calls that same value `id`. Normalise
on ingest or the ordering will silently break.

There is no other widget event type — no `poll_update`, nothing. Votes, options and question
edits all arrive as `submessage`.

Fan-out: `event_recipient_ids_for_action_on_messages` — the same audience as a reaction or an
edit, i.e. everyone who can see the message, not just participants.

`/register` explicitly does nothing with these
([`zerver/lib/events.py`](https://raw.githubusercontent.com/zulip/zulip/main/zerver/lib/events.py)):

```python
elif event["type"] == "submessage":
    # The client will get submessages with their messages
    pass
```

So the initial state comes from `GET /messages`; the queue only carries deltas.

### Applying one incrementally

Web's `handle_event`
([`web/src/submessage.ts`](https://raw.githubusercontent.com/zulip/zulip/main/web/src/submessage.ts))
is the reference:

1. Look up the message. If absent, **drop it silently** — the comment says
   *"the server can send us events without us having received the original message, since the
   server doesn't track that."*
2. Append `{id: submessage_id, message_id, sender_id, msg_type, content}` to
   `message.submessages`, **de-duplicating by id** (`"Got submessage multiple times: " + id`).
   Do this even when the poll is not currently rendered, so a later render replays a complete
   log.
3. If `msg_type !== "widget"`, warn and stop.
4. `JSON.parse(content)`; on failure warn and stop.
5. Apply the parsed event to the live widget state.

zulip-flutter's `Poll.handleSubmessageEvent` wraps the parse in try/catch and logs rather than
throwing, and `_applyEvent` no-ops on a `question` from a non-owner, a vote for an unknown
key, and an unknown vote op. **Malformed submessages are dropped, never fatal.** Match that;
a hostile or newer-server submessage must not break the message list.

---

## 10. How zulip-flutter and zulip-mobile handle polls

### zulip-flutter — full support, polls only

One file holds both the wire model and the state machine:
[`lib/api/model/submessage.dart`](https://raw.githubusercontent.com/zulip/zulip-flutter/main/lib/api/model/submessage.dart).
There is no `lib/model/submessage.dart`.

- `Submessage { senderId, msgType, content }`. It **deliberately drops `id` and `messageId`** —
  a design choice worth not copying, since Zulu needs `id` for the de-dup in §9.
- `SubmessageType { widget, unknown }`; `WidgetType { poll, unknown }` with `todo` commented
  out as `// TODO(#882)` and `zform` dismissed as a demo.
- `PollEventSubmessageType { newOption, question, vote, unknown }`, `PollVoteOp` mapping
  `add → 1`, `remove → -1`, `unknown → null`.
- `Poll extends ChangeNotifier`; `PollOption { key, text, voters: Set<int> }`.
- "Crunchy-shell validation" on vote keys: split on `,`, first segment must be `"canned"` or
  parse as int, second must parse as int, else throw.
- Rendering and voting in `lib/widgets/poll.dart` — **it votes**, it is not read-only:
  ```dart
  final op = option.voters.contains(store.selfUserId) ? PollVoteOp.remove : PollVoteOp.add;
  unawaited(sendSubmessage(store.connection, messageId: widget.messageId,
    submessageType: SubmessageType.widget,
    content: PollVoteEventSubmessage(key: option.key, op: op)));
  ```
- Live updates bypass the message list: `Poll` is a `ChangeNotifier` and notifies its own
  listeners, so a vote does not rebuild the list.

**Todo lists are not implemented in zulip-flutter** (issue #882). A `/todo` message falls to
`UnsupportedWidgetData` and renders as ordinary content.

### zulip-mobile — full support for both, via a WebView

Renders polls inside its message WebView by importing the web app's own logic
(`import * as poll_data from '@zulip/shared/lib/poll_data'` in `src/webview/html/message.js`),
replaying submessages through `pollData.handle_event(...)` and emitting
`<div class="poll-widget">`. Taps post `{type: 'vote', messageId, key, vote}` out of the
WebView, and `src/webview/handleOutboundEvents.js` calls `api.sendSubmessage(...)`. Falls back
to an **"Interactive message / To use, open on web or desktop"** placeholder when the first
submessage is not a well-formed widget definition — a decent model for Zulu's `/todo` and
`zform` fallback.

---

## 11. Feature gating

Searching the whole of
[`api_docs/changelog.md`](https://raw.githubusercontent.com/zulip/zulip/main/api_docs/changelog.md)
for `submessage`, `widget`, `/poll`, `/todo` yields exactly one relevant entry, at **FL 354**:

> `POST /submessage`: Users can interact with polls and similar widgets in messages in
> unsubscribed private channels that are accessible only via groups that grant content
> access.

That is an access-control widening, not a protocol change. There is **no feature-level gate on
the wire format, on the `submessages` array, on the `submessage` event, or on the
`/submessage` endpoint**. All of it predates the changelog. Zulu can implement this
unconditionally and does not need to branch on `zulip_feature_level`.

The `desc` field on todo tasks and the `question`-editing event are newer than the original
2018 widget work but carry no changelog entry; a very old server may reject them. Since all
client rules are "drop what you do not understand", the failure mode is a 400 on send, which
should be surfaced as a plain error.

---

## 12. What this means for Zulu

Design decisions stay with the ticket, but the protocol forces some shapes:

- **The poll is an append-only log keyed by `(message_id, submessage_id)`.** Storing a derived
  vote tally is a cache, not the record. A `submessages` table of the five raw columns plus a
  unique index on `id` gives idempotent event application for free — which matters, because
  the same submessage arrives twice routinely (once in `GET /messages`, once via the queue).
- **Never trust the array to be sorted.** The API returns it ordered by `(message_id, id)`,
  but events append out of band. Sort by `id` at replay.
- **Two id namespaces.** `submessage_id` on the event, `id` in the array. Normalise at the
  API-client boundary.
- **Optimistic voting is safe.** The toggle is computed client-side and the server is a
  set-add/set-remove, so an optimistic flip that later gets confirmed by the echoed
  `submessage` event converges.
- **A poll message's body must be suppressed at the parse boundary**, the way flutter does it
  — decide before invoking the HTML parser, not by post-processing its output.
- **Todo lists are not free.** Same transport, but a different `extra_data`, a different event
  set, a reversed key encoding, and a `key` field that is an int on one event and a string on
  another. Zulip's own Flutter client skipped them. A placeholder card is a defensible v1.
- **Creating polls costs nothing extra** — it is `POST /messages` with `/poll` text. The work
  is the compose UI, not the protocol.

---

## 13. Could not determine

- **No documented enum for `msg_type`.** Only `"widget"` is ever observed; the DB column is
  free text. If a future Zulip adds a second `msg_type`, nothing in the docs will warn us.
  Mitigation: ignore submessages whose `msg_type != "widget"`, as web does.
- **`POST /submessage` is absent from the OpenAPI spec.** Grepping `zulip.yaml` for a
  `/submessage` path returns nothing, and `https://zulip.com/api/send-submessage` 404s. Its
  parameter contract here comes from the server source and from what flutter/mobile send —
  reliable, but not covered by Zulip's API-stability promise. The docs call the whole
  subsystem "experimental".
- **The feature level at which `/submessage`, the `submessage` event, or the `submessages`
  array were introduced.** No changelog entry exists. All observed Zulip versions have them.
- **Whether `msg_type` values other than `"widget"` are rejected.** `process_submessage` does
  not validate it and stores it verbatim; the resulting row would simply be invisible to
  `get_widget_type`. Untested against a live server.
- **Exact `rendered_content` for a `/poll` message.** Derived from the absence of any
  markdown special-casing rather than from a captured server response. Worth confirming
  against a real server before relying on the precise HTML — though the recommendation
  (suppress the body entirely) makes it moot.
- **`widget_content`'s behaviour on very old servers.** It is `DOCUMENTATION_PENDING` today
  and has never been documented; irrelevant to us, since it cannot create polls anyway.

---

## 14. Source index

Server (`zulip/zulip`, `main`):
- [`zerver/lib/widget.py`](https://raw.githubusercontent.com/zulip/zulip/main/zerver/lib/widget.py)
- [`zerver/models/messages.py`](https://raw.githubusercontent.com/zulip/zulip/main/zerver/models/messages.py)
- [`zerver/views/submessage.py`](https://raw.githubusercontent.com/zulip/zulip/main/zerver/views/submessage.py)
- [`zerver/actions/submessage.py`](https://raw.githubusercontent.com/zulip/zulip/main/zerver/actions/submessage.py)
- [`zerver/lib/validator.py`](https://raw.githubusercontent.com/zulip/zulip/main/zerver/lib/validator.py)
- [`zerver/lib/message_cache.py`](https://raw.githubusercontent.com/zulip/zulip/main/zerver/lib/message_cache.py)
- [`zerver/lib/events.py`](https://raw.githubusercontent.com/zulip/zulip/main/zerver/lib/events.py)
- [`zproject/urls.py`](https://raw.githubusercontent.com/zulip/zulip/main/zproject/urls.py)
- [`web/src/poll_data.ts`](https://raw.githubusercontent.com/zulip/zulip/main/web/src/poll_data.ts)
- [`web/src/todo_data.ts`](https://raw.githubusercontent.com/zulip/zulip/main/web/src/todo_data.ts)
- [`web/src/submessage.ts`](https://raw.githubusercontent.com/zulip/zulip/main/web/src/submessage.ts)
- [`web/src/widgetize.ts`](https://raw.githubusercontent.com/zulip/zulip/main/web/src/widgetize.ts)
- [`web/src/widget_schema.ts`](https://raw.githubusercontent.com/zulip/zulip/main/web/src/widget_schema.ts)
- [`api_docs/changelog.md`](https://raw.githubusercontent.com/zulip/zulip/main/api_docs/changelog.md)

Official docs:
- <https://zulip.com/api/get-messages>
- <https://zulip.com/api/get-events>
- <https://zulip.com/api/send-message>
- <https://zulip.com/api/changelog>
- <https://zulip.com/help/create-a-poll>
- <https://zulip.com/help/collaborative-to-do-lists>

Clients:
- [`zulip-flutter lib/api/model/submessage.dart`](https://raw.githubusercontent.com/zulip/zulip-flutter/main/lib/api/model/submessage.dart)
- [`zulip-flutter lib/api/route/submessage.dart`](https://raw.githubusercontent.com/zulip/zulip-flutter/main/lib/api/route/submessage.dart)
- [`zulip-flutter lib/widgets/poll.dart`](https://raw.githubusercontent.com/zulip/zulip-flutter/main/lib/widgets/poll.dart)
- [`zulip-flutter lib/model/content.dart`](https://raw.githubusercontent.com/zulip/zulip-flutter/main/lib/model/content.dart)
- [`zulip-mobile src/api/submessages/sendSubmessage.js`](https://github.com/zulip/zulip-mobile/blob/main/src/api/submessages/sendSubmessage.js)
- [`zulip-mobile src/webview/html/message.js`](https://github.com/zulip/zulip-mobile/blob/main/src/webview/html/message.js)
