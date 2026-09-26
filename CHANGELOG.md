# Changelog

## [1.6.0](https://github.com/slop-place/zulu/compare/zulu-v1.5.2...zulu-v1.6.0) (2026-09-26)


### Features

* edit and delete messages, large emoji-only messages ([8e30790](https://github.com/slop-place/zulu/commit/8e3079023083a7fc0d88df27cf00f79b5ff64664))
* image viewer ([4b35d7d](https://github.com/slop-place/zulu/commit/4b35d7d2ea9554b3b84dcc8de467c469a314cf5d))

## [1.5.2](https://github.com/slop-place/zulu/compare/zulu-v1.5.1...zulu-v1.5.2) (2026-09-25)


### Bug Fixes

* scroll to bottom button showing ([c361473](https://github.com/slop-place/zulu/commit/c361473bfbeac6dcf28f999101de64765c47db3d))

## [1.5.1](https://github.com/slop-place/zulu/compare/zulu-v1.5.0...zulu-v1.5.1) (2026-09-25)


### Bug Fixes

* **compose:** only raise the keyboard when the compose bar is tapped ([435927f](https://github.com/slop-place/zulu/commit/435927f54c9c61c52dc63bb3a0204ce477cfb71b))
* **sidebar:** light a forum's row for its general chat only and always list unread topics ([0434f6d](https://github.com/slop-place/zulu/commit/0434f6d95b9ddef834a886959ad038f245a503bd))

## [1.5.0](https://github.com/slop-place/zulu/compare/zulu-v1.4.0...zulu-v1.5.0) (2026-09-25)


### Features

* **api:** send and receive typing notifications ([9b1ae6a](https://github.com/slop-place/zulu/commit/9b1ae6a912569303d611f3af119949ef5b51c126))
* **api:** tag sends with queue and local id and read it back on the echo ([cd5294c](https://github.com/slop-place/zulu/commit/cd5294c51eef339d65541f5c6e8795990ad6be0d))
* **app:** add typing indicators, optimistic send, notification level menus, open at first unread and new unread styling ([13bf024](https://github.com/slop-place/zulu/commit/13bf024718fec761a080b7a184fe8691b1b802c0))
* **compose:** add outbox ledger and per-conversation draft store ([d96d691](https://github.com/slop-place/zulu/commit/d96d691ce0222693e3e31ddac4b471ff03ca1766))
* **store:** store notification levels for topics, channels and groups ([bf04d8f](https://github.com/slop-place/zulu/commit/bf04d8f424516a0fbf68a5e9b44fdb782422571a))


### Bug Fixes

* **app:** steady chat scrolling, fixed typing line, sent-state outbox, image caching and saved drafts ([9ca14b7](https://github.com/slop-place/zulu/commit/9ca14b7b4ab4b3eb5b77f1dbe6dcea1204b2f8d3))
* **app:** stop crash when opening a tapped notification ([b1688fb](https://github.com/slop-place/zulu/commit/b1688fbf9b1e55a3d6ce6e6bae015dff30a34745))
* **app:** stop sync bursts from rebuilding the message list and looping mac layout ([f61ace0](https://github.com/slop-place/zulu/commit/f61ace01f2428c99ee1f53da1667fde49ae2ec6c))
* **mac:** allow pasting images into the composer ([bb17fe9](https://github.com/slop-place/zulu/commit/bb17fe91183a0448e30b032f74fa0aab3fda1a4b))
* **mac:** keep running in the background when the window is closed ([9b58c05](https://github.com/slop-place/zulu/commit/9b58c058fc56822f5e462f1db66cb1ba54d26bdb))
* **markup:** follow html whitespace rules so line breaks are not doubled ([b8fda7a](https://github.com/slop-place/zulu/commit/b8fda7a05d3c0f20497e8b5976f31d4d63e42741))
* **notifications:** let the channel level win over topics zulip followed on its own ([8e31b05](https://github.com/slop-place/zulu/commit/8e31b05f56263125e95a2d52ff3f1ee3370ce36a))
* **store:** count promoted topic unreads on the topic, not its channel ([fa9819f](https://github.com/slop-place/zulu/commit/fa9819f73a4df5b33522163ff62b70577386d15d))

## [1.4.0](https://github.com/slop-place/zulu/compare/zulu-v1.3.0...zulu-v1.4.0) (2026-09-24)


### Features

* **app:** add dark mode app icons ([0f9d79e](https://github.com/slop-place/zulu/commit/0f9d79e89e505e8b1a81b716c63bde5b7881717d))

## [1.3.0](https://github.com/slop-place/zulu/compare/zulu-v1.2.1...zulu-v1.3.0) (2026-09-24)


### Features

* **app:** reorder channel groups on the rail ([98381ac](https://github.com/slop-place/zulu/commit/98381ac68d6285018dc310b4855ab2ad7c84250d))

## [1.2.1](https://github.com/slop-place/zulu/compare/zulu-v1.2.0...zulu-v1.2.1) (2026-09-24)


### Bug Fixes

* **app:** stop swipe-to-reply from blocking conversation scrolling ([b5e0058](https://github.com/slop-place/zulu/commit/b5e00583262570c4ad0bf8754ccf3d00ede647dc))

## [1.2.0](https://github.com/slop-place/zulu/compare/zulu-v1.1.2...zulu-v1.2.0) (2026-09-24)


### Features

* **app:** configure notification service url with status and test page ([437fb07](https://github.com/slop-place/zulu/commit/437fb07543c8c55bd3eaf6acf7eaf9f10dd1659a))

## [1.1.2](https://github.com/slop-place/zulu/compare/zulu-v1.1.1...zulu-v1.1.2) (2026-09-24)


### Bug Fixes

* more adjustments ([506ba96](https://github.com/slop-place/zulu/commit/506ba96782e0793ece46665ffc3b41aa00abe69c))

## [1.1.1](https://github.com/slop-place/zulu/compare/zulu-v1.1.0...zulu-v1.1.1) (2026-09-23)


### Bug Fixes

* support every ipad orientation for app store upload ([e8d00f9](https://github.com/slop-place/zulu/commit/e8d00f92414a6ecf586e2ce56fe30c9164c1920a))

## [1.1.0](https://github.com/slop-place/zulu/compare/zulu-v1.0.0...zulu-v1.1.0) (2026-09-23)


### Features

* more stuff changed?? ([dbbe6ba](https://github.com/slop-place/zulu/commit/dbbe6bacd52d95388fdd64addf608e236623e9fa))
