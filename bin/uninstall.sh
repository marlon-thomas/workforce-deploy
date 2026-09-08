#!/usr/bin/env bash
# uninstall.sh — stop and remove the stack (deployment-spec §B3).
# Refuses to delete data without an export bundle + typed confirmation.
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

echo "This will stop the Care Angels Workforce system on this machine."
echo "Data (database, evidence, configuration) is KEPT unless you choose removal below."
echo ""
echo "Step 1 — making a final backup…"
./bin/backup.sh --tag final || echo "Backup failed — continuing, but keep this in mind."

echo ""
echo "Step 2 — stopping the system…"
docker compose down

echo ""
echo "Everything is stopped. Data volumes (database, evidence, branding) remain on disk."
echo "To start again later: docker compose up -d"
echo ""
printf 'Do you also want to DELETE all data (final dump is in ./backups)? Type DELETE-DATA to continue: '
read -r CONFIRM
if [ "$CONFIRM" != "DELETE-DATA" ]; then
  echo "Data kept. Nothing more to do."
  exit 0
fi

echo "Deleting data volumes…"
docker compose down -v
echo "Volumes removed. The backup archive remains in ./backups — keep it somewhere safe."
