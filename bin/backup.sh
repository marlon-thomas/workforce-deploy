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
# Optional off-site copy (BACKUP_TARGET), always encrypted first to BACKUP_ENCRYPT_RECIPIENT, the
# public half of an age key pair whose private half is kept off this server. No usable recipient
# means no off-site copy, never a plaintext one. Local archives stay as they are, on the same disk as
# the live data. RUNBOOK, "Off-site backup targets".
#
#   ./bin/backup.sh [--tag NAME]     make an archive, copy it off-site, apply retention
#   ./bin/backup.sh --offsite-only   copy the newest archive off-site by the same code and say whether
#                                    that worked. Exit 3 it failed, 4 no target set, 5 no archive yet
#   ./bin/backup.sh --verify-key <key file, or - to paste it> [<a copy fetched from the target>]
#                                    prove the private key matches the recipient, without a restore.
#                                    Exit 0 it does, 6 it doesn't, 1 it couldn't check
# One at a time: exit 75 if another backup is running. A tagged one, which an update or upgrade is
# waiting on, waits for it instead.
set -euo pipefail
cd "$(dirname "$0")/.."

TAG=""; OFFSITE_ONLY=0; VERIFY_KEY=""; VERIFY_COPY=""
case "${1:-}" in
  --tag) TAG="-${2}"; shift 2 ;;
  --offsite-only) OFFSITE_ONLY=1; shift ;;
  --verify-key)
    VERIFY_KEY="${2:-}"; VERIFY_COPY="${3:-}"
    [ -n "$VERIFY_KEY" ] || { echo "Usage: ./bin/backup.sh --verify-key <key file, or - to paste it> [<a copy fetched from the target>]"; exit 1; }
    ;;
esac

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
# The encrypted file an rsync copy sends from, for as long as that takes. Only the holder of the lock
# below touches it.
SEND_DIR="backups/.offsite-send"

# age_start_opens — stdin is the start of an encrypted archive, or all of it. Does the key open it?
# 0 yes, 6 wrong key, 1 something else is wrong. It's a gzip file inside, so its first two bytes say so.
age_start_opens() {
  local hex
  hex="$(head -c 262144 | age_decrypt 2>"$VERIFY_TMP/err" | head -c 2 | od -An -tx1 | tr -d ' \n')" || true
  if [ "$hex" = 1f8b ]; then return 0; fi
  if grep -q 'no identity matched' "$VERIFY_TMP/err"; then return 6; fi
  return 1
}

# s3_newest_copy_start — the first bytes of the newest encrypted copy on an S3 target, or nothing and
# non-zero if these credentials can't read it, which is what a write-only key should do.
s3_newest_copy_start() {
  local bucket_path bucket prefix newest
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
  newest="$(docker run --rm -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION \
    "$AWS_CLI_IMAGE" s3 ls "${BACKUP_TARGET%/}/" 2>/dev/null \
    | awk '{ print $NF }' | { grep -E '\.tar\.gz\.age$' || true; } | sort | tail -n 1)" || return 1
  [ -n "$newest" ] || return 1
  echo "Reading the start of ${newest} from the target…" >&2
  bucket_path="${BACKUP_TARGET#s3://}"; bucket_path="${bucket_path%/}"
  bucket="${bucket_path%%/*}"
  prefix=""; [ "$bucket_path" = "$bucket" ] || prefix="${bucket_path#*/}/"
  # shellcheck disable=SC2016  # expanded inside the container
  docker run --rm -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION --log-driver none \
    --entrypoint sh "$AWS_CLI_IMAGE" -c \
    'aws s3api get-object --bucket "$1" --key "$2" --range bytes=0-262143 /tmp/start >/dev/null && cat /tmp/start' \
    sh "$bucket" "${prefix}${newest}" 2>/dev/null
}

