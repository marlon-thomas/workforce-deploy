#!/usr/bin/env bash
# Self-test for bin/lib/prod-guards.sh: the test inbox and mailpit can't reach production (Workforce, owner
# 8 November 2026). Hermetic: temp files only.
#   ./bin/tests/prod-guards-test.sh      exit 0 = all pass
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/prod-guards.sh
. "$HERE/../lib/prod-guards.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

PASS=0; FAILN=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAILN=$((FAILN+1)); printf 'FAIL: %s: expected [%s] got [%s]\n' "$1" "$3" "$2"; fi; }
rc() { "$@" >/dev/null 2>&1; echo $?; }

env_with() { printf '%s\n' "ENV_NAME=prod" "$@" > "$WORK/prod.env"; rc prod_guard_env_file "$WORK/prod.env"; }
check "a clean prod.env passes" "$(env_with 'SMTP_HOST=smtp.example.org' 'COMPOSE_PROFILES=staffmail')" 0
check "TEST_INBOX in prod.env" "$(env_with 'TEST_INBOX=on')" 1
check "TEST_INBOX_HOSTNAME in prod.env" "$(env_with 'TEST_INBOX_HOSTNAME=testmail.example.org')" 1
check "the mail profile in prod.env" "$(env_with 'COMPOSE_PROFILES=staffmail,mail')" 1
check "mailpit as SMTP_HOST" "$(env_with 'SMTP_HOST=mailpit')" 1
check "mailpit as SIGNIN_SMTP_HOST" "$(env_with 'SIGNIN_SMTP_HOST=mailpit:1025')" 1
check "SERVER_ACTIONS_PLAIN_RELAY in prod.env" "$(env_with 'SERVER_ACTIONS_PLAIN_RELAY=relay.example.org:25')" 1
check "a comment saying never is fine" "$(env_with '# NEVER set TEST_INBOX here')" 0
check "an empty SERVER_ACTIONS_PLAIN_RELAY is fine" "$(env_with 'SERVER_ACTIONS_PLAIN_RELAY=')" 0

printf 'example.org {\n\treverse_proxy api:8080\n}\n' > "$WORK/Caddyfile"
check "a clean production Caddyfile" "$(rc prod_guard_caddyfile "$WORK/Caddyfile")" 0
printf 'testmail.example.org {\n\treverse_proxy mailpit:8025\n}\n' >> "$WORK/Caddyfile"
check "a production Caddyfile with the inbox" "$(rc prod_guard_caddyfile "$WORK/Caddyfile")" 1

check "runtime: the test appliance may" "$(rc prod_guard_runtime test on testmail.x mail yes)" 0
check "runtime: prod, nothing test-only" "$(rc prod_guard_runtime prod '' '' staffmail no)" 0
check "runtime: prod with TEST_INBOX" "$(rc prod_guard_runtime prod on '' '' no)" 1
check "runtime: prod with the inbox host" "$(rc prod_guard_runtime prod '' testmail.x '' no)" 1
check "runtime: prod with the mail profile" "$(rc prod_guard_runtime prod '' '' staffmail,mail no)" 1
check "runtime: prod with mailpit running" "$(rc prod_guard_runtime prod '' '' '' yes)" 1
check "runtime: no ENV_NAME counts as prod" "$(rc prod_guard_runtime '' on '' '' no)" 1

check "start: test with the inbox" "$(rc prod_guard_start test on)" 0
check "start: prod with the inbox refuses" "$(rc prod_guard_start prod on)" 1
check "start: prod without it" "$(rc prod_guard_start prod '')" 0

# The real files in this repo.
REPO="$HERE/../.."
for f in "$REPO"/environments/*.env; do
  [ "$(basename "$f")" = test.env ] && continue
  check "$(basename "$f") has nothing test-only" "$(rc prod_guard_env_file "$f")" 0
done
for f in "$REPO"/gateway/Caddyfile "$REPO"/gateway/Caddyfile.duckdns; do
  check "$(basename "$f") has no test inbox" "$(rc prod_guard_caddyfile "$f")" 0
done
check "the test CA's Caddyfile has the inbox" "$(grep -c 'TEST_INBOX_HOSTNAME' "$REPO/gateway/Caddyfile.localca")" 1

echo "prod-guards self-test: ${PASS} passed, ${FAILN} failed"
[ "$FAILN" -eq 0 ]
