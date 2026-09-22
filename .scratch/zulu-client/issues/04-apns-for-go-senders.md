# APNs from a Go service, multi-device

Type: research
Status: claimed

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
