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
# Setup -> Email in Workforce starts this too, through bin/server-actions.sh in the backup container,
# so everything here also has to work on alpine with busybox and no python or ansible.
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

set_env() { env_set "$1" "$2"; }   # bin/lib/common.sh

profiles_with() {   # profiles_with add|remove NAME
  local current="${COMPOSE_PROFILES:-}" out=""
  IFS=',' read -ra parts <<< "$current"
  for p in "${parts[@]}"; do [ -n "$p" ] && [ "$p" != "$2" ] && out="${out:+$out,}$p"; done
  [ "$1" = add ] && out="${out:+$out,}$2"
  printf '%s' "$out"
}

valid_host() { [[ "$1" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]; }

# render_webmail_blueprint HOST — what the identity converge renders from the same template, for the
# backup container, which has no ansible. Only the webmail blueprint depends on the webmail host. The
# values are a checked host name and generated hex, and anything left that looks like a template
# means the template has moved on from this renderer: refused rather than applied half-done. Written
# in place, so authentik's mount of this one file (bound to its inode) sees the new contents.
render_webmail_blueprint() {
  local host="$1" key secret tmp
  key="$(cat secrets/mail_lookup_key)"; secret="$(cat secrets/webmail_oidc_secret)"
  [[ "$key" =~ ^[0-9a-fA-F]+$ ]] && [[ "$secret" =~ ^[0-9a-fA-F]+$ ]] || fail "The webmail keys in secrets/ aren't what this expects"
  tmp="$(mktemp)"
  awk -v host="$host" -v key="$key" -v secret="$secret" '
    /^\{% if webmail_hostname/ { off = 1; next }
    /^\{% else %\}/            { off = 0; next }
    /^\{% endif %\}/           { next }
    off                        { next }
    { gsub(/\{\{ webmail_hostname \}\}/, host); gsub(/\{\{ mail_lookup_key \}\}/, key)
      gsub(/\{\{ webmail_oidc_secret \}\}/, secret); print }' \
    ansible/roles/authentik/templates/webmail-app.yaml.j2 > "$tmp"
  if grep -qE '\{\{|\{%' "$tmp"; then rm -f "$tmp"; fail "The webmail sign-in template has something this can't fill in"; fi
  cat "$tmp" > blueprints/webmail-app.yaml
  rm -f "$tmp"
}

apply_webmail_blueprint() {
  local tries=0 out
  # A mount left pointing at an old copy can only be fixed by recreating the sign-in containers.
  if ! docker exec -w / workforce-deploy-authentik-server-1 cat /blueprints/webmail-app.yaml 2>/dev/null | cmp -s - blueprints/webmail-app.yaml; then
    say "Restarting the sign-in server so it sees the webmail settings…"
    docker compose up -d --no-deps --force-recreate authentik-server authentik-worker
  fi
  while [ "$tries" -lt 30 ]; do
    tries=$((tries + 1))
    if out="$(docker exec -w / workforce-deploy-authentik-server-1 python /manage.py apply_blueprint /blueprints/webmail-app.yaml 2>&1)"; then
      case "$out" in *"Blueprint invalid"*) ;; *) return 0 ;; esac
    fi
    sleep "${STAFF_MAIL_RETRY_SECS:-10}"
  done
  fail "Sign-in setup failed: authentik would not apply the webmail settings"
}

converge_identity() {
  if [ "${WORKFORCE_IN_STACK:-}" = 1 ]; then
    say "Setting up webmail sign-in…"
    render_webmail_blueprint "$1"
    apply_webmail_blueprint
  elif [ -f inventories/local/hosts.yml ] && command -v ansible-playbook >/dev/null 2>&1; then
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
  # They were made 0600 just above, and the app runs as uid 999: without this, staff email stayed
  # silently off until the next update put the modes right.
  secret_modes
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
    # Only meaningful on the host: inside a container this shows the container's own setting, which
    # is always open. From the backup container, the mail server failing to start says the same.
    floor=0
    [ "${WORKFORCE_IN_STACK:-}" = 1 ] || floor="$(cat /proc/sys/net/ipv4/ip_unprivileged_port_start 2>/dev/null || echo 0)"
    [ "$floor" -le 25 ] || fail "This server can't receive mail yet: as root run
    sysctl -w net.ipv4.ip_unprivileged_port_start=25 and set it in /etc/sysctl.conf (the ansible common role does this), then run this again."
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
