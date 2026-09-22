# Zulip's notification settings model

Research for issue `03-zulip-notification-settings.md`.

**Sources.** Server source read from `zulip/zulip` at `main`, commit `370f7b66fca175e66f9545330f4534290cc9f9db`. API facts from `https://zulip.com/api/`, help center from `https://zulip.com/help/`. Every claim below carries a URL.

---

## 1. Short answer

Zulip's "should this notify" decision lives in one file: [`zerver/lib/notification_data.py`](https://github.com/zulip/zulip/blob/main/zerver/lib/notification_data.py). It is fully replicable by a third party, because every input is readable over the public API — **except** the server's own idea of whether the user is "idle", which a third-party service must supply itself.

Three layers of state, resolved by one function, then an eight-way ordered trigger switch.

| Layer | Storage | API | Tri-state? |
|---|---|---|---|
| Global | `UserProfile` | `PATCH /settings`, register `user_settings` | no — plain booleans |
| Per channel | `Subscription` | `POST /users/me/subscriptions/properties`, `GET /users/me/subscriptions` | **yes** — `null` = inherit global |
| Per topic | `UserTopic` | `POST /user_topics`, register `user_topics` | **yes** — policy `0` = inherit |
| Per sender | `MutedUser` | `POST`/`DELETE /users/me/muted_users/{id}` | no |

Everything Zulu needs can be mirrored. Nothing needs a parallel store.

---

## 2. Global settings on `UserProfile`