# verify_key <key source> [<fetched copy>] — exits. Encrypts a test blob to the recipient and opens it
# with the key, which proves the pair; then, if a real copy can be reached, opens the start of that.
verify_key() {
  local src="$1" copy="${2:-}" problem probe got rc=0 what
  read_age_identity "$src" || exit 1
  problem="$(offsite_encryption_problem "${BACKUP_ENCRYPT_RECIPIENT:-}")"
  if [ -n "$problem" ]; then echo "Can't check the key: ${problem}."; exit 1; fi
  VERIFY_TMP="$(mktemp -d)"; trap 'rm -rf "$VERIFY_TMP"' EXIT
  probe="workforce-key-check-$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"
  got="$(printf '%s' "$probe" | age_encrypt "$BACKUP_ENCRYPT_RECIPIENT" 2>/dev/null | age_decrypt 2>/dev/null)" || got=""
  if [ "$got" != "$probe" ]; then
    echo "This key does NOT match BACKUP_ENCRYPT_RECIPIENT: it can't open the off-site copies being made now."
    echo "Find the right key, or rotate to a new pair (RUNBOOK, \"Off-site backup targets\")."
    exit 6
  fi
  echo "OK: this key matches BACKUP_ENCRYPT_RECIPIENT (checked with a test blob)."
  if [ -n "$copy" ]; then
    [ -f "$copy" ] || { echo "No such file: $copy"; exit 1; }
    what="$copy"
    age_start_opens < "$copy" || rc=$?
  else
    case "${BACKUP_TARGET:-}" in
      s3://*)
        what="the newest copy on the target"
        if ! s3_newest_copy_start > "$VERIFY_TMP/start" || [ ! -s "$VERIFY_TMP/start" ]; then
          echo "Couldn't read a copy back from the target, which is normal with a write-only key."
          echo "To check a real copy, fetch one with your own access and add its path to this command."
          exit 0
        fi
        age_start_opens < "$VERIFY_TMP/start" || rc=$?
        ;;
      *:*)
        echo "A write-only rsync key can't read copies back. To check a real copy, fetch one with your own"
        echo "access to the target and add its path to this command."
        exit 0
        ;;
      *) exit 0 ;;
    esac
  fi
  case "$rc" in
    0) echo "OK: this key opens ${what}." ;;
    6) echo "This key does NOT open ${what}: it was encrypted for a different key, perhaps from before a rotation."; exit 6 ;;
    *) echo "Couldn't read ${what}: it isn't an encrypted Workforce backup, or it's damaged."; exit 1 ;;
  esac
  exit 0
}

if [ -n "$VERIFY_KEY" ]; then verify_key "$VERIFY_KEY" "$VERIFY_COPY"; fi

# Nothing else takes this lock, and it goes when the process does, however it ended.
if { exec 8>>backups/.backup.lock; } 2>/dev/null && command -v flock >/dev/null 2>&1; then
  if [ -n "$TAG" ]; then
    flock -w 3600 8 || { echo "Another backup has been running for over an hour; not waiting any longer."; exit 75; }
  elif ! flock -n 8; then
    echo "Another backup is already running."; exit 75
  fi
fi
trap 'rm -rf "$SEND_DIR"' EXIT

# offsite_copy ARCHIVE — encrypt it and send it as <name>.tar.gz.age. Says what happened, and returns
# non-zero when it didn't work. Nothing is ever sent if it can't be encrypted. Works from the backup
# container as well as from the host: S3 is a stream through stdin, with no bind mount and no second
# copy on disk. rsync can't read a pipe, and its write-only key (rrsync -wo) allows nothing else, so
# there it's an encrypted file beside the archive, removed as soon as the copy ends.
offsite_copy() {
  local problem sent
  problem="$(offsite_encryption_problem "${BACKUP_ENCRYPT_RECIPIENT:-}")"
  if [ -z "$problem" ] && ! printf 'x' | age_encrypt "$BACKUP_ENCRYPT_RECIPIENT" >/dev/null 2>&1; then
    problem="age can't encrypt to BACKUP_ENCRYPT_RECIPIENT here"
  fi
  if [ -n "$problem" ]; then
    echo "Off-site copy failed — nothing was sent: ${problem}, and backups never leave this server unencrypted (backup is still local). RUNBOOK.md, \"Off-site backup targets\", has the steps."
    return 1
  fi
  sent="$(basename "$1").age"
  case "$BACKUP_TARGET" in
    s3://*)
      echo "Copying off-site to ${BACKUP_TARGET}…"
      # .env sets these but doesn't export them, and `docker run -e NAME` only passes an exported value.
      export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
      age_encrypt "$BACKUP_ENCRYPT_RECIPIENT" < "$1" | docker run --rm -i -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION \
        "$AWS_CLI_IMAGE" s3 cp - "${BACKUP_TARGET%/}/${sent}" --sse AES256 || {
        echo "Off-site copy failed — check the backup target credentials (backup is still local)."
        return 1
      }
      ;;
    *:*)
      rm -rf "$SEND_DIR"; mkdir -p "$SEND_DIR"
      if ! age_encrypt "$BACKUP_ENCRYPT_RECIPIENT" < "$1" > "$SEND_DIR/$sent" || ! is_age_file "$SEND_DIR/$sent"; then
        rm -rf "$SEND_DIR"
        echo "Off-site copy failed — encrypting it didn't finish, so nothing was sent; is the disk full? (backup is still local)."
        return 1
      fi
      echo "Copying off-site to ${BACKUP_TARGET}…"
      # An SSH target needs a key: secrets/backup_ssh_key (RUNBOOK), since cron has no agent or home.
      RSYNC_SSH=(); if [ -s secrets/backup_ssh_key ]; then RSYNC_SSH=(-e "ssh -i secrets/backup_ssh_key -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=backups/.known_hosts"); fi
      rsync -az "${RSYNC_SSH[@]}" "$SEND_DIR/$sent" "$BACKUP_TARGET/backups/" || {
        rm -rf "$SEND_DIR"
        echo "Off-site copy failed — backup is still local."
        return 1
      }
      rm -rf "$SEND_DIR"
      ;;
    *)
      echo "Off-site copy failed — BACKUP_TARGET is neither s3://… nor host:path (backup is still local)."
      return 1
      ;;
  esac
}

