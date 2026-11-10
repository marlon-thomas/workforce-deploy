#!/bin/sh
# authentik's entrypoint wrapper (Workforce ADR-0039, review findings 8, 9 and 18): which outgoing mail the sign-in
# codes use, chosen as ONE route. With SIGNIN_SMTP_HOST set, only SIGNIN_SMTP_* values are used, even empty ones,
# so a sign-in relay never gets the staff relay's username or password. Without it, only SMTP_*. Port 465 means
# implicit TLS. The raw values are removed from the environment before authentik starts.
#
# Mounted read-only by compose.yaml; self-tested by bin/tests/email-route-test.sh (with a stand-in for `ak`).
set -eu

if [ -n "${SIGNIN_SMTP_HOST:-}" ]; then
  host="$SIGNIN_SMTP_HOST"
  port="${SIGNIN_SMTP_PORT:-587}"
  user="${SIGNIN_SMTP_USERNAME:-}"
  pass="${SIGNIN_SMTP_PASSWORD:-}"
  starttls="${SIGNIN_SMTP_STARTTLS:-false}"
  from="${SIGNIN_SMTP_FROM:-${SMTP_FROM:-workforce@localhost}}"
else
  host="${SMTP_HOST:-}"
  port="${SMTP_PORT:-587}"
  user="${SMTP_USERNAME:-}"
  pass="${SMTP_PASSWORD:-}"
  starttls="${SMTP_STARTTLS:-false}"
  from="${SMTP_FROM:-workforce@localhost}"
fi
[ -n "$port" ] || port=587

ssl=false
if [ "$port" = 465 ]; then
  ssl=true
  starttls=false
fi

export AUTHENTIK_EMAIL__HOST="$host"
export AUTHENTIK_EMAIL__PORT="$port"
export AUTHENTIK_EMAIL__USERNAME="$user"
export AUTHENTIK_EMAIL__PASSWORD="$pass"
export AUTHENTIK_EMAIL__USE_TLS="$starttls"
export AUTHENTIK_EMAIL__USE_SSL="$ssl"
export AUTHENTIK_EMAIL__FROM="$from"
unset SIGNIN_SMTP_HOST SIGNIN_SMTP_PORT SIGNIN_SMTP_USERNAME SIGNIN_SMTP_PASSWORD SIGNIN_SMTP_STARTTLS SIGNIN_SMTP_FROM
unset SMTP_HOST SMTP_PORT SMTP_USERNAME SMTP_PASSWORD SMTP_STARTTLS SMTP_FROM

exec ak "$@"
