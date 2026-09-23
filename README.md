# Zulu

A native Zulip client for iOS and macOS.

Zulu exists because the official clients make topics hard to live in. Here topics are
first-class: a channel that uses them renders as a list of threads, a channel that
doesn't renders as plain chat, and the app works out which is which. Channels group into
folders you make, topics can be promoted to sit beside channels, and anything can be
renamed or hidden for yourself alone — none of which the Zulip server ever learns about.

Minimum iOS 27, built on Liquid Glass.

## Status

Early but usable. Sign in against any Zulip server; read and send in channels, topics and
DMs; react and reply; attach files, photos and camera captures; vote in polls. A Go
notification service lives in `service/` and builds to a container, but is not deployed.

See [`.scratch/zulu-client/map.md`](.scratch/zulu-client/map.md) for the decisions already
locked and what is still open.

## Layout

| Path | What |
| --- | --- |
| `App` | The iOS app |
| `Packages/ZuluKit` | `ZulipAPI`, `ZuluStore` (GRDB), `ZuluSync`, `ZuluMarkup`, `ZuluEmoji`, `ZuluCompose`, `ZuluPolls` |
| `service` | The Go notification service |
| `prototypes/` | Throwaway prototypes that answer one design question each |
| `.scratch/zulu-client/` | The wayfinder map, its decision tickets, and research notes |

## Running it

```sh
cd App && xcodegen generate && open Zulu.xcodeproj
```

Then sign in with your Zulip organization's address. Password and SSO both work; SSO opens
a browser and comes back through the `zulip://` callback the server hardcodes.

Releases to TestFlight happen on every push to `main` — see
[`docs/RELEASING.md`](docs/RELEASING.md) for the one-time Apple setup that requires.

The nav-shell prototype still runs on its own:

```sh
prototypes/nav-shell/run.sh
```
