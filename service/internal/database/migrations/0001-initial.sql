CREATE TABLE users (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    realm_url       TEXT    NOT NULL,
    zulip_user_id   INTEGER NOT NULL,
    email           TEXT    NOT NULL,
    api_key_box     BLOB    NOT NULL,
    status          TEXT    NOT NULL DEFAULT 'active',
    status_detail   TEXT    NOT NULL DEFAULT '',
    created_at      TEXT    NOT NULL DEFAULT (datetime('now')),
    updated_at      TEXT    NOT NULL DEFAULT (datetime('now')),
    UNIQUE (realm_url, zulip_user_id)
);

CREATE TABLE devices (
    id            TEXT    PRIMARY KEY,
    user_id       INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token         TEXT    NOT NULL,
    environment   TEXT    NOT NULL,
    platform      TEXT    NOT NULL,
    app_version   TEXT    NOT NULL DEFAULT '',
    secret_hash   BLOB    NOT NULL,
    registered_at TEXT    NOT NULL DEFAULT (datetime('now')),
    last_seen_at  TEXT    NOT NULL DEFAULT (datetime('now')),
    UNIQUE (token, environment)
);

CREATE INDEX devices_by_user ON devices (user_id);
CREATE UNIQUE INDEX devices_by_secret ON devices (secret_hash);

-- One row per user: the event queue this service holds on their behalf, plus the
-- mirrored notification settings that queue's snapshot produced. They are written
-- together because a cursor is only meaningful with the state built from the same
-- register call.
CREATE TABLE queue_state (
    user_id       INTEGER PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    queue_id      TEXT    NOT NULL,
    last_event_id INTEGER NOT NULL,
    state         TEXT    NOT NULL,
    updated_at    TEXT    NOT NULL DEFAULT (datetime('now'))
);

-- The delivery log is what makes redelivery harmless: Zulip's event stream is
-- at-least-once, so the same message can arrive twice after a dropped
-- acknowledgement.
CREATE TABLE deliveries (
    user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    device_id  TEXT    NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    message_id INTEGER NOT NULL,
    trigger    TEXT    NOT NULL,
    status     TEXT    NOT NULL,
    detail     TEXT    NOT NULL DEFAULT '',
    created_at TEXT    NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (user_id, device_id, message_id)
);
