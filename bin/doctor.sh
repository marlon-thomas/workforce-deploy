#!/usr/bin/env bash
# doctor.sh — one-page green/red health check (deployment-spec §B3).
# Designed to be pasted to support verbatim. Exits 0 when all green.
set -euo pipefail
cd "$(dirname "$0")/.."

SMOKE=0
[ "${1:-}" = "--smoke" ] && SMOKE=1

GREEN="\033[1;32m"; RED="\033[1;31m"; YELLOW="\033[1;33m"; DIM="\033[2m"; OFF="\033[0m"
FAILS=0
row() { # row <label> <ok|warn|fail> <detail>
  case "$2" in
    ok)   printf " ${GREEN}OK  ${OFF} %-22s %s\n" "$1" "$3" ;;
    warn) printf " ${YELLOW}WARN${OFF} %-22s %s\n" "$1" "$3" ;;
    fail) printf " ${RED}FAIL${OFF} %-22s %s\n" "$1" "$3"; FAILS=$((FAILS+1)) ;;
  esac
}

echo "Workforce — health check ($(date '+%Y-%m-%d %H:%M'))"
echo "(first boot: api/authentik can take several minutes — re-run if FAILs persist)"
echo "-------------------------------------------------------------"

# --- configuration present?
if [ ! -f .env ]; then
  row "configuration" fail "deploy/.env missing — installer has not run here"
  echo "-------------------------------------------------------------"; exit 1
fi
# shellcheck disable=SC1091
. ./.env

# Docker daemon selection (rootless-aware) lives in ONE place: bin/lib/common.sh.
# shellcheck source=lib/common.sh
. ./bin/lib/common.sh
use_docker_socket
row "configuration" ok "hostname ${APP_HOSTNAME}"

# --- containers
for svc in gateway api worker postgres object-storage clamav authentik-server; do
  state="$(docker compose ps --format '{{.State}}' "$svc" 2>/dev/null | head -1)"
  [ "$state" = "running" ] && row "service $svc" ok "running" \
                            || row "service $svc" fail "not running ($state)"
done

# --- version identity (compare running vs configured)
# The api port is NOT published (only gateway 80/443 are) — probe via the gateway
# (TLS) and fall back to exec inside the api container.
RUNNING_META="$(curl -fsSk --max-time 5 "https://${APP_HOSTNAME}/api/v1/build-meta" 2>/dev/null \
  || docker compose exec -T api curl -fsS --max-time 5 http://localhost:8080/api/v1/build-meta 2>/dev/null \
  || true)"
if [ -n "$RUNNING_META" ]; then
  RV="$(echo "$RUNNING_META" | grep -o '"version":"[^"]*"' | cut -d'"' -f4)"
  row "running version" ok "$RV (configured: ${APP_VERSION})"
else
    DISC="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "https://${AUTH_HOSTNAME}/application/o/workforce/.well-known/openid-configuration" 2>/dev/null || echo 000)"
    if [ "$DISC" = "404" ]; then
      row "running version" fail "api down — the sign-in blueprint has NOT applied (discovery 404). See authentik-worker logs"
    elif [ "$DISC" = "000" ]; then
      row "running version" fail "api down and sign-in unreachable — identity plane not converged; re-run me in 2 minutes"
    else
      row "running version" warn "api still booting (sign-in OK, discovery ${DISC}) — re-run me in a minute"
    fi
fi

# --- DNS + TLS
RESOLVED="$(getent hosts "$APP_HOSTNAME" 2>/dev/null | awk '{print $1}' | head -1)"
[ -n "$RESOLVED" ] && row "DNS" ok "$APP_HOSTNAME -> $RESOLVED" || row "DNS" fail "no resolution"
if [ "$SMOKE" -eq 0 ]; then
  ISSUER="$(echo | timeout 8 openssl s_client -connect "${APP_HOSTNAME}:443" -servername "${APP_HOSTNAME}" 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null | head -1)"
  [ -n "$ISSUER" ] && row "TLS" ok "certificate present" || row "TLS" warn "certificate not readable yet (first issuance can take a minute)"
  REACH="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 "https://${APP_HOSTNAME}" 2>/dev/null || echo 000)"
  case "$REACH" in
    000) row "reachability" fail "no answer on 443 — check the cloud provider's firewall (80/443) and DNS" ;;
    2*|3*|4*|5*) row "reachability" ok "https://${APP_HOSTNAME} answers (HTTP ${REACH})" ;;
    *) row "reachability" warn "unreadable answer (${REACH}) — re-run in a minute" ;;
  esac
