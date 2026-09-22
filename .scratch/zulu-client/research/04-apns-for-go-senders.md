# APNs from a Go service, multi-device

Research notes for issue `04-apns-for-go-senders.md`. Date: 2026-09-22.

Sources are Apple's official developer documentation (fetched from the DocC JSON behind
`developer.apple.com/documentation/...`) and the upstream Git repositories of the Go libraries.
Anything sourced from a forum post or that I could not confirm is marked as such.

---

## 1. Transport

APNs is HTTP/2 over TLS 1.2+. There is no other protocol; the legacy binary protocol was
removed on 2021-03-31.

| | |
|---|---|
| Production | `https://api.push.apple.com:443` |
| Development (sandbox) | `https://api.sandbox.push.apple.com:443` |
| Alternate port on either | `2197` |
| Method / path | `POST /3/device/<device_token>` (`<device_token>` = hex string) |
| Max payload | 4096 bytes (`4 KB`); VoIP 5120 bytes |

Payloads must not be compressed. APNs ignores HTTP/2 `PRIORITY` frames — do not send them.
APNs may terminate a connection with a `GOAWAY` frame whose payload is JSON with a `reason`
key drawn from the same error-string table as normal responses.

Source: <https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns>

### Apple's stated best practices for a high-volume sender

- Make an **uncached DNS query** before each connection so traffic spreads across APNs servers.
- Spread pushes across many connections; avoid bursts down one connection.
- Reuse a connection "for many hours to days"; send an HTTP/2 `PING` after ~1 hour idle.
- Always set a unique `apns-id` so you can correlate errors.
- Never assume a device-token length.
- Honour the HTTP/2 `SETTINGS` frame's stream limits — the number of concurrent streams
  varies with server load and auth method. **With token auth, APNs allows only one stream
  until you have posted a request carrying a valid token.**

Same source as above.

---

## 2. Request headers (exact names)

| Header | Required? | Notes |
|---|---|---|
| `:method` | required | `POST` |
| `:path` | required | `/3/device/<device_token>` |
| `authorization` | required for token auth | `bearer <provider_token>` — literal lowercase `bearer`, one space |
| `apns-push-type` | required on watchOS 6+, recommended everywhere else | see values below |
| `apns-topic` | required | app bundle ID, possibly with a push-type suffix |
| `apns-id` | optional | canonical lowercase UUID, 8-4-4-4-12. Echoed back in the response; APNs generates one if omitted |
| `apns-expiration` | optional | UNIX epoch seconds (UTC). `0` = try once, do not store. Omitted = APNs default storage policy |
| `apns-priority` | optional | `10` immediate (default), `5` power-aware, `1` prioritises device power over everything and will not wake the device |
| `apns-collapse-id` | optional | ≤ **64 bytes**. Merges repeat notifications into one |

Response headers: `apns-id`, `:status`, and `apns-unique-id` (development environment only —
use it to look up the delivery log in Push Notifications Console).

`apns-push-type` values, with the `apns-topic` suffix each one requires:

| Value | `apns-topic` |
|---|---|
| `alert` | bundle ID, no suffix |
| `background` | bundle ID, no suffix; **must** use `apns-priority: 5` — priority 10 is an error |
| `voip` | `<bundleID>.voip` |
| `complication` | `<bundleID>.complication` |
| `fileprovider` | `<bundleID>.pushkit.fileprovider` |
| `location` | `<bundleID>.location-query` (token auth only) |
| `liveactivity` | `<bundleID>.push-type.liveactivity` |
| `widgets` | `<bundleID>.push-type.widgets` |
| `controls` | `<bundleID>.push-type.controls` |
| `pushtotalk` | `<bundleID>.voip-ptt` |
| `mdm` | UID from the MDM push certificate |

Zulu needs `alert` and `background` only.

HPACK guidance from Apple (relevant when writing a raw HTTP/2 client — most Go libraries
do not expose this): encode `:path` and `authorization` as *literal header fields without
indexing*; encode `apns-id`, `apns-expiration`, `apns-collapse-id` with incremental indexing
on first use and without indexing thereafter; everything else with incremental indexing.

Source: <https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns>

---

## 3. Token-based (p8/JWT) auth

### The key

Created at <https://developer.apple.com/account/resources/keys/list>. Apple returns a
**10-character Key ID** and a `.p8` file containing a PKCS#8 EC private key. The Team ID is
also 10 characters.

Two kinds of key exist:

- **Team-scoped keys** — valid for every topic in the team. Restricted to either Sandbox or
  Production. Max **two keys per environment**. Apple recommends environment-specific keys;
  legacy keys that work in both environments continue to be supported.
- **Topic-specific keys** — scoped to named topics in one environment. Max **200 keys per
  environment**, up to **400 topics per key**. A topic-specific key may have at most one
  related key in the same environment; both may be used on a single connection.

Source: <https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns>

### The JWT

```
header:  { "alg": "ES256", "kid": "<10-char Key ID>" }
claims:  { "iss": "<10-char Team ID>", "iat": <unix seconds> }
```

`ES256` is the **only** algorithm APNs supports. `iat` must be no more than one hour old or
APNs returns `403 ExpiredProviderToken`. The signed, Base64URL-encoded JWT goes in
`authorization: bearer <jwt>`.

### Refresh rules — the important operational constraint

> "Refresh your token no more than once every **20 minutes** and no less than once every
> **60 minutes**."

Too-frequent refresh on the same connection yields `429 TooManyProviderTokenUpdates`. Too
old yields `403 ExpiredProviderToken`. The safe pattern is one goroutine regenerating the
JWT on a ~40–50 minute ticker, shared by all senders, with the current token read under a
mutex or `atomic.Pointer`.

Source: <https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns>

### Connection pinning rules (these bite in a multi-tenant/self-hosted setup)

- A connection cannot be mapped to multiple teams. Separate connection pools per developer
  account.
- APNs binds a team ID and its bundle IDs to a connection **on the first push**. Afterwards,
  using a different team, or a newly added bundle ID, is an error. Adding a new topic means
  opening new connections.
- If you first push with a team-scoped key, you cannot then push with a topic-specific key
  or a team-scoped key from another environment on that connection. Errors:
  `403 UnrelatedKeyIdInToken`, `403 BadEnvironmentKeyIdInToken`.
