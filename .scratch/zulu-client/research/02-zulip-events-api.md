# Zulip real-time events API

Research for issue `02-zulip-events-api.md`. All claims cite a primary source: the official API docs
at zulip.com/api, the OpenAPI spec in `zulip/zulip` (`zerver/openapi/zulip.yaml`), the server source,
and the official clients (`zulip/zulip-flutter`, `zulip/zulip-mobile`).

Server source read at `main` on 2026-09-22.

## 1. The two endpoints

| Endpoint | Purpose |
| --- | --- |
| `POST /api/v1/register` | Allocate an event queue and fetch the initial state snapshot in one atomic call. |
| `GET /api/v1/events` | Long-poll the queue for new events. |
| `DELETE /api/v1/events` | Delete a queue (`queue_id` in body). |

Source: <https://zulip.com/api/register-queue>, <https://zulip.com/api/get-events>,
<https://zulip.com/api/delete-queue>, `zerver/openapi/zulip.yaml` (`/events` path, `get` + `delete`).

The register-then-poll design exists specifically to remove races between "fetch state" and "start
listening". The server allocates the queue first, fetches state non-atomically via
`fetch_initial_state_data`, then replays any events that landed in the queue during the fetch onto
that state via `apply_events` before returning. So the snapshot you get back is already consistent
with `last_event_id`.

Source: <https://zulip.readthedocs.io/en/latest/subsystems/events-system.html>,
`zerver/views/events_register.py`, `zerver/lib/events.py`.

`GET /events` will also implicitly register a queue if you pass `/register` parameters and no
`queue_id`. Do not rely on this; it hides the snapshot.

Source: `zerver/openapi/zulip.yaml`, `x-parameter-description` on `/events`.

## 2. `POST /api/v1/register` parameters

| Parameter | Type | Default | Notes |
| --- | --- | --- | --- |
| `apply_markdown` | bool | **`false`** | `true` returns `content` as rendered HTML; the default returns the raw Markdown the user typed. Zulu must pass `true` explicitly. |
| `client_gravatar` | bool | `true` (authed), `false` (unauth) | If `true`, `avatar_url` is only sent when there is a real Zulip avatar and is `null` for gravatar users; the client derives the gravatar URL. "This option significantly reduces the compressed size of user data." Passing `true` unauthenticated is an error. |
| `slim_presence` | bool | `false` | `presences` keyed by user ID, modern per-user format. New in Zulip 3.0 (no feature level; API was unstable). |
| `presence_history_limit_days` | int | `14` | Oldest presence data fetched is at most N days old. New in feature level 288. |
| `event_types` | string[] | all | Which event types the queue delivers. |
| `fetch_event_types` | string[] | value of `event_types` | Which state keys the snapshot includes. |
| `all_public_streams` | bool | `false` | Also receive `message` events for public channels the user is not subscribed to. |
| `narrow` | (string[])[] | `[]` | Filter `message` events to a narrow. |
| `client_capabilities` | object | `{"notification_settings_null": false}` | Backwards-compat switches; see below. Every key defaults to `false`. |
| `idle_queue_timeout` | int \| `"mobile"` | `600` | Seconds the queue survives without polling. New in feature level 481. |
| `include_subscribers` | `"true"`/`"false"`/`"partial"` | `"false"` | Include subscriber ID lists on every channel. See below. |

`include_subscribers` deserves its own note, verbatim from the spec: "Client apps supporting
organizations with many thousands of users should not pass `true`, because the full subscriber
matrix may be several megabytes of data. The `partial` value, combined with the `subscriber_count`
and fetching subscribers for individual channels as needed, is recommended." With `partial`, some
channels return `partial_subscribers` instead of `subscribers`; the server guarantees a complete
`subscribers` list for channels with fewer than 250 subscribers, and guarantees that
`partial_subscribers` includes all bots and all users active in the last 14 days. `partial` is new
in Zulip 11.0, feature level 412 — on older servers Zulu must choose between `true` (potentially
megabytes) and `false`.

Response top-level fields: `queue_id` (string, `null` only for unauthenticated public-access realms),
`last_event_id` (int, the value to pass to the first `GET /events`), `idle_queue_timeout_secs`,
`zulip_feature_level`, `zulip_version`, plus every requested state key.

Source: <https://zulip.com/api/register-queue>, `zerver/openapi/zulip.yaml` lines ~18370-18800.

### `event_types` vs `fetch_event_types`

- `event_types` controls the *stream*: which events the queue will deliver.
- `fetch_event_types` controls the *snapshot*: which state keys the `/register` response contains.
- If `fetch_event_types` is omitted it defaults to `event_types`. If both are omitted, you get
  everything, for both.
- Unsupported types are ignored rather than erroring, explicitly so a client can support several
  server versions: "Event types not supported by the server are ignored, in order to simplify the
  implementation of client apps that support multiple server versions."

Source: `zerver/openapi/zulip.yaml`, `fetch_event_types` description.

The docs are blunt about the cost of not filtering: "Before using your client in production, you
should set appropriate `event_types` and `fetch_event_types` filters so that your client only
requests the data it needs. A few minutes doing this often saves 90% of the total bandwidth and
other resources consumed by a client using this API."

Source: <https://zulip.com/api/register-queue> (endpoint description).

Server-side filtering is exact: `ClientDescriptor.accepts_event()` drops any event whose `type` is
not in `event_types`.

Source: `zerver/tornado/event_queue.py`, `accepts_event`.

### `narrow` and `all_public_streams`

`narrow` on `/register` is **not** the same thing as `narrow` on `GET /messages`: "this narrow
parameter is simply a filter on messages that the user receives through their channel subscriptions
(or because they are a recipient of a direct message)." A narrow of `[["channel", "Denmark"]]` gets
you nothing at all if the user is not subscribed to Denmark.

`all_public_streams: true` additionally delivers `message` events for public channels the user is
not subscribed to. Intended for bots.

Neither is useful for Zulu: the app wants every message the user can see, unfiltered.

Source: `zerver/openapi/zulip.yaml`, `Narrow` and `AllPublicChannels` schemas.

### `client_capabilities`

These are backwards-compatibility switches. Each one, when set, changes the shape of the snapshot
and/or of events. Relevant ones and the feature level that introduced them:

| Capability | Effect | Since |
| --- | --- | --- |
| `notification_settings_null` | Client handles `null` channel-level notification settings (meaning "inherit the global setting"). | Zulip 2.1 |
| `bulk_message_deletion` | `delete_message` events carry `message_ids` (a batch) instead of one `message_id`. | FL 13 |
| `user_avatar_url_field_optional` | Server may omit `avatar_url` on user objects; client uses `GET /avatar/{user_id}`. "This is an important optimization in organizations with 10,000s of users." | FL 18 |
| `stream_typing_notifications` | Receive channel (not just DM) `typing` events. Without it the server drops them. | FL 58 |
| `user_settings_object` | Get `user_settings` events. Has no effect on modern servers; before FL 439, setting it `false` made the server *additionally* send legacy `update_display_settings` / `update_global_notifications`. | FL 89 |
| `linkifier_url_template` | Accept RFC 6570 URL-template linkifiers. Without it, `realm_linkifiers` comes back empty. | FL 176 |
| `user_list_incomplete` | Client tolerates an incomplete user DB (inaccessible users omitted). | FL 232 |
| `include_deactivated_groups` | Client filters deactivated user groups itself. | FL 294 |
| `archived_channels` | Receive archived channels in `stream`/`subscription` data. | FL 315 |
| `empty_topic_name` | Client handles `""` as a real topic name; otherwise the server substitutes `realm_empty_topic_display_name`. | FL 334 |
| `simplified_presence_events` | `presence` events use the modern `presences` field. | FL 419 |
| `individual_emoji_changes` | `realm_emoji/add` and `realm_emoji/edit` events instead of a full `realm_emoji/update` dump. | FL 491 |

