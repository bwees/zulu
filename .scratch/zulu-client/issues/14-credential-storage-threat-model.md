# Credential storage and threat model

Type: grilling
Status: open
Blocked by: 01, 13

## Question

How are users' Zulip API keys held, and what is the stated threat model?

The service holds keys that grant full account access on servers the dev does not control. Decide:
- Encryption at rest in SQLite, where the key-encryption key lives, and what an attacker with the database file alone can do.
- Whether the service's key is separate from the app's, and whether it can be scoped or independently revoked.
- What the user is told at registration, and how they revoke.
- Transport and authentication between app and service.
- What is logged and what must never be logged.
- The honest, written statement of what compromise of the instance would mean.