- If you revoke a key, close all connections and open new ones.

Same source.

---

## 4. Sandbox vs production split

The environment is determined by the **app's entitlement at build/sign time**, not by anything
the server does. The server must know which environment each stored device token belongs to
and send it to the matching host.

| Platform | Entitlement key | Values |
|---|---|---|
| iOS / iPadOS / tvOS / watchOS / visionOS | `aps-environment` | `development`, `production` |
| macOS | `com.apple.developer.aps-environment` | `development`, `production` |

Xcode sets the value from the provisioning profile: development profile → `development`;
production profile and TestFlight → `production`. Apple's own docs state "the `development`
environment is also referred to as the `sandbox` environment."

Sources:
<https://developer.apple.com/documentation/bundleresources/entitlements/aps-environment>,
<https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.aps-environment>

**Implication for the Zulu device table:** store an explicit `environment` column
(`development` | `production`) alongside every token, set by the client at registration time.
Sending a sandbox token to production (or the reverse) returns `400 BadDeviceToken`, which is
indistinguishable at the protocol level from a genuinely dead token — so an environment bug
silently looks like mass token death. There is no API to ask APNs which environment a token
belongs to; the client must report it. The client can read its own value from the
embedded entitlement/provisioning profile, or you can infer it from build configuration.

---

## 5. Device token lifecycle

### Registration