if [ "$OFFSITE_ONLY" -eq 1 ]; then
  [ -n "${BACKUP_TARGET:-}" ] || { echo "No off-site target is set (BACKUP_TARGET in .env)."; exit 4; }
  NEWEST=""
  for p in backups/*.tar.gz; do
    [ -e "$p" ] || continue
    if [ -z "$NEWEST" ] || [ "$p" -nt "$NEWEST" ]; then NEWEST="$p"; fi
  done
  [ -n "$NEWEST" ] || { echo "No backup to copy yet."; exit 5; }
  echo "Testing the off-site copy with ${NEWEST}…"
  RC=0; offsite_copy "$NEWEST" || RC=3
  echo "Off-site copy test finished."
  exit "$RC"
fi

STAMP="$(date +%Y-%m-%d_%H%M%S)"
OUT="backups/${STAMP}${TAG}.tar.gz"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" "${OUT}.part" "$SEND_DIR"' EXIT

echo "Dumping the application database…"
docker compose exec -T postgres pg_dump -U "${DB_USER}" -d "${DB_NAME}" -Fc \
  > "${TMP}/database.dump"
[ -s "${TMP}/database.dump" ] || { echo "Application database dump is empty — backup FAILED."; exit 1; }

echo "Dumping the sign-in (authentik) database…"
docker compose exec -T authentik-postgres pg_dump -U "${AK_DB_USER}" -d "${AK_DB_NAME}" -Fc \
  > "${TMP}/authentik.dump"
[ -s "${TMP}/authentik.dump" ] || { echo "Sign-in database dump is empty — backup FAILED."; exit 1; }

# Staff email (mail-calendar-spec §11): the mail server's database, when this installation has one.
if docker compose exec -T postgres psql -U "${DB_USER}" -d "${DB_NAME}" -tAc "SELECT 1 FROM pg_database WHERE datname = 'stalwart'" 2>/dev/null | grep -q 1; then
  echo "Dumping the staff mail database…"
  docker compose exec -T postgres pg_dump -U "${DB_USER}" -d stalwart -Fc > "${TMP}/mail.dump"
  [ -s "${TMP}/mail.dump" ] || { echo "Staff mail database dump is empty — backup FAILED."; exit 1; }
fi

echo "Copying evidence…"
evidence_export > "${TMP}/evidence.tar" \
  || { echo "Evidence copy FAILED — no archive written (evidence is never silently dropped)."; exit 1; }

PARTS="MANIFEST database.dump authentik.dump evidence.tar"
[ -s "${TMP}/mail.dump" ] && PARTS="${PARTS} mail.dump"
if docker compose cp api:/app/data/branding "${TMP}/branding" >/dev/null 2>&1; then
  PARTS="${PARTS} branding"
else
  echo "  (no branding assets captured — api not running or none uploaded)"
fi

{
  echo "created=${STAMP}"
  echo "app_version=${APP_VERSION:-unknown}"
  echo "authentik_image=$(grep -m1 -oE 'goauthentik/server:[0-9.]+' compose.yaml || echo unknown)"
  # What the sign-in database was actually on (the pin can be ahead mid-upgrade); restore.sh
  # refuses to load it into a different authentik version.
  AK_VER="$(authentik_version)"
  echo "authentik_version=${AK_VER:-unknown}"
  ( cd "$TMP" && sha256sum database.dump authentik.dump evidence.tar )
  if [ -s "${TMP}/mail.dump" ]; then ( cd "$TMP" && sha256sum mail.dump ); fi
} > "${TMP}/MANIFEST"

# shellcheck disable=SC2086  # PARTS is a word list on purpose
tar -czf "${OUT}.part" -C "$TMP" ${PARTS}
mv "${OUT}.part" "$OUT"
chmod 600 "$OUT"
echo "Wrote $OUT ($(du -h "$OUT" | cut -f1))"

# --- off-site (optional) -----------------------------------------------------
# A failed copy is reported and the local archive stands: this isn't a failed backup.
if [ -n "${BACKUP_TARGET:-}" ]; then
  offsite_copy "$OUT" || true
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
