# Setting up the Zulu notification service

How to get `zulu-notifyd` running, configured, and actually delivering pushes.
For what it does and why it is built this way, read [README.md](README.md); for
what it can do with a user's credentials, read [SECURITY.md](SECURITY.md).

You do not need cooperation from your Zulip administrator. You do need an Apple
Developer account before real pushes will leave the machine — until then, run in
dry-run mode, which logs every push it would have sent.

---

## 1. Decide where it runs

One process, one SQLite file, no external database. It needs:

- A host reachable from your phone over HTTPS.
- Outbound access to your Zulip server and to `api.push.apple.com`.
- Persistent storage for the SQLite file. Lose the file and every user
  re-registers.

A single small VPS or a container host is enough. The service holds one long-poll
connection to Zulip per registered user, so its cost scales with users, not with
message volume.

## 2. Generate the key-encryption key

The service stores each user's Zulip API key sealed with AES-256-GCM. The key
that unwraps them is read from the environment and never written to the database.

```sh
head -c 32 /dev/urandom | base64
```

Keep it somewhere the database file is not. A database and its key in the same
backup is the same as no encryption at all. **If you lose it, every user must
register again** — there is no recovery path, by design.

## 3. Get APNs credentials

Token-based auth, not certificates. One key works for every app and never
expires.