- iOS/tvOS: `UIApplication.registerForRemoteNotifications()`, result in
  `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
- macOS: `NSApplication.registerForRemoteNotifications()` (macOS 10.14+), result in the
  `NSApplicationDelegate` method of the same name.
- Failure: `application(_:didFailToRegisterForRemoteNotificationsWithError:)` — set a flag
  and retry later.

Apple is explicit on two points:

> "Never cache device tokens in local storage. APNs issues a new token when the user restores
> a device from a backup, when the user installs your app on a new device, and when the user
> reinstalls the operating system. You get an up-to-date token each time you ask the system
> to provide the token."

> "You can't use the same device token for more than one app, even when the apps are on the
> same device."

So the client must call `register…` on **every launch** and re-POST the token to the Go
service every time (idempotent upsert), not only when it changes.

Source: <https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns>

### Rotation and garbage collection — there is no feedback service

The old binary-protocol feedback service is gone. The only documented signal that a token is
dead is the per-push response:

| Status | `reason` | Meaning |
|---|---|---|
| `410` | `Unregistered` | "The device token is inactive for the specified topic. There is no need to send further pushes to the same device token, unless your application retrieves the same device token" |
| `410` | `ExpiredToken` | The device token has expired |
| `400` | `BadDeviceToken` | Invalid token, **or the token doesn't match the environment** |
| `400` | `DeviceTokenNotForTopic` | Token doesn't match the `apns-topic` |

A `410` response body carries a `timestamp` key — milliseconds since epoch — "the time at
which APNs confirmed the token was no longer valid for the topic". This key is present
**only** for `410`.

Apple notes that status `410` "isn't considered an error condition" for the purposes of
connection throttling; `400`-class errors, especially `BadDeviceToken`, will get your
connection dropped if you accumulate them.

**Recommended SQLite reaping rule:** store `registered_at` per token row. On `410`, delete
the row **only if `registered_at < timestamp`** from the response body; if the app
re-registered the same token after that instant the token is live again and must be kept.
This is the direct consequence of Apple's "unless your application retrieves the same device
token" caveat. On `400 BadDeviceToken` / `DeviceTokenNotForTopic`, do not blind-delete —
first rule out an environment or topic bug, since a config error produces the same code
across every token at once.

Do not retry `BadDeviceToken`, `DeviceTokenNotForTopic`, `Forbidden`, `ExpiredToken`,
`Unregistered`, or `PayloadTooLarge`. `TooManyRequests` (429, same device token) may be
retried with delay. `5xx` may be retried after 15 minutes with backoff.

Full status/reason table:
<https://developer.apple.com/documentation/usernotifications/handling-notification-responses-from-apns>

Apple's Metrics documentation independently recommends building the reaper:

> "consider building a system to remove push tokens of inactive users and save on resources
> for your service."

Source: <https://developer.apple.com/documentation/usernotifications/viewing-the-status-of-push-notifications-using-metrics-and-apns>

### Storage behaviour worth knowing for a chat app

APNs stores **one notification per bundle ID per device**. If a device is offline and you
send five messages, four are dropped and only one (usually but not reliably the last) is
delivered when it reconnects. Default TTL in storage is 30 days or `apns-expiration`,
whichever is sooner. Consequence: the client cannot treat notifications as a complete event
stream — it must resync from the Zulip server on foreground.

Sources: the sending doc and the Metrics doc, both linked above.

---

## 6. Grouping a topic into one conversation

Three separate mechanisms, often confused:

### `thread-id` — grouping (stacking) in Notification Center

`aps.thread-id` (String). Surfaces as `UNNotificationContent.threadIdentifier`
(iOS 10+, macOS 10.14+, get-only on `UNNotificationContent`, settable on
`UNMutableNotificationContent`). Apple: "For remote notifications, the system sets this
property to the value of the `thread-id` key in the `aps` dictionary."

Notifications sharing a `thread-id` stack into one group. **This is the key for Zulu's
"messages grouped by topic"** — set `thread-id` to a stable identifier of the Zulip
stream+topic (or DM conversation), e.g. `stream:<stream_id>:<topic>` hashed if length is a
concern.

Sources:
<https://developer.apple.com/documentation/usernotifications/generating-a-remote-notification>,
<https://developer.apple.com/documentation/usernotifications/unnotificationcontent/threadidentifier>

### `apns-collapse-id` — replacement, not grouping

Request header, ≤ 64 bytes. It makes a **new push replace the previous one** rather than add
to the stack. Critically:

> "For remote notifications, the system sets this property [`UNNotificationRequest.identifier`]
> to the value of the `apns-collapse-id` key that you specified in the APNs request header…
> If your app doesn't set a value, the system automatically assigns an identifier."

Source: <https://developer.apple.com/documentation/usernotifications/unnotificationrequest/identifier>

**This is the single most useful fact for Zulu.** Setting `apns-collapse-id` to a value the
Go service computes deterministically (e.g. `z:<zulip_message_id>`) makes the delivered
notification's identifier *predictable on every device*, which is exactly what
`removeDeliveredNotifications(withIdentifiers:)` needs (see §9). Without it, identifiers are
random per device and cross-device dismissal is impossible without first enumerating
delivered notifications.

Note the trade-off: reusing one collapse ID per topic would make a topic show only its latest
message (WhatsApp-style "3 new messages" replacement), whereas a per-message collapse ID keeps
every message visible and stacked by `thread-id`. Per-message is the better fit for Zulu, and
also gives per-message dismissal.

### Summary line formatting

- `aps.alert.summary-arg` / `UNNotificationContent.summaryArgument` — **deprecated iOS 15 /
  iPadOS 15 / watchOS 8 / tvOS 15 with the message "summaryArgument is ignored"**. It is
  still nominally present on macOS (introduced 10.14, no deprecation recorded), but do not
  build on it. Note it does not even appear in Apple's current `alert` payload key table.
  Source: <https://developer.apple.com/documentation/usernotifications/unnotificationcontent/summaryargument>
  (deprecation is in the page's platform metadata, not its prose)
- `UNNotificationCategory.categorySummaryFormat` (iOS 12+, macOS 10.14+) — a format string
  for the summary description when the system groups the category's notifications. Set it
  client-side when registering categories.
- `hiddenPreviewsBodyPlaceholder` — the string shown when previews are off. `%u` is "the
  only supported formatting character" and expands to "the number of notifications with the
  same thread identifier", e.g. `"%u Messages"` → `"2 Messages"`. Use a `.stringsdict` via
  `NSString.localizedUserNotificationString(forKey:arguments:)` for plurals.
  Source: <https://developer.apple.com/documentation/usernotifications/unnotificationcategory/init(identifier:actions:intentidentifiers:hiddenpreviewsbodyplaceholder:categorysummaryformat:options:)>

### Communication notifications also group

`INSendMessageIntent.conversationIdentifier` is the grouping key the system uses for
communication notifications. Apple: "Provide a unique `conversationIdentifier` that
represents the conversation. Use the same identifier for each message that the user receives
in the same conversation. This is especially important for group conversations where the
group name and membership can change." Set it to the same topic identity you use for
`thread-id`.

---

## 7. `aps` payload keys (exact, current)

Keys inside `aps`:

| Key | Type | Notes |
|---|---|---|
| `alert` | Dictionary (recommended) or String | see below |
| `badge` | Number | `0` removes the badge |
| `sound` | String or Dictionary | `"default"` for system sound; dictionary form only for critical alerts |
| `thread-id` | String | grouping |
| `category` | String | must match a registered `UNNotificationCategory.identifier` |
| `content-available` | Number | `1` = background push; must not be combined with alert/badge/sound |
| `mutable-content` | Number | `1` = run the Notification Service Extension |
| `target-content-id` | String | which scene/window to bring forward → `targetContentIdentifier` |
| `interruption-level` | String | `"passive"`, `"active"`, `"time-sensitive"`, `"critical"` |
| `relevance-score` | Number | 0–1; highest is featured in the scheduled summary |
| `filter-criteria` | String | evaluated by `SetFocusFilterIntent` for Focus filtering |
| `stale-date`, `content-state`, `timestamp`, `event`, `dismissal-date`, `attributes-type`, `attributes` | | Live Activities only — not relevant to Zulu |

Keys inside `alert`: `title`, `subtitle`, `body`, `launch-image`, `title-loc-key`,
`title-loc-args`, `subtitle-loc-key`, `subtitle-loc-args`, `loc-key`, `loc-args`.

Keys inside the `sound` dictionary (critical alerts only): `critical` (Number, `1`), `name`
(String), `volume` (Number 0–1).

**Custom keys go as siblings of `aps`, never inside it** — "Don't add your own custom keys to
the `aps` dictionary; APNs ignores custom keys." They arrive as
`UNNotificationContent.userInfo`.

`interruption-level` maps to `UNNotificationInterruptionLevel` (iOS 15+, macOS 12+): cases
`passive`, `active`, `timeSensitive`, `critical`. `timeSensitive` requires the Time Sensitive
Notifications capability. Communication notifications break through Focus and the scheduled
summary *by default*, without needing `time-sensitive`.

Apple's explicit warning, which matters because Zulu's payloads carry plaintext sender,
channel, topic and body:

> "Don't include customer information or any sensitive data, like a credit card number, in a
> notification's payload. If you must include customer information or sensitive data, encrypt
> it before adding it to the payload. You can use a notification service app extension to
> decrypt the data on the user's device."

Source: <https://developer.apple.com/documentation/usernotifications/generating-a-remote-notification>

Suggested Zulu payload shape:

```json
{
  "aps": {
    "alert": { "title": "#channel > topic", "subtitle": "Sender Name", "body": "…" },
    "thread-id": "z:stream:123:general",
    "category": "ZULU_MESSAGE",
    "mutable-content": 1,
    "sound": "default",
    "interruption-level": "active"
  },
  "zulipMessageId": 987654,
  "zulipStreamId": 123,
  "zulipTopic": "general",
  "senderId": 42,
  "senderAvatarUrl": "https://…"
}
```

with headers `apns-push-type: alert`, `apns-priority: 10`,
`apns-collapse-id: z:987654`, `apns-topic: <bundle id>`.

---

## 8. Notification Service Extension

`UNNotificationServiceExtension` — iOS 10+, iPadOS 10+, Mac Catalyst 13.1+, **macOS 10.14+**,
watchOS 6+, visionOS 1+.
Source: <https://developer.apple.com/documentation/usernotifications/unnotificationserviceextension>

### Trigger conditions

The extension runs **only** when both are true:

1. `aps.mutable-content` is `1`, and
2. the payload includes an `alert` dictionary with title, subtitle, or body.

It also does not run if alerts are disabled for the app, or if the payload only plays a sound
or badges the icon.

### Timing

`didReceive(_:withContentHandler:)` has "about 30 seconds". If it runs out, the system calls
`serviceExtensionTimeWillExpire()` and you must return immediately. If you never call the
content handler, the system shows the original payload unchanged.

Source: <https://developer.apple.com/documentation/usernotifications/modifying-content-in-newly-delivered-notifications>

The extension ships as a bundle inside the app. Xcode's template sets
`NSExtensionPointIdentifier` to `com.apple.usernotifications.service` and
`NSExtensionPrincipalClass` to your `UNNotificationServiceExtension` subclass.
You must implement `didReceive(_:withContentHandler:)`; Apple "strongly recommends"
overriding `serviceExtensionTimeWillExpire()`.
Source: <https://developer.apple.com/documentation/usernotifications/unnotificationserviceextension>

### What it is for, in Zulu's case

- **Encrypting the payload end-to-end.** Given Apple's warning above, this is the clean fix
  for plaintext sender/topic/body: ship an opaque blob in a custom key and decrypt in the NSE.
  Apple documents exactly this pattern with a worked example.
- **Downloading avatars** as `UNNotificationAttachment` (iOS 10+, macOS 10.14+), which would
  otherwise blow the 4 KB payload limit.
- **Rewriting title/body** using local state (e.g. the user's local nickname for a sender).
- **Promoting to a communication notification** (below).

### Communication notifications (`INSendMessageIntent`)

This is what gets you the large avatar, the sender's name as the notification identity,
Focus/summary breakthrough, and the "Messages-like" look.

Setup:

1. Enable the **Communication Notifications** capability on the app target.
2. Add `INSendMessageIntent` to the `NSUserActivityTypes` array in `Info.plist`.

Per-notification, inside the NSE:

```swift
let handle = INPersonHandle(value: "unique-user-id-1", type: .unknown)
let avatar = INImage(named: "profilepicture.png")
let sender = INPerson(personHandle: handle, nameComponents: nil,
                      displayName: "Example", image: avatar,
                      contactIdentifier: nil, customIdentifier: nil)

