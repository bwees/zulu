# Threat model

This service holds Zulip API keys belonging to accounts on servers its operator
does not control. This document says what that means, without softening it.

## What is stored

| Data                                                | Where                 | Protection                            |
| --------------------------------------------------- | --------------------- | ------------------------------------- |
| Zulip API key                                       | `users.api_key_box`   | AES-256-GCM, key from the environment |
| Realm URL, email, Zulip user id                     | `users`               | plaintext                             |
| APNs device token                                   | `devices.token`       | plaintext                             |
| Device secret (the app's bearer token)              | `devices.secret_hash` | SHA-256 of a 256-bit random value     |
| Mirrored notification settings                      | `queue_state.state`   | plaintext JSON                        |
| Zulip event queue id and cursor                     | `queue_state`         | plaintext                             |
| Delivery log: which message id went to which device | `deliveries`          | plaintext                             |

Message content is never stored. It goes from the Zulip event straight into an
APNs payload and is then dropped.

## The encryption, precisely

Each API key is sealed with AES-256-GCM under a single key-encryption key read
from `ZULU_KEY_ENCRYPTION_KEY`. Every record gets a fresh random nonce. The realm
URL and Zulip user id are authenticated as additional data, so a ciphertext
copied onto another row fails to open rather than granting access to the wrong
account.

The key-encryption key is never written to the database, never logged, and is not
derived from anything in the database.

There is no key rotation. Changing `ZULU_KEY_ENCRYPTION_KEY` makes every stored
credential unreadable; workers then fail to unseal, and every user must register
again.

## An attacker with the database file alone

They get: every registered user's realm, email, Zulip user id, their APNs device
tokens, their channel and topic notification settings, the muted-user lists, and
a log of which message ids were pushed to which device and when.

They do **not** get: any Zulip API key, any message content, or the ability to
authenticate to this service (the device secrets are stored hashed).

That is not nothing. The delivery log plus the settings mirror is a decent map of
who the user talks to and which topics they care about, and the device tokens are
enough to send pushes if the attacker also has the APNs signing key. But they
cannot read the user's Zulip account.

## An attacker who compromises the running instance

They get everything. The key-encryption key is in the process environment, so
every stored API key can be unsealed, and a Zulip API key is full account access:
read every message the user can read, including direct messages and private
channels, send messages as them, change their settings.

There is no mitigation for this in the current design, and no meaningful one
available: the service must use the keys continuously, so it must be able to
decrypt them. Encryption at rest protects a stolen file and a leaked backup. It
does not protect a compromised host.

The blast radius is every registered user, not one. This is a single-instance,
single-operator design; the operator is trusted absolutely by everyone who
registers.

## Revocation

There is nothing to scope. A Zulip account has exactly one API key, shared by the
app and this service.

- Deregistering the last device deletes the account row here, and with it the
  sealed key. Nothing at Zulip changes.
- Actual revocation is regenerating the key in Zulip, which also signs the user
  out of the official Zulip apps and out of Zulu.
- When that happens, the next poll gets a 401. The worker stops, marks the
  account `auth_failed`, deletes its Zulip event queue, and `GET /v1/status`
  reports it so the app can prompt for a fresh sign-in.

## What the user must be told at registration

The app should say this before sending a key, not afterwards:

1. The notification service stores the account's Zulip API key and can therefore
   read and send messages as that account.
2. Notification text — sender, channel, topic, and message body — is sent to
   Apple in plaintext, as APNs requires.
3. While the service is running, Zulip stops sending its own push _and email_
   notifications for the account.
4. Removing the device stops notifications and deletes the stored key, but to
   revoke the key itself the user must regenerate it in Zulip, which signs every
   client out.

## Transport

Between app and service: HTTPS, terminated by whatever reverse proxy fronts the
deployment. The service speaks plain HTTP and must not be exposed directly.
Registration sends the API key in the body, so a plaintext deployment leaks it on
the first request.

Between service and Zulip: HTTPS, with the API key in an HTTP basic header, as
Zulip's API requires. Realm URLs are accepted with `http://` as well, which is
useful for a development server and a bad idea anywhere else.

Between service and APNs: HTTPS with token (p8/JWT) auth.

## What is logged

Logged: user ids (this service's and Zulip's), realm URLs, device ids, message
ids, notification triggers, APNs status codes and reasons, and the reason a
message was not notifiable.

Never logged: API keys, device secrets, APNs device tokens, message content,
sender or channel names, topic names, and the key-encryption key. The dry-run
sender logs alert titles, which contain channel and topic names — it is a
development aid and must not be enabled in production.

## Known weaknesses

- **Registration is unauthenticated.** Anyone who can reach the service can
  attempt to register with credentials they hold. The check is that Zulip accepts
  them. There is no rate limit on this endpoint, so it can be used to probe a
  Zulip server for valid keys at this service's expense; put a rate limit in the
  reverse proxy.
- **A device secret never expires** and is not rotated. It identifies an account
  to this service; stealing one lets the thief list and deregister that account's
  devices, which is a denial of notifications, not account access.
- **APNs payloads carry plaintext** sender, channel, topic and body, by design.
  Apple's own guidance is not to put sensitive data in a payload. Anyone who can
  read the notification — over the shoulder, or on a compromised device — reads
  the message.
- **No audit trail.** Nothing records who registered when, beyond the delivery
  log and the row timestamps.
- **The delivery log is pruned on boot only**, at eight days. A long-running
  instance keeps eight days of conversation metadata at all times.
