# Forum-vs-chat auto-detection

Type: grilling
Status: resolved
Blocked by: 02, 03

## Question

What is the heuristic that decides whether a channel renders as a forum or as flat chat?

Decide the signal (topic cardinality over a recent window, message distribution, channel age), the thresholds, when it is evaluated, and whether the answer can change under the user without feeling unstable. Decide how the per-channel user override is represented, how it interacts with re-evaluation, and what a brand-new empty channel defaults to.

## Answer

**Topic count is the wrong signal on its own.** Plenty of chat channels have accumulated a
long tail of dead topics, and the old "more than one topic" rule called every one of them a
forum. On the real account that misread `immich-focus-topic`, which has three topics but is
plainly a chat room.

What separates the two is whether more than one topic is *currently* live. Message ids rise
monotonically across the realm, so a topic's newest id stands in for how recently it was
touched:

> Sort the channel's topics by newest message id. If the leader is more than **half the
> channel's whole id span** ahead of the runner-up, one conversation is absorbing the
> traffic and the channel is a chat room. Otherwise it is a forum.

One topic is always chat; several topics sharing an id is a burst across topics, so a forum.
Exactly at the threshold counts as a forum, so a channel is only demoted when one topic is
clearly dominant.

- Cached on the channel as `detectedForum`, recomputed whenever topics are refetched, so the
  sidebar does not re-derive it per row.
- `modeOverride` is the person's explicit choice and wins outright; `nil` hands the channel
  back to the detector. Reachable by long-pressing a channel row: Automatic / Chat / Forum.
- Seven tests on the rule, and it was checked against the real account: eleven channels read
  as forums, five as chat, including the three-topic channel the old rule got wrong.

Not carried over from the original ticket: the override is **not synced**, for the same
reason [channel groups are not](10-channel-groups-icloud-sync.md) — no iCloud entitlement.
It belongs in the same synced document when that becomes possible.
