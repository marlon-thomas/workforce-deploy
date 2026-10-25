#!/usr/bin/env bash
# restore-drill.sh — prove a backup archive restores (deployment-spec D-DEP9).
#
# Runs on an operator/CI machine with Incus — NEVER on an appliance. Launches
# a throw-away Incus system container, brings up only the data plane
# (postgres, authentik-postgres, object-storage), restores the archive with
# the SAME bin/restore.sh customers use (--data-only), then checks that every
# part actually landed:
#   app DB      flyway history present (successful migrations > 0)
#   sign-in DB  authentik users present
#   evidence    object count in the bucket == file count in evidence.tar
# The container is deleted afterwards (KEEP=1 keeps it for inspection).
#
#   GHCR_TOKEN_FILE=~/.config/workforce-dev/ghcr-read.token \
#     ./bin/restore-drill.sh backups/2026-10-24_020000.tar.gz
#
# GHCR_TOKEN_FILE: a read:packages token (the MinIO images are private GHCR
# packages). Read from the file and fed to `docker login --password-stdin`
# inside the drill container — never placed on a command line.
# Optional: GHCR_USER (default marlon-thomas), DRILL_IMAGE (default
# images:ubuntu/24.04), DRILL_NAME, KEEP=1.
#
# Exit 0 = PASS. Scheduling (nightly, against the newest off-site archive) is
# deliberately left to the operator — see RUNBOOK.md.
set -euo pipefail
cd "$(dirname "$0")/.."
BUNDLE="$(pwd)"

ARCHIVE="${1:-}"
[ -n "$ARCHIVE" ] && [ -f "$ARCHIVE" ] || { echo "Usage: GHCR_TOKEN_FILE=<file> ./bin/restore-drill.sh <archive.tar.gz>"; exit 1; }
[ -n "${GHCR_TOKEN_FILE:-}" ] && [ -r "${GHCR_TOKEN_FILE/#\~/$HOME}" ] \
  || { echo "GHCR_TOKEN_FILE must name a readable file holding a read:packages token."; exit 1; }
