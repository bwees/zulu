# Zulip real-time events API

Type: research
Status: claimed

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