fi

# --- database + migrations
DB_OK=$(docker compose exec -T postgres pg_isready -U "${DB_USER}" -d "${DB_NAME}" >/dev/null 2>&1 && echo yes || echo no)
[ "$DB_OK" = yes ] && row "database" ok "accepting connections" || row "database" fail "not accepting"
FW=$(docker compose exec -T postgres psql -U "${DB_USER}" -d "${DB_NAME}" -tAc \
  "select coalesce((select version from flyway_schema_history where success and version is not null order by installed_rank desc limit 1),'none')" 2>/dev/null || echo "?")
case "$FW" in
  none|\?) row "schema migrations" fail "no successful migration history" ;;
  *)       row "schema migrations" ok "at version $FW" ;;
esac

# --- storage
if docker compose exec -T object-storage mc ready local >/dev/null 2>&1; then
  row "object storage" ok "ready"
else
  row "object storage" warn "mc not ready (checking port instead)"; 
  docker compose exec -T object-storage curl -fsS http://localhost:9000/minio/health/live >/dev/null 2>&1 \
    && row "object storage" ok "health endpoint live" || row "object storage" fail "unreachable"
fi

# --- the application can read its secrets (it runs unprivileged; a 0600 file silently switches a
#     feature off: staff email, invitations, the assistant, push). Names only, never contents.
UNREADABLE=$(docker compose exec -T -u 999 api sh -c 'for f in /run/secrets/*; do [ -r "$f" ] || printf "%s " "$(basename "$f")"; done' 2>/dev/null)
if [ -z "$UNREADABLE" ]; then
  row "app secrets" ok "all readable by the application"
else
  row "app secrets" fail "unreadable: ${UNREADABLE}(run ./bin/update.sh, which fixes the permissions)"
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
[ "$CV" = ok ] && row "antivirus" ok "ClamAV listening" || row "antivirus" warn "not answering (it can take minutes on first ever start)"

# --- sign-in server
# Probe authentik readiness via the gateway auth vhost (stable path from the host),
# falling back to exec python inside the container.
AH=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 6 "https://${AUTH_HOSTNAME}/-/health/ready/" 2>/dev/null || echo 000)
case "$AH" in
  2*|3*) AH=ok ;;
  *) AH=$(docker compose exec -T authentik-server /ak-root/venv/bin/python -c 'import urllib.request; urllib.request.urlopen("http://localhost:9000/-/health/ready/", timeout=3)' >/dev/null 2>&1 && echo ok || echo no) ;;
esac
[ "$AH" = ok ] && row "sign-in server" ok "healthy" || row "sign-in server" fail "not healthy"

# --- disk + backups
DISK_PCT=$(df --output=pcent /var/lib/docker 2>/dev/null | tail -1 | tr -dc '0-9' || df / | tail -1 | tr -dc '0-9')
[ "${DISK_PCT:-0}" -lt 85 ] && row "disk space" ok "${DISK_PCT}% used" || row "disk space" warn "${DISK_PCT}% used — consider archiving"
LATEST=$( { ls -1t backups/*.tar.gz 2>/dev/null || true; } | head -1 )
if [ -n "$LATEST" ]; then
  AGE_H=$(( ( $(date +%s) - $(stat -c %Y "$LATEST") ) / 3600 ))
  [ "$AGE_H" -lt 26 ] && row "last backup" ok "$AGE_H h ago" || row "last backup" warn "$AGE_H h old — run ./bin/backup.sh"
else
  row "last backup" warn "none yet — ./bin/backup.sh after your first data entry"
fi

# --- license (slot; populated when licensing ships)
row "license" ok "not yet enforced (deployment-spec §B7 slot)"

echo "-------------------------------------------------------------"
[ "$FAILS" -eq 0 ] && printf " ${GREEN}All checks passed.${OFF}\n" \
                    || printf " ${RED}%s check(s) failed — copy this whole output to support.${OFF}\n" "$FAILS"
exit "$FAILS"
