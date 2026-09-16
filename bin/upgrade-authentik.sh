#!/usr/bin/env bash
# upgrade-authentik.sh — walk the supported upgrade ladder on THIS box.
#
# authentik does not support downgrades and forbids skipping major (year)
# lines: the docs require stepping every minor line (latest patch) in order
# — workforce-deploy issue #1. This script encodes that ladder and refuses
# to jump; each step must pass health + discovery before the next begins.
#
# Run as root on the appliance (it drives the service user's rootless docker
# like update.sh does). A pre-flight backup is mandatory and automatic.
#
# Usage: ./bin/upgrade-authentik.sh [target]     (default target: 2026.8.2)
set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
. ./.env

# Rootless-aware docker context (same resolution as update.sh)
resolve_docker_context() {
  if [ "$(id -u)" -eq 0 ] && [ -S "/home/workforce_app_sa/.docker/run/docker.sock" ]; then
    export DOCKER_HOST="unix:///home/workforce_app_sa/.docker/run/docker.sock"
  elif [ "$(id -u)" -ne 0 ] && [ -z "${DOCKER_HOST:-}" ]; then
    for s in "$HOME/.docker/run/docker.sock" "/run/user/$(id -u)/docker.sock"; do
      if [ -S "$s" ]; then export DOCKER_HOST="unix://$s"; export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"; break; fi
    done
  fi
}
resolve_docker_context

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mXX\033[0m %s\n' "$*"; exit 1; }

CURRENT_FULL="$(docker exec workforce-deploy-authentik-server-1 printenv AUTHENTIK_BOOTSTRAPPED_VERSION 2>/dev/null || true)"
# The running version is stamped in the image tag; read it from compose (authoritative pin)
CURRENT_TAG="$(grep -m1 -oE 'goauthentik/server:[0-9.]+' compose.yaml | cut -d: -f2)"
TARGET="${1:-2026.8.2}"

# The supported ladder: every minor line, latest patch, in order (issue #1).
LADDER=(2025.2.4 2025.4.4 2025.6.4 2025.8.6 2025.10.4 2025.12.6 2026.2.7 2026.5.7 2026.8.2)

# Where do we start? First ladder entry strictly newer than the current pin.
STEPS=()
for v in "${LADDER[@]}"; do
  if [[ "$(printf '%s\n%s\n' "$CURRENT_TAG" "$v" | sort -V | head -1)" == "$CURRENT_TAG" && "$CURRENT_TAG" != "$v" ]]; then
    STEPS+=("$v")
  fi
done

if [ "${#STEPS[@]}" -eq 0 ]; then
  say "authentik pin $CURRENT_TAG is already at/after every ladder entry — nothing to do."
  exit 0
fi
if [[ "${STEPS[-1]}" != "$TARGET" && "$TARGET" != "2026.8.2" ]]; then
  fail "target $TARGET is not the ladder end; edit the LADDER if you know better."
fi

say "authentik ladder: $CURRENT_TAG -> ${STEPS[*]}"
say "Backing up BEFORE anything (authentik does not support downgrades)…"
./bin/backup.sh --tag pre-authentik-upgrade || fail "backup failed — upgrade aborted, nothing touched."

step_ok() { # $1 = tag — gates on the signals that actually exist on this
  # topology: the images' own healthchecks (9000 is never published to the
  # host on a rootless daemon, so a host-side curl can only ever fail — the
  # first ladder run learned that the hard way) + OIDC discovery through the
  # edge, which proves gateway, TLS and issuer scheme end to end.
  local tries=0
  while true; do
    sleep 10
    tries=$((tries + 1))
    local up
    up="$(docker ps --filter name=workforce-deploy-authentik-server --filter name=workforce-deploy-authentik-worker --filter health=healthy --format '{{.Names}}' | wc -l)"
    if [ "$up" -ge 2 ]; then
      local code
      code="$(curl -sk -o /dev/null -w '%{http_code}' "https://${AUTH_HOSTNAME}/application/o/workforce/.well-known/openid-configuration" || echo 0)"
      [ "$code" = "200" ] && return 0
    fi
    [ "$tries" -ge 60 ] && return 1
  done
}

for VER in "${STEPS[@]}"; do
  say "Step: $CURRENT_TAG -> $VER"
  sed -i "s|image: ghcr.io/goauthentik/server:[0-9.]*|image: ghcr.io/goauthentik/server:$VER|g" compose.yaml
  docker compose pull authentik-server authentik-worker >/dev/null 2>&1 || true
  docker compose up -d authentik-postgres ak-redis >/dev/null
  docker compose up -d authentik-server authentik-worker
  if step_ok "$VER"; then
    say "  $VER healthy + discovery OK through the edge."
    CURRENT_TAG="$VER"
  else
    docker logs --tail 40 workforce-deploy-authentik-server-1 2>&1 | tail -25 || true
    fail "step $VER did not become healthy within 10 minutes. The pin is still on $VER — inspect the logs above, fix, restore from the pre-authentik-upgrade backup if needed, then re-run."
  fi
done

say "Ladder complete at $CURRENT_TAG. Final assertions…"
# Blueprint must re-apply cleanly on the new engine (managed-flow slugs, scope
# mappings, provider schema all drift between years — this catches it).
sleep 60
BP="$(docker exec workforce-deploy-authentik-worker-1 python /manage.py shell -c "
from authentik.blueprints.models import BlueprintInstance as B
print(next(iter(B.objects.filter(path='workforce-app.yaml').values_list('status', flat=True)), 'missing'))" 2>/dev/null | tail -1)"
if [ "$BP" != "successful" ]; then
  docker logs --tail 30 workforce-deploy-authentik-worker-1 2>&1 | tail -15 || true
  fail "blueprint status on $CURRENT_TAG is '$BP' (expected successful) — managed-flow slugs or provider schema likely changed; fix the blueprint, re-run the playbook (apply is deterministic), then re-run this script with no steps remaining."
fi

say "authentik is on $CURRENT_TAG, blueprint applied, discovery live through the edge."
say "Now verify RP-Initiated Logout return-to-app (issue #14/#1): sign out from the app → you should land back at the app root."
