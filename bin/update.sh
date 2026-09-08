#!/usr/bin/env bash
# update.sh — upgrade to a new pinned version (deployment-spec §B3).
# Backup first (fail-closed), pull, migrate, restart, health check,
# automatic rollback on red. Never crosses major versions silently.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .env ] || { echo "No deploy/.env — run install.sh first."; exit 1; }
# shellcheck disable=SC1091
. ./.env

# Rootless-aware docker context: when run as root on a rootless install, talk to the
# service user's daemon socket (compose exec etc. need the right socket).
resolve_docker_context() {
  if [ "$(id -u)" -eq 0 ] && [ -S "/home/workforce_app_sa/.docker/run/docker.sock" ]; then
    export DOCKER_HOST="unix:///home/workforce_app_sa/.docker/run/docker.sock"
  fi
}
resolve_docker_context

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

say "Backing up before touching anything…"
./bin/backup.sh --tag pre-update || fail "Backup failed — update aborted (nothing was changed)."

say "Pinning version $TARGET…"
sed -i.bak "s|^APP_VERSION=.*|APP_VERSION=$TARGET|" .env

say "Fetching the new version and starting it…"
docker compose pull api worker
if ! docker compose up -d; then
  say "Start failed — rolling back to $APP_VERSION…"
  sed -i.bak "s|^APP_VERSION=.*|APP_VERSION=$APP_VERSION|" .env
  docker compose up -d
  fail "The new version would not start. You are back on $APP_VERSION; your data is untouched. Send ./bin/doctor.sh output to support."
fi

say "Running the database migration…"
if ! docker compose run --rm migrate; then
  say "Migration failed — rolling back to $APP_VERSION…"
  cp .env.bak .env
  docker compose up -d
  fail "The database migration did not complete. You are back on $APP_VERSION. Send ./bin/doctor.sh output to support."
fi

say "Health check…"
sleep 20
if ./bin/doctor.sh; then
  say "Updated to $TARGET successfully. Your pre-update backup is kept in ./backups."
else
  say "Health check is red — rolling back to $APP_VERSION automatically…"
  cp .env.bak .env
  docker compose up -d
  sleep 15
  ./bin/doctor.sh || true
  fail "The new version did not pass the health check. You are back on $APP_VERSION and your data is safe.
  Send the output above to support."
fi
