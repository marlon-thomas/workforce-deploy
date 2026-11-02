#!/usr/bin/env bash
# doctor.sh — one-page green/red health check (deployment-spec §B3).
# Designed to be pasted to support verbatim. Exits with the number of FAIL rows (0 = all green).
#
#   ./bin/doctor.sh           the check, for people (colour)
#   ./bin/doctor.sh --plain   the same rows without colour, one per line, tab-separated:
#                             STATUS<TAB>check<TAB>detail (STATUS = OK|WARN|FAIL|SKIP); other lines
#                             start with '#' and the last is '# done fails=N' (bin/healthwatch.sh
#                             reads this — a missing 'done' line means the check stopped early)
#   ./bin/doctor.sh --gate    the deploy gate (install/update/restore): the operational checks —
#                             backup age, disk, staff mail, notifications, alerting — report at most
#                             WARN, so an unrelated problem never fails an install or rolls back a
#                             good update. Run by hand without it to see them as FAILs.
#   ./bin/doctor.sh --smoke   skip the TLS and reachability probes (pre-provisioning smoke run)
#
# Run inside the stack (the backup container, which sets WORKFORCE_IN_STACK=1) the gateway is
# probed at its address on the private network instead of the public name, so no hairpin NAT is
# needed; whether the outside world can reach the server is for an outside monitor to say.
set -euo pipefail
cd "$(dirname "$0")/.."

SMOKE=0; PLAIN=0; GATE=0
for arg in "$@"; do
  case "$arg" in
    --smoke) SMOKE=1 ;;
    --plain) PLAIN=1 ;;
    --gate)  GATE=1 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "doctor.sh: ignoring unknown option '$arg' (see --help)" >&2 ;;
  esac
done
IN_STACK=0
[ "${WORKFORCE_IN_STACK:-}" = "1" ] && IN_STACK=1

if [ "$PLAIN" -eq 1 ]; then
  GREEN=""; RED=""; YELLOW=""; DIM=""; OFF=""
else
  GREEN="\033[1;32m"; RED="\033[1;31m"; YELLOW="\033[1;33m"; DIM="\033[2m"; OFF="\033[0m"
fi
FAILS=0
row() { # row <label> <ok|warn|fail|skip> <detail>
  if [ "$PLAIN" -eq 1 ]; then
    local s
    case "$2" in ok) s=OK ;; warn) s=WARN ;; fail) s=FAIL ;; *) s=SKIP ;; esac
    printf '%s\t%s\t%s\n' "$s" "$1" "$3"
  else
    case "$2" in
      ok)   printf " ${GREEN}OK  ${OFF} %-22s %s\n" "$1" "$3" ;;
      warn) printf " ${YELLOW}WARN${OFF} %-22s %s\n" "$1" "$3" ;;
      fail) printf " ${RED}FAIL${OFF} %-22s %s\n" "$1" "$3" ;;
      *)    printf " ${DIM}SKIP${OFF} %-22s %s\n" "$1" "$3" ;;
    esac
  fi
  if [ "$2" = fail ]; then FAILS=$((FAILS+1)); fi
  return 0
}
# oprow — an operational check: a FAIL by hand and for the health watch, at most WARN under --gate.
oprow() {
  if [ "$GATE" -eq 1 ] && [ "$2" = fail ]; then row "$1" warn "$3"; else row "$1" "$2" "$3"; fi
}
say_line() { if [ "$PLAIN" -eq 1 ]; then printf '# %s\n' "$*"; else printf '%s\n' "$*"; fi; }
rule() { if [ "$PLAIN" -eq 0 ]; then echo "-------------------------------------------------------------"; fi; }
finish() {
  rule
  if [ "$PLAIN" -eq 1 ]; then
    printf '# done fails=%s\n' "$FAILS"
  elif [ "$FAILS" -eq 0 ]; then
    printf " ${GREEN}All checks passed.${OFF}\n"
  else
    printf " ${RED}%s check(s) failed — copy this whole output to support.${OFF}\n" "$FAILS"
  fi
  exit "$FAILS"
}
is_count() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

say_line "Workforce — health check ($(date '+%Y-%m-%d %H:%M'))"
say_line "(first boot: api/authentik can take several minutes — re-run if FAILs persist)"
rule

# --- configuration present?
if [ ! -f .env ]; then
  row "configuration" fail "deploy/.env missing — installer has not run here"
  finish
fi
# shellcheck disable=SC1091
. ./.env

