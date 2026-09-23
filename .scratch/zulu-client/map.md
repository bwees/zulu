# Zulu — native Apple Zulip client

Label: wayfinder:map

## Destination

A handoff-ready implementation spec for **Zulu**: a SwiftUI client for iOS and macOS with Discord-style navigation and topics as first-class citizens, plus the Go + SQLite notification service that feeds it. The spec covers architecture, domain model, navigation, the Zulip integration strategy, and the service's API contract in enough detail that build sessions execute it without re-deciding anything.

## Notes

**Domain**: Zulip client software. Apple platforms (SwiftUI, GRDB, APNs, iCloud) and a Go backend service.

**Repo**: `github.com/bwees/zulu`. Bundle identifier prefix `com.bwees.zulu`. CI builds on every push and PR.

**Fixed decisions from charting** — these are settled, do not reopen:

- **v1 feature scope** — daily-driver core: read/send, channels + topics, DMs, reactions, replies/quotes, file and image upload/view, markdown compose, unread and mark-read, notification controls, search, auth (SSO + password). Out: drafts sync, scheduled send, edit-history UI, admin/org settings. Polls were originally out and are now in — see [Polls](issues/22-poll-support.md).
- **Single realm in v1.** One Zulip organization signed in at a time. The data model should not foreclose multi-realm later, but no multi-realm UI.
- **"Servers" are user-defined channel groups**, created and named by the user, client-side, synced across the user's devices via iCloud. Not Zulip realms.
- **Channel render mode is auto-detected** — forum (topic list) vs flat chat — with a per-channel user override that syncs via iCloud alongside groups.
- **Works against any Zulip server.** No server-side cooperation, no admin access, no plugins. Public REST and events API only.
- **Notification service**: one Go instance, hosted by the dev, serving many users. SQLite. Holds each user's Zulip API key to run an event queue on their behalf.
- **APNs payloads carry plaintext** sender, channel, topic, and body.
- **Notification controls mirror Zulip's own** per-channel and per-topic settings via the API. No parallel preference store.
- **Local store is SQLite via GRDB**, local-first: the event queue writes, the UI reads only from the DB.
- **Code structure**: shared Swift packages for domain, store, API client, and sync; two thin SwiftUI app targets (iOS, macOS) owning their own navigation.
- **Minimum deployment target is iOS 27** and its macOS contemporary. No back-deployment, no availability branching.
- **Liquid Glass throughout, per Apple's HIG.** Glass belongs to the navigation and control layer; content stays opaque. Never glass on glass. A consequence learned in the nav prototype: glass bars sample whatever sits behind them in the window, so views underneath must be unmounted rather than merely covered.

**Skills every session should consult**: `/grilling`, `/domain-modeling`. Go tickets also: `/golang-how-to`, `/golang-project-layout`, `/golang-uber-fx`, `/golang-database`, `/golang-security`.

**Mode**: building. The client is now under construction in `App` and `Packages/ZuluKit`;
the map keeps recording decisions, but the destination is working software, not only a spec.
The notification service is **deferred** — its tickets stay open and unworked until the client
is worth notifying about.

## Decisions so far

<!-- one line per resolved ticket -->

