# Zulip real-time events API

Type: research
Status: resolved

## Question

What exactly does a client get from Zulip's event system, and what does a robust consumer look like?

Find:
- `/register` — the `event_types` and `fetch_event_types` options, what the initial state snapshot contains, and how big it gets on a busy realm.
- The longpoll `/events` loop: queue ids, `last_event_id`, heartbeats, and the `BAD_EVENT_QUEUE_ID` re-register path.
- Queue expiry rules and what a client must do to recover without losing events.
- The event types relevant to v1: `message`, `update_message`, `delete_message`, `reaction`, `update_message_flags`, `subscription`, `stream`, `typing`, `user_settings`, `muted_topics` / user topic events, `presence`.
- How unread state arrives (`unread_msgs` in the register snapshot) and how it is kept current.
- Whether one API key can hold several concurrent event queues — the app and the notification service will each want one.

## Research output

`.scratch/zulu-client/research/02-zulip-events-api.md`

## Answer

`POST /register` for the snapshot, then longpoll `GET /events?queue_id&last_event_id` with a ~90s server timeout and 45–55s heartbeats. Event ids increase but skip — flag events get compressed in-queue. Queues idle out after 10 minutes by default, swept every minute, with the clock refreshed on connect rather than on event; `BAD_EVENT_QUEUE_ID` is an HTTP 400 and recovery is a full re-register plus a message-tail refetch, never a partial resync. `idle_queue_timeout` (`"mobile"` = 12h) exists but only on very recent servers, so assume 10 minutes.

Concurrent queues on one API key are uncapped, so the app and the service can each hold one. But holding a queue that accepts `message` events makes `receiver_is_off_zulip()` false, which suppresses Zulip's own push **and email** notifications for that user — see [Zulip's own notifications go quiet](19-zulip-push-suppression.md).

Corrections to assumptions in the ticket: `muted_topics` is superseded by `user_topic`; `subscription` events do not mutate unread state (the server asynchronously emits `update_message_flags`, sometimes minutes later); `apply_markdown` defaults to `false` and must be passed explicitly. Unread state is tri-valued, not boolean — `old_unreads_missing` is a third case, and `MAX_UNREAD_MESSAGES` is 50000.

Full findings: `.scratch/zulu-client/research/02-zulip-events-api.md`