# Docker daemon selection (rootless-aware) lives in ONE place: bin/lib/common.sh.
# shellcheck source=lib/common.sh
. ./bin/lib/common.sh
use_docker_socket
row "configuration" ok "hostname ${APP_HOSTNAME}"

# Inside the stack: reach the gateway at its private address, presenting the public names.
CURL_PIN=()
TLS_CONNECT="${APP_HOSTNAME}"
if [ "$IN_STACK" -eq 1 ]; then
  GW_IP="$(getent hosts gateway 2>/dev/null | awk 'NR==1 {print $1}')" || GW_IP=""
  if [ -n "$GW_IP" ]; then
    CURL_PIN=(--resolve "${APP_HOSTNAME}:443:${GW_IP}" --resolve "${AUTH_HOSTNAME}:443:${GW_IP}")
    TLS_CONNECT="$GW_IP"
  fi
fi
compose_state() { # compose_state <service> — "running", "exited", … or nothing
  docker compose ps --format '{{.State}}' "$1" 2>/dev/null | head -1 || true
}

# --- rootless Docker's port driver: the default shows every client as the Docker gateway, so
#     signature certificates and the audit would hold a meaningless address (host only: the
#     backup container can't see the daemon's process).
if [ "$IN_STACK" -eq 0 ] && command -v pgrep >/dev/null 2>&1; then
  RK="$(pgrep -af 'rootlesskit --state-dir' 2>/dev/null | head -1)" || RK=""
  case "$RK" in
    "") : ;;
    *--port-driver=slirp4netns*) row "client addresses" ok "real addresses reach the app" ;;
    *) row "client addresses" warn "rootless Docker hides client addresses, so certificates and the audit record the Docker gateway — see RUNBOOK (client addresses)" ;;
  esac
fi

# --- containers
# In the backup container, one clear failure rather than every service "not running" (a wrong
# DOCKER_SOCK means nightly backups and these checks cannot run at all).
if [ "$IN_STACK" -eq 1 ] && ! docker version >/dev/null 2>&1; then
  row "docker access" fail "the backup container can't reach Docker (DOCKER_SOCK=${DOCKER_SOCK:-unset}) — nightly backups and health checks can't run; ./bin/update.sh <running version> corrects it"
  finish
fi
for svc in gateway api worker postgres object-storage clamav authentik-server; do
  state="$(compose_state "$svc")"
  if [ "$state" = "running" ]; then row "service $svc" ok "running"
  else row "service $svc" fail "not running ($state)"; fi
done
# The backup container also runs the 15-minute health watch (bin/healthwatch.sh).
state="$(compose_state backup)"
if [ "$state" = "running" ]; then
  # Running isn't enough: it drives compose through the mounted socket. (docker may still be
  # installing on a first boot, which is not a fault.)
  if [ "$IN_STACK" -eq 0 ] && ! docker compose exec -T backup sh -c 'command -v docker >/dev/null || exit 0; docker version >/dev/null' >/dev/null 2>&1; then
    oprow "service backup" fail "running but can't reach Docker (DOCKER_SOCK=${DOCKER_SOCK:-unset}) — nightly backups and alerts don't run; ./bin/update.sh <running version> corrects it"
  else
    oprow "service backup" ok "running (nightly backup + health watch)"
  fi
else oprow "service backup" fail "not running ($state) — no nightly backup and no alerts: docker compose up -d backup"; fi

# --- version identity (compare running vs configured)
# The api port is NOT published (only gateway 80/443 are) — probe via the gateway
# (TLS) and fall back to exec inside the api container.
RUNNING_META="$(curl -fsSk --max-time 5 "${CURL_PIN[@]}" "https://${APP_HOSTNAME}/api/v1/build-meta" 2>/dev/null \
  || docker compose exec -T api curl -fsS --max-time 5 http://localhost:8080/api/v1/build-meta 2>/dev/null \
  || true)"
