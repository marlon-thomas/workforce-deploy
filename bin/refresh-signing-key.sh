#!/usr/bin/env bash
# refresh-signing-key.sh — make the application trust the key the sign-in server signs with. For when
# ./bin/doctor.sh says they differ, which locks everyone out while everything else looks healthy. It
# happens when a sign-in database comes back from another installation; bin/restore.sh does this itself.
# Restarts the api and worker, so signing in and the app are unavailable for a minute or two.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .env ] || { echo "No .env — run install.sh first."; exit 1; }
# shellcheck disable=SC1091
. ./.env
# shellcheck source=lib/common.sh
. ./bin/lib/common.sh
use_docker_socket

export_oidc_signing_key || {
  echo "Couldn't read the key from the sign-in database, so nothing was changed. Is authentik-postgres running?"
  exit 1
}
# Always restarted: the file can be right while the running app still holds an older key.
docker compose up -d --no-deps --force-recreate api worker
echo "Done. The application now trusts the key the sign-in server uses."
