# Zulip's own notifications go quiet

Type: grilling
Status: open
Blocked by: 03, 13

## Question

Our service holding an event queue makes Zulip believe the user is at their desk. What do we do about it?

`receiver_is_off_zulip()` counts any queue accepting `message` events, so the moment the notification service connects for a user, Zulip stops sending that user its own push **and email** notifications. That is fine while our service works and silently harmful when it does not — a user whose worker has crashed gets nothing from anyone.

Decide:
- Whether suppressing Zulip's own notifications is desirable (no duplicates with the official app) or dangerous (single point of failure).
- What the service does when it cannot deliver — does it disconnect its queue so Zulip takes over again, and how fast?
- How the user is told their notifications are degraded.
- Whether a user running both Zulu and the official Zulip app gets one notification or two, and which we want.
- Whether any register-time capability exempts a queue from this, and if not, whether it is worth proposing upstream.

Discovered by [Zulip real-time events API](02-zulip-events-api.md) and [Zulip's notification settings model](03-zulip-notification-settings.md).
