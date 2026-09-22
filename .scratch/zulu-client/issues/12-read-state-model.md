# Read and unread state

Type: grilling
Status: open
Blocked by: 02, 11

## Question

How is unread state computed, displayed, and propagated?

Decide:
- Where unread counts come from: the register snapshot, local derivation, or both, and how they stay reconciled.
- What marking-as-read means per render mode — scrolling a chat channel versus opening a forum thread.
- How the mark-read call is batched and what happens when it fails offline.
- How badge counts roll up from topic to channel to group to app icon.
- The muted-topic and muted-channel interaction with every count above.
- How reading on one device clears a pending or delivered notification on another.
