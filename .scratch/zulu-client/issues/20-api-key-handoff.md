# One key, two holders

Type: grilling
Status: open
Blocked by: 01

## Question

A Zulip account has exactly one API key, and both the app and the notification service need it. How is it obtained and handed over?

`UserProfile.api_key` is a single unique column. There is no scoping and no second credential: regenerating it for one holder revokes the other and signs the user out of the official clients. Bot users are independent but cannot see the owner's DMs or unread state, so they cannot back the service.

Decide:
- Whether the app signs in and hands the key to the service, or the service runs its own sign-in — and what the user is shown either way.
- What happens when the key is regenerated elsewhere: how each side notices, and how the user recovers.
- Whether the app can function with the service unreachable, and vice versa.

Second, separate problem from the same research: **the `zulip://` redirect scheme is hardcoded in the Zulip server**, so Zulu must claim a URL scheme the official app also claims. iOS behaviour when both are installed is undetermined. Decide whether this needs an on-device test first (a [task](README.md) ticket), a workaround, or an upstream change.

Discovered by [Zulip auth for native clients](01-zulip-auth-api.md).
