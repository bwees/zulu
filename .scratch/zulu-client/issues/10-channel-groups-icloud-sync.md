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
