#!/usr/bin/env bash
# versions.sh — list published suite versions available to THIS box.
# update.sh refuses 'latest' on purpose, so the operator needs the exact
# strings: this reads the stored GHCR credential (~/.docker/config.json —
# the same one install.sh uses) and asks the registry which versions exist,
# newest first. Run as the service user on the appliance.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .env ] || { echo "No .env — run install.sh first."; exit 1; }
# shellcheck disable=SC1091
. ./.env

command -v jq >/dev/null 2>&1 || { echo "needs jq (apt-get install -y jq as root, or run as root)"; exit 1; }

IMG_PATH="${API_IMAGE#ghcr.io/}"                 # e.g. marlon-thomas/workforce-suite
AUTH_B64="$(jq -r '.auths["ghcr.io"].auth // empty' "$HOME/.docker/config.json")"
[ -n "$AUTH_B64" ] || { echo "No ghcr.io entry in ~/.docker/config.json — run: docker login ghcr.io"; exit 1; }

TOKEN="$(curl -fsS -H "Authorization: Basic $AUTH_B64" \
  "https://ghcr.io/token?scope=repository:${IMG_PATH}:pull" | jq -r .token)"

echo "Published ${API_IMAGE} versions (newest first; current pin: ${APP_VERSION}):"
curl -fsS -H "Authorization: Bearer $TOKEN" \
  "https://ghcr.io/v2/${IMG_PATH}/tags/list" \
  | jq -r '.tags[]' \
  | sort -V -r \
  | sed -e "s|^${APP_VERSION}$|* ${APP_VERSION}  <- installed here|" \
        -e 's/^\([0-9]/    \1/'
