# Swift package layout and module boundaries

Type: grilling
Status: resolved
Blocked by: 07, 11

## Question

What are the Swift packages, and what does each own?

Decide the split across domain model, persistence, Zulip API client, event sync, notification-service client, and shared view models; which of those the two app targets depend on; where platform-conditional code is allowed; how the OpenAPI-generated notification-service client is vendored; and what the dependency direction rules are.

## Answer — settled by building it

One package, `Packages/ZuluKit`, four targets:

- `ZulipAPI` — REST, auth, events, uploads. No UI, no persistence, no other Zulu target.
- `ZuluMarkup` — parses `rendered_content` into blocks. Depends on nothing at all.
- `ZuluStore` — GRDB records, schema, queries. Depends on `ZulipAPI` for the wire types.
- `ZuluSync` — owns the event queue. Depends on `ZulipAPI` and `ZuluStore`.

GRDB stops at `ZuluStore`: when the sync engine needed to mutate rows the answer was to add
store methods, not to let a second target import GRDB. The app target holds all SwiftUI.

macOS is not yet a target. The four packages are platform-agnostic, so it is additive.
