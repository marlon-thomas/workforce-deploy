#!/usr/bin/env bash
# test-inbox.sh — the TEST appliance's test inbox (owner, 8 November 2026): mailpit's web UI at
# https://testmail.<app host>, to read test sign-in codes and emails. Run on the box by deploy_to_test.py.
#
#   ./bin/test-inbox.sh on     turn it on: hostname, password (made here once) and its hash in .env, then the
#                              gateway and mailpit (re)started. Prints TEST_INBOX_NEW_PASSWORD=<password> only
#                              the first time, for deploy_to_test.py to show once; afterwards it's in .env only.
#
# Refuses anywhere but ENV_NAME=test. The route is in gateway/Caddyfile.localca only; mailpit has no read-only
# mode, so the page is mailpit's ordinary UI. Reachable only where the appliance is: the tailnet.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] || { echo "No .env here — run ./bin/install.sh first." >&2; exit 2; }
# shellcheck disable=SC1091
. ./.env
# shellcheck source=lib/common.sh
. ./bin/lib/common.sh
use_docker_socket

[ "${1:-}" = on ] || { echo "usage: $0 on" >&2; exit 2; }
if [ "${ENV_NAME:-prod}" != test ]; then
  echo "The test inbox is for the TEST appliance only (ENV_NAME=${ENV_NAME:-prod}). Nothing was changed." >&2
  exit 1
fi
case "${GATEWAY_CADDYFILE:-}" in
  *localca*) ;;
  *) echo "The test inbox needs the test CA's gateway (gateway/Caddyfile.localca). Nothing was changed." >&2; exit 1 ;;
esac

set_env() { # set_env KEY VALUE — replaces or adds one line; the value is written single-quoted (a hash has $)
  local tmp
  tmp="$(mktemp .env.XXXXXX)"
  grep -v "^$1=" .env > "$tmp" || true
  printf "%s='%s'\n" "$1" "$2" >> "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" .env
}

new=""
if [ -z "${TEST_INBOX_PASSWORD:-}" ]; then
  TEST_INBOX_PASSWORD="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  new=1
fi
if [ -n "$new" ] || [ -z "${TEST_INBOX_HASH:-}" ]; then
  # Hashed by the gateway's own caddy, the password on stdin (never on a command line).
  TEST_INBOX_HASH="$(printf '%s\n%s\n' "$TEST_INBOX_PASSWORD" "$TEST_INBOX_PASSWORD" \
    | docker compose run --rm --no-deps -T --entrypoint caddy gateway hash-password 2>/dev/null | tail -1)"
  case "$TEST_INBOX_HASH" in
    '$2'*) ;;
    *) echo "Couldn't hash the test inbox password with the gateway's caddy. Nothing was changed." >&2; exit 1 ;;
  esac
fi
set_env TEST_INBOX on
set_env TEST_INBOX_HOSTNAME "testmail.${APP_HOSTNAME}"
set_env TEST_INBOX_PASSWORD "$TEST_INBOX_PASSWORD"
set_env TEST_INBOX_HASH "$TEST_INBOX_HASH"
docker compose up -d mailpit gateway >/dev/null
echo "TEST_INBOX_URL=https://testmail.${APP_HOSTNAME}"
[ -z "$new" ] || echo "TEST_INBOX_NEW_PASSWORD=${TEST_INBOX_PASSWORD}"
