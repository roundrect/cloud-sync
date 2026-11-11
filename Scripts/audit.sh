#!/usr/bin/env bash
# audit.sh — cloud-sync's own app-neutrality audit. Three checks:
#   1. No denylisted (platform-UI / app-only) import anywhere under Sources/.
#   2. No app-brand literal (a bundle id, a product name) survives in the client
#      or the server — storage location and identity are the HOST's decision,
#      never this package's. This package is macOS-only (Security, CryptoKit), so
#      the template's Linux import-seam check does not apply.
#   3. server/src/core is portable: it imports nothing from cloudflare:* or node:*
#      and never names the Worker's Env or a Cloudflare binding type. The two
#      hosts (server/src/cloudflare, and server/src/celld, which wraps it) own those.
set -euo pipefail

PACKAGE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$PACKAGE/Package.swift"
DENYLIST="$PACKAGE/Scripts/import-denylist.txt"

fail() {
    printf 'x audit: %s\n' "$1" >&2
    exit 1
}

[[ -f "$MANIFEST" ]] || fail "missing Package.swift"
[[ -f "$DENYLIST" ]] || fail "missing import denylist"

ALTS=$(grep -v '^#' "$DENYLIST" | grep -v '^$' | paste -sd'|' -)
if [[ -n "$ALTS" ]]; then
    BAD=$(grep -rnE --include='*.swift' \
        "^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+(${ALTS})([[:space:]]|$|\.)" \
        "$PACKAGE/Sources" | head -20 || true)
    if [[ -n "$BAD" ]]; then
        printf 'x audit: denylisted import in %s:\n%s\n' "$(basename "$PACKAGE")" "$BAD" >&2
        exit 1
    fi
fi

# No consumer's bundle id or product name may be hardcoded here.
BRAND=$(grep -rnEi --include='*.swift' --include='*.ts' --include='*.jsonc' --include='Dockerfile' --include='*.sh' \
    'com\.roundrect|shorty|swurl' "$PACKAGE/Sources" "$PACKAGE/server/src" "$PACKAGE/server/test" "$PACKAGE/server/wrangler.jsonc" "$PACKAGE/server/celld.jsonc" "$PACKAGE/server/Dockerfile" "$PACKAGE/server/scripts" | head -10 || true)
if [[ -n "$BRAND" ]]; then
    printf 'x audit: app-brand literal survives in the package:\n%s\n' "$BRAND" >&2
    exit 1
fi

# The portable core stays portable.
CORE="$PACKAGE/server/src/core"
[[ -d "$CORE" ]] || fail "missing server/src/core"
LEAK=$(grep -rnE --include='*.ts' \
    "(from|import|require)[[:space:]]*\(?[[:space:]]*['\"](cloudflare|node):|\\b(Env|D1Database|D1PreparedStatement|DurableObject[A-Za-z]*|ExecutionContext|RateLimit|WebSocketPair)\\b" \
    "$CORE" | head -10 || true)
if [[ -n "$LEAK" ]]; then
    printf 'x audit: server/src/core reaches for a host (cloudflare:*, node:* or a Cloudflare type):\n%s\n' "$LEAK" >&2
    exit 1
fi

printf 'ok audit: %s is import-neutral, app-brand free and has a portable server core\n' "$(basename "$PACKAGE")"