if [ -n "$RUNNING_META" ]; then
  RV="$(echo "$RUNNING_META" | grep -o '"version":"[^"]*"' | cut -d'"' -f4)" || RV="?"
  row "running version" ok "$RV (configured: ${APP_VERSION})"
else
    DISC="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "${CURL_PIN[@]}" "https://${AUTH_HOSTNAME}/application/o/workforce/.well-known/openid-configuration" 2>/dev/null)" || DISC=000
    if [ "$DISC" = "404" ]; then
      row "running version" fail "api down — the sign-in blueprint has NOT applied (discovery 404). See authentik-worker logs"
    elif [ "$DISC" = "000" ]; then
      row "running version" fail "api down and sign-in unreachable — identity plane not converged; re-run me in 2 minutes"
    else
      row "running version" warn "api still booting (sign-in OK, discovery ${DISC}) — re-run me in a minute"
    fi
fi

# --- DNS + TLS
RESOLVED="$(getent hosts "$APP_HOSTNAME" 2>/dev/null | awk 'NR==1 {print $1}')" || RESOLVED=""
if [ -n "$RESOLVED" ]; then row "DNS" ok "$APP_HOSTNAME -> $RESOLVED"; else row "DNS" fail "no resolution"; fi
if [ "$SMOKE" -eq 0 ]; then
  if command -v openssl >/dev/null 2>&1; then
    ISSUER="$(echo | timeout 8 openssl s_client -connect "${TLS_CONNECT}:443" -servername "${APP_HOSTNAME}" 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null | head -1)" || ISSUER=""
    if [ -n "$ISSUER" ]; then row "TLS" ok "certificate present"
    else row "TLS" warn "certificate not readable yet (first issuance can take a minute)"; fi
  else
    row "TLS" skip "openssl is not installed here"
  fi
  REACH="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 "${CURL_PIN[@]}" "https://${APP_HOSTNAME}" 2>/dev/null)" || REACH=000
  if [ "${#CURL_PIN[@]}" -gt 0 ]; then
    case "$REACH" in
      000) row "reachability" fail "the gateway does not answer on 443 (checked from inside the stack)" ;;
      2*|3*|4*|5*) row "reachability" ok "the gateway answers (HTTP ${REACH}; checked from inside the stack)" ;;
      *) row "reachability" warn "unreadable answer (${REACH}) — re-run in a minute" ;;
    esac
  else
    case "$REACH" in
      000) row "reachability" fail "no answer on 443 — check the cloud provider's firewall (80/443) and DNS" ;;
      2*|3*|4*|5*) row "reachability" ok "https://${APP_HOSTNAME} answers (HTTP ${REACH})" ;;
      *) row "reachability" warn "unreadable answer (${REACH}) — re-run in a minute" ;;
    esac
  fi
fi

# --- database + migrations
DB_OK=$(docker compose exec -T postgres pg_isready -U "${DB_USER}" -d "${DB_NAME}" >/dev/null 2>&1 && echo yes || echo no)
if [ "$DB_OK" = yes ]; then row "database" ok "accepting connections"; else row "database" fail "not accepting"; fi
FW=$(docker compose exec -T postgres psql -U "${DB_USER}" -d "${DB_NAME}" -tAc \
  "select coalesce((select version from flyway_schema_history where success and version is not null order by installed_rank desc limit 1),'none')" 2>/dev/null || echo "?")
case "$FW" in
  none|\?|"") row "schema migrations" fail "no successful migration history" ;;
  *)          row "schema migrations" ok "at version $FW" ;;
esac

# db_value <sql> — one READ-ONLY query on the application database; prints the value.
# Non-zero when the database or the query fails (callers degrade to WARN/SKIP).
db_value() {
  docker compose exec -T -e "PGOPTIONS=-c default_transaction_read_only=on" postgres \
    psql -X -q -v ON_ERROR_STOP=1 -U "${DB_USER}" -d "${DB_NAME}" -tAc "$1" 2>/dev/null
}
db_has_table() { [ "$(db_value "select to_regclass('$1') is not null" || true)" = t ]; }

# --- storage
if docker compose exec -T object-storage mc ready local >/dev/null 2>&1; then
  row "object storage" ok "ready"
else
  row "object storage" warn "mc not ready (checking port instead)";
  if docker compose exec -T object-storage curl -fsS http://localhost:9000/minio/health/live >/dev/null 2>&1; then
    row "object storage" ok "health endpoint live"
  else
    row "object storage" fail "unreachable"
  fi
fi

# --- the application can read its secrets (it runs unprivileged; a 0600 file silently switches a
#     feature off: staff email, invitations, the assistant, push). Names only, never contents.
if UNREADABLE=$(docker compose exec -T -u 999 api sh -c 'for f in /run/secrets/*; do [ -r "$f" ] || printf "%s " "$(basename "$f")"; done' 2>/dev/null); then
  if [ -z "$UNREADABLE" ]; then
    row "app secrets" ok "all readable by the application"
  else
    row "app secrets" fail "unreadable: ${UNREADABLE}(run ./bin/update.sh, which fixes the permissions)"
  fi
