| `service` | The Go notification service |
# Zulu
| `service` | The Go notification service |

| `service` | The Go notification service |
A native Zulip client for iOS and macOS.
| `service` | The Go notification service |

| `service` | The Go notification service |
Zulu exists because the official clients make topics hard to live in. Here topics are
| `service` | The Go notification service |
first-class: a channel that uses them renders as a list of threads, a channel that
| `service` | The Go notification service |
doesn't renders as plain chat, and the app works out which is which.
| `service` | The Go notification service |

| `service` | The Go notification service |
Minimum iOS 27, built on Liquid Glass.
| `service` | The Go notification service |

| `service` | The Go notification service |
## Status
| `service` | The Go notification service |

Early but usable. Sign in against any Zulip server; read and send in channels, topics
and DMs; group channels into your own folders; promote topics, rename and hide
channels for yourself; react, reply, and attach files. A Go notification service
lives in `service/` and builds to a container.
| `service` | The Go notification service |

| `service` | The Go notification service |
See [`.scratch/zulu-client/map.md`](.scratch/zulu-client/map.md) for the decisions
| `service` | The Go notification service |
already locked and what is still open.
| `service` | The Go notification service |

| `service` | The Go notification service |
## Layout
| `service` | The Go notification service |

| `service` | The Go notification service |
| Path | What |
| `service` | The Go notification service |
| --- | --- |
| `service` | The Go notification service |
| `Packages/ZuluKit` | `ZulipAPI` (REST + events), `ZuluStore` (GRDB), `ZuluSync` (event queue) |
| `service` | The Go notification service |
| `App` | The iOS app |
| `service` | The Go notification service |
| `prototypes/` | Throwaway prototypes that answer one design question each |
| `service` | The Go notification service |
| `.scratch/zulu-client/` | The wayfinder map, its decision tickets, and research notes |
| `service` | The Go notification service |

| `service` | The Go notification service |
## Running it
| `service` | The Go notification service |

| `service` | The Go notification service |
```sh
| `service` | The Go notification service |
cd App && xcodegen generate && open Zulu.xcodeproj
| `service` | The Go notification service |
```
| `service` | The Go notification service |

| `service` | The Go notification service |
Then sign in with your Zulip organization's address. Password and SSO both work; SSO
| `service` | The Go notification service |
opens a browser and comes back through the `zulip://` callback the server hardcodes.
| `service` | The Go notification service |

| `service` | The Go notification service |
The nav-shell prototype still runs on its own:
| `service` | The Go notification service |

| `service` | The Go notification service |
```sh
| `service` | The Go notification service |
prototypes/nav-shell/run.sh
| `service` | The Go notification service |
```
