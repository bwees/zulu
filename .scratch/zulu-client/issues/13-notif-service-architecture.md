# Notification service architecture

Type: grilling
Status: open
Blocked by: 02

## Question

What is the shape of the Go service that runs an event queue per user?

Decide:
- The per-user worker model: goroutine lifecycle, longpoll loop, backoff, queue re-registration, and what happens when a user's key is revoked.
- How many users one instance is designed to hold, and what the resource budget per user is.
- The SQLite schema: users, realms, credentials, device tokens, per-user queue cursors, and delivery log.
- Process structure with uber/fx: which components exist and how they are wired.
- Restart behaviour — what is durable and what is rebuilt on boot.
- How a user is onboarded to and removed from the service.
