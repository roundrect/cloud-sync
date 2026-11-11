-- Global lookups that must work before a request is routed to an account's Durable Object (030, D2).
-- All timestamps are ISO-8601 UTC strings from Date.toISOString(), so they compare correctly as text.

CREATE TABLE accounts (
  id            TEXT PRIMARY KEY,
  created_at    TEXT NOT NULL,
  entitled_until TEXT              -- unused until billing (030.B3); see src/entitlement.ts
);

CREATE TABLE devices (
  id           TEXT PRIMARY KEY,
  account_id   TEXT NOT NULL REFERENCES accounts(id),
  name         TEXT NOT NULL,
  token_hash   TEXT NOT NULL,      -- hex SHA-256(pepper || secret); the secret itself is never stored
  created_at   TEXT NOT NULL,
  last_seen_at TEXT,
  revoked_at   TEXT,
  namespace    TEXT NOT NULL       -- one app's slice of the account (036.03)
);
CREATE INDEX devices_account ON devices(account_id);
CREATE INDEX devices_account_namespace ON devices(account_id, namespace);

-- A pairing is created by the new Mac, bound to an account by an already-linked Mac, and consumed
-- (deleted) by the new Mac's poll, which is when its device and token are minted.
CREATE TABLE pairings (
  id               TEXT PRIMARY KEY,
  code_hash        TEXT NOT NULL UNIQUE,
  poll_secret_hash TEXT NOT NULL,
  device_name      TEXT NOT NULL,
  account_id       TEXT REFERENCES accounts(id),   -- NULL until approved
  approved_by      TEXT REFERENCES devices(id),
  created_at       TEXT NOT NULL,
  expires_at       TEXT NOT NULL,
  namespace        TEXT NOT NULL    -- the namespace of the route that started it
);
CREATE INDEX pairings_expires ON pairings(expires_at);

-- Bad pairing codes entered by an approving device, for the 5-per-10-minutes limit.
CREATE TABLE approve_failures (
  device_id TEXT NOT NULL,
  at        TEXT NOT NULL
);
CREATE INDEX approve_failures_device ON approve_failures(device_id, at);
