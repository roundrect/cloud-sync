# Sync service

Stores one synced document per app and account (an app's text in a small JSON envelope) with a linear
revision history, and broadcasts every write over WebSockets. The server treats `body` as opaque and never
parses it.

**One Worker, two places to run it.** The API lives in `src/core`, which imports nothing from Cloudflare. The
Worker (`src/cloudflare`: a SQLite-backed Durable Object per document, plus D1) runs on Cloudflare, or self-hosted
under [celld](https://github.com/denoland/celld), Deno's runtime for Cloudflare Workers and Durable Objects
(`src/celld` wraps the Worker with the one thing celld lacks, applying the D1 migrations). The same contract tests run
against both.

**One shared deployment, many apps.** An app is a *namespace*, not a deployment. All apps share one set of
accounts and one database; each app's devices, document, history and sockets are its own, and
`MIN_CLIENT` is a minimum per namespace.

```
src/core/         app.ts        route table, dispatch, handlers: createApp(platform) -> (Request) => Response
                  ports.ts      Platform, Sql, RevisionStore, DocHandle, Config: what a host provides
                  doc-log.ts    If-Match, kinds, revert, retention, history paging
                  namespace.ts  slug check, document naming     config.ts   parses and validates the settings
                  auth devices entitlement errors pairing router util
src/cloudflare/   index.ts      the Worker entry (exports only `default` and `AccountDoc`)
                  account-doc.ts  the AccountDoc Durable Object      d1.ts  D1 as the Sql port
src/celld/        index.ts      the self-host entry: the Worker, after applying pending D1 migrations (once per isolate)
                  migrate.ts    the explicit migration list, the d1_migrations ledger, atomic apply
migrations/       0001_init.sql: both hosts apply these same files
wrangler.jsonc    the Cloudflare deployment     celld.jsonc  the same Worker as celld runs it (celld rejects wrangler.jsonc's extra keys)
scripts/          install-celld.sh: the pinned celld, checksum-verified (the one place its version lives)
Dockerfile        celld in a container          docker-entrypoint.sh  writes .dev.vars from the environment, then runs celld
```

## Namespaces

Every route is `/v1/ns/<namespace>/<route>`; anything else is `404 not_found`, except `GET /v1/meta`, an
unauthenticated probe that answers just `{"api":1}`. A namespace is a slug, `^[a-z][a-z0-9-]{0,31}$`.

- A device belongs to one namespace, the one it was created or paired in. Its token works only on that
  namespace's routes: anything else is `403 namespace_mismatch`, checked before the billing check and before any
  document is touched.
- A document is named `<account>:<namespace>`. A second app on the same account therefore has its own document,
  history and sockets.
- `GET /v1/ns/<namespace>/devices` lists the whole account, each device with its `namespace`, so a Mac that has linked two apps
  shows twice. Renaming or revoking a device works only inside the caller's namespace (404 otherwise).
- **Pairing across namespaces.** A device may approve a pairing for its own namespace, or for a namespace in which
  the account has no device at all (revoked ones count). That is how an account's first Mac in a new app gets
  linked. Approving into a namespace that already has a device is `403 namespace_mismatch`, answered before the
  preview, so the new device's name is not disclosed. The preview shows the `namespace` that is joining.

## Settings

| Variable | Meaning |
|---|---|
| `TOKEN_PEPPER` | secret; mixed into every token hash. Changing it signs every device out. The Docker image will not start without it |
| `INVITE_SECRET` | secret; the bootstrap passphrase for `POST /accounts`. Empty means nobody can create an account |
| `MIN_CLIENT` | JSON, `{"<namespace>":"<version>"}`, default `{}`. A namespace with no entry has no minimum. A malformed value fails closed: the Worker answers 500 |
| `HISTORY_LIMIT` | revisions kept per document (default `1000`) |
| `ENFORCE_ENTITLEMENT` | `"0"`. Set `"1"` only when billing exists; accounts then need `accounts.entitled_until` in the future (a missing value is refused with `402`) |

Tokens start `shk1_`. It is a fixed part of the format, not a brand: changing it would sign out every device
already linked.

## Develop and test (local only, never the network)

```sh
make server-install     # npm ci, then the pinned celld into server/.celld-bin/ (scripts/install-celld.sh)
make server-check       # tsc (Workers half, Node half) + generated-types freshness
make server-test        # vitest: two projects, `workers` and `celld`
cp server/.dev.vars.example server/.dev.vars    # once; gitignored
make server-dev         # the Worker under wrangler on http://localhost:8787, local D1 + Durable Objects in server/.wrangler/state
make server-local       # the Worker under celld on http://127.0.0.1:8787, state in server/.celld/dev
```

`make server-install` uses `npm ci` from the lockfile. If you ever have to change dependencies and npm 10 fails
with `Cannot read properties of null (reading 'edgesOut')`, run the install with npm 11
(`npx npm@11 install ...`) and commit the updated `package-lock.json`. (npm 10 also drops the `libc` fields from
the lockfile, which breaks Linux installs, so use npm 11 for any change.)

**Tests.** `test/contract/` holds the behaviour of the API. It runs in both vitest projects through one harness
interface (`test/harness/types.ts`); the `@harness` alias picks `workers.ts` (the real Worker entry, D1 and Durable
Objects in Miniflare) or `celld.ts` (a real `celld dev` process per test file, over HTTP and real sockets). The celld
project runs `test/celld/entry.ts`, which is `src/celld/index.ts` plus test-only hooks (`/__test/sql`,
`/__test/revisions`, an `x-test-vars` header that overrides settings for one request); it is never shipped. Direct
database pokes go through `harness.sql`. A test that can only mean one host lives outside `contract/`:
`test/workers/` (the entry's exports) or `test/celld/` (migrations apply once and are recorded; a restart keeps the
data). The Workers project uses `@cloudflare/vitest-plugin` and applies the D1 migrations in
`test/workers/apply-migrations.ts`. The celld project needs the binary from `make server-install`.

**Types.** Workers types and Node types conflict, so there are two tsconfigs: `tsconfig.json` (Workers half: the
Worker, `src/celld`, `test/celld/entry.ts`) and `tsconfig.node.json` (Node half: the test code that spawns celld).
`src/core` and `test/contract` are in both, which is how core stays free of either. After editing `wrangler.jsonc`, run
`npm run types` and commit `worker-configuration.d.ts` (`make server-check` fails if it is stale). `make audit` also
fails if `src/core` imports `cloudflare:*` or `node:*`, or names a Cloudflare type.

**A new migration** is a new file in `migrations/` AND a line in the list in `src/celld/migrate.ts`
(`test/celld/celld.test.ts` fails if the two disagree).

## Deploy to Cloudflare (the owner's step; nothing in the repo does this for you)

You need a Cloudflare account. Workers, Durable Objects (SQLite-backed) and D1 all work on the free plan for a
handful of Macs; check the dashboard's usage after the first day. There is one deployment for every app.

The Workers are `cloud-sync` and `cloud-sync-dev`, named in `wrangler.jsonc`. Your database ids go in
`wrangler.local.jsonc`, a copy that git and Docker ignore, so `wrangler.jsonc` stays the neutral file every
deployment starts from. Ids are not secret, but they are yours.

```sh
cd server

# 1. Log in (opens a browser).
npx wrangler login

# 2. Make your local config. To use other names, change "name" and the two database names here too.
cp wrangler.jsonc wrangler.local.jsonc

# 3. Create the two databases, then paste each printed database_id into wrangler.local.jsonc.
npx wrangler d1 create cloud-sync-dev
npx wrangler d1 create cloud-sync

# 4. Apply the schema to the remote databases.
npx wrangler d1 migrations apply cloud-sync-dev --remote --env dev --config wrangler.local.jsonc
npx wrangler d1 migrations apply cloud-sync --remote --config wrangler.local.jsonc

# 5. Deploy, so the Workers exist, then set the two secrets for BOTH environments. Use long random
#    values (openssl rand -base64 32). They are prompted for, never written to a file.
npx wrangler deploy --env dev --config wrangler.local.jsonc
npx wrangler deploy --config wrangler.local.jsonc
npx wrangler secret put TOKEN_PEPPER --env dev --config wrangler.local.jsonc
npx wrangler secret put INVITE_SECRET --env dev --config wrangler.local.jsonc
npx wrangler secret put TOKEN_PEPPER --config wrangler.local.jsonc
npx wrangler secret put INVITE_SECRET --config wrangler.local.jsonc

# 6. Verify. The deploy prints the URL: https://cloud-sync-dev.<subdomain>.workers.dev
curl -s https://cloud-sync-dev.<subdomain>.workers.dev/v1/meta
#    -> {"api":1}
```

If `wrangler.jsonc` changes later, make the same change in `wrangler.local.jsonc`: wrangler reads only the file it's given.

In the dashboard, Workers & Pages -> the Worker -> Settings -> Bindings should list `ACCOUNT_DOC` as a
SQLite-backed Durable Object, and Logs should show your requests. No secret appears in `wrangler.jsonc`.

Notes:
- The Durable Object class is still called `AccountDoc`, with binding `ACCOUNT_DOC` and migration tag `v1`, though
  it now holds one document rather than one account. A live deployment's data depends on those names; do not rename them.
- A client sending `Sync-Client: <older>` to a namespace with a `MIN_CLIENT` entry gets `426`; a request with no
  such header (curl) is allowed.
- `format` is checked only for shape (`^[a-z0-9][a-z0-9.+-]{0,63}$`, else `422 unsupported_format`). What a format
  means is between the apps that write and read it; the server never opens `body`.
- The optional `PAIR_LIMITER` rate-limit binding guards `pair/start` and `pair/poll` per IP. If you remove it from
  `wrangler.jsonc` the Worker simply skips that limit (under celld it is always absent). The limit on wrong approval codes (5 per device per
  10 minutes) is stored in the database and always on.

## Self-host with celld

The same Worker, with no Cloudflare account, run by [celld](https://github.com/denoland/celld) (Deno's self-hosted
runtime for Workers and Durable Objects, pinned to v0.6.3 in `scripts/install-celld.sh`). `celld.jsonc` is the config.
Three things differ from Cloudflare:

- **No pairing rate limit.** celld has no `ratelimits` binding and no `cf-connecting-ip`, so the per-IP limit on
  `pair/start` and `pair/poll` is off. The limit on wrong approval codes (5 per device per 10 minutes) is stored in the
  database and stays on. Put rate limiting in your reverse proxy if the server is public.
- **Migrations run at the first request** (in `src/celld`), because `celld dev` has no migration command. They are
  recorded in `d1_migrations`, the table wrangler uses, and applied atomically.
- **`TOKEN_PEPPER` and `INVITE_SECRET` come from `.dev.vars`** beside `celld.jsonc`, which `celld dev` reads.

### Locally: `celld dev`

One node, one persistent local SQLite store in `server/.celld/dev`.

```sh
make server-install
cp server/.dev.vars.example server/.dev.vars     # then put long random values in it (openssl rand -base64 32)
make server-local                                # http://127.0.0.1:8787
curl -s http://127.0.0.1:8787/v1/meta            # -> {"api":1}
```

Deleting `server/.celld/dev` starts empty. Keep the pepper: it is part of every stored token hash, so a different one
signs every device out.

### In Docker: `celld dev` in a container

The same single node. State is celld's local store in the `/app/.celld` volume.

```sh
docker build -t cloud-sync-server server/

docker run -d --name sync --restart unless-stopped \
  -p 127.0.0.1:8787:8787 \
  -v sync-data:/app/.celld \
  -e TOKEN_PEPPER="$(openssl rand -base64 32)" \
  -e INVITE_SECRET="$(openssl rand -base64 24)" \
  cloud-sync-server

curl -s http://127.0.0.1:8787/v1/meta
```

Put the two secrets in an env file (`--env-file`) rather than your shell history, and keep them.

| Variable | Default | Meaning |
|---|---|---|
| `TOKEN_PEPPER` | none | **required**; the container refuses to start without it |
| `INVITE_SECRET` | none | **required**; needed to create the first account |
| `MIN_CLIENT`, `HISTORY_LIMIT`, `ENFORCE_ENTITLEMENT` | as in Settings | optional |

The entrypoint writes these to `/app/.dev.vars` and runs `celld dev /app/celld.jsonc --host 0.0.0.0 --port 8787`.
Upgrading is: build the new image, stop the old container, start the new one on the same volume. Back up by stopping
the container and copying the volume.

**HTTPS is required.** The server speaks plain HTTP, and the client refuses a plain-HTTP server except on
localhost, because tokens travel in every request. Put a TLS proxy in front of it:

- **Caddy** (public name): `sync.example.com { reverse_proxy 127.0.0.1:8787 }`.
- **Tailscale Serve** (private to your tailnet): `tailscale serve --bg 8787`, then use the `https://<machine>.<tailnet>.ts.net` address.
- **Cloudflare Tunnel**: `cloudflared tunnel --url http://127.0.0.1:8787` to try it, or a named tunnel for good.

### A celld fleet (NOT tested by us)

`celld dev` is one node on local storage. Several nodes share state through a bucket: `celld deploy` needs an
S3-compatible, GCS or Azure bucket that celld qualifies (R2, S3 and Tigris do; MinIO is listed as "passes but not
qualified for production"). We have not run this path; read celld's own documentation before relying on it.

```sh
export CELLD_BUCKET=s3://YOUR-BUCKET            # plus the endpoint, region and credentials celld documents
mkdir deploy && cp -R src migrations deploy/ && cp celld.jsonc deploy/wrangler.jsonc   # deploy reads wrangler.jsonc
# in deploy/wrangler.jsonc: add "migrations_dir": "migrations" to the D1 entry, and the secrets to "vars" (below)
celld deploy deploy --bucket "$CELLD_BUCKET"
celld d1 migrations apply DB --bucket "$CELLD_BUCKET"      # optional: the entry also applies them itself
```

`celld deploy` does not read `.dev.vars`, so in fleet mode `TOKEN_PEPPER` and `INVITE_SECRET` must go in the deployed
config's `vars`: they are then in that config file and in the bucket, so keep the config out of git and the bucket
private. HTTPS and rate limiting are again a proxy's job.

## Bootstrap the first account with curl

`example` is the app's namespace.

```sh
URL=https://sync-dev.<subdomain>.workers.dev      # or http://127.0.0.1:8787
NS=$URL/v1/ns/example

# Create the account and its first device. The token is shown ONCE; keep it.
curl -s -X POST $NS/accounts -d '{"invite":"<INVITE_SECRET>","deviceName":"My Mac"}'
# -> {"accountId":"acc_...","device":{"id":"dev_...","name":"My Mac"},"token":"shk1_dev_..._..."}

TOKEN=shk1_dev_...
curl -s -H "Authorization: Bearer $TOKEN" $NS/doc                  # -> {"rev":0}   (empty document)

BODY=$'version: 1\n'
SHA=$(printf '%s' "$BODY" | shasum -a 256 | cut -d' ' -f1)
curl -s -X PUT -H "Authorization: Bearer $TOKEN" -H 'If-Match: 0' $NS/doc \
  -d "{\"format\":\"example-text\",\"schema\":1,\"body\":\"version: 1\\n\",\"sha256\":\"$SHA\",\"summary\":\"first upload\"}"
# -> {"rev":1}      a second PUT with If-Match: 0 now answers 409 with the current document
curl -s -H "Authorization: Bearer $TOKEN" $NS/history
```

Further Macs join with the pairing flow (`POST pair/start` on the new Mac, `POST pair/approve` on a linked one,
`POST pair/poll` to collect the token), which `SyncClient.link` and `SyncClient.approve` drive.

## API summary (v1)

JSON in and out, camelCase keys, dates as ISO-8601 strings with milliseconds. Errors are
`{"error": "<code>", "message": "<text>"}`. Authenticated routes need `Authorization: Bearer shk1_...`.
Clients should send `Sync-Client: <version>`. Each route below is at
`/v1/ns/{namespace}/<route>`, except the probe `GET /v1/meta`.

| Route | Notes |
|---|---|
| `GET meta` | `{api: 1, minClient}` for that namespace (`0.0.0` if it has no minimum); no auth. `GET /v1/meta`, with no namespace, answers just `{api: 1}` |
| `POST accounts` | `{invite, deviceName}` -> 201 `{accountId, device: {id, name}, token}`, the device in this namespace; 401 `invalid_invite` |
| `POST pair/start` | `{deviceName}` -> 201 `{pairingId, code: "K7QF-M2XD", pollSecret, expiresIn: 600}`; the pairing belongs to this namespace |
| `POST pair/poll` | `{pairingId, pollSecret}` -> `{status: "pending"}` / `{status: "expired"}` / `{status: "approved", accountId, device, token}` (once; later polls say `expired`). A poll naming a different namespace from the pairing's reads `expired`. The device is minted into the pairing's namespace |
| `POST pair/approve` | `{code}` -> `{deviceName, namespace}` (preview); `{code, confirm: true}` -> `{approved: true, deviceName}`; 404 `invalid_code`; 403 `namespace_mismatch` (see Namespaces); 429 after 5 wrong codes |
| `GET doc` | `{rev, format, schema, body, sha256, summary, updatedAt, deviceId, deviceName}`, or `{rev: 0}`; `ETag: "<rev>"` |
| `PUT doc` | body = `{format, schema, body, sha256, summary}`; `If-Match: <rev>` required (428); 200 `{rev}`; 409 = the current document (+ `error`, `message`); 413 over 512 KB; 422 `unsupported_format` (malformed `format`) / `checksum_mismatch` |
| `GET history?before=&limit=` | `{revisions: [{rev, createdAt, deviceId, deviceName, kind, revertedTo?, summary}], nextBefore}`, newest first; `limit` 1-200 (default 50); `nextBefore` is the `before` for the next page, or `null` |
| `GET history/{rev}` | the revision with its body and `kind` / `revertedTo?`; 404 if missing or pruned |
| `POST revert` | `{rev, ifMatch, summary?}` -> 200 `{rev}` (a new revision, `kind: "revert"`); 409 if `ifMatch` is stale; 404 if `rev` is gone |
| `GET devices` | `{devices: [{id, name, namespace, createdAt, lastSeenAt, current}]}`: active devices of the whole account |
| `PATCH devices/{id}` | `{name}` -> the device; 404 unless it is in the caller's namespace |
| `DELETE devices/{id}` | revoke (also the caller itself = unlink) -> `{revoked: true, id}`; closes its sockets; 404 unless it is in the caller's namespace |
| `GET ws` | WebSocket upgrade with the `Authorization` header |

Every authenticated route answers `403 namespace_mismatch` when the token's namespace is not the route's, and a
slug that doesn't match the pattern is `400 bad_namespace`. `kind` is `bootstrap` for revision 1, `put` for later
writes, `revert` for a revert.

**WebSocket.** On connect the server sends `{"type":"hello","rev":N}`. Every write (PUT or revert) is then
broadcast to every socket on that namespace's document as
`{"type":"doc","rev","format","schema","body","sha256","deviceId","deviceName","summary","kind","updatedAt","revertedTo?"}`;
clients ignore their own `deviceId` and anything with `rev <= lastRev`. Sending the text `{"type":"ping"}`
is answered with `{"type":"pong"}` (on Cloudflare without waking the object; protocol-level pings are free too; celld answers it the same way).
Revoking a device closes its sockets with code `4401`. Clients send nothing else; writes go over HTTPS.