Field names and defaults from [`zerver/models/users.py` L202-L279](https://github.com/zulip/zulip/blob/main/zerver/models/users.py).

### Channel-message notifications (the fallback for per-channel settings)

| Field | Default | Notes |
|---|---|---|
| `enable_stream_push_notifications` | `False` | fallback for `Subscription.push_notifications` |
| `enable_stream_email_notifications` | `False` | fallback for `Subscription.email_notifications` |
| `enable_stream_desktop_notifications` | `False` | client-side only; server never reads it |
| `enable_stream_audible_notifications` | `False` | client-side only |

### DM and mention notifications

| Field | Default | Notes |
|---|---|---|
| `enable_offline_push_notifications` | `True` | gates DMs **and** personal/wildcard mentions, push |
| `enable_offline_email_notifications` | `True` | same, email |
| `enable_online_push_notifications` | `True` | the **only** way a non-idle user gets a push |
| `enable_desktop_notifications` | `True` | client-side |
| `enable_sounds` | `True` | client-side |

Naming trap: `enable_offline_*_notifications` is not DM-only despite the name. It gates the `dm_*` **and** `mention_*` families — see `dm_mention_push_disabled_user_ids` in [`zerver/actions/message_send.py` L487-L497](https://github.com/zulip/zulip/blob/main/zerver/actions/message_send.py).

### Wildcard mentions

| Field | Default |
|---|---|
| `wildcard_mentions_notify` | `True` |

### Followed topics (Zulip 8.0 / FL 189)

| Field | Default |
|---|---|
| `enable_followed_topic_push_notifications` | `True` |
| `enable_followed_topic_email_notifications` | `True` |
| `enable_followed_topic_desktop_notifications` | `True` (client-side) |
| `enable_followed_topic_audible_notifications` | `True` (client-side) |
| `enable_followed_topic_wildcard_mentions_notify` | `True` |

### Automatic visibility-policy changes (state drift the mirror must track)

[`zerver/models/users.py` L263-L279](https://github.com/zulip/zulip/blob/main/zerver/models/users.py):

```python
AUTOMATICALLY_CHANGE_VISIBILITY_POLICY_ON_PARTICIPATION = 1
AUTOMATICALLY_CHANGE_VISIBILITY_POLICY_ON_SEND = 2
AUTOMATICALLY_CHANGE_VISIBILITY_POLICY_ON_INITIATION = 3
AUTOMATICALLY_CHANGE_VISIBILITY_POLICY_NEVER = 4

automatically_follow_topics_policy (default 3 = ON_INITIATION)
automatically_unmute_topics_in_muted_streams_policy (default 2 = ON_SEND)
automatically_follow_topics_where_mentioned (default True)
```

These make the server mutate `UserTopic` rows on its own. Zulu must consume `user_topic` events rather than assume its local copy is authoritative. `automatically_follow_topics_policy` / `automatically_unmute_topics_in_muted_streams_policy` are FL 214; `automatically_follow_topics_where_mentioned` is FL 235 ([changelog](https://zulip.com/api/changelog)).

### Other enums on the same endpoint

- `desktop_icon_count_display` — `1`=all unread, `2`=DMs+mentions+followed topics, `3`=DMs+mentions, `4`=none. Option 2 was **inserted** at FL 227 and renumbered the rest.
- `realm_name_in_email_notifications_policy` — `1`=automatic, `2`=always, `3`=never (FL 168, replaced boolean `realm_name_in_notifications`).
- `email_notifications_batching_period_seconds` — integer (FL 82).
- `notification_sound` — string; valid values come back as `available_notification_sounds` in register.
- `presence_enabled` — boolean; also `Realm.presence_disabled` kills all presence-idle computation server-side.
- `resolved_topic_notice_auto_read_policy` — `"always" | "except_followed" | "never"` (FL 385).

Source: [zulip.com/api/update-settings](https://zulip.com/api/update-settings).

---

## 3. Per-channel settings on `Subscription` — the tri-state

[`zerver/models/streams.py` L394-L408](https://github.com/zulip/zulip/blob/main/zerver/models/streams.py):

```python
is_muted = models.BooleanField(default=False)

# These fields are stream-level overrides for the user's default
# configuration for notification, configured in UserProfile.  The
# default, None, means we just inherit the user-level default.
desktop_notifications    = models.BooleanField(null=True, default=None)
audible_notifications    = models.BooleanField(null=True, default=None)
push_notifications       = models.BooleanField(null=True, default=None)
email_notifications      = models.BooleanField(null=True, default=None)
wildcard_mentions_notify = models.BooleanField(null=True, default=None)
```

So the tri-state is literally `true` / `false` / `null`, where `null` means "read the global". **Never coerce `null` to `false`.**

`is_muted` is a plain boolean, not tri-state. `in_home_view` is its deprecated inverse (`in_home_view == !is_muted`), still accepted on write and still emitted as a second event on change since FL 139.

Only these appear on the wire: `API_FIELDS = ["audible_notifications", "color", "desktop_notifications", "email_notifications", "is_muted", "pin_to_top", "push_notifications", "wildcard_mentions_notify"]` (same file, L437-L446).

Server-side write validation accepts exactly this property set ([`zerver/views/streams.py` L1347-L1363](https://github.com/zulip/zulip/blob/main/zerver/views/streams.py)): `color` (hex string) plus booleans `in_home_view`, `is_muted`, `desktop_notifications`, `audible_notifications`, `push_notifications`, `email_notifications`, `pin_to_top`, `wildcard_mentions_notify`.

---

## 4. Per-topic state: `UserTopic.VisibilityPolicy`

[`zerver/models/user_topics.py` L24-L44](https://github.com/zulip/zulip/blob/main/zerver/models/user_topics.py) — exact integers:

```python
class VisibilityPolicy(models.IntegerChoices):
    MUTED    = 1, "Muted topic"
    UNMUTED  = 2, "Unmuted topic in muted stream"
    FOLLOWED = 3, "Followed topic"
    INHERIT  = 0, "User's default policy for the stream."
```

`INHERIT` (0) is a sentinel used in code. **No `UserTopic` row exists for it** — absence of a row means inherit. Writing `visibility_policy: 0` deletes the row. The column's own DB default is `MUTED` (1), which only matters for direct model construction.

Topic names are matched **case-insensitively** (unique constraint on `Lower("topic_name")`, same file). A mirror must fold case when looking up policy.

FL history ([changelog](https://zulip.com/api/changelog)): `POST /user_topics` and `UNMUTED` at FL 170 (Zulip 7.0); `FOLLOWED` at FL 219 (Zulip 7.0); the `user_topic` event and `user_topics` register array at FL 134 (Zulip 6.0).

---

## 5. The resolution function — exact source

This is the whole tri-state/inherit story, verbatim from [`zerver/lib/notification_data.py`](https://github.com/zulip/zulip/blob/main/zerver/lib/notification_data.py):

```python
def user_allows_notifications_in_StreamTopic(
    stream_is_muted: bool,
    visibility_policy: int,
    stream_specific_setting: bool | None,
    global_setting: bool,
    channel_specific_setting_overrides_mute: bool,
) -> bool:
    """
    Captures the hierarchy of notification settings, where visibility policy is considered first,
    followed by stream-specific settings, and the global-setting in the UserProfile is the fallback.

    When `channel_specific_setting_overrides_mute` is True (currently used for
    `wildcard_mentions_notify` setting), `stream_specific_setting` overrides
    channel mute, but not topic mute.
    """
    # Muted topics always suppress notifications, regardless of other settings.
    if visibility_policy == UserTopic.VisibilityPolicy.MUTED:
        return False

    if stream_is_muted and visibility_policy != UserTopic.VisibilityPolicy.UNMUTED:
        if channel_specific_setting_overrides_mute and stream_specific_setting is not None:
            return stream_specific_setting
        return False

    if stream_specific_setting is not None:
        return stream_specific_setting

    return global_setting
```

Precedence, top to bottom:

1. **Topic MUTED** → `false`. Nothing overrides it.
2. **Channel muted** and topic is not `UNMUTED` → `false`. Exception: for `wildcard_mentions_notify` only, an explicit (non-null) per-channel value wins here.
3. **Per-channel setting** if non-null.
4. **Global setting**.

Note what is *not* in this function: `FOLLOWED`, and personal mentions. A followed topic does not flow through it at all, and neither do the `mention_*_notify` fields — a personal or user-group mention is decided solely by the `mentioned` flag plus `enable_offline_*_notifications`, so **mutes never suppress a personal mention**.

### Callers

From [`zerver/actions/message_send.py` L303-L394](https://github.com/zulip/zulip/blob/main/zerver/actions/message_send.py):

```python
stream_push_user_ids  = notification_recipients("push_notifications",  "user_profile_push_notifications")
stream_email_user_ids = notification_recipients("email_notifications", "user_profile_email_notifications")

wildcard_mentions_notify_user_ids = notification_recipients(
    "wildcard_mentions_notify",
    "user_profile_wildcard_mentions_notify",
    channel_specific_setting_overrides_mute=True,   # <- only here
)
```

Followed-topic sets bypass the helper entirely:

```python
def followed_topic_notification_recipients(setting, followed_topic_setting):
    return {
        row["user_profile_id"]
        for row in subscription_rows
        if user_id_to_visibility_policy.get(row["user_profile_id"], UserTopic.VisibilityPolicy.INHERIT)
           == UserTopic.VisibilityPolicy.FOLLOWED
        and row[followed_topic_setting]
    }
```

**Consequence, and it is the least obvious rule in the whole system:** a `FOLLOWED` topic ignores channel mute *and* ignores the per-channel `push_notifications` override. Only the global `enable_followed_topic_push_notifications` matters. Follow is an independent, additive notification channel, not a stronger "unmute".

Topic wildcard sets intersect with topic participants:

```python
topic_wildcard_mention_user_ids = topic_participant_user_ids.intersection(wildcard_mentions_notify_user_ids)
topic_wildcard_mention_in_followed_topic_user_ids = topic_participant_user_ids.intersection(
    followed_topic_wildcard_mentions_notify_user_ids
)
```

---

## 6. The decision: `UserMessageNotificationsData`

Twenty fields ([same file](https://github.com/zulip/zulip/blob/main/zerver/lib/notification_data.py)):

`user_id`, `online_push_enabled`, `dm_email_notify`, `dm_push_notify`, `mention_email_notify`, `mention_push_notify`, `topic_wildcard_mention_email_notify`, `topic_wildcard_mention_push_notify`, `stream_wildcard_mention_email_notify`, `stream_wildcard_mention_push_notify`, `stream_push_notify`, `stream_email_notify`, `followed_topic_push_notify`, `followed_topic_email_notify`, `topic_wildcard_mention_in_followed_topic_push_notify`, `topic_wildcard_mention_in_followed_topic_email_notify`, `stream_wildcard_mention_in_followed_topic_push_notify`, `stream_wildcard_mention_in_followed_topic_email_notify`, `sender_is_muted`, `disable_external_notifications`.

### Universal veto

```python
def trivially_should_not_notify(self, acting_user_id: int) -> bool:
    if self.user_id == acting_user_id:      return True   # own message
    if self.sender_is_muted:                return True   # recipient muted the sender
    if self.disable_external_notifications: return True   # internal/system sender
    return False
```

### Push decision — the exact expression and ordering

```python
def get_push_notification_trigger(self, acting_user_id: int, idle: bool) -> str | None:
    if not idle and not self.online_push_enabled:
        return None

    if self.trivially_should_not_notify(acting_user_id):
        return None

    # The order here is important. If, for example, both
    # `mention_push_notify` and `stream_push_notify` are True, we
    # want to classify it as a mention, since that's more salient.
    if self.dm_push_notify:                                        return NotificationTriggers.DIRECT_MESSAGE
    elif self.mention_push_notify:                                 return NotificationTriggers.MENTION
    elif self.topic_wildcard_mention_in_followed_topic_push_notify:  return NotificationTriggers.TOPIC_WILDCARD_MENTION_IN_FOLLOWED_TOPIC
    elif self.stream_wildcard_mention_in_followed_topic_push_notify: return NotificationTriggers.STREAM_WILDCARD_MENTION_IN_FOLLOWED_TOPIC
    elif self.topic_wildcard_mention_push_notify:                  return NotificationTriggers.TOPIC_WILDCARD_MENTION
    elif self.stream_wildcard_mention_push_notify:                 return NotificationTriggers.STREAM_WILDCARD_MENTION
    elif self.followed_topic_push_notify:                          return NotificationTriggers.FOLLOWED_TOPIC_PUSH
    elif self.stream_push_notify:                                  return NotificationTriggers.STREAM_PUSH
    else:                                                          return None

def is_push_notifiable(self, acting_user_id, idle): return self.get_push_notification_trigger(acting_user_id, idle) is not None
```

The email version is identical except the first gate is `if not idle: return None` (no online escape hatch) and the last two arms are `FOLLOWED_TOPIC_EMAIL` / `STREAM_EMAIL`.

So the **precedence order** is:

1. DM (1:1 or group)
2. Personal mention (includes user-group mentions)
3. Topic wildcard mention inside a followed topic
4. Stream wildcard mention inside a followed topic
5. Topic wildcard mention
6. Stream wildcard mention
7. Followed topic
8. Channel push/email setting

### Trigger string constants

[`zerver/models/scheduled_jobs.py` L71-L82](https://github.com/zulip/zulip/blob/main/zerver/models/scheduled_jobs.py):

```python
class NotificationTriggers:
    # "direct_message" is for 1:1 and group direct messages
    DIRECT_MESSAGE = "direct_message"
    MENTION = "mentioned"
    TOPIC_WILDCARD_MENTION = "topic_wildcard_mentioned"
    STREAM_WILDCARD_MENTION = "stream_wildcard_mentioned"
    STREAM_PUSH = "stream_push_notify"
    STREAM_EMAIL = "stream_email_notify"
    FOLLOWED_TOPIC_PUSH = "followed_topic_push_notify"
    FOLLOWED_TOPIC_EMAIL = "followed_topic_email_notify"
    TOPIC_WILDCARD_MENTION_IN_FOLLOWED_TOPIC = "topic_wildcard_mentioned_in_followed_topic"
    STREAM_WILDCARD_MENTION_IN_FOLLOWED_TOPIC = "stream_wildcard_mentioned_in_followed_topic"
```

The trigger is not a field in the APNs payload. It only selects the alert subtitle ("X mentioned you:", "X mentioned everyone:"). Zulu is free to use it however it likes.

### How the boolean fields get built

From `from_user_id_sets` in the same file. Every field is `user_id in <some set>` plus a flag check:

```python
dm_email_notify = user_id not in dm_mention_email_disabled_user_ids and private_message
mention_email_notify = user_id not in dm_mention_email_disabled_user_ids and "mentioned" in flags
topic_wildcard_mention_email_notify = (
    user_id in topic_wildcard_mention_user_ids
    and user_id not in dm_mention_email_disabled_user_ids
    and "topic_wildcard_mentioned" in flags
)
...
dm_push_notify = push_device_registered and user_id not in dm_mention_push_disabled_user_ids and private_message
...
online_push_enabled        = push_device_registered and user_id in online_push_user_ids
stream_push_notify         = push_device_registered and user_id in stream_push_user_ids
followed_topic_push_notify = push_device_registered and user_id in followed_topic_push_user_ids
stream_email_notify        = user_id in stream_email_user_ids          # no push-device gate
```

Two structural points:

- Every push field is `and`-ed with `push_device_registered`. Irrelevant to Zulu's own service (it is the push transport), but it explains why Zulip's own server may not push for a message Zulu decides to push.
- Wildcard mentions "obey notification settings for personal mentions" — they are gated by `enable_offline_*_notifications`, not by their own toggle. `wildcard_mentions_notify` decides membership in the wildcard user-ID sets; the mention toggle then decides whether that notifies.

Bots short-circuit to all-false.

---

## 7. Idle determination — the one thing Zulu must decide itself

Two independent inputs, OR'd, from [`zerver/tornado/event_queue.py`](https://github.com/zulip/zulip/blob/main/zerver/tornado/event_queue.py):

```python
idle = receiver_is_off_zulip(user_profile_id) or (user_profile_id in presence_idle_user_ids)
```

- `receiver_is_off_zulip` — true when the user has **zero** client event queues that accept `message` events and are not marked offline. A queue is marked offline after `EVENT_QUEUE_OFFLINE_TIMEOUT_SECS = 600` without polling ([same file, L45-L58, L295-L300, L1024-L1034](https://github.com/zulip/zulip/blob/main/zerver/tornado/event_queue.py)).
- `presence_idle_user_ids` — computed at send time in [`message_send.py` L883-L928](https://github.com/zulip/zulip/blob/main/zerver/actions/message_send.py): a user is presence-idle if `UserPresence.last_active_time` is older than `settings.OFFLINE_THRESHOLD_SECS`, default **200** seconds ([`zproject/default_settings.py` L617-L624](https://github.com/zulip/zulip/blob/main/zproject/default_settings.py)). Returns `[]` when `realm.presence_disabled`.

### The trap for Zulu's Go service

`receiver_is_off_zulip` counts *any* long-lived event queue, including the one Zulu's notification service holds open. **Holding an open event queue makes the Zulip server think the user is at their desk**, which suppresses the server's own push/email notifications for that user. That is arguably what Zulu wants (Zulu becomes the sole push authority), but it also suppresses Zulip's *email* notifications, which the user may still expect. Flag this as a product decision.

Corollary: Zulu's service cannot learn "idle" from the server in any useful way. It should compute `idle` from its own knowledge — app foreground/background state per device, last APNs interaction — and pass that into the replicated `get_push_notification_trigger`. Presence is readable (`GET /users/presence`, and `presence` events) but reflects the *user's other clients*, not Zulu's.

---

## 8. What a third-party service actually receives

Critical: **the notification decision is not delivered to clients.**

In `process_message_event`, the server attaches the computed `UserMessageNotificationsData` to the event as `internal_data`. But [`prune_internal_data`](https://github.com/zulip/zulip/blob/main/zerver/tornado/event_queue.py) strips it before `GET /events` returns:

```python
def prune_internal_data(events):
    """Prunes the internal_data data structures, which are not intended to
    be exposed to API clients.
    """
```

`EventQueue.contents(include_internal_data=False)` is the default; only the internal missed-message hook passes `True`.

What a client's `message` event does carry:

```python
user_event = dict(type="message", message=message_dict, flags=flags)
```

So Zulu gets the message and **the per-user flags** — and must do everything else itself.

### Flags that matter

From [zulip.com/api/update-message-flags](https://zulip.com/api/update-message-flags):

| Flag | Meaning | FL |
|---|---|---|
| `mentioned` | personal mention, or via a user group | — |
| `stream_wildcard_mentioned` | `@**all**` / `@**everyone**` / `@**channel**` | 224 |
| `topic_wildcard_mentioned` | `@**topic**` | 224 |
| `wildcard_mentioned` | deprecated; `stream_wildcard_mentioned \|\| topic_wildcard_mentioned` | deprecated 224 |
| `read` | already read | — |
| `has_alert_word` | alert word matched | — |

All four mention flags are server-set and cannot be changed via `POST /messages/flags`.

For pre-FL-224 servers, treat `wildcard_mentioned` as `stream_wildcard_mentioned`.

**Alert words do not notify.** `has_alert_word` appears nowhere in `notification_data.py` or the notification path, and there is no alert-word `NotificationTriggers` constant. If Zulu wants alert-word pushes, that is an invention beyond Zulip's model.

---

## 9. Mention semantics

From [zulip.com/help/mention-a-user-or-group](https://zulip.com/help/mention-a-user-or-group):

| Syntax | Effect |
|---|---|
| `@**Full Name**` | personal mention → `mentioned` flag |
| `@_**Full Name**` | silent mention → no flag, no notification |
| `@*group name*` | user-group mention → `mentioned` flag on each member |
| `@**all**`, `@**everyone**`, `@**channel**` | equivalent; "notify everyone on a channel" → `stream_wildcard_mentioned` |
| `@**topic**` | "notifies everyone who has previously participated in the topic by sending a message or reacting with an emoji" → `topic_wildcard_mentioned` |

`@**channel**` was added at FL 247. `@**stream**` is **not** a keyword.

User-group mentions set the plain `mentioned` flag — there is no separate group trigger. `get_user_group_mentions_data` only picks *which* group name to display, preferring the smallest group, and a personal mention takes priority over any group mention ([`notification_data.py`](https://github.com/zulip/zulip/blob/main/zerver/lib/notification_data.py)). The chosen group id rides along as `mentioned_user_group_id` in the internal notice — **not visible to API clients**.

Wildcard mentions only count if Markdown actually rendered one: the server empties the wildcard user-ID sets unless `rendering_result.mentions_stream_wildcard` / `mentions_topic_wildcard`. Wildcard syntax inside a code block notifies nobody. Zulu should rely on the flags, not on re-parsing message content.

Orgs can restrict wildcard mentions in large channels (`wildcard_mention_policy`; topic wildcards restricted at FL 229). A restricted mention simply never sets the flag.

---

## 10. Read API

One call gets everything:

```
POST /api/v1/register
  fetch_event_types: ["user_settings", "subscription", "user_topic", "muted_users"]
```

([zulip.com/api/register-queue](https://zulip.com/api/register-queue))

| Register key | Contents |
|---|---|
| `user_settings` | every global field in §2, plus `available_notification_sounds` |
| `subscriptions` | array with `is_muted`, `push_notifications`, `email_notifications`, `desktop_notifications`, `audible_notifications`, `wildcard_mentions_notify`, `pin_to_top`, `color` |
| `user_topics` | array of `{stream_id, topic_name, last_updated, visibility_policy}` |
| `muted_users` | array of `{id, timestamp}` |

Requesting `user_topic` suppresses the legacy `muted_topics` array — which is what you want.

Standalone reads also exist: [`GET /users/me/subscriptions`](https://zulip.com/api/get-subscriptions). There is **no** `GET /user_topics` endpoint — register is the only read path for topic policies.

`GET /users/me` ([get-own-user](https://zulip.com/api/get-own-user)) returns **no** notification settings.

---

## 11. Write API

Verified against [`zproject/urls.py`](https://github.com/zulip/zulip/blob/main/zproject/urls.py) — note the methods differ per endpoint:

| What | Method + path | Body |
|---|---|---|
| Global settings | `PATCH /api/v1/settings` | any subset of the §2 fields |
| Per-channel | `POST /api/v1/users/me/subscriptions/properties` | `subscription_data=[{stream_id, property, value}, ...]` |
| Per-topic | `POST /api/v1/user_topics` | `stream_id`, `topic`, `visibility_policy` (0/1/2/3) |
| Mute a user | `POST /api/v1/users/me/muted_users/{muted_user_id}` | — |
| Unmute a user | `DELETE /api/v1/users/me/muted_users/{muted_user_id}` | — |
| Topic mute (legacy) | `PATCH /api/v1/users/me/subscriptions/muted_topics` | `stream_id`/`stream`, `topic`, `op: add\|remove` |

Deprecated aliases still routed but undocumented: `PATCH /settings/notifications`, `PATCH /settings/display` (merged into `PATCH /settings` at FL 80).

`PATCH /users/me/subscriptions/muted_topics` is deprecated as of FL 170 and "may be removed in a future release" ([zulip.com/api/mute-topic](https://zulip.com/api/mute-topic)). Use it only as a fallback when `zulip_feature_level < 170`.

Every write response may include `ignored_parameters_unsupported` (FL 167 for all endpoints) — check it to detect settings an older server silently rejected.

---

## 12. Events to subscribe to

| Event type | Payload | Source |
|---|---|---|
| `user_settings` op `update` | `{property, value, language_name?}` | [`event_types.py` L1246-L1256](https://github.com/zulip/zulip/blob/main/zerver/lib/event_types.py) |
| `subscription` op `update` | `{stream_id, property, value}` | [`event_types.py` L1034-L1039](https://github.com/zulip/zulip/blob/main/zerver/lib/event_types.py) |
| `user_topic` | `{stream_id, topic_name, last_updated, visibility_policy}` | [`event_types.py` L1272-L1277](https://github.com/zulip/zulip/blob/main/zerver/lib/event_types.py) |
| `muted_users` | full replacement array `[{id, timestamp}]` | [`event_types.py` L280-L282](https://github.com/zulip/zulip/blob/main/zerver/lib/event_types.py) |
| `muted_topics` | legacy full replacement; not sent if `user_topic` requested | [`event_types.py` L270-L272](https://github.com/zulip/zulip/blob/main/zerver/lib/event_types.py) |

Legacy `update_global_notifications` / `update_display_settings`: deprecated at FL 89, **no longer sent at all** as of FL 439 ([changelog](https://zulip.com/api/changelog)). Do not implement.

`user_topic` events are emitted only when the row actually changed ([`zerver/actions/user_topics.py` L44-L61](https://github.com/zulip/zulip/blob/main/zerver/actions/user_topics.py)), and a `muted_topics` event is fired alongside for legacy clients.

The Zulip docs explicitly require clients to tolerate unknown `property` values on `subscription` update events without crashing.

---

## 13. The algorithm Zulu's Go service must implement

Given a `message` event with `flags`, for the queue's own user:

```
# 0. Veto
if message.sender_id == user_id:                    -> no notification
if message.sender_id in muted_users:                -> no notification

# 1. DM path
if message.type == "private":
    return enable_offline_push_notifications and (idle or enable_online_push_notifications)
    # trigger = "direct_message"; no per-conversation override exists

# 2. Channel path. Gather:
sub        = subscriptions[message.stream_id]
policy     = user_topics[(stream_id, casefold(topic))] or INHERIT   # 0/1/2/3
muted      = sub.is_muted

# 2a. personal / group mention — deliberately NOT gated by mute or policy
mention_notify = "mentioned" in flags and enable_offline_push_notifications

# 2b. wildcard-mention eligibility
wildcard_ok = resolve(muted, policy, sub.wildcard_mentions_notify,
                      global.wildcard_mentions_notify,
                      overrides_mute=True)
followed_wildcard_ok = (policy == FOLLOWED
                        and global.enable_followed_topic_wildcard_mentions_notify)
# each of these still requires enable_offline_push_notifications

# 2c. channel setting
stream_push = resolve(muted, policy, sub.push_notifications,
                      global.enable_stream_push_notifications,
                      overrides_mute=False)

# 2d. followed topic
followed_push = (policy == FOLLOWED and global.enable_followed_topic_push_notifications)

# 3. Online gate
if not idle and not global.enable_online_push_notifications: -> no notification

# 4. Ordered trigger switch (first match wins)
   mention_notify                                                 -> "mentioned"
   followed_wildcard_ok and "topic_wildcard_mentioned"  in flags   -> "topic_wildcard_mentioned_in_followed_topic"
   followed_wildcard_ok and "stream_wildcard_mentioned" in flags   -> "stream_wildcard_mentioned_in_followed_topic"
   wildcard_ok and "topic_wildcard_mentioned"  in flags            -> "topic_wildcard_mentioned"
   wildcard_ok and "stream_wildcard_mentioned" in flags            -> "stream_wildcard_mentioned"
   followed_push                                                   -> "followed_topic_push_notify"
   stream_push                                                     -> "stream_push_notify"
   otherwise                                                       -> no notification
```

where `resolve` is `user_allows_notifications_in_StreamTopic` from §5.

One simplification versus the server: topic-wildcard mentions server-side additionally intersect with `topic_participant_user_ids`. Zulu does not need that check — if the user was not a topic participant, the server never set `topic_wildcard_mentioned` in their flags in the first place.

State the service must hold per user: the `user_settings` object, the `subscriptions` array (notification fields + `is_muted`), the `user_topics` map keyed by `(stream_id, casefolded topic)`, and the `muted_users` set — each kept current from the corresponding event type.

---

## 14. Things that are not obvious

- **`enable_offline_*` is a misnomer.** It gates DMs *and* mentions, in both the idle and online paths.
- **Muted topic beats every channel and global setting — but not a personal mention.** `mention_push_notify` is computed purely from the `mentioned` flag and `enable_offline_push_notifications`; it never passes through `user_allows_notifications_in_StreamTopic`. So `@**you**` in a muted topic still pushes, while `@**all**` in the same topic does not (wildcard eligibility *does* go through the resolver). Confirmed by the help center: "Messages in muted topics do not generate notifications (including alert word notifications), **unless you are mentioned**" ([zulip.com/help/mute-a-topic](https://zulip.com/help/mute-a-topic)). Same for a muted channel.
- **Followed topic is not "unmute plus".** It is a separate additive path that bypasses channel mute and the per-channel override. `FOLLOWED` does not make `stream_push_notify` true.
- **`UNMUTED` (2) only matters inside a muted channel.** In an unmuted channel it behaves identically to `INHERIT`.
- **`wildcard_mentions_notify` is the only setting where a per-channel value beats a channel mute.**
- **Topic lookup is case-insensitive.**
- **Message-edit re-notification is different.** `maybe_enqueue_notifications_for_message_update` bails out for DMs entirely, for previously-mentioned users, and whenever any stream/followed-topic notify flag is set (assumed already notified). If Zulu notifies on edits, it needs its own rule.
- **The server re-checks at delivery time**: if the message is already marked `read` when the push worker runs, the push is dropped. Zulu should do the same — drop a queued push when a `update_message_flags` `read` event arrives for that message first.
- **Empty topics** are legal since FL 334; `realm_empty_topic_display_name` from register is the display string for `""`.
- **Muted senders' messages are auto-marked-read** by the server, which independently suppresses notifications.
- **Soft-deactivated (`long_term_idle`) users** are prefiltered out of the send path unless they have a notification setting, alert word, mention, topic participation, or a FOLLOWED policy on the topic ([`stream_subscription.py` L258-L324](https://github.com/zulip/zulip/blob/main/zerver/lib/stream_subscription.py)). A user filtered out here cannot be notified at all. Zulu is unlikely to hit this since its users are active by definition.

---

## 15. How the official clients model this

Useful as a sanity check on Zulu's own data model — and as a warning about what they *don't* do.

### zulip-flutter

Server floor is `kMinAllowedZulipFeatureLevel = 277` ([`lib/api/core.dart`](https://github.com/zulip/zulip-flutter/blob/main/lib/api/core.dart)), so it carries no legacy `muted_topics` path at all.

`Subscription` ([`lib/api/model/model.dart`](https://github.com/zulip/zulip-flutter/blob/main/lib/api/model/model.dart)) keeps the five toggles as `bool?` — same tri-state — plus non-null `isMuted`, `pinToTop`, `color`. It deliberately drops `in_home_view`.

```dart
enum UserTopicVisibilityPolicy {
  none(apiValue: 0), muted(apiValue: 1), unmuted(apiValue: 2),
  followed(apiValue: 3), unknown(apiValue: null);
}
```

`unknown` is a parse-only sentinel so an unrecognized int round-trips without throwing; the store refuses to persist it. zulip-mobile solves the same problem with a `UserTopicVisibilityPolicy.isValid(n)` guard at the reducer boundary. Zulu should do one or the other — servers newer than the client will send policy values it has never heard of.

Storage shape, copied in both clients: `Map<channelId, Map<topic, policy>>`, where **`none` is represented by absence** and an emptied per-channel map is pruned. flutter's topic keys compare case-insensitively (`makeTopicKeyedMap`); zulip-mobile's are plain case-sensitive strings, which is a bug relative to the server's `Lower(topic_name)` unique constraint. Match flutter.

### The visibility split — relevant but not the same question

Both clients implement a two-function split in [`lib/model/channel.dart`](https://github.com/zulip/zulip-flutter/blob/main/lib/model/channel.dart):

- `isTopicVisibleInChannel(channelId, topic)` — for UI already scoped to one channel. Ignores channel mute entirely: `muted` → false, everything else → true.
- `isTopicVisible(channelId, topic)` — for cross-channel UI (inbox, combined feed). Channel mute is consulted **only** when the policy is `none`; not subscribed is treated as muted.

This is *visibility*, not notifiability. It does not include the per-channel notification toggles or the global settings, and `followed` vs `unmuted` collapse to the same answer. Do not reuse it as the notification predicate — but do reuse the split itself for Zulu's unread/inbox UI, since it is the same distinction Zulip's own UI makes.

Their action sheets encode the legal transitions ([`lib/widgets/action_sheet.dart`](https://github.com/zulip/zulip-flutter/blob/main/lib/widgets/action_sheet.dart)), gated on `store.zulipFeatureLevel >= 219` for follow:

- Channel **not** muted: `muted` → offer {none, followed}; `none`/`unmuted` → offer {muted, followed}; `followed` → offer {muted, none}.
- Channel muted: `none`/`muted` → offer {**unmuted**, followed}; `unmuted` → offer {muted, followed}; `followed` → offer {muted, none}.

The only difference: in a muted channel the "make visible" option is `unmuted` (2), not `none` (0), because `none` there resolves to invisible. Zulu's UI should do the same.

### Neither client computes "would this notify"

This is the headline finding. `pushNotifications` / `emailNotifications` / `desktopNotifications` / `audibleNotifications` / `wildcardMentionsNotify` appear in zulip-flutter only in the model declaration, the `SubscriptionProperty` enum, and the event-apply loop. **Nothing reads them.** flutter's `UserSettingName` enum does not even include the global notification settings, so the nullable per-channel bools are structurally unresolvable in that store.

zulip-mobile gets one line further ([`src/streams/getIsNotificationEnabled.js`](https://github.com/zulip/zulip-mobile/blob/main/src/streams/getIsNotificationEnabled.js)):

```js
export default (subscription, userSettingStreamNotification) =>
  subscription?.push_notifications ?? userSettingStreamNotification;
```

…and it is used only to render the settings switch, not to decide anything about a message. Its `Subscription` type even marks `audible_notifications` / `desktop_notifications` write-only in Flow specifically so nobody reads them before the inheritance logic exists.

There is no `shouldNotify` in either repo. Both clients store the settings faithfully and let the server decide. **Zulu is doing something neither official client does**, so there is no reference implementation to copy — §13 is the spec, derived from the server.

### Notification payload shape

`NotifPayloadNewMessage` ([`lib/api/notifications.dart`](https://github.com/zulip/zulip-flutter/blob/main/lib/api/notifications.dart)): `realmUrl`, `realmName?`, `userId`, `senderId`, `senderAvatarUrl`, `senderFullName`, `recipient`, `messageId`, `time`, `content`. `NotifPayloadRecipient` is a sealed type discriminated **by key presence** (`channel_id` present → channel recipient) rather than by `recipient_type`. There is **no `trigger` field** in either client's payload model — consistent with the server, which uses the trigger only to pick an alert subtitle.

---

## 16. Could not determine

- **Whether holding a long-lived event queue is acceptable to Zulip server operators at scale**, and what `MOBILE_EVENT_QUEUE_TIMEOUT_SECS` (12 h, server-configurable) means for a service holding one queue per user. Not answerable from the API; needs a load test against a real server.
- **Whether `client_capabilities` or a client-name convention exists to register an event queue that does *not* count toward `receiver_is_off_zulip`.** No such flag was found; `accepts_messages()` is simply "the queue requested `message` events" and requesting no message events defeats the purpose.
- **The exact interaction between Zulu's pushes and the server's own APNs pushes** when the same user also runs the official mobile app — both would fire. Not a settings question; needs a product decision.
- **Whether every self-hosted server exposes `zulip_feature_level` high enough for `user_topics`.** Zulu should degrade: below FL 134, fall back to `muted_topics`; below FL 219, `FOLLOWED` does not exist and followed-topic triggers are dead code.
