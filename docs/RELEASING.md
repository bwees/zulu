# Releasing Zulu

Releases are cut by release-please. Every push to `main` updates one release PR per
component, built from conventional commits:

| Component | Paths | Tag | Merging its release PR runs |
| --- | --- | --- | --- |
| `zulu` | everything but `service/` | `zulu-v1.2.3` | `release.yml`: tests ZuluKit, archives, uploads to TestFlight |
| `notifyd` | `service/` | `notifyd-v0.1.0` | `notifyd-release.yml`: pushes `ghcr.io/bwees/zulu-notifyd:v0.1.0` |

`release.yml` can also be run by hand from the Actions tab. Nothing below happens
automatically — this is the one-time setup a human has to do first, in this order.

Team: **Brandon Wees, `65AMD2STXG`** (not FUTO Holdings). Bundle id: `com.bwees.zulu`.

## 1. Register the App ID

<https://developer.apple.com/account/resources/identifiers>

- Identifiers → **+** → App IDs → App.
- Description: `Zulu`. Bundle ID: **Explicit**, `com.bwees.zulu`.
- No capabilities to enable yet. Push notifications will need one later; the Go
  service in `service/` is not wired to APNs through this pipeline.

`xcodebuild -allowProvisioningUpdates` creates the provisioning profile itself on
every run, so there is no profile to make or store by hand. The App ID is the one
thing it cannot invent for you correctly, because the bundle id has to be explicit
rather than wildcard for App Store submission.

## 2. Create the app record in App Store Connect

<https://appstoreconnect.apple.com/apps>

- **+** → New App. Platform iOS, bundle ID `com.bwees.zulu`, SKU `zulu-ios`.
- Primary language, name, user access: your call.

Uploads are rejected until this record exists. You do not need to fill in any store
metadata to use TestFlight internal testing.

## 3. Export the signing certificates

The workflow needs **both** identities in one `.p12`. `xcodebuild archive` with
automatic signing signs the archive for development, and `-exportArchive` re-signs
it for distribution; a runner holding only the distribution certificate fails at the
archive step.

In **Keychain Access**, login keychain, My Certificates:

- Select both `Apple Development: Brandon Wees` and
  `Apple Distribution: Brandon Wees` (cmd-click) — the rows with a disclosure
  triangle hiding a private key. A row without one is useless here.
- Right click → Export 2 items… → Personal Information Exchange (.p12).
- Set a password. You need it again in step 5.

Then base64 it for the secret:

```sh
base64 -i Certificates.p12 | pbcopy
```

If you ever need to make the distribution certificate from scratch:
<https://developer.apple.com/account/resources/certificates> → **+** → Apple
Distribution, upload a CSR from Keychain Access → Certificate Assistant → Request a
Certificate From a Certificate Authority, then double-click the download to install it.

## 4. Create the App Store Connect API key

<https://appstoreconnect.apple.com/access/integrations/api> → Team Keys.

- **+**, name it `GitHub Actions`, access **App Manager**. Developer is not enough:
  the key both creates provisioning profiles and uploads builds.
- Download the `.p8`. **Apple lets you download it once.** Store it in a password
  manager.
- The page shows the three values you need:
  - **Key ID** — the column next to the key name, e.g. `ABC123DEF4`.
  - **Issuer ID** — a UUID above the key table, shared by every key in the team.
  - The `.p8` file itself.

Base64 the key:

```sh
base64 -i AuthKey_ABC123DEF4.p8 | pbcopy
```

## 5. Set the GitHub secrets

Repo → Settings → Secrets and variables → Actions → New repository secret. All four
are required, spelled exactly as below.

| Secret | Value |
| --- | --- |
| `APPLE_SIGNING_CERTIFICATES_P12` | base64 of the two-identity `.p12` from step 3 |
| `APPLE_SIGNING_CERTIFICATES_PASSWORD` | the password you set when exporting that `.p12` |
| `APP_STORE_CONNECT_KEY_ID` | Key ID from step 4, plain text, e.g. `ABC123DEF4` |
| `APP_STORE_CONNECT_ISSUER_ID` | Issuer ID from step 4, plain text UUID |
| `APP_STORE_CONNECT_PRIVATE_KEY` | base64 of the `.p8` from step 4 |

