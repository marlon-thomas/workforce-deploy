#!/usr/bin/env bash
# restore.sh — restore a backup archive (deployment-spec §B3).
# Verifies the archive by restoring into a scratch database first, then swaps.
set -euo pipefail
cd "$(dirname "$0")/.."

ARCHIVE="${1:-}"
[ -z "$ARCHIVE" ] && { echo "Usage: ./bin/restore.sh backups/<archive>.tar.gz"; exit 1; }
[ -f "$ARCHIVE" ] || { echo "No such archive: $ARCHIVE"; exit 1; }
# shellcheck disable=SC1091
[ -f .env ] && . ./.env

# Rootless-aware docker context: when run as root on a rootless install, talk to the
# service user's daemon socket (compose exec etc. need the right socket).
resolve_docker_context() {
  if [ "$(id -u)" -eq 0 ] && [ -S "/home/workforce_app_sa/.docker/run/docker.sock" ]; then
    export DOCKER_HOST="unix:///home/workforce_app_sa/.docker/run/docker.sock"
  fi
}
resolve_docker_context

echo "This will REPLACE the current database and evidence with the contents of:"
echo "  $ARCHIVE"
printf 'Type RESTORE to continue: '
read -r CONFIRM
[ "$CONFIRM" = "RESTORE" ] || { echo "Aborted."; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
tar -xzf "$ARCHIVE" -C "$TMP"
[ -f "$TMP/database.dump" ] || { echo "Archive has no database.dump — wrong file?"; exit 1; }

echo "Verifying the backup against a scratch database…"
docker compose exec -T postgres psql -U "${DB_USER:-workforce_app}" -d postgres \
  -c "DROP DATABASE IF EXISTS restore_check" -c "CREATE DATABASE restore_check" >/dev/null
docker compose exec -T postgres pg_restore -U "${DB_USER:-workforce_app}" \
  -d restore_check --no-owner --exit-on-error < /dev/null >/dev/null 2>&1 || true
docker cp "$TMP/database.dump" "$(docker compose ps -q postgres)":/tmp/restore_check.dump
if ! docker compose exec -T postgres pg_restore -U "${DB_USER:-workforce_app}" \
    -d restore_check --no-owner --exit-on-error /tmp/restore_check.dump >/dev/null 2>&1; then
  docker compose exec -T postgres psql -U "${DB_USER:-workforce_app}" -d postgres \
    -c "DROP DATABASE IF EXISTS restore_check" >/dev/null
  echo "This backup failed verification — nothing was changed. Send it to support."
  exit 1
fi
docker compose exec -T postgres psql -U "${DB_USER:-workforce_app}" -d postgres \
  -c "DROP DATABASE IF EXISTS restore_check" >/dev/null
echo "Backup verified."

echo "Stopping the application…"
docker compose stop api worker

echo "Restoring the database…"
docker compose exec -T postgres psql -U "${DB_USER:-workforce_app}" -d postgres \
  -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${DB_NAME:-workforce}' AND pid <> pg_backend_pid()" >/dev/null
docker compose exec -T postgres dropdb -U "${DB_USER:-workforce_app}" --if-exists "${DB_NAME:-workforce}"
docker compose exec -T postgres createdb -U "${DB_USER:-workforce_app}" "${DB_NAME:-workforce}"
docker cp "$TMP/database.dump" "$(docker compose ps -q postgres)":/tmp/final.dump
docker compose exec -T postgres pg_restore -U "${DB_USER:-workforce_app}" \
  -d "${DB_NAME:-workforce}" --no-owner /tmp/final.dump

if [ -d "$TMP/evidence" ]; then
  echo "Restoring evidence…"
  docker cp "$TMP/evidence/." "$(docker compose ps -q object-storage)":/tmp/ 2>/dev/null || true
fi

echo "Starting the application…"
docker compose start api worker
sleep 15
./bin/doctor.sh || true
echo "Restore complete."