Source: `zerver/openapi/zulip.yaml`, `client_capabilities` description block (lines ~18540-18690);
mirrored at <https://zulip.com/api/register-queue>.

Note the `stream_typing_notifications` gate is enforced in `accepts_event`: a `typing` event with a
`stream_id` is only delivered if the capability is on.

Source: `zerver/tornado/event_queue.py`, `accepts_event`.

### What the official Flutter client actually sends

`zulip-flutter` hard-codes its register parameters, with a comment explaining why: "those parameters
control the shape of the data that the server returns, mostly in enabling modern rather than legacy
APIs."

```dart
connection.post('registerQueue', InitialSnapshot.fromJson, 'register', {
  'idle_queue_timeout': ?idleQueueTimeout,
  // event_types and fetch_event_types omitted; get all events and all data
  'apply_markdown': true,
  'client_gravatar': false, // TODO(#255): turn on
  // 'include_subscribers': false, // the default
  'slim_presence': true,
  'client_capabilities': {
    'notification_settings_null': true,
    'bulk_message_deletion': true,
    'user_avatar_url_field_optional': true,
    'stream_typing_notifications': true,
    'user_settings_object': true,
    'include_deactivated_groups': true,
    'empty_topic_name': true,
    'individual_emoji_changes': true,
  },
});
```

Source: <https://github.com/zulip/zulip-flutter/blob/main/lib/api/route/events.dart>.

Two things worth copying and one worth not: copy the capability set and `apply_markdown: true`;
note that Flutter deliberately does **not** filter `event_types`, contradicting the docs' advice,
because the app genuinely wants everything. Zulu's *app* queue is in the same position. Zulu's
*notification service* queue is not: it should filter down to roughly
`["message", "update_message", "delete_message", "update_message_flags", "user_settings",
"user_topic", "subscription", "realm_user"]` so the server does not ship it presence and typing
traffic it will discard.

### Server version floor

`zulip-flutter` defines two floors, which is a reasonable model for Zulu:

- `kMinAllowedZulipFeatureLevel = 277` — below this, refuse to connect at all.
- `kMinSupportedZulipVersion = '10.0'`, `kMinSupportedZulipFeatureLevel = 371` — the supported
  floor, per Zulip's policy that all supported versions are less than 18 months old.

Source: <https://github.com/zulip/zulip-flutter/blob/main/lib/api/core.dart>;
<https://zulip.readthedocs.io/en/latest/overview/release-lifecycle.html#client-apps>.

"Works against ANY Zulip server" in practice means picking a feature-level floor and gating the
newer options (`idle_queue_timeout` FL 481, `include_subscribers=partial` FL 412,
`event_queue_longpoll_timeout_seconds` FL 74) on `zulip_feature_level` from the register response.

## 3. `GET /api/v1/events` — the long-poll loop

Query parameters:

- `queue_id` (required) — from `/register`.
- `last_event_id` (int) — "The highest event ID in this queue that you've received and wish to
  acknowledge." Events at or below this ID are deleted server-side.
- `dont_block` (bool, default `false`) — if `true`, return immediately with whatever is queued
  (possibly an empty `events` array).

Response: `{"result": "success", "msg": "", "queue_id": "...", "events": [ {"id": N, "type": "...", ...}, ... ]}`.

Caveat from the Flutter client's model: "TODO(server): Docs say queueId required; empirically
sometimes missing." Treat `queue_id` in the response as optional.

Source: <https://github.com/zulip/zulip-flutter/blob/main/lib/api/route/events.dart>, `GetEventsResult`.

Ordering guarantee, verbatim from the docs: "Event IDs are guaranteed to be increasing, but they are
not guaranteed to be consecutive." So track the max ID seen; never assume `+1`.

Event IDs are per-queue: each `ClientDescriptor` owns an `EventQueue` with a private `next_event_id`
starting at 0. IDs mean nothing across queues. The gaps come from **virtual events**: `flags/*`
events (except `flags/remove/read`) are compressed inside the queue, the merged event takes the
newest ID, and the intermediate IDs never appear.

Source: `zerver/tornado/event_queue.py` (`EventQueue.push`, `virtual_events`).

Delivery is at-least-once in transit, deduplicated by your own `last_event_id`: if your
acknowledging request is lost you will be re-sent events you already applied. The developer docs:
"If network failures were impossible, the `last_event_id` parameter in the protocol would not be
required, but it is important for enabling exactly-once delivery in the presence of potential
failures." Make event handlers idempotent, or drop `id <= lastEventId`.

Source: <https://zulip.readthedocs.io/en/latest/subsystems/events-system.html>.

Two `last_event_id` validation errors, both plain 400 `BAD_REQUEST` rather than
`BAD_EVENT_QUEUE_ID`:

- `"An event newer than {event_id} has already been pruned!"` — you went backwards.
- `"Event {event_id} was not in this queue"` — you acknowledged an ID this queue never issued.

Source: `zerver/tornado/event_queue.py`, `fetch_events`.

With `dont_block=false` the server **never** returns an empty `events` array: it holds the socket
open and eventually returns a heartbeat. An empty array only happens with `dont_block=true`. nginx
allows the long-poll location up to `proxy_read_timeout 1200`.

Source: `zerver/tornado/event_queue.py` (`fetch_events` returns `dict(type="async")`),
`puppet/zulip/files/nginx/zulip-include-common/proxy_longpolling`.

### Other error responses on `/events`

| Status | `code` | Cause |
| --- | --- | --- |
| 400 | `BAD_EVENT_QUEUE_ID` | Queue GC'd, unknown, or owned by a different user (same error either way — no info leak). |
| 400 | `BAD_REQUEST` | Missing `queue_id`/`last_event_id`, or the two pruning errors above. |
| 401 | `UNAUTHORIZED` | Invalid or revoked API key. |
| 404 | — | `{"result":"error","msg":"Not found"}`. |
| 429 | `RATE_LIMIT_HIT` | Sets a **`Retry-After`** header plus `X-RateLimit-Limit`/`-Remaining`/`-Reset`. |
| 500 | — | `{"result":"error","msg":"Internal server error"}`. |

Source: `zerver/lib/exceptions.py`, `zerver/tornado/exceptions.py`, `zerver/tornado/views.py`,
`zerver/middleware.py` (`RateLimitMiddleware`).

Neither `zulip-flutter` nor `zulip-mobile` currently honours `Retry-After`; both just use their own
jittered backoff. Flutter has this flagged as a TODO. Zulu should do better and respect the header.