- [Zulip auth for native clients](issues/01-zulip-auth-api.md) — password is `fetch_api_key`; SSO is the undocumented `mobile_flow_otp` browser round-trip. An account has exactly **one** API key, so the app and the service cannot hold separate credentials.
- [Zulip real-time events API](issues/02-zulip-events-api.md) — `/register` then longpoll `/events`; queues idle out in 10 minutes and recovery is a full re-register. Concurrent queues per key are fine, but holding one suppresses Zulip's own notifications.
- [Zulip's notification settings model](issues/03-zulip-notification-settings.md) — all four settings layers are readable and writable, and the server's decision is reimplementable, but it is never sent to clients. Personal mentions ignore every mute.
- [APNs from a Go service, multi-device](issues/04-apns-for-go-senders.md) — `apns-collapse-id` gives notifications a predictable identity for cross-device dismissal; there is no delete API, so foreground reconciliation is the backstop. `sideshow/apns2` is the only real library and is dormant.
- [Zulip message content model](issues/05-zulip-message-model.md) — render the server's `rendered_content` HTML natively; never re-parse markdown. The topic field is `subject` on the wire.
- [iPhone navigation shell](issues/06-iphone-navigation.md) — the Discord-style drawer shell wins over a native tab bar and a flat topic inbox. Three levels deep at most; DMs are a rail entry.
- [Local store schema and sync model](issues/11-local-store-schema.md) — settled by building it: GRDB, six tables, DM conversations derived from a participant key rather than a table. Fetch-gap tracking and retention are still missing.
- [macOS navigation shell](issues/07-macos-navigation.md) — settled by building it: one window, a rail-plus-list sidebar beside the conversation, forum topics nested under a disclosure, selection shared with iOS through the model's destination. The menu bar, ⌘K, an `NSTextView` composer, hover actions and running-app notifications came with it.
- [Swift package layout and module boundaries](issues/17-package-layout.md) — settled by building it: `ZulipAPI`, `ZuluMarkup`, `ZuluStore`, `ZuluSync`, with GRDB stopping at the store.

## Not yet specified

- **DM section design.** Group DMs, DM search, and unread DMs within the chosen drawer shell.
- **Search UX and API mapping.** Which subset of Zulip's search operators gets a UI, and where search lives in the drawer shell.
- **File upload and attachment viewing.** Picker, progress, inline rendering, and the authenticated-media fetch path the message-model research pinned down.
- **Message actions.** Reactions picker, quote-reply, edit, delete, move-to-topic.
- **Connection and error UX.** Reconnect, queue expiry, server unreachable, auth expiry — and the degraded-notifications state the push-suppression ticket will define.
- **Onboarding and account switching flow.** First-run, realm URL entry, sign-out, token revocation.
- **Notification Service Extension on macOS.** Reportedly unreliable; gates avatars and communication notifications there. Needs an on-device spike before the Mac notification design is settled.
- **Testing strategy.** What gets unit tests, what gets snapshot tests, how the Go service is tested against a fake Zulip.
- **User presence and status.** How presence is fetched and kept current, its polling cost on mobile, how much arrives in the register snapshot, and whether the client publishes its own presence. The rendering is decided; the mechanism is not.
- **Rate limiting and API etiquette.** Backfill pacing, Zulip's rate limits, service-side request budgeting across many users.

## Out of scope

- **Visual design system and branding** — colors, typography, app icon, custom component library. The spec uses system SwiftUI styling and Liquid Glass defaults.
- **Go service operations** — deployment target, monitoring, backups, scaling past one box. Its build and test pipeline is in scope; how it runs in production is not.
- **Android and web clients** — Apple platforms only.


## Shortcuts taken, to be paid back

- **Message rendering uses the system HTML importer.** `MessageContent` converts Zulip's `rendered_content` with `NSAttributedString`'s HTML document type. It is slow, main-thread-only, and drops Zulip-specific structure — spoilers, code-block languages, mention chips. The research settled that a native parse of the server HTML into a view tree is what the client needs; this is a stopgap so messages are readable now.
- **Channel groups sync through iCloud key-value storage.** See [Channel groups and iCloud sync](issues/10-channel-groups-icloud-sync.md).
- **Forum-vs-chat detection is a placeholder.** A channel renders as a forum when it has more than one topic. [Forum-vs-chat auto-detection](issues/09-channel-mode-detection.md) is where the real rule gets decided.
- **No local echo on send.** A sent message appears when the event queue returns it. `queue_id` + `local_id` exist for optimistic echo and are unused.
- **Topics are fetched per channel in a loop** after each register, because there is no bulk endpoint. Fine at small channel counts, rude at large ones.

### Paid back

- **Message rendering is now native.** `ZuluMarkup` parses Zulip's `rendered_content` into blocks and the app lays them out: paragraphs with inline styling, quotes, code blocks, lists, uploaded images, realm custom emoji, and mentions. The `NSAttributedString` HTML importer is gone. 18 tests cover it, several written from HTML captured off zulip.futo.org.

- **Message rendering paid back further.** Quote-and-reply is recognised as its own block and drawn as a compact Discord-style reply line, and uploads now work from the composer. Polls remain unrendered — they ride the `submessages` protocol, not markdown, and are now [their own ticket](issues/22-poll-support.md).
- **Read state is still crude.** Opening a conversation marks everything in it read, whether or not it was seen. [Read and unread state](issues/12-read-state-model.md) is where that gets fixed.
