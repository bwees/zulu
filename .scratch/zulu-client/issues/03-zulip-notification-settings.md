# Zulip's notification settings model

Type: research
Status: claimed

## Question

What per-channel and per-topic notification vocabulary does Zulip expose, and can a third-party service read and write all of it?

Find:
- Realm-wide user settings for push, email, and desktop notifications, and which apply to channels vs DMs vs mentions.
- Per-channel subscription settings: `push_notifications`, `desktop_notifications`, `audible_notifications`, `wildcard_mentions_notify`, and their tri-state inherit behaviour.
- Per-topic state: the user-topic visibility policy (followed / unmuted / muted / inherit), how it is set, and which events announce changes.
- Mention semantics: personal, wildcard, user-group, and how `@topic` behaves.
- Exactly which fields a service must evaluate to decide "should this message notify this user" the same way Zulip's own server would.

## Research output

`.scratch/zulu-client/research/03-zulip-notification-settings.md`
