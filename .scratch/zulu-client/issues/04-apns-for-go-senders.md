# APNs from a Go service, multi-device

Type: research
Status: resolved

## Question

What does the Go service need to deliver good iOS and macOS notifications for many users across many devices?

Find:
- Token-based (p8/JWT) APNs auth from Go, the current library landscape, token refresh rules, and the sandbox vs production split.
- Device token lifecycle: registration, rotation, and the feedback path for dead tokens so SQLite does not accumulate garbage.
- Notification grouping: `thread-id`, `apns-collapse-id`, and summary formatting — the shape that makes a topic read as one conversation.
- Notification Service Extension capabilities: rewriting content, attaching avatars, and communication notifications via `INSendMessageIntent`.
- Inline reply and other notification actions, and what the app must do to send a reply from the extension.
- Removing or updating a delivered notification when the user reads the message on another device.
- macOS specifics: how APNs registration differs for a native Mac app and whether the same payloads work.

## Research output

`.scratch/zulu-client/research/04-apns-for-go-senders.md`

## Answer

`apns-collapse-id` is the piece everything else hangs off: Apple documents that for remote notifications it becomes `UNNotificationRequest.identifier`, so a deterministic id per message makes the delivered notification predictable on every device — which is exactly what `removeDeliveredNotifications(withIdentifiers:)` needs to clear a notification after the user reads elsewhere.

There is no APNs delete API. Clearing on read needs a background push, which Apple caps at 2–3/hour and does not guarantee, so foreground reconciliation via `deliveredNotifications()` has to be the backstop. On macOS it has to be the *primary* mechanism: AppKit has no `didReceiveRemoteNotification:fetchCompletionHandler:` and only delivers pushes while the app runs.

Go side: `sideshow/apns2` is the only real option and is dormant — last release Oct 2024, untagged master. Token refresh is correct. Two dependency floors must be raised in our own `go.mod`: `golang-jwt/jwt/v5 ≥ v5.3.1` and `golang.org/x/net ≥ v0.59.0`. It also cannot send `apns-expiration: 0`, which read-state pushes want, so it goes behind an interface.

Flagged risk: `UNNotificationServiceExtension` is documented macOS 10.14+ but Apple's own guide is iOS-only and it reportedly does not launch reliably on Mac. It gates avatars and communication notifications there — prototype it early.

Full findings: `.scratch/zulu-client/research/04-apns-for-go-senders.md`
