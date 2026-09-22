# Zulu

A native Zulip client for iOS and macOS, plus the notification service that feeds it.

Zulu exists because the official clients make topics hard to live in. Here topics are
first-class: a channel that uses them renders as a list of threads, a channel that
doesn't renders as plain chat, and the app works out which is which. Channels group
into user-defined folders that sync across your devices.

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
prototypes/nav-shell/run.sh            # three iPhone navigation shells, A/B/C
prototypes/nav-shell/run.sh "iPhone 17"  # pick a simulator
```

Flip between variants with the yellow bar, or jump straight to one:

```sh
SIMCTL_CHILD_VARIANT=C xcrun simctl launch "iPhone 16 Pro" com.zulu.navshell
```
