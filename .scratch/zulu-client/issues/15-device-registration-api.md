# App to service API

Type: grilling
Status: open
Blocked by: 04, 13

## Question

What is the contract between the app and the notification service?

Decide:
- Registration: what the app sends (realm URL, API key, device token, platform, app version) and what it gets back.
- How a single user's multiple devices are identified, listed, and deregistered.
- Authentication on subsequent calls.
- Re-registration on token rotation, app reinstall, and realm change.
- The transport and spec format — the repo standard is OpenAPI-first with a generated client, and fuego for the Go side.
- Health, status, and how the app surfaces "notifications are not working".