Source: <https://zulip.com/api/get-events>, `zerver/openapi/zulip.yaml` `/events` `get`.

### Timeouts and heartbeats

- The server holds the request open until an event is available. If nothing arrives, it emits a
  `heartbeat` event, which ends the long poll.
- `HEARTBEAT_MIN_FREQ_SECS = 45`, and the actual interval is `45 + random.randint(0, 10)` seconds
  per connection — so 45-55s. The comment in the source explains the 55s cap: "to deal with crappy
  home wireless routers that kill 'inactive' http connections."
- Heartbeat event shape: `{"type": "heartbeat", "id": N}` (`create_heartbeat_event`).
- Client HTTP timeout: use `event_queue_longpoll_timeout_seconds` from the `/register` response
  (present when `realm` is in `fetch_event_types`). "This is guaranteed to be somewhat greater than
  the heartbeat timeout." **New in Zulip 5.0 / feature level 74; on older servers it is absent and
  clients should fall back to 90 seconds.**

Source: `zerver/tornado/event_queue.py` (`HEARTBEAT_MIN_FREQ_SECS`, `connect_handler`,
`create_heartbeat_event`); `zerver/openapi/zulip.yaml` `event_queue_longpoll_timeout_seconds`;
<https://zulip.com/api/get-events> endpoint description.

Practical rule for Zulu: set the HTTP request timeout to `event_queue_longpoll_timeout_seconds`
(fallback 90s). If the poll returns nothing at all past that, treat the connection as dead and
reconnect; do not treat a heartbeat as an error.

## 4. Queue lifetime, garbage collection, and `BAD_EVENT_QUEUE_ID`

Constants, from `zerver/tornado/event_queue.py`:

| Constant | Value | Meaning |
| --- | --- | --- |
| `DEFAULT_EVENT_QUEUE_TIMEOUT_SECS` | `60 * 10` (10 min) | Default idle lifetime of a queue. |
| `MOBILE_EVENT_QUEUE_TIMEOUT_SECS` | `12 * 60 * 60` (12 h) | Used when `idle_queue_timeout="mobile"`. |
| `MAX_QUEUE_TIMEOUT_SECS` | `7 * 24 * 60 * 60` (7 days) | Hard cap; requested values are `min()`ed against it. |
| `EVENT_QUEUE_GC_FREQ_MSECS` | `1000 * 60` (1 min) | How often the GC scan runs. |
| `EVENT_QUEUE_OFFLINE_TIMEOUT_SECS` | `60 * 10` (10 min) | How long without polling before the user counts as offline for notification purposes. |
| `HEARTBEAT_MIN_FREQ_SECS` | `45` | Heartbeat floor. |

The idle clock is `last_connection_time`, set in `connect_handler` — i.e. it is refreshed every time
you open a poll, not every time you receive an event. `expired()` is
`current_handler_id is None and now - last_connection_time >= queue_timeout`.

