# Zulip auth for native clients

Type: research
Status: resolved

## Question

How does a native app obtain a long-lived Zulip API key for both password and SSO sign-in, against any Zulip server?

Find:
- The `fetch_api_key` / `dev_fetch_api_key` endpoints and what a password login actually posts.
- The mobile/desktop SSO flow: how `/accounts/login/sso`, SAML, and OIDC hand a key back to a native app, the custom URL scheme or `ASWebAuthenticationSession` pattern the official clients use, and what the redirect payload contains.
- How a client discovers which auth backends a given realm has enabled before showing a sign-in screen.
- Key lifetime, revocation, and what happens on password change or session invalidation.
- Whether one account can hold multiple independent API keys, so the notification service's key is separable from the app's.

## Research output

`.scratch/zulu-client/research/01-zulip-auth-api.md`

## Answer

Password login is `POST {realm}/api/v1/fetch_api_key` (form-encoded, no auth). SSO uses the undocumented `mobile_flow_otp` protocol: generate 64 hex chars, open `realm + login_url + ?mobile_flow_otp=…` in `ASWebAuthenticationSession`, and the server ends on a 302 to `zulip://login?otp_encrypted_api_key=…` — the key XOR'd with the pad. SAML, OIDC, and `/accounts/login/sso` all arrive through that one mechanism. Backends are discovered ahead of the sign-in screen via unauthenticated `GET /api/v1/server_settings`.

Three consequences that change other tickets:

- **A Zulip account has exactly one API key.** `UserProfile.api_key` is a single unique column; the app and the notification service cannot hold separate credentials, and regenerating for one revokes the other and signs the user out of the official apps. Bot users are the only independent credential but cannot see the owner's DMs or unread state, so they can't back the service.
- **The `zulip://` redirect scheme is hardcoded server-side**, so Zulu must claim a scheme the official app also claims. iOS behaviour with both installed is undetermined and needs an on-device test.
- **`desktop_flow_otp` is not usable** — it returns a 15-second session token, not an API key. macOS uses the mobile flow too.

Full findings, with endpoint shapes and source links: `.scratch/zulu-client/research/01-zulip-auth-api.md`