else
  row "app secrets" warn "not checked — the api container is not answering"
fi

# --- AI services listed for testing only (ADR-0021 §6): offered only on the test appliance.
if [ "${AI_TEST_SERVICES:-false}" = "true" ]; then
  if [ "${ENV_NAME:-prod}" = "test" ]; then
    row "AI test services" warn "offered (test appliance): fictitious people only"
  else
    row "AI test services" fail "AI_TEST_SERVICES=true on '${ENV_NAME:-prod}': set it to false in .env — never in production"
  fi
fi

# --- the emergency administrator's recovery email (Workforce ADR-0026): outside this server, or a
#     locked-out administrator cannot read the reset email (mail here needs the lost sign-in).
#     Warns only; never fails. Staff domains come from a read-only query, skipped if unavailable.
RECOVERY="$(printf '%s' "${ADMIN_RECOVERY_EMAIL:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
if [ -z "$RECOVERY" ]; then
  row "admin recovery email" warn "ADMIN_RECOVERY_EMAIL is empty: set an address outside this server in .env, then ./bin/update.sh"
else
  R_DOMAIN="${RECOVERY##*@}"
  # This server's names and their parent domains (only names with a dot: never a bare TLD).
  HOSTED="$(printf '%s\n' "${APP_HOSTNAME:-}" "${AUTH_HOSTNAME:-}" "${WEBMAIL_HOSTNAME:-}" \
    "${APP_HOSTNAME#*.}" "${AUTH_HOSTNAME#*.}" | tr '[:upper:]' '[:lower:]' | grep '\.' | sort -u || true)"
  STAFF_DOMAINS="$(docker compose exec -T postgres psql -U "${DB_USER}" -d "${DB_NAME}" -tAc \
    "select staff_domain from mail_setting where staff_domain is not null" 2>/dev/null || true)"
  ON_HERE=""
  for d in $HOSTED $STAFF_DOMAINS; do
    case "$R_DOMAIN" in "$d"|*."$d") ON_HERE="$d"; break ;; esac
  done
  # What authentik holds now (applied by the identity converge in ./bin/update.sh).
  AK_NOW="$(docker compose exec -T authentik-postgres psql -U "${AK_DB_USER:-authentik}" -d "${AK_DB_NAME:-authentik}" -tAc \
    "select lower(email) from authentik_core_user where username = 'admin'" 2>/dev/null | tr -d '[:space:]' || true)"
  MASKED="${RECOVERY:0:1}•••@${R_DOMAIN}"
  if [ -n "$ON_HERE" ]; then
    row "admin recovery email" warn "${MASKED} is on ${ON_HERE}, which this server may host: use an address outside this server"
  elif [ -n "$AK_NOW" ] && [ "$AK_NOW" != "$RECOVERY" ]; then
    row "admin recovery email" warn "${MASKED} is set in .env but not applied yet: run ./bin/update.sh"
  else
    row "admin recovery email" ok "${MASKED} (outside this server)"
  fi
fi

# --- antivirus
CV=$(docker compose exec -T clamav sh -c "nc -z localhost 3310" >/dev/null 2>&1 && echo ok || echo no)
if [ "$CV" = ok ]; then row "antivirus" ok "ClamAV listening"
else row "antivirus" warn "not answering (it can take minutes on first ever start)"; fi

# --- the app's own view of the services it calls (from inside the api/worker containers, which
#     have bash, curl and openssl). A service can be up yet unreachable from the app (network, name).
# in_app <service> <script> [args…] — runs a bash snippet in that container; non-zero if it fails.
in_app() { local svc="$1"; shift; docker compose exec -T "$svc" bash -c "$@" >/dev/null 2>&1; }
TCP='exec 3<>"/dev/tcp/$1/$2"'
AV_BAD=""
for svc in api worker; do
  in_app "$svc" "timeout 5 bash -c '$TCP' _ clamav 3310" || AV_BAD="${AV_BAD:+${AV_BAD}, }${svc}"
done
if [ -z "$AV_BAD" ]; then row "antivirus from app" ok "api and worker reach ClamAV"
else oprow "antivirus from app" fail "${AV_BAD} can't reach clamav:3310 — uploads stay unscanned and unreadable"; fi

if in_app api 'curl -fsS --max-time 5 http://gotenberg:3000/health'; then
  row "PDF service" ok "the api reaches Gotenberg"
else
  oprow "PDF service" fail "the api can't reach gotenberg:3000 — PDF reports and exports fail"
fi

# --- outgoing email (the app's notifications: invitations, password resets, reminders)
if [ -z "${SMTP_HOST:-}" ]; then
  if [ "${ENV_NAME:-prod}" = test ]; then
    row "outgoing email" warn "SMTP_HOST not set — emails stay queued, nothing is sent"
  else
    oprow "outgoing email" fail "SMTP_HOST not set — invitations, password resets and reminders are never sent (set SMTP_* in .env; RUNBOOK question 5)"
  fi
else
  SMTP_TO="${SMTP_HOST}:${SMTP_PORT:-587}"
  if ! in_app api "timeout 6 bash -c '$TCP' _ \"\$1\" \"\$2\"" _ "${SMTP_HOST}" "${SMTP_PORT:-587}"; then
    oprow "outgoing email" fail "the api can't reach the relay ${SMTP_TO} — emails stay queued"
  elif [ "${SMTP_STARTTLS:-false}" = true ] && ! in_app api 'timeout 12 openssl s_client -starttls smtp -connect "$1:$2" -servername "$1" -brief </dev/null' _ "${SMTP_HOST}" "${SMTP_PORT:-587}"; then
    oprow "outgoing email" fail "the relay ${SMTP_TO} answers but STARTTLS fails — check SMTP_PORT (587) and SMTP_STARTTLS"
  else
    row "outgoing email" ok "relay ${SMTP_TO} reachable from the api$([ "${SMTP_STARTTLS:-false}" = true ] && echo ' (STARTTLS ok)')"
  fi
fi
if [ -z "${NOTIFICATION_BASE_URL:-}" ]; then
  row "email links" warn "NOTIFICATION_BASE_URL not set — links in emails won't open Workforce"
fi

# --- secret files that must not be empty (names and sizes only — never contents). Some are empty
#     by design until a feature is used: ai_api_key, mail_relay_password, feedback_github_key.
EMPTY=""
need_secret() { [ -s "secrets/$1" ] || EMPTY="${EMPTY:+${EMPTY}, }$1"; }
for s in db_password minio_access minio_secret ak_db_password ak_secret oidc_client_id \
         oidc_client_secret oidc_jwks_uri ai_credential_key; do need_secret "$s"; done
case ",${COMPOSE_PROFILES:-}," in
  *,staffmail,*) for s in mail_admin_password mail_db_password mail_lookup_key webmail_oidc_secret webmail_des_key; do need_secret "$s"; done ;;
