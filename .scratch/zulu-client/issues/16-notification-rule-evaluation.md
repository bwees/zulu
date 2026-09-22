# Deciding what notifies

Type: grilling
Status: open
Blocked by: 03, 12, 13

## Question

How does the service decide whether a given event becomes a push, and to which devices?

Decide:
- The evaluation order across realm settings, per-channel subscription settings, per-topic policy, mention type, and DM.
- How the service keeps a current copy of those settings without re-fetching per message.
- Suppression: already-read messages, the user's own messages, messages the user is actively viewing on another device, and edits or deletions of a message already pushed.
- Per-device targeting — whether every device always gets every push.
- Batching and rate limiting so a busy topic does not produce a notification storm.
- The payload shape, including the fields the NSE and the app's deep link need.
