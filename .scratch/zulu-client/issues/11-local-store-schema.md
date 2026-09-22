# Local store schema and sync model

Type: grilling
Status: open
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
