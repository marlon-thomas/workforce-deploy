#!/usr/bin/env bash
# update.sh — upgrade to a new pinned version (deployment-spec §B3).
#
#   1. full backup (fail-closed)              — the archive restore.sh can use
#   2. pull the new images                    — old version keeps serving
#   3. stop api + worker                      — no writes from here on
#   4. pre-update DB dump                     — the exact rollback point
#   5. pin the new version, run migrate EXPLICITLY (never implicitly via
#      `compose up`, whose depends_on would migrate before we could dump)
#   6. start the new version, health check
#   on failure at 5/6: restore the pre-update dump, re-pin the previous
#   version, start it. Rolling back the image alone against a migrated schema
#   is NOT a rollback. Never crosses major versions silently.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .env ] || { echo "No deploy/.env — run install.sh first."; exit 1; }
# shellcheck disable=SC1091
. ./.env
# shellcheck source=lib/common.sh
. ./bin/lib/common.sh
use_docker_socket

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
  echo "Usage: ./bin/update.sh <version>     (e.g. ./bin/update.sh 0.2.0)"
  echo "Announced versions are listed in the release notes; 'latest' is not allowed here."
  exit 1
fi
[ "$TARGET" = "latest" ] && { echo "Refusing 'latest' — pin a real version so rollback stays possible."; exit 1; }

MAJOR_BEFORE="${APP_VERSION%%.*}"; MAJOR_AFTER="${TARGET%%.*}"
if [ "$MAJOR_BEFORE" != "$MAJOR_AFTER" ]; then
  echo "This update changes the major version ($APP_VERSION -> $TARGET)."
  echo "Major upgrades are announced with their own instructions — follow those instead."
  exit 1
fi

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mXX\033[0m %s\n' "$*"; exit 1; }
PREV="$APP_VERSION"

say "Backing up before touching anything…"
./bin/backup.sh --tag pre-update || fail "Backup failed — update aborted (nothing was changed)."

say "Fetching version $TARGET (the current version keeps running meanwhile)…"
APP_VERSION="$TARGET" docker compose pull api worker migrate \
  || fail "Could not fetch $TARGET — update aborted (nothing was changed)."

say "Stopping the application for the upgrade…"
docker compose stop api worker

say "Taking the pre-update database dump (rollback point)…"
umask 077
ROLLBACK_DUMP="backups/pre-update-db-$(date +%Y-%m-%d_%H%M%S).dump"
if ! docker compose exec -T postgres pg_dump -U "${DB_USER}" -d "${DB_NAME}" -Fc > "$ROLLBACK_DUMP" \
   || [ ! -s "$ROLLBACK_DUMP" ]; then
  rm -f "$ROLLBACK_DUMP"
  docker compose start api worker || true
  fail "Could not take the pre-update database dump — update aborted; $PREV restarted, nothing changed."
fi

# rollback <what failed> — DB first, then images. If the DB cannot be put
# back, do NOT start the old version against a half-migrated schema.
rollback() {
  say "$1 — rolling back to $PREV (database restored from the pre-update dump)…"
  docker compose stop api worker || true
  cp -p .env.pre-update .env
  if ! pg_replace_db postgres "${DB_USER}" "${DB_NAME}" "$ROLLBACK_DUMP"; then
    fail "ROLLBACK INCOMPLETE: the database could not be restored, so the application
  was left STOPPED (the old version must not run on a half-migrated schema).
  Restore the full pre-update backup:  ./bin/restore.sh $(ls -1t backups/*-pre-update.tar.gz | head -1)
  then send ./bin/doctor.sh output to support."
  fi
  docker compose up -d || true
  sleep 15
  ./bin/doctor.sh || true
  fail "$1. You are back on $PREV with the database as it was before the update
  (rollback dump kept: $ROLLBACK_DUMP). Send the output above to support."
}

say "Pinning version $TARGET…"
cp -p .env .env.pre-update
sed -i.bak "s|^APP_VERSION=.*|APP_VERSION=$TARGET|" .env

say "Running the database migration…"
docker compose run --rm migrate || rollback "The database migration did not complete"

say "Starting $TARGET…"
docker compose up -d || rollback "The new version would not start"

say "Health check…"
HEALTHY=0
# Same ~2-minute budget as before, but probed every 5s: a fixed 20s sleep before the
# first probe added up to 20s to every update that was already healthy.
DEADLINE=$(( $(date +%s) + 120 ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  sleep 5
  if ./bin/doctor.sh >/dev/null 2>&1; then HEALTHY=1; break; fi
done
./bin/doctor.sh || true
[ "$HEALTHY" -eq 1 ] || rollback "The new version did not pass the health check"

rm -f "$ROLLBACK_DUMP" .env.pre-update
say "Updated to $TARGET successfully. Your pre-update backup is kept in ./backups."