Source: `zerver/tornado/event_queue.py`
(<https://github.com/zulip/zulip/blob/main/zerver/tornado/event_queue.py>).

Historical note on the source comment: "The idle timeout used to be a week, but we found that in
that situation, queues from dead browser sessions would grow quite large due to the accumulation of
message data in those queues."

### `idle_queue_timeout` is new

`idle_queue_timeout` (request) and `idle_queue_timeout_secs` (response) are **new in Zulip 12.0,
feature level 481**. Against any older server the queue lifetime is fixed at 10 minutes and there is
no way to ask for more. Zulu must therefore assume a 10-minute idle window on the majority of
deployed servers and treat `idle_queue_timeout` as a bonus when `zulip_feature_level >= 481`.

Source: `zerver/openapi/zulip.yaml` (`idle_queue_timeout` description and register `**Changes**`
block), <https://zulip.com/api/register-queue>.

### The error

HTTP **400**, body:

```json
{
  "code": "BAD_EVENT_QUEUE_ID",
  "msg": "Bad event queue ID: fb67bf8a-c031-47cc-84cf-ed80accacda8",
  "queue_id": "fb67bf8a-c031-47cc-84cf-ed80accacda8",
  "result": "error"
}
```

Source: `zerver/openapi/zulip.yaml`, `BadEventQueueIdError` schema; `/events` `400` response.

Docs on required behaviour: "This error occurs if the target event queue has been garbage collected.
A compliant client will handle this error by re-initializing itself (e.g. a Zulip web app browser
window will reload in this case)."

And from the developer docs: "If the client returns, it will receive a 'queue not found' error when
requesting events; its handler for this case should just restart the client / reload the browser so
that it refetches initial data the same way it would on startup."

Source: `zerver/openapi/zulip.yaml`; <https://zulip.readthedocs.io/en/latest/subsystems/events-system.html>.

### What a robust consumer looks like: `zulip-flutter`'s `UpdateMachine.poll`

The loop in `lib/model/store.dart` is the reference implementation. Its shape:

```dart
while (true) {
  result = await getEvents(store.connection,
    queueId: store.queueId,
    lastEventId: lastEventId,
    dontBlock: store.isRecoveringEventStream ? true : null,
    timeout: store.eventQueueLongpollTimeout);
  for (final event in result.events) { await store.handleEvent(event); }
  if (events.isNotEmpty) { lastEventId = events.last.id; }
}
```

Notable decisions, each with the reasoning from the source:

- `lastEventId = events.last.id` — take the last event's ID, relying on the increasing-but-not-
  consecutive guarantee.
- `dontBlock: true` while recovering: "If the UI shows we're busy getting event-polling to work
  again, ask the server to tell us immediately that it's working again, rather than waiting for an
  event, which could take up to a minute in the case of a heartbeat event."
- An explicit client-side `timeout` equal to `event_queue_longpoll_timeout_seconds`: "If the request
  outlives this, assume the connection is dead even if it still looks open; give up on it and retry."

Error triage is split in two (`_handlePollRequestError` vs `_handlePollError`):

| Error | Action |
| --- | --- |
| `NetworkException` (connection failed) | Backoff, retry **same queue**. Not reported to user. Backoff is aborted early when the app wakes. |
| Other `NetworkException`, `Server5xxException` | Backoff, retry same queue, report to user. |
| HTTP 429 / `RATE_LIMIT_HIT` | Backoff, retry same queue, report to user. |
| `BAD_EVENT_QUEUE_ID` | Rethrow → tear down and **re-register from scratch**. Treated as normal, not a bug. |
| Any other `ZulipApiException`, malformed response | Re-register from scratch, with an extra 60s-max backoff, and log as a bug. |
| Exception thrown while *applying* an event | Re-register from scratch. The comment: "We can't just continue with the next event, because our state may be garbled due to failing to apply this one." |

Backoff parameters (`lib/api/backoff.dart`): `firstBound` 100 ms, `maxBound` 10 s, `base` 2, giving
bounds of 0.1, 0.2, 0.4, 0.8, 1.6, 3.2, 6.4, 10, 10, ... seconds, with **full jitter** — the actual
wait is uniform random on `[0, bound]`. The "unexpected error" machine uses `maxBound` 60 s and is
static so it persists across store reloads, to avoid a retry storm.

Source: <https://github.com/zulip/zulip-flutter/blob/main/lib/model/store.dart>,
<https://github.com/zulip/zulip-flutter/blob/main/lib/api/backoff.dart>.

The "re-register on any event-application failure" rule is the one worth internalizing for Zulu's
GRDB store: a bad event is not recoverable in place, because your invariants may already be broken.

### Recovery rule for a local-first store

There is **no** partial-resync mechanism. `last_event_id` is only meaningful within one queue's
lifetime; a new queue starts a fresh ID space. Recovery is: `POST /register` again, take the new
snapshot as ground truth, and reconcile the local SQLite store against it.

Consequences for Zulu's GRDB store:

- Treat the register snapshot as authoritative for everything it covers (subscriptions, unreads,
  user settings, muted topics, presence).
- Locally cached *messages* are not covered by the snapshot; after re-register, refetch the tail via
  `GET /api/v1/messages` (`anchor=newest`) and backfill until you reach a message ID you already
  have. The snapshot's `max_message_id` gives you the target.
- Anything whose mutation you might have missed while the queue was dead (edits, deletions,
  reactions, flag changes on old messages) can only be recovered by refetching those messages.

## 5. Multiple concurrent queues per API key

**Yes.** Nothing in the API or the server ties a queue to a credential or limits the count per user.
`clients` is a plain dict of queue-id to `ClientDescriptor`, and `get_client_descriptors_for_user`
returns a list — the code is written throughout to expect many queues per user (every browser tab
plus every mobile app is its own queue).

Source: `zerver/tornado/event_queue.py` (`clients`, `get_client_descriptors_for_user`,
`do_gc_event_queues`); <https://zulip.readthedocs.io/en/latest/subsystems/events-system.html>
("one queue per connected client (browser tab, mobile app, or API bot)").

So the Zulu app and the Go notification service can each hold their own queue on the same API key.
There is one important interaction, below.

I found **no per-user or per-credential cap on the number of queues** anywhere in
`zerver/tornado/event_queue.py`. The only relevant throttle is the generic API rate limit,
`DEFAULT_RATE_LIMITING_RULES["api_by_user"] = [(60, 200)]` — 200 requests per minute per user. A
long-poll that returns roughly once a minute is nowhere near that, even with several queues, but a
tight re-register loop after an error would be, hence the mandatory backoff.

Source: <https://github.com/zulip/zulip/blob/main/zproject/default_settings.py>
(`DEFAULT_RATE_LIMITING_RULES`).

Practical caution: queues hold undelivered event data in Tornado's memory, and the server comment on
`DEFAULT_EVENT_QUEUE_TIMEOUT_SECS` says long-lived abandoned queues "would grow quite large due to
the accumulation of message data." Zulu should `DELETE /api/v1/events` on clean shutdown rather than
leaving queues to time out, and should not open more than the two it needs. Note the in-tree TODO
that `DELETE /events` returns 200 before the queue is actually removed on a remote Tornado shard, so
a `GET /events` immediately after a successful delete can still succeed.

Source: `zerver/tornado/views.py`.

### Second gotcha: there is a known duplicate-notification bug with multiple queues

From `do_gc_event_queues` in `zerver/tornado/event_queue.py`:

> "TODO: If a user has multiple queues and all of them are being removed in the same sweep,
> `last_client_for_user` will be True for all of them, causing `missedmessage_hook` to enqueue
> duplicate notifications. Push notifications are deduplicated by the
> `active_mobile_push_notification` flag on UserMessage, but email notifications are not —
> duplicate `ScheduledMessageNotificationEmail` rows will be created."

So if the Zulu app queue and the notification-service queue die in the same GC sweep, the user can
get duplicate missed-message emails from the server. Another argument for staggering the two
queues' lifetimes, or for not having the notification service request `message` events at all if
Zulu wants stock server notifications to keep working.

### Gotcha: an actively-polling queue makes the user look "online"

`receiver_is_off_zulip(user_profile_id)` returns `True` only when the user has **no** active,
non-offline, message-accepting event queue:

```python
def receiver_is_off_zulip(user_profile_id: int) -> bool:
    # If a user has no active, non-offline message-receiving event
    # queues, they've got no open Zulip session so we notify them.
    all_client_descriptors = get_client_descriptors_for_user(user_profile_id)
    not_offline_message_event_queues = [
        client
        for client in all_client_descriptors
        if client.accepts_messages() and not client.offline
    ]
    off_zulip = len(not_offline_message_event_queues) == 0
    return off_zulip
```

`accepts_messages()` is `self.event_types is None or "message" in self.event_types`.

Source: `zerver/tornado/event_queue.py`.

Implication: if the Go notification service holds a queue that requests `message` events and polls
it continuously, the Zulip server will consider the user permanently online and will **suppress its
own push/email missed-message notifications** for that user (unless the user has
`enable_online_push_notifications` on, which is documented as "Enable mobile notification for direct
messages and @-mentions received when the user is online").

Source: `zerver/tornado/event_queue.py` (`receiver_is_off_zulip`, `missedmessage_hook`,
`mark_clients_offline`); `zerver/openapi/zulip.yaml` (`enable_online_push_notifications`).

For Zulu this is arguably the desired outcome — Zulu's own service is doing the notifying — but it
must be a deliberate decision, and it means a user cannot run Zulu's notification service and rely
on stock Zulip push at the same time.

Related: `missedmessage_hook` fires when a queue is marked offline (after
`EVENT_QUEUE_OFFLINE_TIMEOUT_SECS` = 10 minutes without polling) **or** GC'd, and only if it was the
last active queue for the user. For long-lived (e.g. `"mobile"`) queues the hook fires at the
10-minute offline mark rather than waiting for the full `queue_timeout`, so stock notifications are
delayed by at most ~10 minutes rather than 12 hours.

Source: `zerver/tornado/event_queue.py`, `missedmessage_hook` docstring and `mark_clients_offline`.


## 6. Message-family events

Every event has `id` (increasing per queue) and `type`. Sources for this section:
<https://zulip.com/api/get-events>, `zerver/openapi/zulip.yaml` (`/events` path, event schemas),
`zerver/lib/event_types.py` (the authoritative pydantic models),
`zerver/tornado/event_queue.py`, `zerver/actions/message_edit.py`,
`zerver/actions/message_flags.py`, `zerver/lib/retention.py`.

### `message`

```json
{
  "type": "message",
  "id": 1,
  "flags": [],
  "message": { "id": 31, "sender_id": 10, "content": "<p>…</p>", "recipient_id": 23,
               "timestamp": 1594825416, "client": "test suite", "subject": "test",
               "topic_links": [], "is_me_message": false, "reactions": [], "submessages": [],
               "sender_full_name": "King Hamlet", "sender_email": "user10@zulip.testserver",
               "sender_realm_str": "zulip", "display_recipient": "Denmark",
               "type": "stream", "stream_id": 1, "avatar_url": null,
               "content_type": "text/html" }
}
```

The `message` object in an event is a restricted schema (`MessagesEvent`), not the full message
object from `GET /messages`. Fields: `id`, `type` (`stream`/`private`), `sender_id`, `sender_email`,
`sender_full_name`, `sender_realm_str`, `content`, `content_type`, `timestamp`, `client`, `subject`,
`topic_links`, `stream_id` (channel messages only), `display_recipient`, `recipient_id`,
`avatar_url`, `is_me_message`, `reactions`, `submessages`. `edit_history`, `last_edit_timestamp` and
`last_moved_timestamp` are in the general schema but do not appear on a `message` event — a
newly-sent message has never been edited.

`content_type` is `text/html` when `apply_markdown: true`, else `text/x-markdown`.

**Do not assume a new message is unread.** The docs are explicit: "Clients should inspect the flags
field rather than assuming that new messages are unread; muted users, messages sent by the current
user, and more subtle scenarios can result in a new message that the server has already marked as
read for the user."

`local_message_id` (string) appears only on the *sender's own* queue, and only when the send call
passed both `local_id` and `queue_id` to `POST /messages`. It is the client's `local_id` echoed
back, uninspected. This is the local-echo reconciliation hook Zulu needs.

Source: `zerver/tornado/event_queue.py`:

```python
if is_sender:
    local_message_id = event_template.get("local_id", None)
    if local_message_id is not None:
        user_event["local_message_id"] = local_message_id
```

`internal_data` (the server's notification bookkeeping) is stripped before delivery. Never expect it.

### `update_message`

Covers three distinct things: content edits, topic/channel moves, and rendering-only re-renders
(inline URL previews). Always present: `type`, `id`, `user_id`, `message_id`, `message_ids`,
`flags`, `edit_timestamp`, `rendering_only`.

| Field | Present when |
| --- | --- |
| `user_id` | Always; **`null`** for rendering-only updates. |
| `rendering_only` | Always (FL 114+). `true` = server re-render, not a user edit. |
| `message_id` | The one message whose **content** changed. |
| `message_ids` | Every message a **move** applies to. Always includes `message_id`. Sorted since FL 393. |
| `flags` | The receiving user's flags for `message_id` **after** the edit. |
| `stream_id` | Message was in a channel. This is the **pre-edit** channel. Present for all channel edits since FL 112. |
| `new_stream_id` | Channel move. Post-edit channel. |
| `propagate_mode` | A move happened. `change_one` / `change_later` / `change_all`. |
| `orig_subject` | A move happened. Pre-edit topic. |
| `subject`, `topic_links` | The **topic** changed. Absent when moving channels but keeping the topic name. |
| `orig_content`, `orig_rendered_content` | Content changed. |
| `content`, `rendered_content` | Content changed, or rendering-only. |
| `is_me_message` | Content changed. |

There is **no** `stream_ids` field. The plural array is `message_ids`.

Dispatch rules a client should implement (these mirror the server's own tests):

- Rendering-only: `rendering_only === true` (FL 114+); on older servers, `user_id` key absent.
- Content edit: `"orig_content" in event` — this is literally the server's test
  (`event_queue.py`: `content_edited = "orig_content" in event_template`). Apply to `message_id`
  **only**, never to the rest of `message_ids`.
- Topic move: `"subject" in event`.
- Channel move: `"new_stream_id" in event`.
- Channel move keeping the topic name: `new_stream_id` present, `subject` absent, `orig_subject`
  present.
- Content + topic can arrive together. Content + channel cannot; the server rejects it.

`propagate_mode` is **not** how you compute the affected set — the server already resolved it into
`message_ids` (`message_edit.py`: `event["message_ids"] = sorted(changed_message_ids)`). It exists
for navigation UX: if the user is viewing the old topic and the mode is `change_later` or
`change_all`, the web app follows the move and retargets the compose box.

The docs guarantee: these messages "are guaranteed to have all been previously sent to channel
`stream_id` with topic `orig_subject`, and have been moved to `new_stream_id` with topic `subject`
(if those fields are present)." Clients must update all cached history for `message_ids` **including
`unread_msgs` bookkeeping for messages they do not have locally**.

Users who lose access because of a cross-channel move get a `delete_message` instead.

### `delete_message`

```json
{"type": "delete_message", "message_ids": [37, 38], "message_type": "stream",
 "stream_id": 5, "topic": "test", "id": 0}
```

`message_type` is `"stream"` or `"private"` and is always present. `stream_id` and `topic` appear
only for `"stream"`. With the `bulk_message_deletion` capability you get `message_ids` (sorted);
without it the server loops and sends N events each carrying a scalar `message_id` and no
`message_ids`:

```python
if client.bulk_message_deletion:
    client.add_event(deletion_event)
    continue
for message_id in deletion_event["message_ids"]:
    compatibility_event = dict(deletion_event)
    compatibility_event["message_id"] = message_id
    del compatibility_event["message_ids"]
    client.add_event(compatibility_event)
```

Source: `zerver/tornado/event_queue.py`.

There is **no `user_ids` field** on `delete_message` for DMs. The historical `sender_id` /
`recipient_id` fields were removed at FL 77. A DM deletion tells you nothing about who was in it;
the client must look the message up locally.

Also sent when a user *loses access* to a message rather than the message being deleted (e.g. moved
to a channel they cannot see). Retention-policy deletions only generate events from FL 452 onward;
before that they were silent and clients showed stale messages until reload.

### `reaction`

```json
{"type": "reaction", "op": "add", "user_id": 10, "message_id": 32,
 "emoji_name": "tada", "emoji_code": "1f389", "reaction_type": "unicode_emoji", "id": 0}
```

`op` is `add` or `remove`; the field set is identical. `reaction_type` is
`unicode_emoji` | `realm_emoji` | `zulip_extra_emoji`, and each is a separate namespace for
`emoji_code`: a Unicode codepoint sequence in dash-separated hex, the custom emoji's numeric ID as a
string, or the emoji name respectively.

The dedup key for a reaction row in SQLite is therefore `(message_id, user_id, reaction_type,
emoji_code)` — **not** `emoji_name`, which can differ for the same custom emoji.

The deprecated `user` dict has a non-monotonic history: present before FL 328, removed at 328,
re-added to reaction events only at 339 to unbreak old mobile clients, removed for good at FL 484.
Read `user_id`; treat `user` as junk.

### `update_message_flags`

```json
{"type": "update_message_flags", "op": "add", "operation": "add",
 "flag": "starred", "messages": [63], "all": false, "id": 0}
```

```json
{"type": "update_message_flags", "op": "remove", "operation": "remove",
 "flag": "read", "messages": [63],
 "message_details": {"63": {"type": "stream", "stream_id": 22, "topic": "lunch"}},
 "all": false, "id": 0}
```

- `op` is canonical since FL 32; `operation` is a deprecated duplicate that current servers still
  emit. Read `op ?? operation`.
- `all: true` only ever comes from "mark everything as read" (`do_mark_all_as_read`), with
  `messages: []`. The server comment: "Empty list because the client reloads anyway." Marking a
  single channel or topic read uses `all: false` with explicit IDs. On `op: remove`, `all` is
  deprecated and always `false`.
- `message_details` is present **only when `flag === "read"`** on `op: remove` (i.e. marking
  unread), keyed by message ID **as a string**. Entries carry `type`, plus `mentioned` (only if the
  message mentions you), `user_ids` (DMs; everyone except yourself, `[]` for a self-DM), or
  `stream_id` + `topic` (channels). Its whole purpose is to let a client rebuild `unread_msgs` for
  messages it does not have locally. New in FL 121; mark-as-unread did not exist before that.

Flag names. User-settable: `read`, `starred`, `collapsed`, `hide_link_previews` (FL 510+).
Server-computed: `mentioned`, `stream_wildcard_mentioned` (FL 224+), `topic_wildcard_mentioned`
(FL 224+), `has_alert_word`, `historical`, and the deprecated `wildcard_mentioned`
(= stream OR topic wildcard, pre-FL-224).

`historical` means the user did not receive the message when it was sent but later gained access to
its history (e.g. starred a public-channel message from before they subscribed).

Two behaviours worth designing around:

1. Flag events are only sent when the user already had and still has access. "When a message newly
   appears or disappears, a `message` or `delete_message` event is sent instead."
2. Flag changes caused by another change can arrive **later** than that change — "typically at most
   a few hundred milliseconds and can in rare cases be minutes or longer." Do not assume a flag
   event is atomic with the move that caused it.

Queue-level compression matters here. `flags/add/read` (and other flag events) get coalesced inside
the queue, so one delivered event's `messages` array may be the union of many server-side actions.
`flags/remove/read` is deliberately excluded from compression because of `message_details`. The
server source carries a known-bug note on this:

> "BUG: This compression algorithm is incorrect in the presence of mark-as-unread, since it does not
> respect the ordering of 'mark as read' and 'mark as unread' updates for a given message."

Source: `zerver/tornado/event_queue.py`.

There is **no `update_message_flags_remove` client capability and no such event type.** It is an
internal pydantic class name in `zerver/lib/event_types.py`. `message_details` is sent
unconditionally at FL >= 121. (The ticket listed this; it does not exist.)

### `submessage`

Experimental widget API (`/poll` etc.).

```json
{"type": "submessage", "msg_type": "widget", "message_id": 970461,
 "submessage_id": 4737, "sender_id": 58,
 "content": "{\"type\":\"vote\",\"key\":\"58,1\",\"vote\":1}", "id": 28}
```

The same data appears in `message.submessages[]`, but with `id` where the event uses
`submessage_id`. `content` is an opaque JSON string whose schema depends on `msg_type`. A client
that does not implement widgets can ignore these, but must not mistake them for edits.

### `heartbeat`

```json
{"type": "heartbeat", "id": 0}
```

"Clients do not need to do anything to process these events, beyond the common `last_event_id`
accounting." You must still advance `last_event_id` past them or the server redelivers them.

## 7. Message-family version compatibility

Facts a "works against any server" client has to branch on:

| FL | Zulip | Change |
| --- | --- | --- |
| 2 | 3.0 | `user_id` added to `reaction` events; `user` dict deprecated. |
| 13 | 3.0 | `bulk_message_deletion` capability; `message_id` → `message_ids`. |
| 26 | 3.1 | `sender_short_name` removed from message objects. |
| 32 | 4.0 | `op` added to `update_message_flags`; `operation` deprecated. |
| 46 | 4.0 | `topic_links` became `{text, url}` objects instead of URL strings. |
| 77 | 5.0 | `recipient_id`/`sender_id` removed from DM `delete_message`. |
| 112 | 5.0 | `stream_id` present on **all** channel-message `update_message` events. Below this, absence of `stream_id` does not imply DM. |
| 114 | 5.0 | `rendering_only` added; `user_id` always present (null for re-renders). Below this, detect re-renders by absent `user_id`. |
| 118 | 5.0 | `edit_history` gained `stream`/`topic`; `prev_subject` → `prev_topic`. |
| 121 | 5.0 | `message_details` on `update_message_flags` remove; mark-as-unread introduced. |
| 155 | 6.0 | No-op flag changes no longer listed in the event. |
| 224 | 8.0 | `wildcard_mentioned` split into `stream_wildcard_mentioned` + `topic_wildcard_mentioned`. |
| 274 | 9.0 | `delete_message` always sent to the deleting user. |
| 284 | 10.0 | `prev_rendered_content_version` removed from `edit_history`. |
| 327 | 10.0 | `recipient_id` for incoming 1:1 DMs became per-conversation. |
| 328 | 10.0 | `user` dict removed from `reactions` in messages and from `reaction` events. |
| 334 | 10.0 | `empty_topic_name` capability; `""` is a valid topic. |
| 339 | 10.0 | `user` re-added to `reaction` events only. |
| 365 | 10.0 | `last_moved_timestamp` added; `last_edit_timestamp` narrowed to content edits. |
| 393 | 11.0 | `message_ids` guaranteed sorted ascending on `update_message` and `delete_message`. |
| 452 | 12.0 | Retention-policy deletions now emit `delete_message`. |
| 457 | 12.0 | `delete_message` filtered to messages the recipient can access. |
| 482 | 12.0 | `recipient_id` raw value for 1:1 DMs changed again. |
| 484 | 12.0 | `user` removed from `reaction` events permanently. |
| 510 | 13.0 | `hide_link_previews` message flag. |

Source: <https://zulip.com/api/changelog> and the `**Changes**` blocks in
`zerver/openapi/zulip.yaml`.

Without the `empty_topic_name` capability the server substitutes `realm_empty_topic_display_name`
for `""` in `message.subject`, `delete_message.topic`, `update_message.orig_subject`/`subject`,
`user_topic.topic_name`, `typing.topic`, and `update_message_flags.message_details[*].topic`.
Source: `zerver/tornado/event_queue.py`.

## 8. Non-message events

Sources for this section: <https://zulip.com/api/get-events>, `zerver/openapi/zulip.yaml` (`/events`
path), `zerver/lib/event_types.py`, `zerver/lib/events.py`, `zerver/actions/typing.py`,
`zerver/actions/user_topics.py`, <https://zulip.com/api/set-typing-status>,
<https://zulip.com/api/update-presence>, <https://zulip.com/api/changelog>.

### `subscription`

Five ops.

`op: "add"` — `subscriptions` is an array of **full** subscription objects (`color`, `is_muted`,
`pin_to_top`, `desktop_notifications`, `push_notifications`, `wildcard_mentions_notify`,
`in_home_view`, `stream_weekly_traffic`, `can_*_group` permission settings, `subscribers` if
requested, etc.).

`op: "remove"` — `subscriptions` is **minimal**: only `stream_id` and `name`.

```json
{"type": "subscription", "op": "remove", "subscriptions": [{"name": "test", "stream_id": 9}], "id": 0}
```

`op: "update"` — a change to **your** personal subscription properties. Fields are `stream_id`,
`property`, `value`. There is no `subscriptions` array and no `name`.

```json
{"op": "update", "type": "subscription", "property": "pin_to_top", "value": true, "stream_id": 11, "id": 0}
```

The docs instruct: "Clients should generally handle an unknown property received here without
crashing." Design the GRDB writer accordingly.

Quirk: since FL 139, muting a channel sends **two** `subscription/update` events — one for `is_muted`
and one for the deprecated `in_home_view`, whose values are inverted (`in_home_view == !is_muted`).
Before FL 139 you only got the `in_home_view` one.

`op: "peer_add"` / `op: "peer_remove"` — someone else subscribed or unsubscribed. Both carry exactly
`stream_ids: int[]` and `user_ids: int[]`.

```json
{"type": "subscription", "op": "peer_add", "stream_ids": [9], "user_ids": [12], "id": 0}
```

Compatibility traps:

- FL 35 made these plural arrays; older servers send singular `stream_id` / `user_id` integers.
- FL 19 replaced `name` with `stream_id`.
- `peer_remove` on user deactivation is new in FL 377. The docs give the fallback explicitly:
  "Clients supporting older server versions and maintaining peer subscriber data need to remove all
  channel subscriptions for a user when processing the `realm_user` event with `op="remove"`."
- Ordering guarantee: on deactivation, `peer_remove` arrives **before** `realm_user`/`remove`.

### `stream`

**The event type is still named `stream`, not `channel`.** FL 255 was a strings-only rename across
the API docs and UI; the wire format did not change. (`channel_folder` is a different, unrelated
event type.) `include_streams` is not a client parameter — it is an internal argument of
`fetch_initial_state_data`, hardcoded `True` for authenticated register requests and `False` for
spectators, gating the top-level `streams` key in the snapshot.

Source: <https://zulip.com/api/changelog> FL 255; `zerver/lib/events.py`;
`zerver/views/events_register.py`.

`op: "create"` — `streams` is an array of channel objects. Also fires when you *gain* access, not
only on real creation (private→public at FL 134, guest subscribed at FL 192, role change at FL 205).

`op: "delete"` — carries **both** shapes:

```json
{"type": "stream", "op": "delete", "streams": [{"stream_id": 1}, {"stream_id": 2}],
 "stream_ids": [1, 2], "id": 0}
```

`stream_ids` is new in FL 343 and `streams` was deprecated at the same time; below FL 343 you must
read `streams[].stream_id`. Also fires when you *lose* access.

`op: "update"`:

```json
{"op": "update", "type": "stream", "property": "invite_only", "value": true,
 "history_public_to_subscribers": true, "is_web_public": false,
 "stream_id": 11, "name": "test", "id": 0}
```

`name` is always present. `rendered_description` appears only when `property == "description"`;
`history_public_to_subscribers` and `is_web_public` only when `property == "invite_only"`. `value`
can be an integer, boolean, string, `null` (FL 389, channel removed from a folder), or a group-setting
object `{direct_members: int[], direct_subgroups: int[]}` (FL 320+). Same "handle unknown property
without crashing" rule.

Archive and unarchive are routed by capability: with `archived_channels` you get `update` carrying
`is_archived`; without it you get `create`/`delete`.

### `typing`

```json
{"type": "typing", "op": "start", "message_type": "direct",
 "sender": {"user_id": 10, "email": "user10@zulip.testserver"},
 "recipients": [{"user_id": 8, "email": "..."}, {"user_id": 10, "email": "..."}], "id": 0}
```

`op` is `start` or `stop`; the field sets are identical. `message_type` is `"direct"` or `"stream"`
— **FL 215 replaced the value `"private"` with `"direct"`.** The field itself is new in FL 58; before
that all typing events were DMs and there was no field. `recipients` (DM only) is an array of
`{user_id, email}` and the sender is guaranteed to be in it. `stream_id` and `topic` appear for
channel typing only.

Channel typing events are delivered **only** if you declared `stream_typing_notifications: true`:

```python
if event["type"] == "typing" and "stream_id" in event:
    return self.stream_typing_notifications
```

Since FL 253 the per-user setting `receives_typing_notifications` suppresses delivery entirely for
users who turn it off. Channel typing is also silently skipped when a channel's subscriber count
exceeds `MAX_STREAM_SIZE_FOR_TYPING_NOTIFICATIONS`.

Timing protocol, from <https://zulip.com/api/set-typing-status>. The server is stateless here; the
client owns the timers:

- Send `op: "start"` when the user starts composing.
- Resend `op: "start"` every `server_typing_started_wait_period_milliseconds` while they keep
  interacting with the compose UI (including the emoji picker).
- Send `op: "stop"` after `server_typing_stopped_wait_period_milliseconds` of no compose activity,
  or when the compose is cancelled (only if a start was sent).
- On receiving `op: "start"`, show the indicator until a `stop` arrives **or**
  `server_typing_started_expiry_period_milliseconds` elapses with no new start.

Those three values come from `/register` (FL 204+). Documented fallbacks for older servers: 10000,
5000, 15000 ms respectively. The expiry rule is what prevents "perpetually typing" ghosts after a
sender's network drops.

`POST /typing` params: `op` (required), `type` (`"direct"` default, or `"stream"`/`"channel"`), `to`
(user IDs for direct), `stream_id` and `topic` (required for channel). The docs note "Clients
shouldn't care about the APIs prior to Zulip 8.0 (feature level 215) for channel typing
notifications, as no client actually implemented the previous API."

Related: `typing_edit_message` event (op `start`/`stop`), new in FL 351, with `sender_id`,
`message_id`, and `recipient`.

### `user_settings`

```json
{"type": "user_settings", "op": "update", "property": "high_contrast_mode", "value": false, "id": 0}
```

`property` names match the parameters of `PATCH /settings`. `value` is boolean, integer, or string.
`language_name` is added only when `property == "default_language"`.

The legacy pair, for servers below FL 439:

```json
{"type": "update_display_settings", "user": "iago@zulip.com",
 "setting_name": "high_contrast_mode", "setting": false, "id": 0}
{"type": "update_global_notifications", "user": "iago@zulip.com",
 "notification_name": "enable_sounds", "setting": true, "id": 0}
```

The cross-version recipe is stated in the docs: send `user_settings_object: true`, request all three
event types, then "use the `zulip_feature_level` in this endpoint's response or the presence/absence
of a `user_settings` key to determine where to look for the data." At FL 439 the legacy types were
removed entirely and the capability became inert.

### `user_topic` and `muted_topics`

`user_topic` is new in FL 134 and has **no `op`**:

```json
{"id": 1, "type": "user_topic", "stream_id": 1, "topic_name": "topic",
 "last_updated": 1594825442, "visibility_policy": 1}
```

`visibility_policy`: `0` none, `1` muted, `2` unmuted (FL 170), `3` followed (FL 219). The
corresponding snapshot key is `user_topics` (also FL 134).

The legacy event replaces the whole list each time:

```json
{"type": "muted_topics", "muted_topics": [["Denmark", "topic", 1594825442]], "id": 0}
```

Tuples are `[channel_name, topic_name, muted_at]`; before FL 1 they were 2-tuples with no timestamp.

The compatibility mechanism is server-side suppression:

```python
if event["type"] == "muted_topics" and "user_topic" in self.event_types:
    return False
```

So request **both** types in `event_types`. New servers then send only `user_topic`; old servers do
not know `user_topic` and send `muted_topics`. Important caveat: this suppression only works when
`event_types` is explicitly set. A queue registered with no `event_types` filter receives **both**,
and the client must ignore `muted_topics` itself.

Source: `zerver/tornado/event_queue.py`, `accepts_event`.

### `presence`

The docs are explicit that events are not the whole story: "Event sent to all users in an
organization when a user comes back online after being offline for a while. In addition to handling
these events, a client that wants to maintain presence data must poll the main presence endpoint.
Most updates to presence data, refreshing the timestamps of users who are already online, do not
appear in the event queue."

There are three wire formats, chosen per queue in `process_presence_event`:

```python
if client.simplified_presence_events:  modern_event
elif client.slim_presence:             slim_event
else:                                  legacy_event
```

Legacy (the default, and all you get below FL 419):

```json
{"type": "presence", "user_id": 10, "email": "user10@zulip.testserver",
 "server_timestamp": 1594825445.32,
 "presence": {"website": {"client": "website", "status": "idle",
                          "timestamp": 1594825445, "pushable": false}}, "id": 0}
```

From FL 178 the key is always `"website"`, `client` is always `"website"` and `pushable` is always
`false` — the server stopped recording which client reported presence. `email` is omitted when
`slim_presence: true`.

Modern (`simplified_presence_events` capability, FL 419):

```json
{"type": "presence", "presences": {"10": {"active_timestamp": 1656958520,
                                          "idle_timestamp": 1656958530}}, "id": 0}
```

Keys are user IDs as strings. The docs say "Clients should support updating multiple users in a
single event" even though the server currently sends one, and "Clients are strongly encouraged to
implement this client capability, as legacy format support will be removed in a future release."
Interpretation: a current `active_timestamp` means fully present; a current `idle_timestamp` with no
current `active_timestamp` means potentially present.

Keeping presence current means polling `POST /users/me/presence`, which both reports your own status
and returns everyone else's:

- `status` (required, `"active"` or `"idle"`). Report `"active"` when the user is presently using the
  device — would see a notification immediately — even without direct interaction.
- `last_update_id` (FL 263): pass `-1` on first fetch, then echo back `presence_last_update_id` from
  each response. Passing it implies the modern format. If the response's value equals what you sent,
  nothing changed. `-1` back means no data (e.g. presence disabled in the realm).
- `history_limit_days` (FL 288), default 14, ignored when `last_update_id > 0`.
- `ping_only: true` updates your own status and skips the expensive `presences` payload.
- `new_user_input` should be `true` only on real interaction; it feeds usage analytics.
- `slim_presence` is the pre-FL-263 way to ask for the modern format; deprecated at FL 263.

Cadence comes from `/register` (present when `realm` is in `fetch_event_types`), both new in FL 164
with documented fallbacks:

| Field | Meaning | Fallback |
| --- | --- | --- |
| `server_presence_ping_interval_seconds` | How often to POST presence. | 60 |
| `server_presence_offline_threshold_seconds` | How stale a timestamp may be before showing offline. | 140 |

Note `zerver/lib/events.py`: if the client passes `presence_last_update_id` or
`simplified_presence_events`, the server forces `slim_presence = True` for the initial state too.

Invisible mode is server-side. Render the *current user* as online/offline from the `presence_enabled`
field on their user object, not from what the client is reporting.

### `realm_user`

Needed for user metadata. Before FL 228 these went to everyone in the realm; now only to users who
can access the modified user.

- `op: "add"` — `person` is a full user object.
- `op: "remove"` — `person` is `{user_id, full_name}`; `full_name` is deprecated (stopped being sent
  at FL 222, un-deprecated at FL 228 for guests losing access).
- `op: "update"` — `person` is a **partial** object: always `user_id` plus exactly one logical
  change. Documented variants: `full_name`; the avatar quad (`avatar_url`, `avatar_source`,
  `avatar_url_medium`, `avatar_version`); `email`; `timezone`; `bot_owner_id`; `role`;
  `delivery_email`; `custom_profile_field` (`{id, value, rendered_value?}`); `new_email`;
  `is_active`; `is_imported_stub`; `date_joined`.

Merge `person` into the user row by `user_id`, ignoring unknown keys. With
`user_avatar_url_field_optional` declared, `avatar_url` may be absent and you fall back to
`GET /avatar/{user_id}`.

### Smaller types worth handling for rendering

`muted_users` (FL 48) — full replacement list, no `op`:

```json
{"type": "muted_users", "muted_users": [{"id": 1, "timestamp": 1594825442}], "id": 0}
```

`alert_words` — full replacement list, no `op`. The server computes the `has_alert_word` flag; the
client needs the list only for highlight rendering.

`realm_emoji` — needed to render `:custom_emoji:` and reactions with `reaction_type: "realm_emoji"`.
Legacy `op: "update"` replaces the whole table. With `individual_emoji_changes` (FL 491) you get
`op: "add"` with a single `emoji` object and `op: "update_one"` with `emoji_id` + `data`.

`custom_profile_fields` — full replacement list, no `op`. `type` enum: 1 short text, 2 long text,
3 list of options, 4 date, 5 link, 6 user, 7 external account, 8 pronouns. `field_data` is a JSON
**string**, not an object. These define the schema of `person.profile_data` in `realm_user` events.

## 9. Non-message event compatibility highlights

| FL | Change |
| --- | --- |
| 1 | `muted_topics` tuples gained the timestamp (were 2-tuples). |
| 19 | `subscription` peer events use `stream_id` instead of `name`. |
| 35 | `peer_add`/`peer_remove` became plural `stream_ids`/`user_ids` arrays. |
| 48 | `muted_users` event added. |
| 58 | Channel typing notifications; `message_type` field on `typing`. |
| 89 | `user_settings` event type. |
| 134 | `user_topic` event type (replaces `muted_topics`); private→public sends `peer_add`. |
| 139 | Muting a channel sends two `subscription/update` events (`is_muted` + `in_home_view`). |
| 164 | `server_presence_ping_interval_seconds` / `server_presence_offline_threshold_seconds`. |
| 170 / 219 | `visibility_policy` values 2 (unmuted) and 3 (followed). |
| 178 | Presence stopped tracking which client reported; key is always `website`. |
| 204 | The three typing timing values in `/register`. |
| 215 | `typing.message_type` value `"private"` → `"direct"`; channel typing params settled. |
| 222 / 228 | `realm_user/remove` `full_name` deprecated, then un-deprecated; presence and user events restricted to accessible users. |
| 253 | `receives_typing_notifications` user setting suppresses typing delivery. |
| 255 | Streams renamed to channels **in strings only**; the event type is still `stream`. |
| 263 | `last_update_id` / `presence_last_update_id` presence polling. |
| 288 | `presence_history_limit_days`. |
| 320 | `stream/update` `value` can be a group-setting object. |
| 343 | `stream/delete` gained `stream_ids`; `streams` deprecated. |
| 351 | `typing_edit_message` event. |
| 377 / 428 | `peer_remove` on deactivation; extended to archived channels. |
| 389 | `stream/update` `value` can be `null` (folder removed). |
| 412 | `include_subscribers: "partial"` and `partial_subscribers`. |
| 419 | `simplified_presence_events` capability, modern `presence` event. |
| 439 | `update_display_settings` / `update_global_notifications` removed. |
| 491 | `realm_emoji` `add` / `update_one` ops. |
