#!/usr/bin/env bash
# Self-test for bin/lib/env-file.sh (Workforce issue 462 review, finding 2): a .env the scripts can't read with
# `. ./.env` is named before they try, with the line and the setting and never the value; one they can is left
# alone. And update.sh, doctor.sh and backup.sh ask before they read it. Hermetic: bash only.
#   ./bin/tests/env-file-test.sh      exit 0 = all pass
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS=0; FAILN=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAILN=$((FAILN+1)); printf 'FAIL: %s: expected [%s] got [%s]\n' "$1" "$3" "$2"; fi; }
# shellcheck source=../lib/env-file.sh
. "$HERE/../lib/env-file.sh"
cd "$WORK" || exit 1

problem() { printf '%s\n' "$1" > .env; env_file_problem .env; }
# What the RUNBOOK used to show: Compose reads it, `. ./.env` under set -e stops (exit 127).
printf 'ENV_NAME=test\nGATEWAY_TRUSTED_PROXIES=203.0.113.10/32 203.0.113.11/32\n' > .env
check "the old RUNBOOK example: sourcing it stops the scripts" "$(bash -c 'set -euo pipefail; . ./.env; echo read' 2>/dev/null; echo "rc=$?")" "rc=127"
r="$(env_file_problem .env)"
check "and is named, by line and setting" "$(printf '%s' "$r" | grep -c "^.env line 2: GATEWAY_TRUSTED_PROXIES's value has a space but no quotes")" 1
check "saying how to write it" "$(printf '%s' "$r" | grep -c "GATEWAY_TRUSTED_PROXIES='…'")" 1
check "never the value" "$(printf '%s' "$r" | grep -c '203.0.113')" 0
check "single quotes: fine" "$(problem "GATEWAY_TRUSTED_PROXIES='203.0.113.10/32 203.0.113.11/32'")" ""
check "double quotes: fine" "$(problem 'GATEWAY_TRUSTED_PROXIES="203.0.113.10/32 203.0.113.11/32"')" ""
check "one value: fine" "$(problem 'GATEWAY_TRUSTED_PROXIES=203.0.113.10/32')" ""
check "empty: fine" "$(problem 'GATEWAY_TRUSTED_PROXIES=')" ""
check "a comment after the value: fine" "$(problem 'APP_VERSION=0.2.130   # the release')" ""
check "comments and blank lines: fine" "$(problem $'# GATEWAY_TRUSTED_PROXIES=a b\n\nX=1')" ""
check "commas with a space after them" "$(problem 'CLIENT_ADDRESSES_CONFIRMED=203.0.113.7, 203.0.113.8' | cut -d: -f1)" ".env line 1"
r="$(problem 'SMTP_PASSWORD=correct horse battery')"
check "a password with spaces is named" "$(printf '%s' "$r" | grep -c "SMTP_PASSWORD's value")" 1
check "but never shown" "$(printf '%s' "$r" | grep -c -E 'correct|horse|battery')" 0
r="$(problem "SMTP_PASSWORD='unclosed")"
check "anything else bash can't read: named by line" "$r" ".env can't be read as the scripts read it (line 1): check its quotes there"
check "a file of that name on PATH is never read instead" "$(mkdir -p p && printf 'X=a b\n' > p/.env && printf 'X=1\n' > .env && PATH="$WORK/p:$PATH" env_file_problem .env)" ""
check "no .env: nothing to say" "$(rm -f .env; env_file_problem .env)" ""
for s in update.sh doctor.sh backup.sh; do
  check "$s asks before it reads .env" "$(awk '/env_file_problem \.env/ {p = NR} /^\. \.\/\.env$/ && !r {r = NR} END {print (p && r && p < r) ? "yes" : "no"}' "$HERE/../$s")" yes
done

echo "env file self-test: ${PASS} passed, ${FAILN} failed"
[ "$FAILN" -eq 0 ]
