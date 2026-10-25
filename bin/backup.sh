#!/usr/bin/env bash
# backup.sh — nightly (cron in the stack) and on-demand backup
# (deployment-spec §B3/B4). One archive holds everything restore.sh puts back:
#   database.dump   application DB   (pg_dump -Fc)
#   authentik.dump  sign-in DB       (users, MFA, OIDC provider + client secret)
#   evidence.tar    the whole evidence bucket (MinIO)
#   branding/       admin-uploaded branding assets (best effort)
#   MANIFEST        versions + sha256 of each part
# Every part except branding is mandatory: a missing part FAILS the backup —
# an archive that silently lacks evidence is worse than no archive.
# Retention: nightly archives 14 daily / 8 weekly / 12 monthly; tagged
# archives (--tag final, …) are kept, except the routine pre-update /
# pre-authentik-upgrade ones (newest 5 of each).
# Optional encrypted off-site copy (BACKUP_TARGET).
set -euo pipefail
cd "$(dirname "$0")/.."

TAG=""
[ "${1:-}" = "--tag" ] && { TAG="-${2}"; shift 2; }

[ -f .env ] || { echo "No deploy/.env — run install.sh first."; exit 1; }
# shellcheck disable=SC1091
. ./.env
# shellcheck source=lib/common.sh
. ./bin/lib/common.sh
use_docker_socket

# Off-site S3 client, digest-pinned (ADR-0015) — `:latest` meant every
# nightly run could execute different, unreviewed bytes holding the bucket
# credentials. tag: 2.22.35 (manifest-list digest verified against Docker Hub).
AWS_CLI_IMAGE="amazon/aws-cli@sha256:6977c83ae3dc99f28fcf8276b9ea5eec33833cd5be40574b34112e98113ec7a2"

umask 077
mkdir -p backups
STAMP="$(date +%Y-%m-%d_%H%M%S)"
OUT="backups/${STAMP}${TAG}.tar.gz"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" "${OUT}.part"' EXIT

echo "Dumping the application database…"
docker compose exec -T postgres pg_dump -U "${DB_USER}" -d "${DB_NAME}" -Fc \
  > "${TMP}/database.dump"
[ -s "${TMP}/database.dump" ] || { echo "Application database dump is empty — backup FAILED."; exit 1; }

echo "Dumping the sign-in (authentik) database…"
docker compose exec -T authentik-postgres pg_dump -U "${AK_DB_USER}" -d "${AK_DB_NAME}" -Fc \
  > "${TMP}/authentik.dump"
[ -s "${TMP}/authentik.dump" ] || { echo "Sign-in database dump is empty — backup FAILED."; exit 1; }

echo "Copying evidence…"
evidence_export > "${TMP}/evidence.tar" \
  || { echo "Evidence copy FAILED — no archive written (evidence is never silently dropped)."; exit 1; }

PARTS="MANIFEST database.dump authentik.dump evidence.tar"
if docker compose cp api:/app/data/branding "${TMP}/branding" >/dev/null 2>&1; then
  PARTS="${PARTS} branding"
else
  echo "  (no branding assets captured — api not running or none uploaded)"
fi

{
  echo "created=${STAMP}"
  echo "app_version=${APP_VERSION:-unknown}"
  echo "authentik_image=$(grep -m1 -oE 'goauthentik/server:[0-9.]+' compose.yaml || echo unknown)"
  ( cd "$TMP" && sha256sum database.dump authentik.dump evidence.tar )
} > "${TMP}/MANIFEST"

# shellcheck disable=SC2086  # PARTS is a word list on purpose
tar -czf "${OUT}.part" -C "$TMP" ${PARTS}
mv "${OUT}.part" "$OUT"
chmod 600 "$OUT"
echo "Wrote $OUT ($(du -h "$OUT" | cut -f1))"

# --- off-site (optional) -----------------------------------------------------
# Streamed through stdin: no host bind mount, so this works from the nightly
# backup container as well as from the host.
if [ -n "${BACKUP_TARGET:-}" ]; then
  case "$BACKUP_TARGET" in
    s3://*)
      echo "Copying off-site to ${BACKUP_TARGET}…"
      docker run --rm -i -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION \
        "$AWS_CLI_IMAGE" s3 cp - "${BACKUP_TARGET%/}/$(basename "$OUT")" --sse AES256 < "$OUT" || \
        echo "Off-site copy failed — check the backup target credentials (backup is still local)."
      ;;
    *:*)
      echo "Copying off-site to ${BACKUP_TARGET}…"
      rsync -az "$OUT" "$BACKUP_TARGET/backups/" || echo "Off-site copy failed — backup is still local."
      ;;
  esac
fi

# --- retention ---------------------------------------------------------------
# Nightly (untagged) archives: keep the newest per day for 14 days, per ISO
# week for 8 weeks, per month for 12 months. Dates come from the file names,
# not mtimes (rsync/restore can reset those).
# Portable listing (busybox in the backup container has no find -printf);
# grep's no-match exit is not an error under pipefail here.
archives() { for p in backups/*.tar.gz; do if [ -e "$p" ]; then printf '%s\n' "${p##*/}"; fi; done; }
nightly_prune_list() {
  archives | { grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}\.tar\.gz$' || true; } | sort -r \
    | while read -r f; do
        d="${f%%_*}"
        printf '%s %s %s %s\n' "$f" "$d" "$(date -d "$d" +%G-W%V)" "${d%-*}"
      done \
    | awk '{ keep = 0
             if (!($2 in D)) { D[$2] = 1; if (++nd <= 14) keep = 1 }
             if (!($3 in W)) { W[$3] = 1; if (++nw <= 8)  keep = 1 }
             if (!($4 in M)) { M[$4] = 1; if (++nm <= 12) keep = 1 }
             if (!keep) print $1 }'
}
nightly_prune_list | while read -r old; do rm -f "backups/$old"; done
# Routine safety-net archives from update.sh / upgrade-authentik.sh: newest 5
# of each. Any other tag (final, manual, …) is never pruned automatically.
for t in pre-update pre-authentik-upgrade; do
  archives | { grep -E "^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}-${t}\.tar\.gz$" || true; } | sort -r \
    | tail -n +6 | while read -r old; do rm -f "backups/$old"; done
done
echo "Retention applied (nightly: 14 daily / 8 weekly / 12 monthly; tagged archives kept)."
