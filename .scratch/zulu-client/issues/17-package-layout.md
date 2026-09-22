# Swift package layout and module boundaries

Type: grilling
Status: open
Blocked by: 07, 11

## Question

What are the Swift packages, and what does each own?

Decide the split across domain model, persistence, Zulip API client, event sync, notification-service client, and shared view models; which of those the two app targets depend on; where platform-conditional code is allowed; how the OpenAPI-generated notification-service client is vendored; and what the dependency direction rules are.
