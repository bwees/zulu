# Zulip auth for native clients

Research for issue `01-zulip-auth-api.md`. Read against primary sources on 2026-09-22.

Server source pinned at `zulip/zulip@370f7b6` (main), client source at `zulip/zulip-flutter@bbec50b` (main).

## Answer in brief

- A Zulip account has **exactly one** API key. It is a column on the user row, not a collection.
- Password/LDAP login: `POST /api/v1/fetch_api_key` with form-encoded `username` + `password`.
- SSO (SAML, OIDC, GitHub, Google, Apple, REMOTE_USER): open the realm's `login_url` in a browser with a
  `mobile_flow_otp` query param; the server ends the flow with a 302 to `zulip://login?...` carrying the
  API key XOR'd with that one-time pad.
- Backend discovery: unauthenticated `GET /api/v1/server_settings` on the realm URL.
- The key never expires and is only invalidated by explicit regeneration. Password change does not touch it.
- Because there is one key per account, the notification service cannot hold a key independent of the app's.

## 1. Discovering the realm and its auth backends

`GET {realm_url}/api/v1/server_settings` — no auth, no CSRF, `@require_safe`.

Server: `zerver/views/auth.py::api_get_server_settings`
(<https://github.com/zulip/zulip/blob/main/zerver/views/auth.py>), routed at
`zproject/urls.py` line 883 (<https://github.com/zulip/zulip/blob/main/zproject/urls.py>).
Docs: <https://zulip.com/api/get-server-settings>.

Response (example verbatim from the OpenAPI spec, `zerver/openapi/zulip.yaml` around line 23146):

```json
{
    "authentication_methods": {
        "azuread": false, "dev": true, "email": true, "github": true,
        "google": true, "ldap": false, "password": true, "remoteuser": false, "saml": true
    },
    "email_auth_enabled": true,
    "external_authentication_methods": [
        {
            "name": "saml:idp_name",
            "display_name": "SAML",
            "display_icon": null,
            "login_url": "/accounts/login/social/saml/idp_name",
            "signup_url": "/accounts/register/social/saml/idp_name"
        },
        {
            "name": "google",
            "display_name": "Google",
            "display_icon": "/static/images/authentication_backends/googl_e-icon.png",
            "login_url": "/accounts/login/social/google",
            "signup_url": "/accounts/register/social/google"
        }
    ],
    "is_incompatible": false,
    "msg": "",
    "push_notifications_enabled": false,
    "realm_description": "<p>...</p>",
    "realm_icon": "https://...",
    "realm_name": "Zulip Dev",
    "realm_uri": "http://localhost:9991",
    "realm_url": "http://localhost:9991",
    "realm_web_public_access_enabled": false,
    "require_email_format_usernames": true,
    "result": "success",
    "zulip_merge_base": "5.0-dev-1646-gea6b21cd8c",
    "zulip_version": "5.0-dev-1650-gc3fd37755f",
    "zulip_feature_level": 123
}
```

### Which fields to actually branch on

`authentication_methods` is marked `deprecated: true` in the OpenAPI spec — "Deprecated in Zulip 2.1.0, in
favor of the more expressive `external_authentication_methods`" (`zerver/openapi/zulip.yaml`).
zulip-flutter parses **only** `ldap` out of it and comments the rest out as "deprecated; ignore"
(`lib/api/route/realm.dart`, <https://github.com/zulip/zulip-flutter/blob/main/lib/api/route/realm.dart>).

The decision logic zulip-flutter uses in `lib/widgets/login.dart`:

- show the username/password form when `email_auth_enabled || authentication_methods.ldap`
- render one button per entry of `external_authentication_methods`, in the order given
  (the server sorts them; `sort_order` on each `ExternalAuthMethod` subclass, higher first)
- `require_email_format_usernames == false` means the username field is an LDAP username, not an email —
  skip client-side email validation and label the field "Username"

`external_authentication_methods` includes REMOTE_USER SSO: `ZulipRemoteUserBackend` is itself an
`ExternalAuthMethod` with `name = "remoteuser"`, `display_name = "SSO"`, `display_icon = None`,
`login_url = signup_url = /accounts/login/start/sso/`
(`zproject/backends.py` ~line 2026, <https://github.com/zulip/zulip/blob/main/zproject/backends.py>).
So a client does not need to special-case `/accounts/login/sso`; it arrives as a normal external method.

SAML produces one entry **per configured IdP**, named `saml:{idp_name}`, with the IdP's `display_name` and
`display_icon` if the server operator set them (`SAMLAuthBackend.dict_representation`). OIDC likewise
(`name = "oidc"`, `auth_backend_name = "OpenID Connect"`, one entry per IdP).

### Caveats

- `login_url` / `signup_url` / `display_icon` / `realm_icon` are **relative paths or absolute URLs**; resolve
  against `realm_url`, not against the URL the user typed.
- `realm_url` may differ from what the user typed (`your-org.zulipchat.com` → `https://your-org.zulipchat.com`).
  Use `realm_url` from the response as canonical from then on.
- If the request goes to the root domain of a multi-realm server, the realm-specific keys
  (`realm_name`, `realm_icon`, `external_authentication_methods`, …) are simply **absent**. The view builds
  the response with a loop that skips `None` values and comments: "realm_name, realm_icon, etc. are not
  guaranteed to appear in the response" (`api_get_server_settings`). Every realm field must be optional in
  your Swift model.
- `realm_uri` is deprecated in favour of `realm_url` as of Zulip 9.0 (feature level 257). Old servers only
  send `realm_uri`. zulip-flutter still reads `realm_uri` as the source field.
- URL normalisation zulip-flutter does before the request (`ServerUrlTextEditingController.tryParse`):
  trim; if no `http://`/`https://` prefix, prepend `https://`; reject a `zulip:` scheme, any non-http(s)
  scheme, and any URL with userinfo.

## 2. Password / LDAP sign-in

```
POST {realm_url}/api/v1/fetch_api_key
Content-Type: application/x-www-form-urlencoded

username=iago%40zulip.com&password=abcd1234
```

`@csrf_exempt @require_post`, `security: []` in the OpenAPI spec — no auth header, no CSRF token.
Source: `zerver/views/auth.py::api_fetch_api_key`. Docs: <https://zulip.com/api/fetch-api-key>.

Success 200:

```json
{
  "api_key": "gjA04ZYcqXKalvYMA8OeXSfzUOLrtbZv",
  "email": "iago@zulip.com",
  "user_id": 5,
  "msg": "",
  "result": "success"
}
```

`email` is `user_profile.delivery_email` — use it, not what the user typed, since LDAP usernames are not
emails and the delivery email is what the Basic auth header needs.

zulip-flutter posts exactly these two fields as raw (non-JSON) parameters
(`lib/api/route/account.dart::fetchApiKey`).

### Errors

`api_fetch_api_key` raises `InvalidSubdomainError` if the realm can't be resolved, otherwise maps the
Django `authenticate()` `return_data` through `get_api_key_fetch_authenticate_failure`. From
`zerver/lib/exceptions.py`:

| condition | `code` | HTTP |
|---|---|---|
| bad credentials (and the catch-all) | `AUTHENTICATION_FAILED` | 401 |
| user deactivated | `USER_DEACTIVATED` | 401 |
| realm deactivated | `REALM_DEACTIVATED` | 401 |
| password auth disabled for the realm | `PASSWORD_AUTH_DISABLED` | 401 |
| password disabled, reset required | `PASSWORD_RESET_REQUIRED` | 401 |
| unknown subdomain | `NONEXISTENT_SUBDOMAIN` | 404 |
| rate limited | `RATE_LIMIT_HIT` | 429 |

Note `invalid_subdomain` is deliberately reported as generic `AUTHENTICATION_FAILED` so a client cannot
probe whether an email exists in another org.

The endpoint is **not** documented with error responses upstream (the OpenAPI entry only lists `200`);
the table above is read off the view and exception classes, not the docs.

### Rate limiting

`authenticate_by_username`: **5 failed attempts per 30 minutes per username**
(`zproject/default_settings.py::DEFAULT_RATE_LIMITING_RULES`,
<https://github.com/zulip/zulip/blob/main/zproject/default_settings.py>). A successful auth clears the
history. Self-hosters can override via `RATE_LIMITING_RULES`. Generic API limits also apply:
`api_by_user` 200 req/min, `api_by_ip` 100 req/min (per IPv4 / per IPv6 /64).

### Two-factor auth

`api_fetch_api_key` performs no 2FA step. `TWO_FACTOR_AUTHENTICATION_ENABLED` defaults to `False` and is
commented in `default_settings.py` as "Two factor authentication is not yet implementation-complete".
Treat 2FA as out of scope.

### `dev_fetch_api_key`

`POST /api/v1/dev_fetch_api_key` with just `username`, no password. Development servers only; always errors
in production (<https://zulip.com/api/dev-fetch-api-key>). Surface it only if
`authentication_methods.dev == true`; not worth supporting in Zulu.

### `jwt/fetch_api_key`

`POST /api/v1/jwt/fetch_api_key` with `token` (a JWT whose payload carries an `email` claim) and optional
`include_profile`. New in Zulip 7.0 (feature level 160). Only useful when the server operator has enabled
JWT auth and the client already has a JWT from somewhere else — not reachable from a generic client.

### `json/fetch_api_key`

`POST /json/fetch_api_key` with `password` — requires an authenticated **browser session**, not an API key.
This is what the web app's "show my API key" dialog uses. Not usable from a native app.

## 3. SSO / external auth: the `mobile_flow_otp` protocol

There is no official documentation for this protocol. zulip-mobile's own comment says so: "No docs on this
protocol seem to exist" (`src/start/webAuth.js`,
<https://github.com/zulip/zulip-mobile/blob/main/src/start/webAuth.js>). The description below is read from
the server and both clients.

### Steps

1. Generate a 32-byte CSPRNG one-time pad, hex-encoded → 64 lowercase hex chars.
   zulip-flutter: `generateOtp()` in `lib/api/model/web_auth.dart`
   (<https://github.com/zulip/zulip-flutter/blob/main/lib/api/model/web_auth.dart>).
   Server validation (`zproject/backends.py::validate_otp_params` → `zerver/lib/mobile_auth_otp.py::is_valid_otp`)
   requires exactly `UserProfile.API_KEY_LENGTH * 2 == 64` hex characters.

2. Open, in a browser, `realm_url.resolve(method.login_url)` with `?mobile_flow_otp={otp}`.
   zulip-flutter `_beginWebAuth` in `lib/widgets/login.dart`:

   ```dart
   final url = widget.serverSettings.realmUrl.resolve(method.loginUrl)
     .replace(queryParameters: {'mobile_flow_otp': _otp!});
   await ZulipBinding.instance.launchUrl(url, mode: LaunchMode.inAppBrowserView);
   ```

3. The server carries `mobile_flow_otp` through the whole federated dance:
   - `oauth_redirect_to_root` puts it in the query string when bouncing to the root / `SOCIAL_AUTH_SUBDOMAIN`
     (`zerver/views/auth.py`).
   - python-social-auth stores it in the session; `SOCIAL_AUTH_FIELDS_STORED_IN_SESSION` is
     `["subdomain", "is_signup", "mobile_flow_otp", "desktop_flow_otp", "multiuse_object_key", "next"]`
     (`zproject/computed_settings.py` line 1133).
   - SAML cannot use the session across the IdP round-trip, so it stores these params in Redis under a random
     token and sends only that token in `RelayState`
     (`SAMLAuthBackend.auth_url` / `get_relayed_params`, `zproject/backends.py`).
   - Cross-subdomain hops go through `/accounts/login/subdomain/{token}` (`log_into_subdomain`), with the data
     in Redis; `ExternalAuthResult.LOGIN_KEY_EXPIRATION_SECONDS = 15`.

4. On success, `login_or_register_remote_user` → `finish_mobile_flow` → `create_response_for_otp_flow`
   returns a bare **HTTP 302** whose `Location` is:

   ```
   zulip://login?otp_encrypted_api_key={hex}&email={delivery_email}&user_id={int}&realm={realm_url}
   ```

   (`create_response_for_otp_flow`: `response["Location"] = append_url_query_string("zulip://login", urlencode(params))`.)

5. `otp_encrypted_api_key = hex(api_key_bytes) XOR otp` — a plain one-time pad over the hex-encoded ASCII
   API key (`zerver/lib/mobile_auth_otp.py::otp_encrypt_api_key`,
   <https://github.com/zulip/zulip/blob/main/zerver/lib/mobile_auth_otp.py>). Decrypt by XOR-ing the two hex
   strings and decoding the result as ASCII.

The stated reason for the pad is in that file's header comment: it protects against "a malicious app
registers the `zulip://` URL on a device, which might otherwise allow it to hijack a user's API key". The pad
never leaves the device, so an app that merely intercepts the callback URL learns nothing.

### Client-side validation to copy

`WebAuthPayload.parse` in zulip-flutter enforces:
- scheme `zulip`, host `login`
- all four params present
- `user_id` parses as an int
- `otp_encrypted_api_key` matches `^[0-9a-fA-F]{64}$`

and `handleWebAuthUrl` then checks `payload.realm.origin == serverSettings.realmUrl.origin` before
decrypting. zulip-mobile does the same check via `isUrlOnRealm`. Do both — the callback is attacker-reachable.

Also: keep the OTP only for the duration of one attempt and clear it afterwards (`__otp = null` in the
`finally` of `handleWebAuthUrl`).

### iOS/macOS specifics

- zulip-flutter registers the **custom URL scheme** `zulip` in `ios/Runner/Info.plist`:
  `CFBundleURLTypes` → `CFBundleURLName` `org.zulip.Zulip`, `CFBundleURLSchemes` `["zulip"]`
  (<https://github.com/zulip/zulip-flutter/blob/main/ios/Runner/Info.plist>).
  There is no `macos/Runner/Info.plist` in that repo — zulip-flutter does not ship a macOS build.
- It uses an **in-app browser view** (`LaunchMode.inAppBrowserView` → `SFSafariViewController` on iOS), not
  `ASWebAuthenticationSession`. The callback arrives as a normal deep link into the app
  (`ZulipApp.didPushRouteInformation`, matching `Uri(scheme: 'zulip', host: 'login')` in
  `lib/widgets/app.dart`), and the app then calls `closeInAppWebView()`.
- zulip-mobile does the same: `openLinkEmbedded` (Custom Tabs / `SFSafariViewController`) plus
  `WebBrowser.dismissBrowser()` on iOS (`src/start/webAuth.js`).

For Zulu, `ASWebAuthenticationSession` with `callbackURLScheme: "zulu"` (or whatever scheme you register)
should work and is strictly better on iOS/macOS: the system hands you the callback URL directly instead of
routing it through the app-delegate, and the session is dismissed for you. **The scheme is not negotiable
with the server, though** — the server hardcodes `zulip://login`. So:
- `ASWebAuthenticationSession(url:callbackURLScheme: "zulip")` — you must claim the `zulip` scheme, which
  collides with the official Zulip app if both are installed.
- On iOS the callback is delivered to whichever app the system picks when two apps claim the same scheme —
  undefined behaviour. `ASWebAuthenticationSession`'s own interception happens inside your process before the
  system-wide handoff, so in practice the session wins while it is active, but this is not documented as
  guaranteed and should be tested with the official app installed.
- I could not find any server-side mechanism to make the redirect target a different scheme.
  `settings.REALM_MOBILE_REMAP_URIS` only remaps the `realm` **parameter** value, not the `zulip://` scheme
  (`create_response_for_otp_flow`), and it is a server-side setting a third party cannot set.

### Do not send a `ZulipElectron` User-Agent

`start_social_login`, `start_social_signup`, and `start_remote_user_sso` are wrapped in `@handle_desktop_flow`,
which renders `zerver/desktop_login.html` (a paste-your-token page) whenever
`parse_user_agent(request.headers["User-Agent"])["name"] == "ZulipElectron"` (`zerver/views/auth.py`).
Any other UA gets the normal flow. Send a Zulu-specific UA and the macOS build gets the mobile flow.

### The desktop flow is not what you want

`desktop_flow_otp` exists and is mutually exclusive with `mobile_flow_otp`
(`validate_otp_params` raises "Can't use both mobile_flow_otp and desktop_flow_otp together."). But it does
**not** return an API key. `finish_desktop_flow` renders `templates/zerver/desktop_redirect.html`, which asks
the user to copy an AES-GCM-encrypted `login_token` into the app; the token is single-use, expires in 15s
(`LOGIN_KEY_EXPIRATION_SECONDS`), and only buys a **browser session** via `log_into_subdomain`. Its docstring
says exactly that: "nothing more powerful is needed for the desktop flow". Use `mobile_flow_otp` on macOS too.

### Native Sign in with Apple: unusable for a third-party client

`AppleAuthBackend` supports a native flow — `POST {realm_url}/complete/apple/` with `native_flow=true`,
`id_token=<Apple JWT>`, plus `mobile_flow_otp` and the other relay params
(`zproject/backends.py::AppleAuthBackend.auth_complete`). But the `id_token` audience is validated against
`SOCIAL_AUTH_APPLE_AUDIENCE = [SOCIAL_AUTH_APPLE_SERVICES_ID, SOCIAL_AUTH_APPLE_APP_ID]`
(`zproject/computed_settings.py` line 1154), where `social_auth_apple_app_id` is a **server-side secret** set
by the operator to the bundle ID of the app they expect. Zulu's bundle ID will not be in that list on any
server you don't control, so `ASAuthorizationAppleIDProvider` tokens will fail validation. Use the web flow
for the `apple` external method.

zulip-flutter also notes a live iOS bug in the Apple **web** flow: `launchUrl` throws
`PlatformException("Error while launching …")` on iPhone even when auth succeeds, which they swallow
(`lib/widgets/login.dart`, TODO referencing zulip-flutter#462).

## 4. Using the key

HTTP Basic, username = the account's **delivery email**, password = the API key.

OpenAPI `securitySchemes` (`zerver/openapi/zulip.yaml`): "Basic authentication, with the user's email as the
username, and the API key as the password."

zulip-flutter `lib/api/core.dart`:

```dart
String _authHeaderValue({required String email, required String apiKey}) {
  final authBytes = utf8.encode("$email:$apiKey");
  return 'Basic ${base64.encode(authBytes)}';
}
```

Server side: `zerver/decorator.py::get_basic_credentials` splits the decoded value on `:` into
`(role, api_key)`; `validate_api_key` strips whitespace and looks the user up by key;
`validate_account_and_subdomain` then raises `RealmDeactivatedError` / `UserDeactivatedError` as appropriate.

API key format: 32 characters. `UserProfile.API_KEY_LENGTH = 32`, field is
`models.CharField(max_length=API_KEY_LENGTH, default=generate_api_key, unique=True)`
(`zerver/models/users.py` lines 450 and 533,
<https://github.com/zulip/zulip/blob/main/zerver/models/users.py>).

## 5. Lifetime, revocation, and what invalidates a key

**No expiry.** Nothing in the model or the auth path carries a timestamp or TTL for `api_key`.

What changes it:

| event | key regenerated? | source |
|---|---|---|
| explicit `POST /json/users/me/api_key/regenerate` | yes | `zerver/openapi/zulip.yaml` line 12149; <https://zulip.com/api/regenerate-api-key> |
| SAML SP-initiated logout (IdP `LogoutRequest`) | yes — `delete_user_sessions()` + `do_regenerate_api_key()` | `zproject/backends.py` ~3863 |
| password change | **no** | `zerver/actions/user_settings.py::do_change_password` only sets the password, clears the auth rate-limit history, and writes an audit log entry |
| account deactivation | no, but the key stops working | `do_deactivate_user` deletes sessions; `validate_account_and_subdomain` rejects `is_active == false` with `USER_DEACTIVATED` |
| realm deactivation | no, but the key stops working (`REALM_DEACTIVATED`) | same |
| app-side logout | no — clients only delete the local copy | zulip-flutter `GlobalStore.removeAccount`; it calls `remove_client_device`, not a key revocation |

`do_regenerate_api_key` (`zerver/actions/user_settings.py` line 320) also:
- deletes the old key from the cache,
- writes a `USER_API_KEY_CHANGED` audit log row,
- queues `clear_push_device_tokens`,
- deletes all `Device` rows (E2EE push registrations).

The API docs put it plainly: "Changing a user's API key will immediately log them out of Zulip on devices
registered for mobile push notifications", and, before Zulip 12.0 (feature level 492), regeneration did not
remove E2EE push device registrations.

The help center: "To invalidate an existing API key, you have to generate a new key. Generating a new API key
will immediately log you out of this account on all mobile devices." (<https://zulip.com/api/api-keys>)

### Practical consequence

There is no server-side "revoke this one device". The only revocation is "burn the account's single key",
which logs out every client of that account, including the official apps and including Zulu's own
notification service. Zulu should treat the key like a password: Keychain, no export, and expect that when
the user regenerates it, every stored copy dies at once. Detect this by treating a `401 UNAUTHORIZED` /
`AUTHENTICATION_FAILED` on any authenticated request as "re-run sign-in".

## 6. Can one account hold multiple independent API keys?

**No.** `UserProfile.api_key` is a single `CharField` with `unique=True`. Every code path that hands a key to
a client returns `user_profile.api_key` verbatim:

- `api_fetch_api_key` → `process_api_key_fetch_authenticate_result` → `return user_profile.api_key`
- `finish_mobile_flow` → `api_key = user_profile.api_key`
- `json_fetch_api_key` → `api_key = user_profile.api_key`
- `jwt_fetch_api_key` → same helper

So logging in twice — from the app and from the notification service — yields the **same string**, and
regenerating for one revokes the other. The notification service's credential is not separable from the
app's by any Zulip mechanism.

The only way to get an independent Zulip credential is a **bot user**, which is a separate account:
`GET /json/bots/{bot_id}/api_key` and `POST /json/bots/{bot_id}/api_key/regenerate`
(`zproject/urls.py` lines 370–371). A bot has its own `UserProfile` and its own key. That does not solve the
notification problem, because a bot cannot see the owner's DMs, private channels it isn't subscribed to, or
the owner's unread/mention state — a notification service needs to act **as the user**.

Design implications for Zulu:

- The Go service and the app should share one key per account, fetched once and handed over deliberately,
  rather than each running its own login (two logins just produce the same string and two `email_on_new_login`
  notification emails — `finish_mobile_flow` and `process_api_key_fetch_authenticate_result` both call
  `email_on_new_login` manually, since neither goes through Django's `login()`).
- Any "sign out everywhere" feature you build has to be "regenerate the key", with the understanding that it
  also signs the user out of the official Zulip apps.
- Zulip 12.0 (feature level 468/470) adds `POST /register_client_device` → `{device_id}` and
  `POST /remove_client_device` for per-device records used by E2EE push
  (<https://zulip.com/api/register-client-device>, <https://zulip.com/api/remove-client-device>). These give
  per-device *push* registration, not per-device *credentials*, and only on servers at FL ≥ 468.

## 7. Things I could not determine

- Whether iOS reliably routes the `zulip://login` callback to an `ASWebAuthenticationSession` in Zulu when
  the official Zulip app is also installed and also claims the `zulip` scheme. No Apple or Zulip
  documentation addresses the collision; needs an on-device test.
- Whether any server-side setting lets a client choose the redirect scheme. I found only
  `REALM_MOBILE_REMAP_URIS`, which rewrites the `realm` query parameter, not the scheme, and is
  operator-controlled.
- Documented error codes for `fetch_api_key` — upstream OpenAPI documents only the `200` case. The error
  table above is derived from source, so a future server version could change it without a docs change.
- Whether `push_notifications_enabled: false` in `server_settings` reliably predicts that a self-hosted
  server will not deliver pushes; not investigated here (belongs with issue 04/15).
- Behaviour of `mobile_flow_otp` against servers that predate a given backend (e.g. very old Zulip with no
  `external_authentication_methods`). Zulip 2.1.0 is the floor for that field; zulip-flutter enforces its own
  `kMinAllowedZulipVersion` rather than handling older servers.

## Sources

Server (`zulip/zulip@370f7b6`):
- `zerver/views/auth.py` — <https://github.com/zulip/zulip/blob/main/zerver/views/auth.py>
- `zproject/backends.py` — <https://github.com/zulip/zulip/blob/main/zproject/backends.py>
- `zerver/lib/mobile_auth_otp.py` — <https://github.com/zulip/zulip/blob/main/zerver/lib/mobile_auth_otp.py>
- `zerver/actions/user_settings.py` — <https://github.com/zulip/zulip/blob/main/zerver/actions/user_settings.py>
- `zerver/models/users.py` — <https://github.com/zulip/zulip/blob/main/zerver/models/users.py>
- `zerver/decorator.py` — <https://github.com/zulip/zulip/blob/main/zerver/decorator.py>
- `zerver/lib/exceptions.py` — <https://github.com/zulip/zulip/blob/main/zerver/lib/exceptions.py>
- `zproject/urls.py` — <https://github.com/zulip/zulip/blob/main/zproject/urls.py>
- `zproject/default_settings.py` — <https://github.com/zulip/zulip/blob/main/zproject/default_settings.py>
- `zproject/computed_settings.py` — <https://github.com/zulip/zulip/blob/main/zproject/computed_settings.py>
- `zerver/openapi/zulip.yaml` — <https://github.com/zulip/zulip/blob/main/zerver/openapi/zulip.yaml>
- `templates/zerver/desktop_redirect.html`, `templates/zerver/desktop_login.html`

Clients:
- zulip-flutter `lib/api/model/web_auth.dart`, `lib/api/route/account.dart`, `lib/api/route/realm.dart`,
  `lib/api/core.dart`, `lib/widgets/login.dart`, `lib/widgets/app.dart`, `ios/Runner/Info.plist`
  — <https://github.com/zulip/zulip-flutter>
- zulip-mobile `src/start/webAuth.js` — <https://github.com/zulip/zulip-mobile/blob/main/src/start/webAuth.js>

Docs:
- <https://zulip.com/api/fetch-api-key>
- <https://zulip.com/api/dev-fetch-api-key>
- <https://zulip.com/api/get-server-settings>
- <https://zulip.com/api/regenerate-api-key>
- <https://zulip.com/api/api-keys>
- <https://zulip.com/api/register-client-device>
- <https://zulip.readthedocs.io/en/latest/production/authentication-methods.html>

Third-party:
- python-social-auth `social_core/backends/apple.py` —
  <https://github.com/python-social-auth/social-core/blob/master/social_core/backends/apple.py>