1. Sign in to the [Apple Developer portal](https://developer.apple.com/account)
   → **Certificates, Identifiers & Profiles** → **Keys**.
2. **+**, name it something like `Zulu APNs`, tick **Apple Push Notifications
   service (APNs)**, continue, register.
3. Download the `.p8`. **Apple lets you download it once.** Store it with the
   key-encryption key, not with the database.
4. Note the **Key ID** (10 characters, also in the filename:
   `AuthKey_XXXXXXXXXX.p8`).
5. Note your **Team ID** (10 characters, top right of the portal, or under
   Membership).

The bundle id is `com.bwees.zulu` unless you changed it in `App/project.yml`. It
is sent as the `apns-topic` header, so it has to match the app exactly.

## 4. Configure

Every setting is an environment variable. Only `ZULU_KEY_ENCRYPTION_KEY` is
required; APNs settings are required unless `ZULU_APNS_DRY_RUN=true`, and the
service refuses to boot rather than start up unable to deliver anything.

| Variable | Default | Meaning |
| --- | --- | --- |
| `ZULU_KEY_ENCRYPTION_KEY` | *required* | 32 random bytes, base64. Section 2. |
| `ZULU_DATABASE_PATH` | `zulu.db` | SQLite file. Put it on the persistent volume. |
| `ZULU_HTTP_ADDR` | `:8080` | Listen address. |
| `ZULU_LOG_LEVEL` | `info` | `debug` logs every message it decided *not* to notify about, and why. The first thing to turn on when a push does not arrive. |
| `ZULU_OPENAPI_FILE` | *unset* | Write the generated spec here on boot. It is served at `/swagger/openapi.json` either way. |
| `ZULU_RECONCILE_INTERVAL` | `60s` | How often the supervisor re-reads the user list and starts or stops workers. |
| `ZULU_DELIVERY_GRACE` | `15m` | How long every push to one user may keep failing before that user's worker parks and hands the queue back to Zulip. |
| `ZULU_APNS_DRY_RUN` | `false` | Log pushes instead of sending them. Makes the four settings below optional. |
| `ZULU_APNS_KEY_FILE` | | Path to the `.p8`. |
| `ZULU_APNS_KEY_ID` | | 10-character key id. |
| `ZULU_APNS_TEAM_ID` | | 10-character team id. |
| `ZULU_APNS_BUNDLE_ID` | | The app's bundle id, sent as `apns-topic`. |

Sandbox and production APNs are chosen per device, from the `environment` field
each device sends at registration — not from a setting here. One instance serves
both, so a TestFlight build and a debug build can point at the same host.

## 5. Run it

### With Docker Compose

```sh
cd service
cp .env.example .env
$EDITOR .env                      # paste the key, fill in the APNs values
mkdir -p secrets
cp ~/Downloads/AuthKey_XXXXXXXXXX.p8 secrets/apns.p8
docker compose up --build -d
```

`compose.yaml` keeps the database in a named volume (`zulu-data`) and mounts
`./secrets` read-only at `/run/secrets`, which is what `ZULU_APNS_KEY_FILE`
points at in `.env.example`.

### Straight from source

```sh
cd service
export ZULU_KEY_ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)
export ZULU_APNS_DRY_RUN=true
go run ./cmd/zulu-notifyd
```

### Check it came up

```sh
curl -s localhost:8080/healthz
```

`{"status":"ok"}` means the process is alive and the database migrated. Browse
the full API at `http://localhost:8080/swagger/index.html`.

## 6. Put HTTPS in front of it

The service speaks plain HTTP and does no TLS termination of its own. It must not
be exposed directly: device registration carries a Zulip API key in the request
body.

Point a reverse proxy at it — Caddy needs two lines:

```caddyfile
notify.example.com {
    reverse_proxy localhost:8080
}
```

The only requirement is that the proxy allows long-lived responses; nothing the
API serves streams, so default timeouts are fine.

## 7. Register a device

The app does this for you once it knows the service's URL. To check the service
by hand:

```sh
curl -s https://notify.example.com/v1/devices \
  -H 'content-type: application/json' \
  -d '{
    "realmUrl": "https://chat.example.com",
    "email": "you@example.com",
    "apiKey": "<your Zulip API key>",
    "deviceToken": "<APNs token, hex>",
    "platform": "ios",
    "environment": "sandbox",
    "appVersion": "1.0"
  }'
```

Your Zulip API key is in Zulip under **Personal settings → Account & privacy →
API key**.

The response carries a `deviceSecret`, **shown once**. Every later call
authenticates with it as a bearer token, so the Zulip API key never travels
again:

```sh
curl -s https://notify.example.com/v1/status -H "authorization: Bearer $SECRET"
```

| Route | Auth | What |
| --- | --- | --- |
| `POST /v1/devices` | none | Register. Returns a device id and device secret. |
| `GET /v1/devices` | device secret | The account's registered devices. |
| `DELETE /v1/devices/{deviceId}` | device secret | Deregister. Removing the last device deletes the stored API key. |
| `GET /v1/status` | device secret | Queue health, last event, last error. |
| `GET /healthz` | none | Liveness. |

## 8. Verify a push end to end

1. `ZULU_LOG_LEVEL=debug`, restart.
2. `GET /v1/status` → `"queueConnected": true`. If it is false, `lastError` says
   why.
3. From another account, send yourself a DM — a DM notifies under every default
   setting, which makes it the right first test.
4. The push should arrive within a second or two. In dry-run, it appears in the
   log instead.

## What to check when nothing arrives

Work down this list; it is ordered by how often each one is the answer.

- **`"queueConnected": false`** — the service is not watching Zulip at all. Read
  `lastError`. `auth_failed` for `accountStatus` means the stored API key was
  rejected: it was regenerated somewhere else, and the user must register again
  with the new one.
- **`"parked": true`** — every push to this user failed for `ZULU_DELIVERY_GRACE`,
  so the worker gave the queue back and Zulip is notifying again. `parkedUntil`
  says when it retries. Almost always a bad device token or the wrong APNs
  environment.
- **`BadDeviceToken` in the log** — the token belongs to the other APNs
  environment. A development build registers `sandbox`, TestFlight and the App
  Store register `production`.
- **`TopicDisallowed` / `DeviceTokenNotForTopic`** — `ZULU_APNS_BUNDLE_ID` does
  not match the app's bundle id.
- **Queue connected, no push, nothing in the log** — the message was decided as
  not notifiable. `ZULU_LOG_LEVEL=debug` logs the reason for every message it
  skipped. Muted channels, muted topics and your own messages all land here, and
  so does Zulip's "only notify on mention" channel setting.
- **You stopped getting Zulip's own emails** — expected, and permanent while the
  service is healthy. Holding an event queue makes Zulip consider the account
  online, which suppresses its own push *and* missed-message email. README.md
  covers the tradeoff; the short version is that this service is the sole push
  authority while it is running, and Zulip resumes within about ten minutes of it
  stopping.

## Upgrading

```sh
git pull
docker compose up --build -d
```

Migrations are embedded and applied at boot. On a clean shutdown the service
deletes its Zulip event queues, so Zulip resumes notifying during the restart and
the queues are re-registered on the way back up. Nothing to do by hand.

## Backups

Back up two things, separately:

- The SQLite file at `ZULU_DATABASE_PATH` (in the `zulu-data` volume under
  Compose). Sealed API keys, devices, and queue cursors.
- `ZULU_KEY_ENCRYPTION_KEY` and the `.p8`.

Keeping them in the same place defeats the sealing. Restoring the database
without the key leaves you with rows nothing can read.