command -v incus >/dev/null 2>&1 || { echo "incus is required on this machine."; exit 1; }

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mXX\033[0m %s\n' "$*"; exit 1; }

NAME="${DRILL_NAME:-workforce-drill-$(date +%Y%m%d-%H%M%S)}"
IMAGE="${DRILL_IMAGE:-images:ubuntu/24.04}"
W=/opt/workforce-deploy
cleanup() {
  if [ "${KEEP:-0}" = "1" ]; then
    echo "KEEP=1: drill container '$NAME' left running (incus delete -f $NAME when done)."
  else
    incus delete -f "$NAME" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
in_c() { incus exec "$NAME" -- "$@"; }

say "Launching scratch container $NAME ($IMAGE)…"
# nesting + syscall interception: Docker inside an unprivileged container.
incus launch "$IMAGE" "$NAME" \
  -c security.nesting=true \
  -c security.syscalls.intercept.mknod=true \
  -c security.syscalls.intercept.setxattr=true >/dev/null
for _ in $(seq 1 60); do
  in_c sh -c 'getent hosts get.docker.com >/dev/null 2>&1' && break
  sleep 2
done

say "Installing Docker inside the drill container…"
in_c sh -c 'apt-get update -qq >/dev/null && apt-get install -y -qq curl ca-certificates openssl >/dev/null \
  && curl -fsSL https://get.docker.com | sh >/dev/null 2>&1'
in_c docker compose version >/dev/null || fail "Docker compose did not install in the drill container."
in_c sh -c "docker login ghcr.io -u '${GHCR_USER:-marlon-thomas}' --password-stdin >/dev/null" \
  < "${GHCR_TOKEN_FILE/#\~/$HOME}" || fail "GHCR login failed in the drill container (token needs read:packages)."

say "Shipping the deploy bundle (compose.yaml + bin/) and the archive…"
in_c mkdir -p "$W/secrets" "$W/backups"
tar -C "$BUNDLE" -cf - compose.yaml bin | in_c tar -xf - -C "$W"
incus file push "$ARCHIVE" "$NAME$W/backups/drill.tar.gz" >/dev/null

# Drill-only configuration: fresh throw-away credentials (dumps restore with
# --no-owner as the drill's own superuser, so production passwords are never
# needed), placeholder hostnames, and the image refs compose requires.
in_c sh -c "cd $W && umask 077 && cat > .env <<'ENV'
ENV_NAME=drill
APP_HOSTNAME=drill.invalid
AUTH_HOSTNAME=drill-auth.invalid
DB_NAME=workforce
DB_USER=workforce_app
MINIO_BUCKET=workforce-evidence
AK_DB_NAME=authentik
AK_DB_USER=authentik
OIDC_ISSUER=https://drill-auth.invalid/application/o/workforce/
API_IMAGE=drill.invalid/not-pulled
APP_VERSION=0.0.0
ENV
for s in db_password minio_access minio_secret oidc_client_id oidc_jwks_uri oidc_client_secret \
         ak_db_password ak_secret push_vapid_public push_vapid_private; do
  openssl rand -hex 24 > secrets/\$s
done"

say "Starting the data plane (postgres, authentik-postgres, object-storage)…"
in_c sh -c "cd $W && docker compose up -d --wait postgres authentik-postgres object-storage" \
  || fail "Data plane did not become healthy in the drill container."

say "Restoring with bin/restore.sh --data-only…"
in_c sh -c "cd $W && ./bin/restore.sh --yes --data-only backups/drill.tar.gz" \
  || fail "restore.sh FAILED on this archive — the backup is NOT restorable."

say "Verifying what landed…"
RESULT=0
check() { # check <label> <ok?> <detail>
  if [ "$2" = ok ]; then printf ' PASS %-12s %s\n' "$1" "$3"; else printf ' FAIL %-12s %s\n' "$1" "$3"; RESULT=1; fi
}
FW="$(in_c sh -c "cd $W && docker compose exec -T postgres psql -U workforce_app -d workforce -tAc \
  \"select count(*) || ' (latest ' || coalesce(max(version),'none') || ')' from flyway_schema_history where success\"" 2>/dev/null || echo 0)"
case "$FW" in 0*|'') check "app DB" fail "no successful migrations restored" ;; *) check "app DB" ok "$FW migrations" ;; esac

AKU="$(in_c sh -c "cd $W && docker compose exec -T authentik-postgres psql -U authentik -d authentik -tAc \
  'select count(*) from authentik_core_user'" 2>/dev/null || echo "")"
if tar -xzOf "$ARCHIVE" authentik.dump >/dev/null 2>&1; then
  case "$AKU" in ''|0) check "sign-in DB" fail "no authentik users restored" ;; *) check "sign-in DB" ok "$AKU users" ;; esac
else
  check "sign-in DB" fail "archive has no authentik.dump (pre-fix backup format)"
fi

if tar -xzOf "$ARCHIVE" evidence.tar >/dev/null 2>&1; then
  WANT="$(tar -xzOf "$ARCHIVE" evidence.tar | tar -tvf - | grep -c '^-' || true)"
  # shellcheck disable=SC2016  # expanded inside the init container
  GOT="$(in_c sh -c "cd $W && docker compose run --rm --no-deps -T --entrypoint /bin/sh init -c '
    mc alias set local http://object-storage:9000 \"\$(cat /run/secrets/minio_access)\" \"\$(cat /run/secrets/minio_secret)\" >/dev/null
    mc ls --recursive local/\${MINIO_BUCKET} | wc -l'" 2>/dev/null | tr -dc '0-9')"
  [ "${GOT:-x}" = "$WANT" ] && check "evidence" ok "$GOT objects" \
                            || check "evidence" fail "bucket has ${GOT:-?} objects, archive has $WANT"
else
  check "evidence" fail "archive has no evidence.tar (pre-fix backup format)"
fi

[ "$RESULT" -eq 0 ] && say "RESTORE DRILL PASSED for $ARCHIVE" || fail "RESTORE DRILL FAILED for $ARCHIVE"
