# Promoting topics, and renaming channels for yourself

Type: grilling
Status: resolved
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

## Answer — built

Both halves live in the store beside channel groups, because both are the viewer's alone.

**Promotion.** `promotedTopic(channelID, topic, groupID, position)`. A promoted topic appears
at channel level with the channel it came from underneath it, and **leaves the forum list
beneath that channel** — shown in both places it would be a duplicate whose unread counted
twice. It can be filed into any group independently of its channel, which is most of the
point: the reason to promote a standing conversation is to put it where you actually look.

Promotions survive their target moving, as far as they can:
- `renamePromotedTopic` follows a server-side rename.
- `pruneVanishedPromotions` runs after each topic refetch and drops promotions with nothing
  behind them, rather than leaving a dead entry in the sidebar.

**Rename.** An `alias` column on `channel`. The sidebar shows `COALESCE(alias, name)`; the
server's own name stays in `name` untouched, because a mention has to emit the real one to
produce a working link. Clearing the alias, or entering only whitespace, restores the real
name. Reachable by long-pressing a channel row.

Nine tests, including that the real name survives under an alias and that a promoted topic
leaves and returns to the forum list as it is promoted and demoted.

Verified against the real account: a promoted "general chat" showing "Off-topic" as its
origin, with that channel renamed locally.

**Still not synced**, same blocker as groups: no iCloud entitlement without a Development
Team. Aliases and promotions belong in the same synced document when that exists.

Not built: **search does not yet match aliases** — it matches nothing yet, since search is
unbuilt. When it lands it should match both the alias and the real name.

## Second pass — hiding, absorption, topic aliases

Settled in conversation and built:

- **Promoting the last topic absorbs its channel.** A channel whose every topic is promoted
  drops out of the list, because nothing would be left beneath it but its own promoted topic
  one level up. It returns on its own the moment a new topic appears, and the promotion is
  left alone.
- **Hiding is local and nothing more.** A hidden channel is still subscribed, still notifies,
  still counts its mentions. It simply does not take a row. Reachable and reversible from a
  **Hidden Channels** screen in the list header menu.
- **A hidden channel's unread stops feeding its group's dot, but its mentions still do.**
  Otherwise hiding a noisy channel leaves a dot that can never be cleared; a direct mention
  is addressed to you and outranks your filing.
- **Promoted topics get their own alias**, which is the case that most needs one — promoting
  `general chat` otherwise gives a top-level row whose name says nothing.
- **The real name lives in the conversation header**, under the title, so a reference to it
  from someone else is still recognisable.

Eight more tests cover absorption, the channel's return, hiding and unhiding, and alias
fallback.

The channel list was restyled at the same time: channels read as headers, topics as their
contents on a single quiet rule rather than an elbow per row, with tighter rows and real
separation between one channel's block and the next.
