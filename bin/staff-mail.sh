#!/usr/bin/env bash
# staff-mail.sh — switch staff email on or off for this installation (mail-calendar-spec §11).
#
#   ./bin/staff-mail.sh on --webmail-host mail.example.org [--mail-host mail.example.org]
#                          [--relay smtp.relay.example:587 --relay-user USER [--relay-implicit-tls]
#                           [--relay-spf-include spf.relay.example]] [--private-ca]
#   ./bin/staff-mail.sh off        # stops the mail server and webmail; their data is kept
#   ./bin/staff-mail.sh status
#
# --webmail-host  where staff read their mail (its own name: never a path of the app)
# --mail-host     the name the staff domain's MX record points at (default: the webmail host);
#                 it must resolve to this server, with port 25 open to the internet
# --relay         send outbound mail through a relay (recommended); its password goes in
#                 secrets/mail_relay_password. Without one, mail goes straight to each domain.
# --private-ca    test appliances only (ADR-0014): accept the private CA's certificates when
#                 the mail server and webmail talk to the sign-in server
#
# The organisation's own domains are NOT set here: they are Setup -> Email in Workforce.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .env ] || { echo "No .env — run install.sh first."; exit 1; }
# shellcheck disable=SC1091
. ./.env
# shellcheck source=lib/common.sh
. ./bin/lib/common.sh
use_docker_socket

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mXX\033[0m %s\n' "$*"; exit 1; }

# set_env KEY VALUE — replace KEY's line in .env, or add it.
set_env() {
  local key="$1" value="$2"
  if grep -q "^${key}=" .env; then
    python3 - "$key" "$value" <<'PY'
import sys
key, value = sys.argv[1], sys.argv[2]
lines = open(".env").read().splitlines()
lines = [f"{key}={value}" if l.startswith(key + "=") else l for l in lines]
open(".env", "w").write("\n".join(lines) + "\n")
PY
  else
    printf '%s=%s\n' "$key" "$value" >> .env
  fi
}

profiles_with() {   # profiles_with add|remove NAME
  local current="${COMPOSE_PROFILES:-}" out=""
  IFS=',' read -ra parts <<< "$current"
  for p in "${parts[@]}"; do [ -n "$p" ] && [ "$p" != "$2" ] && out="${out:+$out,}$p"; done
  [ "$1" = add ] && out="${out:+$out,}$2"
  printf '%s' "$out"
}

valid_host() { [[ "$1" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]; }

converge_identity() {
  if [ -f inventories/local/hosts.yml ] && command -v ansible-playbook >/dev/null 2>&1; then
    say "Setting up webmail sign-in…"
    ansible-playbook -i inventories/local/hosts.yml ansible/site.yml --tags identity \
        -e github_token=unused -e ak_admin_password= \
        -e "app_hostname=${APP_HOSTNAME}" -e "auth_hostname=${AUTH_HOSTNAME}" \
        -e "webmail_hostname=$1" \
        >"backups/identity-converge.log" 2>&1 \
      || fail "Sign-in setup failed — see backups/identity-converge.log"
  else
    fail "This box has no local ansible inventory; staff email needs the identity converge (bin/install.sh sets it up)."
  fi
}

ensure_secrets() {
  for s in mail_admin_password mail_db_password mail_lookup_key webmail_oidc_secret webmail_des_key; do
    [ -s "secrets/$s" ] || ( umask 077; openssl rand -hex 24 | tr -d '\n' > "secrets/$s" )
  done
  [ -e secrets/mail_relay_password ] || ( umask 077; : > secrets/mail_relay_password )
  mkdir -p blueprints backups
  [ -e blueprints/webmail-app.yaml ] || printf 'version: 1\nentries: []\n' > blueprints/webmail-app.yaml
}

cmd="${1:-status}"; shift || true
case "$cmd" in
  on)
    WEBMAIL=""; MAILHOST=""; RELAY=""; RELAY_USER=""; RELAY_TLS=false; SPF=""; PRIVATE_CA=false
    while [ $# -gt 0 ]; do
      case "$1" in
        --webmail-host) WEBMAIL="${2,,}"; shift 2 ;;
        --mail-host) MAILHOST="${2,,}"; shift 2 ;;
        --relay) RELAY="$2"; shift 2 ;;
        --relay-user) RELAY_USER="$2"; shift 2 ;;
        --relay-implicit-tls) RELAY_TLS=true; shift ;;
        --relay-spf-include) SPF="$2"; shift 2 ;;
        --private-ca) PRIVATE_CA=true; shift ;;
        *) fail "Unknown option $1 (see the top of this script)" ;;
      esac
    done
    valid_host "$WEBMAIL" || fail "Give the webmail host name, e.g. --webmail-host mail.example.org"
    [ -n "$MAILHOST" ] || MAILHOST="$WEBMAIL"
    valid_host "$MAILHOST" || fail "The mail host \"$MAILHOST\" is not a host name"
    [ "$WEBMAIL" != "$APP_HOSTNAME" ] || fail "Webmail needs its own host name, not the app's ($APP_HOSTNAME)"
    RELAY_HOST=""; RELAY_PORT=587
    if [ -n "$RELAY" ]; then
      RELAY_HOST="${RELAY%%:*}"; [ "$RELAY" != "$RELAY_HOST" ] && RELAY_PORT="${RELAY##*:}"
    fi
    ensure_secrets
    set_env WEBMAIL_HOSTNAME "$WEBMAIL"
    set_env WEBMAIL_URL "https://$WEBMAIL"
    set_env MAIL_HOSTNAME "$MAILHOST"
    set_env MAIL_SERVER_URL "http://mail:8080"
    set_env MAIL_RELAY_HOST "$RELAY_HOST"
    set_env MAIL_RELAY_PORT "$RELAY_PORT"
    set_env MAIL_RELAY_USER "$RELAY_USER"
    set_env MAIL_RELAY_IMPLICIT_TLS "$RELAY_TLS"
    set_env MAIL_RELAY_SPF_INCLUDE "$SPF"
    if [ "$PRIVATE_CA" = true ]; then
      set_env MAIL_TLS_VERIFY false; set_env MAIL_SIGN_IN_ALLOW_INVALID_CERTS true
    else
      set_env MAIL_TLS_VERIFY true; set_env MAIL_SIGN_IN_ALLOW_INVALID_CERTS false
    fi
    set_env COMPOSE_PROFILES "$(profiles_with add staffmail)"
    converge_identity "$WEBMAIL"
    # shellcheck disable=SC1091
    . ./.env
    say "Starting the mail server and webmail…"
    docker compose up -d mail-db-init mail webmail
    docker compose up -d --force-recreate api worker gateway
    say "Staff email is on. Next, in Workforce: Setup -> Email — choose the staff domain, check the"
    say "people, switch email on, then add the DNS records it shows."
    [ -n "$RELAY_USER" ] && [ ! -s secrets/mail_relay_password ] && \
      say "Put the relay's password in secrets/mail_relay_password (never in .env), then re-run this command."
    [ "$PRIVATE_CA" = true ] && say "Test appliance: the TLS certificate must also cover $WEBMAIL (bin/gen-test-ca.sh)."
    exit 0 ;;
  off)
    set_env COMPOSE_PROFILES "$(profiles_with remove staffmail)"
    set_env MAIL_SERVER_URL ""
    set_env WEBMAIL_URL ""
    # shellcheck disable=SC1091
    . ./.env
    say "Stopping the mail server and webmail (their data is kept)…"
    docker compose stop mail webmail >/dev/null 2>&1 || true
    docker compose up -d --force-recreate api worker
    say "Staff email is off. Mailboxes are kept; switching it on again picks up where it left off."
    exit 0 ;;
  status)
    case ",${COMPOSE_PROFILES:-}," in
      *,staffmail,*) echo "Staff email: on — webmail https://${WEBMAIL_HOSTNAME:-?}, mail host ${MAIL_HOSTNAME:-?}, relay ${MAIL_RELAY_HOST:-none}" ;;
      *) echo "Staff email: off" ;;
    esac
    exit 0 ;;
  *) fail "Usage: ./bin/staff-mail.sh on|off|status (see the top of this script)" ;;
esac
