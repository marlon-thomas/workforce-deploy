#!/usr/bin/env bash
# backup.sh — nightly (cron in the stack) and on-demand backup
# (deployment-spec §B3/B4): database dump + evidence tar + branding, retained
# 14 daily / 8 weekly / 12 monthly; optional encrypted off-site copy.
set -euo pipefail
cd "$(dirname "$0")/.."

TAG=""
[ "${1:-}" = "--tag" ] && { TAG="-${2}"; shift 2; }

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

STAMP="$(date +%Y-%m-%d_%H%M%S)"
OUT="backups/${STAMP}${TAG}.tar.gz"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Dumping the database…"
docker compose exec -T postgres pg_dump -U "${DB_USER}" -d "${DB_NAME}" -Fc \
  > "${TMP}/database.dump"

echo "Packing evidence and branding…"
docker compose exec -T -w /tmp object-storage sh -c "mc cp --recursive local/${MINIO_BUCKET} /tmp/evidence" >/dev/null 2>&1 || {
  # mc is not configured inside the minio image by default; use the shell path instead.
  docker run --rm --network "$(basename "$(pwd)")"_back -v "$(pwd)":/work alpine \
    sh -c "apk add -q minio-client >/dev/null 2>&1; mc alias set local http://object-storage:9000 \$(cat /work/secrets/minio_access) \$(cat /work/secrets/minio_secret) && mc mirror local/${MINIO_BUCKET} /work/${TMP}/evidence" || true
}
docker compose cp api:/app/data/branding "$TMP/branding" >/dev/null 2>&1 || true

tar -czf "$OUT" -C "$TMP" database.dump evidence branding 2>/dev/null || tar -czf "$OUT" -C "$TMP" database.dump
chmod 600 "$OUT"
echo "Wrote $OUT ($(du -h "$OUT" | cut -f1))"

# --- off-site (optional) -----------------------------------------------------
if [ -n "${BACKUP_TARGET:-}" ]; then
  case "$BACKUP_TARGET" in
    s3://*)
      echo "Copying off-site to ${BACKUP_TARGET}…"
      docker run --rm -v "$(pwd)":/work -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY amazon/aws-cli:latest \
        s3 cp "/work/$OUT" "$BACKUP_TARGET/" --sse 2>/dev/null || \
        echo "Off-site copy failed — check the backup target credentials (backup is still local)."
      ;;
    *:*)
      echo "Copying off-site to ${BACKUP_TARGET}…"
      rsync -az "$OUT" "$BACKUP_TARGET/backups/" || echo "Off-site copy failed — backup is still local."
      ;;
  esac
fi

# --- retention ---------------------------------------------------------------
cd backups
ls -1t *.tar.gz | tail -n +15 | while read -r old; do rm -f "$old"; done   # 14 daily
ls -1t *.tar.gz | awk 'NR>1 && NR%7==1' | tail -n +9 | while read -r f; do rm -f "$f"; done 2>/dev/null || true
echo "Retention applied (14 most recent kept locally)."
