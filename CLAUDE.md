# CLAUDE.md

Guidance for Claude Code when working in this repo.

**Process lives one level up.** `/feature`, `/plan`, `/ship`, `/fleet`, the `changes/` ledger,
`ROADMAP.md`, `BACKLOG.md`, and `CHANGELOG.md` are workspace-level and run from `roundrect-app-factory`,
not from here. This file holds only the code rules specific to `cloud-sync`.

## This is a sovereign library — release discipline is different from an app

`cloud-sync` ships by **semver tag**, not by app version bumps. `swift build && swift test` at the
root is the whole story for a consumer; this Makefile only adds the audit and the server's targets.

- **A library never depends on an app**, and never depends the other direction on anything under
  `repo/app/*`. The only dependencies this package may declare are other sovereign libraries under
  `repo/lib/*`, by the same `lib()` local/pin resolution an app uses.
- **A library never claims a fleet instance token.** A worktree of this library
  (`.claude/worktrees/slot-<token>/cloud-sync`) reuses the SAME token an app slot already claimed —
  it exists only so that app's build can override to it, never to run this package standalone
  under a fleet instance.
- **This package's own directory basename and the last path component of its remote URL must both
  be `cloud-sync`.** SwiftPM derives package identity from them; get it wrong and every
  `.product(name: …, package: "cloud-sync")` reference in every consumer breaks. Never expose this
  package at two paths (a compatibility symlink produces a duplicate-module clang segfault).
- **A library's slot worktree is one level deeper than an app's**: it ends in the library's own
  name — `.claude/worktrees/slot-<token>/cloud-sync`, not `.../slot-<token>`. The ancestor-walk depth
  used to find the workspace root is **3/7** here (3 from a primary checkout, 7 from a slot
  worktree), vs an app's 3/6, precisely because of that extra path component.

## What this is

`CloudSync` is the client; `server/` is what it talks to: one Worker (a portable core plus a Cloudflare host),
run on Cloudflare or self-hosted under celld. They live together because they
version together: a change to the wire protocol changes both. **`SyncClient` never learns what a document
means.** Anything about one app's document (parsing, merging, validating, applying, wording) belongs behind
`SyncHost`. A host may make the document the file's raw text, so nothing here may assume it can be rebuilt.

**No compatibility is promised before the first tag.** Neither the server nor the client keeps support for an
older wire format, route or schema, and nothing here migrates anything: a change that breaks linked Macs means they
re-link. Keep `sync.json`'s keys (`linkedConfigPath` included) and the `shk1_` token format as they are unless
there is a reason to change them, since changing either unlinks people.

No dependencies. The package is macOS-only (Security, CryptoKit), so the template's Linux job and targets
were removed. `import Foundation` plus those two only.

## Neutrality is checked, not asserted

`Scripts/audit.sh` runs on every `make audit` and in CI. Extend its denylist rather than relaxing
it when a new import is genuinely needed — the checks it runs exist because each one caught a real
regression upstream:

- No denylisted (platform-UI / app-only, e.g. SwiftUI/AppKit/host-framework) import anywhere under
  `Sources/` — this package is meant to be usable from an app or a CLI alike.
- No app-brand literal (a bundle id, a product name) survives in this package. Storage location,
  brand strings, and product identity are the HOST's decision, declared once and bootstrapped in —
  never hardcoded here.

## Verifying changes

```bash
make build         # swift build
make test          # swift test: temp folders and a fake server, never the Keychain or the network
make audit         # Scripts/audit.sh — neutrality + de-branding, client and server
make server-install # npm ci + the pinned celld (server/.celld-bin/celld)
make server-test   # the contract tests against the Worker (Miniflare) and against celld, plus each one's own (never the network)
make server-check  # tsc for the Workers half and the Node half (the celld test code) + generated-types freshness
make server-local  # the Worker under celld on http://127.0.0.1:8787 (self-hosting, by hand); `make server-docker` builds the image
```

## Contributing

Features arrive here by **graduation** from a private playground repo — see `docs/GRADUATION.md`
in the workspace. Issues and fixes are welcome directly; see `CONTRIBUTING.md`.
