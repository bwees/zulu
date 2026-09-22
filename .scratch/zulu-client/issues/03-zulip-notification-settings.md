# Zulip's notification settings model

Type: research
Status: resolved

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

## Answer

Yes — all four state layers are readable and writable by a third party, and the decision is fully replicable. Globals on `UserProfile` (`PATCH /settings`), per-channel tri-state on `Subscription` where `null` means inherit (`POST /users/me/subscriptions/properties`), `UserTopic.visibility_policy` as `INHERIT/MUTED/UNMUTED/FOLLOWED` (`POST /user_topics`), and `MutedUser`. All four come back in one `POST /register` and stay current via their matching events.

Precedence: muted topic → muted channel → per-channel value if non-null → global, then an eight-way ordered trigger switch from DM down to the channel setting.

Four findings that change the design:

- **The server never tells clients its decision** — `internal_data` is stripped from `GET /events`. The service must reimplement the resolver; the per-user `flags` field is the only trustworthy mention signal, so never re-parse content.
- **Personal mentions ignore every mute.** `@**you**` in a muted topic still pushes; `@**all**` in the same topic does not.
- **`FOLLOWED` is an additive channel**, not a stronger unmute — it bypasses both channel mute and the per-channel push override, and answers only to the global followed-topic setting.
- **Neither zulip-flutter nor zulip-mobile implements this**, so there is no reference to copy. The research doc's §13 pseudocode is the spec.

Full findings: `.scratch/zulu-client/research/03-zulip-notification-settings.md`
