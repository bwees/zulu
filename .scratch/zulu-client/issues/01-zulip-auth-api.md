# Zulip auth for native clients

Type: research
Status: claimed

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