esac
[ -z "${MAIL_RELAY_USER:-}" ] || need_secret mail_relay_password
[ -z "${FEEDBACK_GITHUB_APP_ID:-}" ] || need_secret feedback_github_key
if [ ! -d secrets ]; then
  row "secret files" warn "no secrets/ folder here"
elif [ -z "$EMPTY" ]; then
  row "secret files" ok "none missing or empty"
else
  row "secret files" fail "missing or empty: ${EMPTY} — see RUNBOOK (secrets)"
fi

# --- sign-in server
# Probe authentik readiness via the gateway auth vhost (stable path from the host),
# falling back to exec python inside the container.
AH=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 6 "${CURL_PIN[@]}" "https://${AUTH_HOSTNAME}/-/health/ready/" 2>/dev/null) || AH=000
case "$AH" in
  2*|3*) AH=ok ;;
  *) AH=$(docker compose exec -T authentik-server /ak-root/venv/bin/python -c 'import urllib.request; urllib.request.urlopen("http://localhost:9000/-/health/ready/", timeout=3)' >/dev/null 2>&1 && echo ok || echo no) ;;
esac
if [ "$AH" = ok ]; then row "sign-in server" ok "healthy"; else row "sign-in server" fail "not healthy"; fi

# --- staff email (only when switched on: COMPOSE_PROFILES has staffmail — bin/staff-mail.sh)
case ",${COMPOSE_PROFILES:-}," in
  *,staffmail,*)
    MS="$(docker compose ps --format '{{.State}}/{{.Health}}' mail 2>/dev/null | head -1)" || MS=""
    case "$MS" in
      running/unhealthy) oprow "mail server" fail "running but unhealthy — docker compose logs mail" ;;
      running/*)         oprow "mail server" ok "running" ;;
      *)                 oprow "mail server" fail "not running (${MS%/*}) — ./bin/staff-mail.sh status" ;;
    esac
    WS="$(docker compose ps --format '{{.State}}/{{.Health}}' webmail 2>/dev/null | head -1)" || WS=""
    case "$WS" in
      running/unhealthy) oprow "webmail" fail "running but unhealthy — docker compose logs webmail" ;;
      running/*)         oprow "webmail" ok "running" ;;
      *)                 oprow "webmail" fail "not running (${WS%/*}) — ./bin/staff-mail.sh status" ;;
    esac ;;
esac
# Sync between Workforce and the mail server (app DB, read-only). An organisation-level sync error
# or every mailbox failing means the mail server is unreachable; single mailbox errors are a WARN.
if [ "$DB_OK" != yes ]; then
  row "mail sync" skip "database not answering"
elif ! db_has_table mail_mailbox; then
  row "mail sync" skip "staff email is not in this version"
else
  MR="$(db_value "select (select count(*) from mail_setting where enabled)
                  || '|' || (select count(*) from mail_setting where enabled and last_sync_error is not null)
                  || '|' || (select count(*) from mail_mailbox where sync_error is not null)
                  || '|' || (select count(*) from mail_mailbox where kind = 'BUILT_IN' and suspended_at is null)
                  || '|' || (select count(*) from mail_mailbox where kind = 'BUILT_IN' and suspended_at is null and sync_error is not null)")" || MR=""
  IFS='|' read -r M_ORGS M_ORG_ERR M_BOX_ERR M_ACTIVE M_ACTIVE_ERR <<< "$MR" || true
  if ! is_count "${M_ORGS:-}" || ! is_count "${M_ORG_ERR:-}" || ! is_count "${M_BOX_ERR:-}" \
     || ! is_count "${M_ACTIVE:-}" || ! is_count "${M_ACTIVE_ERR:-}"; then
    row "mail sync" warn "could not read the mail sync state from the database"
  elif [ "$M_ORG_ERR" -gt 0 ]; then
    oprow "mail sync" fail "failing for ${M_ORG_ERR} organisation(s) — Setup → Email shows the error; is the mail server up?"
  elif [ "$M_ACTIVE" -gt 0 ] && [ "$M_ACTIVE_ERR" -eq "$M_ACTIVE" ]; then
    oprow "mail sync" fail "all ${M_ACTIVE} mailbox(es) fail to sync — is the mail server up?"
  elif [ "$M_BOX_ERR" -gt 0 ]; then
    row "mail sync" warn "${M_BOX_ERR} mailbox(es) with a sync error — Setup → Email"
  elif [ "$M_ORGS" -eq 0 ] && [ "$M_ACTIVE" -eq 0 ]; then
    row "mail sync" skip "staff email not in use"
  else
    row "mail sync" ok "no sync errors (${M_ACTIVE} mailbox(es))"
  fi
fi

# --- outbound notifications (expiry reminders, invitations, …) in the last 24 h, read-only.
# Rows FAILED for want of an address (a person with no email) are not a mail fault — not counted.
if [ "$DB_OK" != yes ]; then
  row "notifications" skip "database not answering"
elif ! db_has_table notification_delivery; then
  row "notifications" skip "no notification ledger in this version"
else
  NR="$(db_value "select count(*) filter (where state = 'FAILED' and created_at > now() - interval '24 hours'
                           and coalesce(error_message, '') not like 'no deliverable address%'
                           and coalesce(error_message, '') not like 'pre-#6 row%')
                  || '|' || count(*) filter (where state = 'SENT' and sent_at > now() - interval '24 hours')
                  || '|' || count(*) filter (where state = 'QUEUED' and created_at < now() - interval '1 hour')
                  from notification_delivery")" || NR=""
  IFS='|' read -r N_FAILED N_SENT N_STUCK <<< "$NR" || true
  if ! is_count "${N_FAILED:-}" || ! is_count "${N_SENT:-}" || ! is_count "${N_STUCK:-}"; then
    row "notifications" warn "could not read the notification ledger"
  elif [ "$N_FAILED" -ge 3 ] && [ "$N_SENT" -eq 0 ]; then
    oprow "notifications" fail "${N_FAILED} email(s) failed in 24 h and none were sent — the mail relay (SMTP_HOST) is refusing?"
  elif [ "$N_FAILED" -gt 0 ]; then
    row "notifications" warn "${N_FAILED} email(s) failed in 24 h (${N_SENT} sent) — Settings → Notifications"
  elif [ -n "${SMTP_HOST:-}" ] && [ "$N_STUCK" -gt 0 ]; then
    row "notifications" warn "${N_STUCK} email(s) queued for over an hour — is the worker running?"
  else
    row "notifications" ok "${N_SENT} sent in 24 h, none failed"
  fi
fi

# --- disk: the bundle's filesystem (backups, logs) and Docker's data (images, volumes, databases).
# disk_row <label> <path> — WARN under 15 % free, FAIL under 5 %.
disk_row() {
  local line used avail mnt pct gb
  line="$(df -Pk "$2" 2>/dev/null | awk 'NR==2 {print $3, $4, $6}')" || line=""
  read -r used avail mnt <<< "$line" || true
  if ! is_count "${used:-}" || ! is_count "${avail:-}" || [ $((used + avail)) -eq 0 ]; then
    row "$1" warn "could not read the free space of $2"; return 0
  fi
  pct=$(( avail * 100 / (used + avail) ))
  gb="$(awk -v k="$avail" 'BEGIN { printf "%.1f", k / 1048576 }')"
  if [ "$pct" -lt 5 ]; then oprow "$1" fail "${pct}% free (${gb} GB) on ${mnt} — free space now: old backups, docker image prune"
  elif [ "$pct" -lt 15 ]; then row "$1" warn "${pct}% free (${gb} GB) on ${mnt} — consider archiving"
  else row "$1" ok "${pct}% free (${gb} GB) on ${mnt}"; fi
}
disk_row "disk space" .
if [ "$IN_STACK" -eq 1 ]; then
  DOCKER_ROOT=/          # this container's root sits on Docker's data filesystem
else
  DOCKER_ROOT="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)" || DOCKER_ROOT=""
  [ -d "$DOCKER_ROOT" ] || DOCKER_ROOT=/var/lib/docker
fi
BUNDLE_MNT="$(df -Pk . 2>/dev/null | awk 'NR==2 {print $6}')" || BUNDLE_MNT=""
DOCKER_MNT="$(df -Pk "$DOCKER_ROOT" 2>/dev/null | awk 'NR==2 {print $6}')" || DOCKER_MNT=""
if [ -n "$DOCKER_MNT" ] && [ "$DOCKER_MNT" != "$BUNDLE_MNT" ]; then
  disk_row "disk space (docker)" "$DOCKER_ROOT"
fi

# --- backups: backup.sh only ever leaves a finished archive in backups/ (a failed run leaves none),
#     so the newest archive's age is the age of the last successful backup.
LATEST=$( { ls -1t backups/*.tar.gz 2>/dev/null || true; } | head -1 )
if [ -n "$LATEST" ]; then
  AGE_S=$(( $(date +%s) - $(stat -c %Y "$LATEST") )); AGE_H=$(( AGE_S / 3600 ))
  if [ "$AGE_S" -le $((26 * 3600)) ]; then row "last backup" ok "$AGE_H h ago"
  else oprow "last backup" fail "$AGE_H h old — the nightly backup is not succeeding: see backups/cron.log, run ./bin/backup.sh"; fi
else
  # Installed more than 26 h ago (the secrets are written once, at install) and never backed up.
  SINCE="$(stat -c %Y secrets/db_password 2>/dev/null)" || SINCE=""
  if is_count "$SINCE" && [ $(( $(date +%s) - SINCE )) -gt $((26 * 3600)) ]; then
    oprow "last backup" fail "none at all — see backups/cron.log, run ./bin/backup.sh"
  else
    row "last backup" warn "none yet — ./bin/backup.sh after your first data entry"
  fi
fi
if [ -z "${BACKUP_TARGET:-}" ]; then
  row "off-site backup" warn "no BACKUP_TARGET — backups stay on this server and are lost with it"
elif OFFSITE_PROBLEM="$(offsite_encryption_problem "${BACKUP_ENCRYPT_RECIPIENT:-}")" && [ -n "$OFFSITE_PROBLEM" ]; then
  # Backups are never sent unencrypted, so a target with no usable recipient means no off-site copy.
  oprow "off-site backup" fail "nothing is going off-site: ${OFFSITE_PROBLEM}, and backups never leave this server unencrypted — RUNBOOK, \"Off-site backup targets\""
else
  # The newest run's off-site copy (backup.sh logs a failure but keeps the local archive).
  OFFSITE_FAILED="$( { tail -n 400 backups/cron.log 2>/dev/null || true; } \
    | awk '/^Dumping the application database|^Testing the off-site copy/ { f = 0 } /Off-site copy failed/ { f = 1 } END { print f + 0 }')" || OFFSITE_FAILED=0
  case "$BACKUP_TARGET" in s3://*) KIND=S3 ;; *) KIND=rsync ;; esac
  if [ "$OFFSITE_FAILED" = 1 ]; then row "off-site backup" warn "the last off-site copy failed (${KIND}) — see backups/cron.log"
  else row "off-site backup" ok "configured (${KIND}, encrypted)"; fi
fi

# --- server alerts (bin/healthwatch.sh): who outside this server hears about the FAILs above.
alerts_row() {
  local addrs="${OPS_ALERT_EMAIL:-}" issues="" a dom h p ok_to="" hosted="" onhost="" ts age
  local -a list
  addrs="${addrs// /}"
  if [ -z "$addrs" ]; then
    if [ "${ENV_NAME:-prod}" = test ]; then
      row "ops alerts" skip "OPS_ALERT_EMAIL not set — problems are only logged (logs/healthwatch.log)"
    else
      row "ops alerts" warn "OPS_ALERT_EMAIL not set — nobody outside this server hears about problems"
    fi
    return 0
  fi
  # The domains this server answers for: the app/sign-in/mail names and their parent domains.
  for h in "${APP_HOSTNAME:-}" "${AUTH_HOSTNAME:-}" "${MAIL_HOSTNAME:-}" "${WEBMAIL_HOSTNAME:-}"; do
    case "$h" in ""|*.localhost|localhost) continue ;; esac
    hosted="${hosted} ${h}"
    p="${h#*.}"
    case "$p" in *.*) ;; *) continue ;; esac                       # never a bare TLD
    case "$p" in co.uk|org.uk|me.uk|ltd.uk|plc.uk|net.uk|ac.uk|gov.uk|nhs.uk|com.au|net.au|org.au|co.nz|org.nz|co.za) continue ;; esac
    hosted="${hosted} ${p}"
  done
  IFS=',' read -r -a list <<< "$addrs"
  for a in "${list[@]}"; do
    [ -n "$a" ] || continue
    case "$a" in
      *@*.*) ;;
      *) issues="${issues}; '${a}' is not an email address"; continue ;;
    esac
    dom="$(printf '%s' "${a##*@}" | tr '[:upper:]' '[:lower:]')"
    for h in $hosted; do
      h="$(printf '%s' "$h" | tr '[:upper:]' '[:lower:]')"
      if [ "$dom" = "$h" ] || [ "${dom%".${h}"}" != "$dom" ]; then
        onhost="${onhost:+${onhost}, }${a}"; break
      fi
    done
    ok_to="${ok_to:+${ok_to}, }${a}"
  done
  [ -z "$onhost" ] || issues="${issues}; ${onhost} on this server's own domain — if this server handles that mail, alerts stop with it: use an address elsewhere"
  if [ -z "${SMTP_HOST:-}" ]; then
    issues="${issues}; SMTP_HOST is empty — alerts cannot be sent, only logged"
  else
    case "$SMTP_HOST" in
      mail|stalwart|"${MAIL_HOSTNAME:-mail.localhost}")
        issues="${issues}; SMTP_HOST is this server's own mail server — alerts stop when it does" ;;
    esac
  fi
  ts="$(sed -n 's/^last_run=\([0-9][0-9]*\)$/\1/p' state/healthwatch.state 2>/dev/null | head -1)" || ts=""
  if is_count "$ts"; then
    age=$(( ( $(date +%s) - ts ) / 60 ))
    [ "$age" -le 60 ] || issues="${issues}; the health watch last ran ${age} min ago — is the backup container running?"
    ok_to="${ok_to} (watch ran ${age} min ago)"
  else
    ok_to="${ok_to} (the watch has not run yet)"
  fi
  if [ -n "$issues" ]; then row "ops alerts" warn "${issues#; }"
  else row "ops alerts" ok "to ${ok_to}"; fi
}
alerts_row
# Outside uptime check (RUNBOOK §7c): the only alert that works when this server is off.
if [ -n "${OPS_HEARTBEAT_URL:-}" ]; then
  row "uptime check" ok "outside heartbeat set"
elif [ "${ENV_NAME:-prod}" = test ]; then
  row "uptime check" skip "OPS_HEARTBEAT_URL not set (optional on the test appliance)"
else
  row "uptime check" warn "OPS_HEARTBEAT_URL not set — if this server stops, nobody is told (RUNBOOK §7c)"
fi

# --- license (slot; populated when licensing ships)
row "license" ok "not yet enforced (deployment-spec §B7 slot)"

finish