let intent = INSendMessageIntent(recipients: nil,
                                 outgoingMessageType: .outgoingMessageText,
                                 content: "Message content",
                                 speakableGroupName: nil,
                                 conversationIdentifier: "unique-conversation-id-1",
                                 serviceName: nil,
                                 sender: sender,
                                 attachments: nil)

let interaction = INInteraction(intent: intent, response: nil)
interaction.direction = .incoming
try await interaction.donate()

let updatedContent = try request.content.updating(from: intent)
contentHandler(updatedContent)
```

Rules from Apple's doc:

- **Do not include the current user** in `recipients` for an incoming message — the system
  adds them.
- The sender's `INPerson.image` becomes the notification avatar.
- For group conversations, put the *other* participants in `recipients`, and set
  `speakableGroupName`; give the group its own avatar via
  `INIntent.setImage(_:forParameterNamed:)` on the `speakableGroupName` parameter, before
  donating.
- Use `INPersonHandleType.emailAddress` / `.phoneNumber` plus
  `INPersonSuggestionType.none` when you have a real contact handle, so it matches an address
  book entry exactly; otherwise use an app-specific `INPersonHandle` and pick the closest
  `INPersonSuggestionType`.
- Also donate **outgoing** interactions when the user sends a message (direction `.outgoing`,
  `sender` left `nil`) — Apple states this is required for correct breakthrough behaviour.

`UNNotificationContent.updating(from:)` returns a new `UNNotificationContent`; pass it to the
content handler **without mutating it**. It throws a `UNError.Code` if the provider object is
invalid. Availability: iOS 15+, macOS 12+, watchOS 8+, visionOS 1+ (the protocol
`UNNotificationContentProviding` has the same availability).

Sources:
<https://developer.apple.com/documentation/usernotifications/implementing-communication-notifications>,
<https://developer.apple.com/documentation/usernotifications/unnotificationcontent/updating(from:)>,
<https://developer.apple.com/documentation/usernotifications/handling-communication-notifications-and-focus-status-updates>

`INSendMessageIntent` availability: iOS 10+, **macOS 12.0+**, Mac Catalyst 13.1+, watchOS 3.2+,
visionOS 1+. Source: <https://developer.apple.com/documentation/intents/insendmessageintent>

---

## 9. Actions and inline reply

### Declaring

Register categories at launch with `UNUserNotificationCenter.current().setNotificationCategories(_:)`.
For inline reply use `UNTextInputNotificationAction` (iOS 10+, **macOS 10.14+**, watchOS 3+)
instead of `UNNotificationAction`.

`UNNotificationActionOptions`: `.authenticationRequired`, `.destructive`, `.foreground`.
`UNNotificationCategoryOptions`: `.customDismissAction`, `.allowInCarPlay`,
`.allowAnnouncement`, `.hiddenPreviewsShowTitle`, `.hiddenPreviewsShowSubtitle`.

Up to 10 actions shown when space is unlimited; at most 2 when space is limited. All action
identifiers must be unique across the whole app, even across categories.

The `category` key in the payload selects the category. The server side of this is trivially
one string; all the behaviour lives in the client.

### Handling the reply

The response arrives at
`UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:)`
**in the app**, not in the NSE. Downcast the `UNNotificationResponse` to
`UNTextInputNotificationResponse` and read `userText: String` ("If the user does not specify
any text, this property contains an empty string").

System action identifiers to handle: `UNNotificationDefaultActionIdentifier` (user tapped the
notification) and `UNNotificationDismissActionIdentifier` (only delivered if the category was
registered with `.customDismissAction`).

**Answer to the ticket's question "what must the app do to send a reply from the extension":**
it is not the extension. Selecting a text-input action launches the app *in the background*
and calls the delegate method; the app itself must have enough state (credentials, a network
client) to POST the reply to Zulip from a background launch, and must call the completion
handler when done. Practically this means: credentials in the Keychain with an accessibility
class that permits background access, a shared Swift package usable from a background launch,
and a bounded network timeout. A Notification Service Extension cannot handle actions at all —
it only ever gets to rewrite content before display.

Sources:
<https://developer.apple.com/documentation/usernotifications/declaring-your-actionable-notification-types>,
<https://developer.apple.com/documentation/usernotifications/handling-notifications-and-notification-related-actions>,
<https://developer.apple.com/documentation/usernotifications/untextinputnotificationresponse/usertext>

---

## 10. Removing a delivered notification when the message is read elsewhere

### The client API

| Symbol | Availability |
|---|---|
| `UNUserNotificationCenter.removeDeliveredNotifications(withIdentifiers: [String])` | iOS 10+, macOS 10.14+, watchOS 3+, visionOS 1+ |
| `UNUserNotificationCenter.removeAllDeliveredNotifications()` | same |
| `UNUserNotificationCenter.getDeliveredNotifications(completionHandler:)` / `deliveredNotifications() async -> [UNNotification]` | same |
| `UNUserNotificationCenter.setBadgeCount(_:withCompletionHandler:)` / `setBadgeCount(_:) async throws` | iOS 16+, macOS 13+, visionOS 1+ |

`removeDeliveredNotifications(withIdentifiers:)` takes values matching
`UNNotificationRequest.identifier`, and "ignores the identifiers of requests whose
notifications are not currently displayed in Notification Center". It is asynchronous and
returns immediately.

Sources:
<https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/removedeliverednotifications(withidentifiers:)>,
<https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/getdeliverednotifications(completionhandler:)>,
<https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/setbadgecount(_:withcompletionhandler:)>

### The mechanism

There is **no APNs "delete notification" request**. Everything is device-side. The only
documented way for the server to make a device clear a notification is to push a **background
notification** that wakes the app so it can call the removal API itself.

Background push requirements:

- Payload: `aps` containing **only** `content-available: 1`, plus custom keys as siblings.
- Headers: `apns-push-type: background`, `apns-priority: 5` (priority `10` is an error).
- App must have the **Background Modes → Remote notifications** capability.
- Delivered to `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`; the app
  gets **30 seconds**.

Apple's caveats, which make this unreliable as a *guarantee*:

> "The system treats background notifications as low priority… the system doesn't guarantee
> their delivery… don't try to send more than two or three per hour."

> "When the system receives a new background notification, it discards the older notification
> and only holds the newest one." Force-quitting the app discards a held notification.

Source: <https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app>

### Recommended design for Zulu

1. Set `apns-collapse-id` to a deterministic per-message value (`z:<message_id>`). Every
   device's `UNNotificationRequest.identifier` for that message is then the same known string.
2. When the Go service learns a message was read (from Zulip's read receipts / its own read
   endpoint), send a **background push carrying the list of read message IDs** to that user's
   *other* devices.
3. On receipt, the app calls
   `removeDeliveredNotifications(withIdentifiers: ids.map { "z:\($0)" })` and updates the
   badge via `setBadgeCount(_:)`.
4. Because background pushes are throttled and lossy, **also reconcile on foreground**: on
   `willEnterForeground`, call `deliveredNotifications()`, cross-reference against locally
   known read state, and remove the stale ones. Treat the push as an optimisation, not the
   source of truth.
5. Coalesce read events server-side (a short debounce, one background push carrying many IDs)
   to stay inside Apple's "two or three per hour" guidance.

Alternative worth noting: the "3rd-party push provider clears on read" trick of re-sending
an `alert` push with the same `apns-collapse-id` only *replaces* the banner, it does not
remove it. There is no documented suppression path.

**Not determined:** whether an app is permitted to call `removeDeliveredNotifications` from
inside the Notification Service Extension (the API is not marked unavailable to extensions,
but Apple documents no such use). I did not find primary documentation either way.

---

## 11. macOS specifics

| Concern | macOS answer | Source |
|---|---|---|
| Registration API | `NSApplication.registerForRemoteNotifications()`, macOS 10.14+ | [link](https://developer.apple.com/documentation/appkit/nsapplication/registerforremotenotifications()) |
| Entitlement key | `com.apple.developer.aps-environment` (different key name from iOS) | [link](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.aps-environment) |
| `apns-topic` | same bundle ID rules; `alert` and `background` push types are both "recommended on macOS" | [link](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns) |
| Payload | identical. `thread-id`, `category`, `mutable-content`, `interruption-level`, `target-content-id` all exist on macOS | [link](https://developer.apple.com/documentation/usernotifications/unnotificationcontent) |
| `UNUserNotificationCenter` and all removal APIs | macOS 10.14+ | see §10 |
| `UNTextInputNotificationAction` / inline reply | macOS 10.14+ | [link](https://developer.apple.com/documentation/usernotifications/untextinputnotificationaction) |
| `UNNotificationAttachment` | macOS 10.14+ | [link](https://developer.apple.com/documentation/usernotifications/unnotificationattachment) |
| `INSendMessageIntent` + `updating(from:)` | macOS 12.0+ | [link](https://developer.apple.com/documentation/intents/insendmessageintent) |
| `UNNotificationServiceExtension` | documented macOS 10.14+ — but see the caveat below | [link](https://developer.apple.com/documentation/usernotifications/unnotificationserviceextension) |

### Background pushes are weaker on macOS — this affects §10's design

`NSApplicationDelegate` has exactly three push methods, all under "Handling Push Notifications":
`application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`,
`application(_:didFailToRegisterForRemoteNotificationsWithError:)`, and
`application(_:didReceiveRemoteNotification:)`.
<https://developer.apple.com/documentation/appkit/nsapplicationdelegate>

There is **no macOS equivalent of `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`**
— no completion handler, no background-execution budget, and no "Background Modes → Remote
notifications" contract. Apple's own AppKit documentation for the macOS method is stale
(it still describes a 256-byte payload limit and an `alert` dictionary with a `show-view` key),
and states:

> "The delegate receives this message when the application is **running** and a remote
> notification arrives for it."
> "Icon badging is the only notification type supported for non-running applications."

<https://developer.apple.com/documentation/appkit/nsapplicationdelegate/application(_:didreceiveremotenotification:)>

**Consequence for cross-device read clearing:** the background-push mechanism from §10 is
reliable on Mac only while the app is running. That is acceptable in practice — a Mac chat
client is usually open — but the foreground reconciliation pass (step 4 in §10) is not
optional on macOS, it is the primary mechanism. Do not design the Mac path around the
background push arriving.

### The same payloads work

Yes — a single payload and header set serves both app targets. The only server-side
difference is that the two apps have **different bundle IDs** (hence different `apns-topic`)
and therefore **different device tokens**, so each row in SQLite needs a `bundle_id` (or
platform) column as well as `environment`.

### The NSE-on-macOS caveat

This is the one real macOS risk in this design. The `UNNotificationServiceExtension` class
is documented as macOS 10.14+, but:

- Apple's own article "Modifying content in newly delivered notifications" is written
  entirely in terms of iOS ("before it's displayed on the user's **iOS** device") and
  instructs you to add the target from Xcode's **iOS → Application** section. It never
  mentions macOS.
  <https://developer.apple.com/documentation/usernotifications/modifying-content-in-newly-delivered-notifications>
- Multiple Apple Developer Forums threads report the extension either not launching at all on
  macOS or being killed for "sluggish startup", while working on the same code via Catalyst/iOS:
  <https://developer.apple.com/forums/thread/712482>,
  <https://developer.apple.com/forums/thread/125987>,
  <https://forums.developer.apple.com/forums/thread/693011>

Forum posts are not authoritative. **Treat as unverified and prototype early.** If the NSE
turns out to be unreliable on macOS, the consequences are: no payload encryption on Mac (so
plaintext body in the payload, or no body at all on Mac), no downloaded avatars, and no
communication notifications on Mac — the Mac app would need to do its equivalent work in
`application(_:didReceiveRemoteNotification:)` after the banner has already shown. Design the
payload so it is still readable without the NSE.

### Signing / distribution

For a Mac app distributed outside the Mac App Store, the `com.apple.developer.aps-environment`
entitlement must be present and the App ID must have Push Notifications enabled in the
developer account (<https://developer.apple.com/help/account/identifiers/enable-app-capabilities/>).
**Not determined from primary sources:** whether a Developer ID–signed (non–App Store) macOS
build can carry a `production` aps-environment entitlement without an embedded provisioning
profile. Apple's entitlement page only says Xcode derives the value from the provisioning
profile. This needs to be verified against the actual distribution channel Zulu will use
before committing to a Mac release plan.

---

## 12. Go library landscape

### Verdict

`github.com/sideshow/apns2` is still the only realistic choice. It is **feature-complete but
dormant**. Nothing has replaced it, and every maintained downstream push server wraps it.

### Maintenance facts for `sideshow/apns2`

| Fact | Value | Source |
|---|---|---|
| Module path | `github.com/sideshow/apns2` — **no `/v2` suffix** (still v0.x) | <https://raw.githubusercontent.com/sideshow/apns2/master/go.mod> |
| Latest tag | `v0.25.0`, published 2024-10-25 | <https://proxy.golang.org/github.com/sideshow/apns2/@latest>, <https://api.github.com/repos/sideshow/apns2/releases/latest> |
| Last commit on `master` | 2025-07-22, `65966ee9` "Upgrade to Go 1.18 and update dependencies (#239)" — **untagged**, so `go get` gives you something older than `master` | <https://api.github.com/repos/sideshow/apns2/commits?per_page=1> |
| Stars / forks | 3,189 / 355 (no fork has any traction) | <https://api.github.com/repos/sideshow/apns2> |
| Open issues / PRs | 25 issues, 7 PRs | GitHub search API |
| Archived | No | GitHub API |
| License | MIT | GitHub API |
| `go` directive | `go 1.18`; CI matrix only covers Go 1.18–1.22 | <https://raw.githubusercontent.com/sideshow/apns2/master/.github/workflows/tests.yml> |
| Importers | 389 on pkg.go.dev | <https://pkg.go.dev/github.com/sideshow/apns2?tab=importedby> |

"Maintenance mode" is an inference from the commit/PR timeline, not a maintainer statement —
14 months without a commit, with PRs filed after the last commit sitting unmerged (#243
"send expiry as 0" from 2025-11-06, #242 "iOS 18 Live Activity channels" from 2025-02-02,
#213 "token support for client manager" from 2022).

### Two dependency floors to raise

`apns2`'s `go.mod` pins:

```
github.com/golang-jwt/jwt/v5 v5.2.1
golang.org/x/crypto          v0.31.0   (pkcs12, .p12 certs only)
golang.org/x/net             v0.33.0   (http2)
github.com/alecthomas/kingpin v2.2.6+incompatible  (its CLI tool only)
```

Both floors are below known-vulnerable thresholds:

- `golang-jwt/jwt/v5 v5.2.1` → **GO-2025-3553**, excessive memory allocation during header
  parsing. Fixed in v5.2.2; current v5.3.1. <https://vuln.go.dev/ID/GO-2025-3553.json>
- `golang.org/x/net v0.33.0` → **GO-2026-4918**, "Infinite loop in HTTP/2 transport when given
  bad SETTINGS_MAX_FRAME_SIZE". Affected symbols include `http2.Transport.RoundTrip` and
  `clientConnReadLoop.processSettingsNoWrite` — exactly the client path apns2 uses. Fixed in
  v0.53.0; current v0.59.0. <https://vuln.go.dev/ID/GO-2026-4918.json>

Minimal version selection means adding these to Zulu's own `require` block fixes both without
forking:

```
require (
    github.com/sideshow/apns2 v0.25.0
    github.com/golang-jwt/jwt/v5 v5.3.1   // floor: GO-2025-3553
    golang.org/x/net v0.59.0              // floor: GO-2026-4918
)
```

### Token auth API (`token/token.go`)

```go
const TokenTimeout = 3000   // seconds — 50 minutes

