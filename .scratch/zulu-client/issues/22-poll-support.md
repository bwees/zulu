# Polls

Type: grilling
Status: open
Blocked by: 11

## Question

How does Zulu render and take part in a poll?

Polls do not arrive as message content. `/poll` produces a message whose `content` is the
bare command text — which is exactly what Zulu shows today — and the real poll lives in the
message's `submessages` array, a separate wire protocol from the markdown pipeline. Nothing
in the store or the parser knows about it.

Decide:
- The submessage protocol: what `submessages` carries, how options and votes are encoded,
  and which events announce a new vote.
- How a poll is stored. It is per-message state that changes independently of the message,
  so it likely wants its own table rather than a column.
- What the poll looks like in a conversation, and how voting feels on a phone.
- Whether Zulu can *create* polls in v1 or only display and vote on them.
- Whether todo lists — the other widget built on the same protocol — come along for the ride.

This needs a research pass on the submessage protocol before the design questions can be
answered; neither the events nor the message-model research covered widgets.

Scope change: the effort originally ruled polls out of v1. The user has since asked for them.
