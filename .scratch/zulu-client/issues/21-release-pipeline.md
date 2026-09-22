# Release pipeline to App Store Connect

Type: grilling
Status: open
Blocked by: 17

## Question

What does releasing Zulu look like, and what does CI have to do on a tagged release?

Decide:
- The trigger — tag, GitHub release, or manual dispatch — and what gets versioned (marketing version, build number, and where each is stored).
- Signing on CI: certificates and provisioning profiles, where they live, and how secrets reach the runner.
- Whether both the iOS and macOS apps ship through App Store Connect, and whether the Mac app also needs a Developer ID build.
- Whether the notification service releases on the same trigger or its own, and what artifact it produces.
- What must pass before a release build runs.

Newly in scope: the effort originally ruled App Store distribution out, and the user has since asked for automatic builds on release pushing to App Store Connect.
