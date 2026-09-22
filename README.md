# Zulu

A native Zulip client for iOS and macOS, plus the notification service that feeds it.

Zulu exists because the official clients make topics hard to live in. Here topics are
first-class: a channel that uses them renders as a list of threads, a channel that
doesn't renders as plain chat, and the app works out which is which. Channels group
into user-defined folders that sync across your devices.

Minimum iOS 27, built on Liquid Glass.

## Status

Pre-implementation. The way to the spec is being charted — see
[`.scratch/zulu-client/map.md`](.scratch/zulu-client/map.md) for the destination, the
decisions already locked, and what is still open.

## Layout

| Path | What |
| --- | --- |
| `.scratch/zulu-client/` | The wayfinder map, its decision tickets, and research notes |
| `prototypes/` | Throwaway prototypes that answer one design question each |

## Prototypes

Each prototype is disposable and self-contained. Run one with its own script:

```sh
prototypes/nav-shell/run.sh              # the iPhone navigation shell
prototypes/nav-shell/run.sh "iPhone Air" # pick a simulator
```

`nav-shell` holds the chosen drawer shell. The two rejected shells — a native tab bar
and a flat topic inbox — are on the `prototype/nav-shell-variants` branch.
