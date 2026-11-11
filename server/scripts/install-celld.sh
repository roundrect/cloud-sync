#!/usr/bin/env bash
# Installs the pinned celld (Deno's self-hosted Workers runtime) to server/.celld-bin/celld.
#
# The version and the checksums live HERE and nowhere else; the Dockerfile runs this script too.
# Idempotent: does nothing when the installed binary already reports the pinned version.
#
#   scripts/install-celld.sh
#   CELLD_TARGET=x86_64-unknown-linux-gnu CELLD_DEST=/usr/local/bin scripts/install-celld.sh   # the Dockerfile's use
set -euo pipefail

VERSION=0.6.3

sha256_of() {
    case "$1" in
        aarch64-apple-darwin)      echo 2df6b08369345db8c1f9a5edcf3932cecaa6fb35f4658575a6db17df28c22371 ;;
        aarch64-unknown-linux-gnu) echo 6d617cdf9f049e43ca6a4e37c4cce5d8e35395c8e86b371c984d32ba7d803bf5 ;;
        x86_64-unknown-linux-gnu)  echo 5084a083472cf036551a7eac63fa24d22bb9a56323c517f63205724c12783047 ;;
        *) return 1 ;;
    esac
}

SERVER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${CELLD_DEST:-$SERVER/.celld-bin}"
BIN="$DEST/celld"

TARGET="${CELLD_TARGET:-}"
if [[ -z "$TARGET" ]]; then
    case "$(uname -s)/$(uname -m)" in
        Darwin/arm64)                TARGET=aarch64-apple-darwin ;;
        Linux/aarch64 | Linux/arm64) TARGET=aarch64-unknown-linux-gnu ;;
        Linux/x86_64)                TARGET=x86_64-unknown-linux-gnu ;;
        *) echo "x install-celld: no pinned celld for $(uname -s)/$(uname -m)" >&2; exit 1 ;;
    esac
fi
EXPECTED="$(sha256_of "$TARGET")" || { echo "x install-celld: no pinned celld for $TARGET" >&2; exit 1; }

if [[ -x "$BIN" ]] && "$BIN" --version 2>/dev/null | grep -qF "$VERSION"; then
    echo "ok celld $VERSION already installed at $BIN"
    exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
asset="celld-$TARGET.gz"
curl -fsSL --retry 3 -o "$work/$asset" "https://github.com/denoland/celld/releases/download/v$VERSION/$asset"

if command -v sha256sum >/dev/null; then ACTUAL="$(sha256sum "$work/$asset" | cut -d' ' -f1)"; else ACTUAL="$(shasum -a 256 "$work/$asset" | cut -d' ' -f1)"; fi
[[ "$ACTUAL" == "$EXPECTED" ]] || { echo "x install-celld: checksum mismatch for $asset (got $ACTUAL)" >&2; exit 1; }

mkdir -p "$DEST"
gunzip -c "$work/$asset" > "$work/celld"
chmod +x "$work/celld"
mv "$work/celld" "$BIN"
echo "ok celld $VERSION installed at $BIN"