The team ID is not a secret and lives in `env.APPLE_TEAM_ID` in the workflow and in
`App/ExportOptions.plist`.

## 6. Add yourself as an internal tester

App Store Connect → Zulu → TestFlight → Internal Testing → create a group, add your
Apple ID. Internal testing needs no Beta App Review, so a build is installable within
minutes of the upload finishing processing.

## Versioning

| | Where | Who changes it |
| --- | --- | --- |
| `CFBundleShortVersionString` | `MARKETING_VERSION` in `App/project.yml` | release-please, in the release PR |
| `CFBundleVersion` | `git rev-list --count HEAD` | the workflow, per run |

Marketing version follows the commits: `fix:` bumps the patch, `feat:` the minor, and
`!` or `BREAKING CHANGE:` the major. release-please finds the line by its
`x-release-please-version` comment, so keep that comment on it.

Build number has one hard requirement: App Store Connect rejects a build whose
`CFBundleVersion` it has already seen for the same marketing version. Commit count
satisfies that without storing any state, without a commit back to `main`, and
without asking App Store Connect what the last number was. It is also reversible —
given build `41` you can find the exact commit with `git rev-list --count HEAD`
against candidates, or just check out `main~n`. The alternatives are worse:
`github.run_number` is opaque and unreproducible from a checkout, and a
tag-derived number means no build until someone tags.

The one way commit count stops being monotonic is a force-push to `main` that drops
commits. Don't do that; if it happens, bump `MARKETING_VERSION` and the collision
goes away.

`App/ExportOptions.plist` sets `manageAppVersionAndBuildNumber: false` so that
`-exportArchive` leaves the number alone instead of substituting its own.

## Export compliance

`App/project.yml` declares `ITSAppUsesNonExemptEncryption: false` in the app's
`Info.plist`. Zulu only uses HTTPS to reach a Zulip server, which is an exempt use of
encryption. Without the key, every upload lands in TestFlight as **Missing
Compliance** and cannot be distributed to testers until somebody answers the
questionnaire in the web UI by hand — which defeats the point of an automatic
pipeline. If Zulu ever adds its own cryptography, this declaration has to be revisited
and may require a CCATS/exemption filing.

## Why no fastlane

Everything here is two `xcodebuild` invocations and one `xcrun altool` invocation.
fastlane would add a Ruby toolchain, a `Gemfile.lock` to keep current, and a plugin
surface, in exchange for wrapping commands we are already calling directly. `match`
is the part worth wanting, but it needs a second private repository to hold the
certificates, which is more moving parts than one `.p12` in a GitHub secret. Revisit
if a second app or a second signing platform shows up.

`notarytool` does not apply: notarization is for Developer ID distribution of macOS
apps outside the App Store. iOS App Store builds are signed and uploaded, never
notarized.

## Why the release job signs and `ci.yml` doesn't

`ci.yml` builds with `CODE_SIGNING_ALLOWED=NO` for the simulator and stays that way.
No signing settings live in `App/project.yml`, deliberately: a `DEVELOPMENT_TEAM`
there gives the app a real `application-identifier` entitlement, which changes the
keychain access group, which hides the API key `AccountStorage` already wrote — a
local development build silently signs you out. The release workflow passes
`DEVELOPMENT_TEAM` and `CODE_SIGN_STYLE` on the `xcodebuild` command line for the
archive only, so the simulator build keeps its ad-hoc signature and its entitlement-free
bundle.

Do not add `CODE_SIGN_IDENTITY` next to them. Automatic signing refuses a manually
chosen identity and fails the archive with "conflicting provisioning settings".

## When something goes wrong

- **Archive fails on provisioning.** The App ID (step 1) is missing, or the API key
  has Developer access instead of App Manager.
- **Upload rejected as a duplicate build.** Two runs produced the same commit count;
  bump `MARKETING_VERSION`.
- **Build stuck on Processing for hours.** Normal for the first upload of a new app.
  Past that, check the email Apple sends — it names the actual rejection.
- **codesign hangs.** The keychain partition list did not get set; the run will time
  out rather than prompt.
