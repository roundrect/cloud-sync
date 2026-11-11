#!/bin/sh
# The container's entrypoint: writes /app/.dev.vars from the environment (celld dev reads secrets from there), then runs
# celld. TOKEN_PEPPER and INVITE_SECRET are required; the rest are optional and default as in celld.jsonc.
set -eu

APP_DIR="${APP_DIR:-/app}"

need() {
    eval "value=\${$1:-}"
    if [ -z "$value" ]; then
        echo "x $1 is required (set it with -e $1=...). Refusing to start." >&2
        exit 1
    fi
}
need TOKEN_PEPPER
need INVITE_SECRET

# One line per setting: a newline in a value would smuggle in another.
write() {
    eval "value=\${$1:-}"
    [ -n "$value" ] || return 0
    case "$value" in
        *'
'*) echo "x $1 must not contain a newline." >&2; exit 1 ;;
    esac
    printf '%s=%s\n' "$1" "$value"
}

umask 077
{
    write TOKEN_PEPPER
    write INVITE_SECRET
    write HISTORY_LIMIT
    write ENFORCE_ENTITLEMENT
    write MIN_CLIENT
} > "$APP_DIR/.dev.vars"

exec celld dev "$APP_DIR/celld.jsonc" --host 0.0.0.0 --port 8787 --no-watch