type Token struct {
    sync.Mutex
    AuthKey  *ecdsa.PrivateKey
    KeyID    string
    TeamID   string
    IssuedAt int64
    Bearer   string
}

func AuthKeyFromFile(filename string) (*ecdsa.PrivateKey, error)
func AuthKeyFromBytes(bytes []byte) (*ecdsa.PrivateKey, error)
func (t *Token) GenerateIfExpired() (bearer string)
func (t *Token) Expired() bool
func (t *Token) Generate() (bool, error)
```

Errors: `ErrAuthKeyNotPem`, `ErrAuthKeyNotECDSA`, `ErrAuthKeyNil`.

**JWT refresh is automatic and correct.** `Client.setTokenHeader` calls `GenerateIfExpired()`
on every push; `Expired()` is `time.Now().Unix() >= t.IssuedAt + TokenTimeout`, guarded by the
embedded mutex. 3000s = 50 minutes, comfortably inside Apple's 20–60 minute window.
`AuthKeyFromBytes` does `pem.Decode` → `x509.ParsePKCS8PrivateKey` → assert `*ecdsa.PrivateKey`.
`Generate()` builds the header `{"alg":"ES256","kid":KeyID}` and claims `{"iss":TeamID,"iat":…}`
and signs with `jwt.SigningMethodES256`.

Source: <https://raw.githubusercontent.com/sideshow/apns2/master/token/token.go>

### Client API (`client.go`)

```go
const (
    HostDevelopment = "https://api.sandbox.push.apple.com"
    HostProduction  = "https://api.push.apple.com"
)

