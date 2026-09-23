# Channel groups and iCloud sync

Type: grilling
Status: resolved
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

## Scope narrowed: icons stay local

Group **icons are out of iCloud sync**. Only the text — group names, order, and channel
membership — needs to travel between devices. An icon is a per-device nicety; losing it on a
second device is a far smaller cost than the machinery of syncing binary payloads.

That changes the mechanism. Without images the synced document is a few hundred bytes of
JSON, which sits comfortably inside `NSUbiquitousKeyValueStore`'s 1MB budget, so CloudKit
and its `CKAsset` handling are no longer required. KVS also brings last-writer-wins and
change notifications for free, which is enough for a single person editing their own groups.

Still blocked on the same thing: **iCloud of any kind needs an entitlement, which needs a
Development Team on the target.** The project has none. When one exists, this is a small
piece of work rather than a large one.

## Answer — sync built

The Development Team exists now, so the blocker is gone.

- **One document per realm** in `NSUbiquitousKeyValueStore`, keyed by the realm URL, since
  channel ids mean nothing on another server. It carries groups, filing, channel aliases,
  modes, hiding, sidebar order, and promoted topics. Icons stay on the device.
- **Last writer wins** on the whole document.
- **A device only speaks for channels it holds.** Settings for a channel it is not
  subscribed to are passed along untouched, and filled in once that channel arrives.
- **A fresh device writes nothing** until it has something of its own, so it cannot erase
  the document iCloud is still downloading.
- **Signed out of iCloud** keeps working: key-value storage holds a local copy.
- **Signing out of Zulip clears groups locally.** They come back from iCloud on sign-in to
  the same realm; a different realm starts from its own document. Icons do not come back.
- iOS and Mac share one store identifier, so both apps see the same arrangement.

Eleven tests: the document round-trip and carry-over in `ZuluStoreTests`, and two devices
syncing through a fake iCloud in `ZuluSyncTests`. Not yet checked across two real devices.
