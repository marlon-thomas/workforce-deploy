#!/usr/bin/env bash
# Self-test for the scripts under the appliance controller (Workforce ADR-0032, slice 2c): a helper container
# gets the project's one-off labels and a project network there, and nothing extra on today's host layout;
# the ADR-0031 helper hands no folder to anyone there; the branding copy doesn't use `compose cp` there.
# Hermetic: no Docker, no network.
#   ./bin/tests/controller-mode-test.sh      exit 0 = all pass
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"

PASS=0; FAILN=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAILN=$((FAILN+1)); printf 'FAIL: %s: expected [%s] got [%s]\n' "$1" "$3" "$2"; fi; }

unset WORKFORCE_CONTROLLER
helper_args workforce-deploy_back
check "host layout: no extra arguments" "${#HELPER[@]}" 0

export WORKFORCE_CONTROLLER=1 COMPOSE_PROJECT_NAME=workforce-deploy
helper_args workforce-deploy_back
check "controller: labels and network" "${HELPER[*]}" "--label com.docker.compose.project=workforce-deploy --label com.docker.compose.oneoff=True --network workforce-deploy_back"
helper_args none
check "controller: no network" "${HELPER[*]: -1}" "none"

# The ADR-0031 helper, under the controller, chowns nothing and needs the mailbox the controller made.
grep -q 'if \[ "${WORKFORCE_CONTROLLER:-}" = 1 \]; then' "$HERE/../server-actions.sh"; check "server-actions: a controller branch in ensure_mailbox" "$?" 0
# Every `docker run` in the backup's off-site copy passes the helper arguments.
runs="$(grep -c 'docker run --rm' "$HERE/../backup.sh")"
with="$(grep -c 'docker run --rm[ -i]* "${HELPER\[@\]}"' "$HERE/../backup.sh")"
check "backup.sh: every docker run has the helper arguments" "$with" "$runs"
grep -q 'exec -T api tar -C /app/data/branding' "$HERE/../backup.sh"; check "backup.sh: branding by exec under the controller" "$?" 0

echo "controller-mode self-test: ${PASS} passed, ${FAILN} failed"
[ "$FAILN" -eq 0 ]
