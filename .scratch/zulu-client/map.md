# Zulu — native Apple Zulip client

Label: wayfinder:map

## Destination

A handoff-ready implementation spec for **Zulu**: a SwiftUI client for iOS and macOS with Discord-style navigation and topics as first-class citizens, plus the Go + SQLite notification service that feeds it. The spec covers architecture, domain model, navigation, the Zulip integration strategy, and the service's API contract in enough detail that build sessions execute it without re-deciding anything.

## Notes

**Domain**: Zulip client software. Apple platforms (SwiftUI, GRDB, APNs, iCloud) and a Go backend service.

**Fixed decisions from charting** — these are settled, do not reopen:

- **v1 feature scope** — daily-driver core: read/send, channels + topics, DMs, reactions, replies/quotes, file and image upload/view, markdown compose, unread and mark-read, notification controls, search, auth (SSO + password). Out: polls, todo widgets, drafts sync, scheduled send, edit-history UI, admin/org settings.
- **Single realm in v1.** One Zulip organization signed in at a time. The data model should not foreclose multi-realm later, but no multi-realm UI.
- **"Servers" are user-defined channel groups**, created and named by the user, client-side, synced across the user's devices via iCloud. Not Zulip realms.
- **Channel render mode is auto-detected** — forum (topic list) vs flat chat — with a per-channel user override that syncs via iCloud alongside groups.
- **Works against any Zulip server.** No server-side cooperation, no admin access, no plugins. Public REST and events API only.
- **Notification service**: one Go instance, hosted by the dev, serving many users. SQLite. Holds each user's Zulip API key to run an event queue on their behalf.
- **APNs payloads carry plaintext** sender, channel, topic, and body.
- **Notification controls mirror Zulip's own** per-channel and per-topic settings via the API. No parallel preference store.
- **Local store is SQLite via GRDB**, local-first: the event queue writes, the UI reads only from the DB.
- **Code structure**: shared Swift packages for domain, store, API client, and sync; two thin SwiftUI app targets (iOS, macOS) owning their own navigation.

**Skills every session should consult**: `/grilling`, `/domain-modeling`. Go tickets also: `/golang-how-to`, `/golang-project-layout`, `/golang-uber-fx`, `/golang-database`, `/golang-security`.

**Mode**: planning only. Produce decisions, not deliverables.

## Decisions so far

<!-- one line per resolved ticket -->

## Not yet specified

- **DM section design.** Discord puts DMs in their own top-level space. How group DMs, DM search, and unread DMs surface on iPhone vs Mac is dim until the navigation shells exist.
- **Search UX and API mapping.** Zulip's search operators are powerful; which subset gets a UI, and where search lives in each shell, waits on navigation.
- **File upload and attachment viewing.** Picker, progress, inline image/video rendering, quick-look on Mac.
- **Message actions.** Reactions picker, quote-reply, edit, delete, move-to-topic — which are in v1's context menu and how they differ per platform.
- **Connection and error UX.** What the user sees during reconnect, queue expiry, server unreachable, and auth expiry.
- **Onboarding and account switching flow.** First-run, realm URL entry, sign-out, and token revocation.
- **Mac keyboard and menu surface.** Command palette, menu bar, keyboard shortcuts.
- **Testing strategy.** What gets unit tests, what gets snapshot tests, how the Go service is tested against a fake Zulip.
- **Rate limiting and API etiquette.** Backfill pacing, Zulip's rate limits, service-side request budgeting across many users.

## Out of scope

- **App Store distribution and review** — signing, notarization, privacy manifests, TestFlight, listing. A separate effort once the app exists.
- **Visual design system and branding** — colors, typography, app icon, custom component library. The spec uses system SwiftUI styling.
- **Go service operations** — deployment target, CI/CD, monitoring, backups, scaling past one box. The spec covers the service's design and API, not how it runs.
- **Android and web clients** — Apple platforms only.