var (
    HTTPClientTimeout = 60 * time.Second
    ReadIdleTimeout   = 15 * time.Second
    TCPKeepAlive      = 15 * time.Second
    TLSDialTimeout    = 20 * time.Second
)

func NewClient(certificate tls.Certificate) *Client   // certificate auth
func NewTokenClient(token *token.Token) *Client       // token auth
func (c *Client) Development() *Client
func (c *Client) Production() *Client
func (c *Client) Push(n *Notification) (*Response, error)
func (c *Client) PushWithContext(ctx Context, n *Notification) (*Response, error)
func (c *Client) CloseIdleConnections()
```

Both constructors build a `&http2.Transport{DialTLS: DialTLS, ReadIdleTimeout: ReadIdleTimeout}`
— i.e. `golang.org/x/net/http2.Transport` directly, not `net/http.Transport`. PING-based dead
connection detection is wired at 15s out of the box. Hold **one `*Client` for the process
lifetime**; the README claims 4,000+ pushes/sec per instance (unverified wiki figure).

`ClientManager` (`client_manager.go`) exists for pooling but is **certificate-keyed only**
(cache key is a SHA-1 of the cert); there is no token-keyed manager. Irrelevant for Zulu, which
needs at most two clients (sandbox + production) per bundle ID.

Source: <https://raw.githubusercontent.com/sideshow/apns2/master/client.go>

### Notification API (`notification.go`)

```go
type EPushType string
const (
    PushTypeAlert        EPushType = "alert"
    PushTypeBackground   EPushType = "background"
    PushTypeLocation     EPushType = "location"
    PushTypeVOIP         EPushType = "voip"
    PushTypeComplication EPushType = "complication"
    PushTypeFileProvider EPushType = "fileprovider"
    PushTypeMDM          EPushType = "mdm"
    PushTypeLiveActivity EPushType = "liveactivity"
    PushTypePushToTalk   EPushType = "pushtotalk"
)
const ( PriorityLow = 5; PriorityHigh = 10 )

