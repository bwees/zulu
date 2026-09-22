# Promoting topics, and renaming channels for yourself

Type: grilling
Status: open
Blocked by: 10

## Question

How does someone reshape the sidebar into the one they actually want?

Two related powers, both purely the viewer's — the Zulip server never learns about either,
which puts them alongside [channel groups](10-channel-groups-icloud-sync.md) rather than
anything in the API.

**Promote a topic to sit at channel level.** Some topics are permanent — a standing project,
a recurring meeting — and cost two taps every time while one-off topics sit at the same
level. Promoting one lifts it into the sidebar beside channels; the rest of that channel's
topics stay as forum topics underneath it.

- Does a promoted topic still appear in the forum list under its channel, or only at the top
  level? **Working answer: only at the top level.** In both places it would be a duplicate,
  and its unread count would be totalled twice in the channel above it.
- Can a promoted topic be filed into a group on its own, away from its channel?
- What happens when the channel is left, archived, or renamed server-side?
- What happens to a promotion when that topic goes quiet, or is moved or resolved — Zulip
  topics are mutable in a way channels are not, and a promotion is a reference to a name.

**Rename a channel for yourself.** A local alias over the server's name.

- Does the real name stay visible anywhere — the conversation header, a subtitle, a
  long-press?
- Does search match the alias, the real name, or both?
- Does the alias follow into `#**mention**` autocomplete, which must emit the *real* name to
  produce a working link?
- Should topics be renameable the same way, or is that a step too far given they are already
  mutable server-side?

Both belong in the same synced document as groups, so they inherit its blocker: **no iCloud
entitlement without a Development Team.** Local-only until then.
