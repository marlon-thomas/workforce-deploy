#!/usr/bin/env bash
# Self-test for authentik/email-route.sh (Workforce ADR-0039 review, findings 8, 9 and 18): the sign-in codes'
# outgoing mail is chosen as one route, never mixed. Hermetic: a stand-in `ak` prints what authentik would get.
#   ./bin/tests/email-route-test.sh      exit 0 = all pass
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROUTE="$HERE/../../authentik/email-route.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
printf '#!/bin/sh\nenv | grep -E "^(AUTHENTIK_EMAIL__|SIGNIN_SMTP_|SMTP_)" | sort\necho "args: $*"\n' > "$WORK/ak"
chmod +x "$WORK/ak"

PASS=0; FAILN=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAILN=$((FAILN+1)); printf 'FAIL: %s: expected [%s] got [%s]\n' "$1" "$3" "$2"; fi; }
run() { env -i PATH="$WORK:/usr/bin:/bin" "$@" sh "$ROUTE" server; }
val() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

# Only the staff relay set: it is the route.
out="$(run SMTP_HOST=relay.example.org SMTP_PORT=587 SMTP_USERNAME=staff SMTP_PASSWORD=s3cret SMTP_STARTTLS=true SMTP_FROM=noreply@example.org)"
check "no sign-in route: host" "$(val "$out" AUTHENTIK_EMAIL__HOST)" relay.example.org
check "no sign-in route: user" "$(val "$out" AUTHENTIK_EMAIL__USERNAME)" staff
check "no sign-in route: starttls" "$(val "$out" AUTHENTIK_EMAIL__USE_TLS)" true
check "runs authentik with its arguments" "$(printf '%s\n' "$out" | sed -n 's/^args: //p')" server

# A sign-in route with no account of its own: never the staff relay's username or password.
out="$(run SMTP_HOST=relay.example.org SMTP_PORT=2525 SMTP_USERNAME=staff SMTP_PASSWORD=s3cret SMTP_STARTTLS=true \
  SIGNIN_SMTP_HOST=codes.example.org)"
check "sign-in route: its host" "$(val "$out" AUTHENTIK_EMAIL__HOST)" codes.example.org
check "sign-in route: not the relay's port" "$(val "$out" AUTHENTIK_EMAIL__PORT)" 587
check "sign-in route: not the relay's username" "$(val "$out" AUTHENTIK_EMAIL__USERNAME)" ""
check "sign-in route: not the relay's password" "$(val "$out" AUTHENTIK_EMAIL__PASSWORD)" ""
check "sign-in route: not the relay's STARTTLS" "$(val "$out" AUTHENTIK_EMAIL__USE_TLS)" false
check "sign-in route: the raw values are gone" "$(printf '%s\n' "$out" | grep -c -E '^(SIGNIN_SMTP_|SMTP_)')" 0

# Port 465 is implicit TLS.
out="$(run SIGNIN_SMTP_HOST=codes.example.org SIGNIN_SMTP_PORT=465 SIGNIN_SMTP_STARTTLS=true SIGNIN_SMTP_USERNAME=codes)"
check "465: implicit TLS" "$(val "$out" AUTHENTIK_EMAIL__USE_SSL)" true
check "465: not STARTTLS as well" "$(val "$out" AUTHENTIK_EMAIL__USE_TLS)" false
check "465: its own username" "$(val "$out" AUTHENTIK_EMAIL__USERNAME)" codes

echo "email-route self-test: ${PASS} passed, ${FAILN} failed"
[ "$FAILN" -eq 0 ]
