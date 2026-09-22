# Channel groups and iCloud sync

Type: grilling
Status: open
Blocked by: 06

## Question

How are user-defined channel groups modelled and synced across devices?

Decide:
- The group data model: ordering, nesting, whether a channel can be in several groups, and what happens to ungrouped channels.
- What else rides along in the same synced document — channel mode overrides, rail order, collapsed state.
- CloudKit private database versus `NSUbiquitousKeyValueStore` versus a synced file, and the conflict-resolution rule.
- Behaviour when iCloud is unavailable or the user is signed out of iCloud.
- Whether groups survive signing into a different realm later.

## Added while prototyping

Groups carry a **user-supplied icon image**, not just a name — the rail shows the image where one is set and falls back to initials where it isn't. That makes the synced document carry binary payloads, which changes the storage question: `NSUbiquitousKeyValueStore` has a hard 1MB total budget and is almost certainly ruled out. Decide the image's storage, size cap, and downscaling rule alongside the rest of the group model.

## Answer — the model and the UI

Groups are Zulu's own idea, so they live in Zulu's store: `channelGroup` (id, name, icon,
position) and `channelGroupMember` (groupID, channelID, position).

- **A channel belongs to at most one group.** Filing it somewhere removes it from wherever
  it was. Two groups both claiming a channel would make the rail's unread counts double-count.
- **Unfiled channels stay visible** under their own rail entry, so filing is optional rather
  than a chore you must finish before the app is usable.
- **Icons are user-supplied images**, downscaled to 256px JPEG on selection because they are
  meant to sync; a group with no icon draws its initials.
- The rail is DMs, then groups, then unfiled, then a plus. Long-press a group to edit or
  delete it.

## Still open: the sync half

**iCloud sync is not implemented.** Both plausible mechanisms — CloudKit's private database
and `NSUbiquitousKeyValueStore` — require an iCloud entitlement, which requires a
Development Team on the target. The project has none, so the capability cannot be enabled
and nothing can be tested.

The research finding stands: icons are binary, and `NSUbiquitousKeyValueStore` has a 1MB
total budget, so **CloudKit is the mechanism** — a private-database record per group with
the icon as a `CKAsset`.

What is needed before this can be finished:
- A Development Team and the iCloud capability with a CloudKit container.
- Then: a conflict rule (last-writer-wins on a per-group `modifiedAt` is probably enough,
  since a person editing their own groups on two devices at once is rare), and behaviour
  when iCloud is signed out — which should be "keep working locally", not "lose the groups".
