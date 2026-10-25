#!/usr/bin/env bash
# restore.sh — restore a backup archive written by backup.sh (deployment-spec §B3).
# Puts back everything the archive holds: application DB, sign-in (authentik)
# DB, evidence bucket, branding. Every dump is verified by restoring it into a
# scratch database FIRST — a bad archive changes nothing.
#
#   ./bin/restore.sh backups/<archive>.tar.gz              (asks for RESTORE)
#   ./bin/restore.sh --yes --data-only <archive>           (restore-drill.sh only:
#        data plane only — no app/sign-in containers are stopped or started)
set -euo pipefail
cd "$(dirname "$0")/.."

YES=0; DATA_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) YES=1; shift ;;
    --data-only) DATA_ONLY=1; shift ;;
    *) break ;;
  esac
done
ARCHIVE="${1:-}"
[ -z "$ARCHIVE" ] && { echo "Usage: ./bin/restore.sh backups/<archive>.tar.gz"; exit 1; }
[ -f "$ARCHIVE" ] || { echo "No such archive: $ARCHIVE"; exit 1; }
# shellcheck disable=SC1091
[ -f .env ] && . ./.env
# shellcheck source=lib/common.sh
. ./bin/lib/common.sh
use_docker_socket
DB_USER="${DB_USER:-workforce_app}"; DB_NAME="${DB_NAME:-workforce}"
AK_DB_USER="${AK_DB_USER:-authentik}"; AK_DB_NAME="${AK_DB_NAME:-authentik}"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
tar -xzf "$ARCHIVE" -C "$TMP"
[ -f "$TMP/database.dump" ] || { echo "Archive has no database.dump — wrong file?"; exit 1; }
if [ -f "$TMP/MANIFEST" ]; then
  ( cd "$TMP" && grep -E '^[0-9a-f]{64}  ' MANIFEST | sha256sum -c --quiet ) \
    || { echo "Archive contents do not match its MANIFEST checksums — nothing was changed."; exit 1; }
fi
# Archives from before the authentik/evidence fix hold the app DB only.
HAVE_AK=0; [ -f "$TMP/authentik.dump" ] && HAVE_AK=1
HAVE_EV=0; [ -f "$TMP/evidence.tar" ] && HAVE_EV=1
[ "$HAVE_AK" -eq 1 ] || echo "NOTE: this archive has no sign-in database (older backup) — sign-in data is left as is."
[ "$HAVE_EV" -eq 1 ] || echo "NOTE: this archive has no evidence (older backup) — evidence is left as is."

echo "This will REPLACE the current database$( [ "$HAVE_AK" -eq 1 ] && echo ', sign-in database')$( [ "$HAVE_EV" -eq 1 ] && echo ' and evidence') with the contents of:"
echo "  $ARCHIVE"
if [ "$YES" -ne 1 ]; then
  printf 'Type RESTORE to continue: '
  read -r CONFIRM
  [ "$CONFIRM" = "RESTORE" ] || { echo "Aborted."; exit 1; }
fi

echo "Verifying the backup against scratch databases…"
pg_verify_dump postgres "$DB_USER" "$TMP/database.dump" \
  || { echo "The application database in this backup failed verification — nothing was changed. Send it to support."; exit 1; }
if [ "$HAVE_AK" -eq 1 ]; then
  pg_verify_dump authentik-postgres "$AK_DB_USER" "$TMP/authentik.dump" \
    || { echo "The sign-in database in this backup failed verification — nothing was changed. Send it to support."; exit 1; }
fi
if [ "$HAVE_EV" -eq 1 ]; then
  tar -tf "$TMP/evidence.tar" >/dev/null \
    || { echo "The evidence in this backup is unreadable — nothing was changed. Send it to support."; exit 1; }
fi
echo "Backup verified."

if [ "$DATA_ONLY" -eq 0 ]; then
  echo "Stopping the application and sign-in server…"
  docker compose stop api worker authentik-server authentik-worker
fi

echo "Restoring the application database…"
pg_replace_db postgres "$DB_USER" "$DB_NAME" "$TMP/database.dump"

if [ "$HAVE_AK" -eq 1 ]; then
  echo "Restoring the sign-in database…"
  pg_replace_db authentik-postgres "$AK_DB_USER" "$AK_DB_NAME" "$TMP/authentik.dump"
fi

if [ "$HAVE_EV" -eq 1 ]; then
  echo "Restoring evidence…"
  evidence_import < "$TMP/evidence.tar"
fi

if [ "$DATA_ONLY" -eq 1 ]; then
  echo "Restore complete (data plane only)."
  exit 0
fi

echo "Starting the sign-in server and the application…"
docker compose start authentik-server authentik-worker
docker compose start api worker
if [ -d "$TMP/branding" ]; then
  echo "Restoring branding…"
  docker compose cp "$TMP/branding/." api:/app/data/branding \
    || echo "  (branding not restored — re-upload it in the admin settings)"
fi
sleep 15
./bin/doctor.sh || { echo "Restore finished but the health check is RED — copy the output above to support."; exit 1; }
echo "Restore complete."