type Notification struct {
    ApnsID      string
    CollapseID  string
    DeviceToken string
    Topic       string
    Expiration  time.Time
    Priority    int
    Payload     interface{}
    PushType    EPushType
}
```

`setHeaders` maps these to `apns-topic`, `apns-id`, `apns-collapse-id`, `apns-priority` (only
when `> 0`), `apns-expiration` (only when `Expiration.After(time.Unix(0,0))`), and
`apns-push-type` (**defaults to `alert`** when unset).

Known gaps relevant to Zulu: **you cannot send `apns-expiration: 0`** (the zero check
suppresses the header) — open PR #243. Zulu probably wants `apns-expiration: 0` for the
read-state background pushes so a stale "clear this notification" never arrives days later;
today the workaround is a near-future expiration time, or a small patch/fork.

Source: <https://raw.githubusercontent.com/sideshow/apns2/master/notification.go>

### Response API (`response.go`)

```go
const StatusSent = http.StatusOK

type Response struct {
    StatusCode   int
    Reason       string
    ApnsID       string
    Timestamp    Time      // custom type; UnmarshalJSON divides epoch millis by 1000
    ApnsUniqueID string    // apns-unique-id header, development env only
}
func (c *Response) Sent() bool  // StatusCode == 200
```

Plus ~30 `Reason*` constants matching Apple's table: `ReasonBadDeviceToken`,
`ReasonUnregistered`, `ReasonExpiredToken`, `ReasonExpiredProviderToken`,
`ReasonTooManyProviderTokenUpdates`, `ReasonTooManyRequests`, `ReasonPayloadTooLarge`, etc.

`Response.Timestamp` is exactly the `410` reaping signal from §5 — compare it against the
token's `registered_at` in SQLite.

Error model: a non-nil `error` is a transport/cert failure; a non-nil `*Response` means APNs
answered — branch on `res.Sent()`.

Source: <https://raw.githubusercontent.com/sideshow/apns2/master/response.go>

### Payload builder (`payload/builder.go`)

`payload.NewPayload()` with a fluent API covering everything Zulu needs: `Alert`, `AlertTitle`,
`AlertSubtitle`, `AlertBody`, `Badge`, `ZeroBadge`, `UnsetBadge`, `Sound`, `SoundName`,
`ContentAvailable`, `MutableContent`, `Category`, `ThreadID`, `Custom`, `InterruptionLevel`,
`RelevanceScore`. `Notification.Payload` is `interface{}`, so a hand-rolled struct with
`json` tags works equally well and is easier to unit-test.

### Alternatives surveyed — all dead, wrappers, or servers

| Project | Stars | Last commit | Status |
|---|---|---|---|
| appleboy/gorush | 8,776 | 2026-07-25 | Maintained **service**, not a library; its go.mod requires `sideshow/apns2 v0.25.0`. Strongest evidence apns2 is still the right engine |
| uniqush/uniqush-push | 1,560 | 2026-09-10 | Maintained server; rolls its own APNs client under `srv/apns/`, not consumable standalone |
| micromdm/nanomdm | 660 | 2026-09-18 | MDM-specific; own client, **certificate-only**, no JWT path |
| pennersr/shove | 285 | 2026-08-20 | Server, wraps apns2 v0.23.0 |
| RobotsAndPencils/buford | 472 | 2023-02-25 | **Archived** |
| mercari/gaurun | 930 | 2021-09-24 | **Archived** |
| edganiukov/apns | 7 | 2023-02-24 | **Archived** |
| timehop/apns | 185 | 2023-04-03 | Effectively dead, pre-HTTP/2 lineage |
| appleboy/go-fcm | 330 | 2026-08-30 | FCM only, no APNs |

pkg.go.dev "apns" search importer counts: `sideshow/apns2` 389; next is `anachronistic/apns`
at 37 (last published 2015). Everything else is one to two orders of magnitude smaller and
roughly a decade old. <https://pkg.go.dev/search?q=apns&m=package>

**There is no first-party Apple Go SDK and no OpenAPI description of the APNs provider API** —
the docs are prose and header tables only. No generated client exists.

### Rolling your own on stdlib

Feasible — roughly 150 lines — but three traps:

1. **HTTP/2 silently disables itself.** `net/http.Transport` documents: *"ForceAttemptHTTP2
   controls whether HTTP/2 is enabled when a non-zero `Dial`, `DialTLS`, or `DialContext` func
   or `TLSClientConfig` is provided. By default, use of any those fields conservatively
   disables HTTP/2."* <https://pkg.go.dev/net/http#Transport>
2. **ES256 signature encoding.** JWS ES256 needs the raw fixed-width `R || S` 64-byte
   (JOSE/IEEE-P1363) form. `crypto/ecdsa.SignASN1` returns ASN.1 DER — wrong — and
   `ecdsa.Sign` gives `*big.Int` r/s you must left-pad to 32 bytes each. Getting it wrong
   yields `403 InvalidProviderToken` with no further hint. Good reason to keep
   `golang-jwt/jwt/v5`'s `SigningMethodES256` either way.
   <https://pkg.go.dev/crypto/ecdsa>
3. **Idle connection health.** APNs connections go dead silently. Go 1.24 added
   `http.Transport.HTTP2 *http.HTTP2Config`; set `SendPingTimeout` (the successor to
   `x/net/http2.Transport.ReadIdleTimeout`) or the first push after a lull hangs until
   `Client.Timeout`. <https://pkg.go.dev/net/http#HTTP2Config>, <https://go.dev/doc/go1.24>

```go
tr := &http.Transport{
    TLSClientConfig:   tlsCfg,   // certificate auth only
    ForceAttemptHTTP2: true,     // REQUIRED once TLSClientConfig is set
    HTTP2: &http.HTTP2Config{
        SendPingTimeout:  15 * time.Second,
        PingTimeout:      15 * time.Second,
        WriteByteTimeout: 15 * time.Second,
    },
}
```

Note: as of Go 1.24, `golang.org/x/net/http2.Transport` carries
`Deprecated: Use http.Transport instead`, and apns2 still uses it directly.
<https://pkg.go.dev/golang.org/x/net/http2#Transport>

### Operational notes that follow from Apple's docs

- **Warm the connection before fanning out.** With token auth APNs allows only one stream
  until a request with a valid token has been posted. A cold start that launches N goroutines
  will make `http2.Transport` open N TCP connections instead of multiplexing. Send one push,
  wait for it, then fan out — or set `StrictMaxConcurrentStreams`/`StrictMaxConcurrentRequests`.
- **GOAWAY reason is lost.** Apple puts a JSON `reason` in the `GOAWAY` debug data; the Go
  http2 transport does not surface it. You get `http2.GoAwayError` with an `ErrCode` only.
  Log it and reconnect.
- **One connection pool per developer account** (team/bundle binding on first push).
- Port 2197 is available as an alternative to 443; apns2 hardcodes 443 in its host constants,
  so you'd override `Client.Host` to use it.

### Recommendation for Zulu

Use `sideshow/apns2` with token auth and the two CVE floors above. Structure it behind a small
interface in the notification service so the ~800 lines can be vendored or replaced later
without touching callers — given the dormancy and the `apns-expiration: 0` gap, that seam is
worth having:

```go
type Pusher interface {
    Push(ctx context.Context, n Delivery) (Receipt, error)
}
```

Hold one client per (environment, bundle ID) for the process lifetime, always use
`PushWithContext`, and treat `ReasonUnregistered` / `ReasonBadDeviceToken` as the reaping
signals described in §5.

Open issue worth tracking before shipping: **#238 "http2: potential connection/goroutine
leaked"** (opened 2024-11-11, unaddressed) — the only open bug that looks capable of hurting
a long-running server. <https://github.com/sideshow/apns2/issues/238>

---

## 13. Things I could not determine

1. Whether `UNNotificationServiceExtension` actually functions reliably in a native (non-Catalyst)
   macOS app. Documented as supported since 10.14; forum evidence says otherwise. **Prototype first.**
2. Whether the Communication Notifications capability is offered for macOS app targets in Xcode.
   `INSendMessageIntent` and `UNNotificationContent.updating(from:)` are both macOS 12+, which
   implies yes, but I found no Apple documentation page for the capability itself on macOS, and
   the entitlement `com.apple.developer.usernotifications.communication` has no published
   documentation page (404 on Apple's docs site).
3. Whether `removeDeliveredNotifications(withIdentifiers:)` may legally be called from inside
   a Notification Service Extension.
4. Whether a Developer ID (non–App Store) macOS build can ship `production` aps-environment
   without an embedded provisioning profile.
5. Whether APNs enforces any documented per-token or per-topic rate limit beyond the
   `429 TooManyRequests` ("too many requests were made consecutively to the same device
   token") response. Apple publishes no numeric limit.
6. Whether `sideshow/apns2` is formally in maintenance mode. There is no maintainer
   statement, no `MAINTENANCE.md`, and the repo is not archived — "dormant" is inferred from
   14 months without a commit and unmerged PRs filed after the last commit.
7. Why the 2025-07-22 `master` commit was never tagged, and whether a `v0.26.0` is planned.
8. Whether apns2's direct use of the now-deprecated `golang.org/x/net/http2.Transport` will
   break. `x/net` deprecations carry no announced removal date that I could find.
9. Severity of apns2 issue #238 ("http2: potential connection/goroutine leaked", open since
   2024-11-11). I did not read the thread in depth; it is the one open bug that looks capable
   of affecting a long-running sender.
10. The apns2 README's "4,000+ pushes/sec per client" figure comes from an undated project
    wiki page and was not verified.
