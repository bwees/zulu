# Local store schema and sync model

Type: grilling
Status: resolved
Blocked by: 02, 05

## Question

What does the GRDB schema look like, and how does the event stream drive it?

Decide:
- Tables for channels, topics, messages, reactions, flags, users, and subscriptions, and their keys and indexes.
- How the register snapshot lands, and how events apply as incremental writes.
- Backfill: when history is fetched, how far, and how gaps are represented so the UI can distinguish "nothing there" from "not fetched yet".
- Retention — whether the store grows without bound.
- The observation path from DB to SwiftUI, and where the boundary between store and view model sits.
- Migration strategy.

## Answer — settled by building it

`Packages/ZuluKit/Sources/ZuluStore`. GRDB, six tables: `channel`, `topic`, `message`,
`user`, `reaction`, `syncState`, with indexes on `(channelID, topic, id)` and `(dmKey, id)`.

- **DM conversations have no table.** A message carries a `dmKey` — the sorted, comma-joined
  participant ids including the viewer — so a conversation is a `GROUP BY` rather than a
  row that has to be kept in step.
- **The register snapshot replaces channels wholesale**; events apply as incremental writes;
  `syncState` holds the queue id and last event id so a relaunch resumes.
- **The UI reads only through `ValueObservation`.** Sidebar counts are one query with
  correlated subqueries, not N+1.
- **Gaps are not represented yet.** History is fetched per conversation on first open and
  there is no record of which ranges have been fetched, so "nothing there" and "not fetched"
  still look the same. Backfill on scroll needs that before it can work.
- **Retention is unbounded.** Nothing prunes.

The two gaps above are the remaining work, and they belong with
[Read and unread state](12-read-state-model.md).
