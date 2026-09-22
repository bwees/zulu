# Zulu

A native Zulip client for iOS and macOS.

Zulu exists because the official clients make topics hard to live in. Here topics are
first-class: a channel that uses them renders as a list of threads, a channel that
doesn't renders as plain chat, and the app works out which is which.

Minimum iOS 27, built on Liquid Glass.

## Status

Early. Sign in against any Zulip server, read channels, topics and DMs, and send
messages. A notification service is planned but not started.

See [`.scratch/zulu-client/map.md`](.scratch/zulu-client/map.md) for the decisions
already locked and what is still open.

## Layout

| Path | What |
| --- | --- |
| `Packages/ZuluKit` | `ZulipAPI` (REST + events), `ZuluStore` (GRDB), `ZuluSync` (event queue) |
| `App` | The iOS app |
| `prototypes/` | Throwaway prototypes that answer one design question each |
| `.scratch/zulu-client/` | The wayfinder map, its decision tickets, and research notes |

## Running it

```sh
cd App && xcodegen generate && open Zulu.xcodeproj
```

Then sign in with your Zulip organization's address. Password and SSO both work; SSO
opens a browser and comes back through the `zulip://` callback the server hardcodes.

The nav-shell prototype still runs on its own:

```sh
prototypes/nav-shell/run.sh
```
