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

echo "Care Angels Workforce — health check ($(date '+%Y-%m-%d %H:%M'))"
echo "-------------------------------------------------------------"

# --- configuration present?
if [ ! -f .env ]; then
  row "configuration" fail "deploy/.env missing — installer has not run here"
  echo "-------------------------------------------------------------"; exit 1
fi
# shellcheck disable=SC1091
. ./.env
row "configuration" ok "hostname ${APP_HOSTNAME}"

# --- containers
for svc in gateway api worker postgres object-storage clamav authentik-server; do
  state="$(docker compose ps --format '{{.State}}' "$svc" 2>/dev/null | head -1)"
  [ "$state" = "running" ] && row "service $svc" ok "running" \
                            || row "service $svc" fail "not running ($state)"
done

# --- version identity (compare running vs configured)
RUNNING_META="$(curl -fsS --max-time 5 "http://127.0.0.1:8080/api/v1/build-meta" 2>/dev/null || true)"
if [ -n "$RUNNING_META" ]; then
  RV="$(echo "$RUNNING_META" | grep -o '"version":"[^"]*"' | cut -d'"' -f4)"
  row "running version" ok "$RV (configured: ${APP_VERSION})"
else
  row "running version" fail "api not answering /api/v1/build-meta"
fi

# --- DNS + TLS
RESOLVED="$(getent hosts "$APP_HOSTNAME" 2>/dev/null | awk '{print $1}' | head -1)"
[ -n "$RESOLVED" ] && row "DNS" ok "$APP_HOSTNAME -> $RESOLVED" || row "DNS" fail "no resolution"
if [ "$SMOKE" -eq 0 ]; then
  ISSUER="$(echo | timeout 8 openssl s_client -connect "${APP_HOSTNAME}:443" -servername "${APP_HOSTNAME}" 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null | head -1)"
  [ -n "$ISSUER" ] && row "TLS" ok "certificate present" || row "TLS" warn "certificate not readable yet (first issuance can take a minute)"
fi

# --- database + migrations
DB_OK=$(docker compose exec -T postgres pg_isready -U "${DB_USER}" -d "${DB_NAME}" >/dev/null 2>&1 && echo yes || echo no)
[ "$DB_OK" = yes ] && row "database" ok "accepting connections" || row "database" fail "not accepting"
FW=$(docker compose exec -T postgres psql -U "${DB_USER}" -d "${DB_NAME}" -tAc \
  "select coalesce(max(version),'none') from flyway_schema_history where success" 2>/dev/null || echo "?")
case "$FW" in
  none|\?) row "schema migrations" fail "no successful migration history" ;;
  *)       row "schema migrations" ok "at version $FW" ;;
esac

# --- storage
ST="$(docker compose exec -T -w /tmp object-storage sh -c \
  'mc alias set local "$($$ 2>/dev/null; echo)"' 2>/dev/null; echo "")"
if docker compose exec -T object-storage mc ready local >/dev/null 2>&1; then
  row "object storage" ok "ready"
else
  row "object storage" warn "mc not ready (checking port instead)"; 
  docker compose exec -T object-storage curl -fsS http://localhost:9000/minio/health/live >/dev/null 2>&1 \
    && row "object storage" ok "health endpoint live" || row "object storage" fail "unreachable"
fi

# --- antivirus
CV=$(docker compose exec -T clamav nc -z localhost 3310 >/dev/null 2>&1 && echo ok || echo no)
[ "$CV" = ok ] && row "antivirus" ok "ClamAV listening" || row "antivirus" warn "not answering (it can take minutes on first ever start)"

# --- sign-in server
AH=$(docker compose exec -T authentik-server curl -fsS http://localhost:9000/-/health/ >/dev/null 2>&1 && echo ok || echo no)
[ "$AH" = ok ] && row "sign-in server" ok "healthy" || row "sign-in server" fail "not healthy"

# --- disk + backups
DISK_PCT=$(df --output=pcent /var/lib/docker 2>/dev/null | tail -1 | tr -dc '0-9' || df / | tail -1 | tr -dc '0-9')
[ "${DISK_PCT:-0}" -lt 85 ] && row "disk space" ok "${DISK_PCT}% used" || row "disk space" warn "${DISK_PCT}% used — consider archiving"
LATEST=$(ls -1t backups/*.tar.gz 2>/dev/null | head -1)
if [ -n "$LATEST" ]; then
  AGE_H=$(( ( $(date +%s) - $(stat -c %Y "$LATEST") ) / 3600 ))
  [ "$AGE_H" -lt 26 ] && row "last backup" ok "$AGE_H h ago" || row "last backup" warn "$AGE_H h old — run ./bin/backup.sh"
else
  row "last backup" fail "no backups found"
fi

# --- license (slot; populated when licensing ships)
row "license" ok "not yet enforced (deployment-spec §B7 slot)"

echo "-------------------------------------------------------------"
[ "$FAILS" -eq 0 ] && printf " ${GREEN}All checks passed.${OFF}\n" \
                    || printf " ${RED}%s check(s) failed — copy this whole output to support.${OFF}\n" "$FAILS"
exit "$FAILS"
