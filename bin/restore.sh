#!/usr/bin/env bash
# restore.sh — restore a backup archive written by backup.sh (deployment-spec §B3).
# Puts back everything the archive holds: application DB, sign-in (authentik)
# DB, evidence bucket, branding. Every dump is verified by restoring it into a
# scratch database FIRST — a bad archive changes nothing.
#
#   ./bin/restore.sh backups/<archive>.tar.gz              (asks for RESTORE)
#   ./bin/restore.sh --identity <key file> <archive>.tar.gz.age
#   ./bin/restore.sh --identity - <archive>.tar.gz.age     (the key on stdin; paste it when asked)
#        an off-site copy: the private key is read from there, never from the command line, and
#        is never written down or logged. The wrong key changes nothing.
#   ./bin/restore.sh --yes --data-only <archive>           (restore-drill.sh only:
#        data plane only — no app/sign-in containers are stopped or started)
#   ./bin/restore.sh --yes --config-restored ...           (bin/recover.sh only: this server's .env
#        and secrets/ came from the same copy)
# An off-site copy also holds the server's .env and secrets/, after the data. Nothing here reads them:
# tar stops at the end of the data. Only bin/recover.sh puts them back.
#
# After a full restore of the sign-in database, the app is made to trust the signing key that came
# back with it. If that key isn't the one this server had, secrets/initial-admin-password can't be relied
# on: it's removed, and this says what to do.
set -euo pipefail
cd "$(dirname "$0")/.."

YES=0; DATA_ONLY=0; IDENTITY=""; CONFIG_RESTORED=0
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) YES=1; shift ;;
    --data-only) DATA_ONLY=1; shift ;;
    --config-restored) CONFIG_RESTORED=1; shift ;;
    --identity)
      [ $# -ge 2 ] || { echo "--identity needs a key file, or - to give the key on stdin."; exit 1; }
      IDENTITY="$2"; shift 2 ;;
    *) break ;;
  esac
done
ARCHIVE="${1:-}"
[ -z "$ARCHIVE" ] && { echo "Usage: ./bin/restore.sh [--identity <key file>] backups/<archive>.tar.gz[.age]"; exit 1; }
[ -f "$ARCHIVE" ] || { echo "No such archive: $ARCHIVE"; exit 1; }
# shellcheck disable=SC1091
[ -f .env ] && . ./.env
# shellcheck source=lib/common.sh
. ./bin/lib/common.sh
use_docker_socket
DB_USER="${DB_USER:-workforce_app}"; DB_NAME="${DB_NAME:-workforce}"
AK_DB_USER="${AK_DB_USER:-authentik}"; AK_DB_NAME="${AK_DB_NAME:-authentik}"

TMP="$(mktemp -d)"; AGE_ERR="$(mktemp)"; trap 'rm -rf "$TMP" "$AGE_ERR"' EXIT
if is_age_file "$ARCHIVE"; then
  if [ -z "$IDENTITY" ]; then
    echo "This backup is encrypted, so it needs the private key kept off the server when it was set up."
    echo "Usage: ./bin/restore.sh --identity <key file> $ARCHIVE    (or --identity - to give the key on stdin)"
    exit 1
  fi
  read_age_identity "$IDENTITY" || { echo "Nothing was changed."; exit 1; }
  set +e
  # Read to the end, past the config tar doesn't look at: age and gzip only vouch for what they've read,
  # and left unread they'd die of a closed pipe.
  age_decrypt < "$ARCHIVE" 2>"$AGE_ERR" | gzip -dc 2>/dev/null \
    | { tar -xf - -C "$TMP" 2>/dev/null; TAR_RC=$?; cat >/dev/null; exit "$TAR_RC"; }
  DECRYPT_RC=("${PIPESTATUS[@]}")
  set -e
  if grep -q 'no identity matched' "$AGE_ERR"; then
    echo "This key doesn't open this backup: it was encrypted for a different key. If the key has been"
    echo "rotated since, this backup needs the older one. Nothing was changed."
    exit 1
  fi
  # All the data came out, and it's what follows that's bad: that can be got past, by hand.
  if [ "${DECRYPT_RC[2]}" -eq 0 ] && [ -f "$TMP/database.dump" ] && { [ "${DECRYPT_RC[0]}" -ne 0 ] || [ "${DECRYPT_RC[1]}" -ne 0 ]; }; then
    echo "This backup is damaged after its data: the data in it looks whole, but the server's settings that follow"
    echo "aren't readable, so it can't be vouched for as it stands. Nothing was changed. Use an earlier copy if you"
    echo "can. If not, RUNBOOK, \"Off-site backup targets\", has \"By hand\": how to get the data out and restore that."
    exit 1
  fi
  if [ "${DECRYPT_RC[0]}" -ne 0 ] || [ "${DECRYPT_RC[1]}" -ne 0 ] || [ "${DECRYPT_RC[2]}" -ne 0 ]; then
    echo "This backup couldn't be decrypted and unpacked: the file is damaged or incomplete, or age"
    echo "couldn't run here (it uses a helper container if it isn't installed). Nothing was changed."
    exit 1
  fi
else
  case "$ARCHIVE" in
    *.age) echo "This file is named as an encrypted backup but isn't one: wrong file, or damaged? Nothing was changed."; exit 1 ;;
  esac
  [ -z "$IDENTITY" ] || echo "NOTE: this backup isn't encrypted, so the key wasn't needed."
  # Only tar's word counts here. Whatever follows the data doesn't matter to a restore, and the MANIFEST
  # below is what vouches for the data: a copy with a damaged tail, unpacked by hand, restores this way.
  set +e
  gzip -dc < "$ARCHIVE" 2>/dev/null | { tar -xf - -C "$TMP"; TAR_RC=$?; cat >/dev/null; exit "$TAR_RC"; }
  PLAIN_RC=("${PIPESTATUS[@]}")
  set -e
  if [ "${PLAIN_RC[1]}" -ne 0 ]; then echo "This archive couldn't be unpacked: it's damaged or incomplete. Nothing was changed."; exit 1; fi
fi
[ -f "$TMP/database.dump" ] || { echo "Archive has no database.dump — wrong file?"; exit 1; }
if [ -f "$TMP/MANIFEST" ]; then
  ( cd "$TMP" && grep -E '^[0-9a-f]{64}  ' MANIFEST | sha256sum -c >/dev/null ) \
    || { echo "Archive contents do not match its MANIFEST checksums — nothing was changed."; exit 1; }
fi
# Archives from before the authentik/evidence fix hold the app DB only.
HAVE_AK=0; [ -f "$TMP/authentik.dump" ] && HAVE_AK=1
HAVE_EV=0; [ -f "$TMP/evidence.tar" ] && HAVE_EV=1
[ "$HAVE_AK" -eq 1 ] || echo "NOTE: this archive has no sign-in database (older backup) — sign-in data is left as is."
[ "$HAVE_EV" -eq 1 ] || echo "NOTE: this archive has no evidence (older backup) — evidence is left as is."

# authentik migrates its database forward only, one line at a time: a sign-in database from
# another version must be loaded into that same version (upgrade-authentik.sh --hold <ver>).
if [ "$HAVE_AK" -eq 1 ] && [ -f "$TMP/MANIFEST" ]; then
  AK_WAS="$(sed -n 's/^authentik_version=//p' "$TMP/MANIFEST")"
  AK_NOW="$(authentik_version)"
  if [ -n "$AK_WAS" ] && [ "$AK_WAS" != unknown ] && [ -n "$AK_NOW" ] && [ "$AK_WAS" != "$AK_NOW" ]; then
    echo "This backup's sign-in database is from authentik $AK_WAS; this box runs $AK_NOW."
    echo "Run ./bin/upgrade-authentik.sh --hold $AK_WAS first, restore, then ./bin/upgrade-authentik.sh."
    echo "Nothing was changed."
    exit 1
  fi
fi

echo "This will REPLACE the current database$( [ "$HAVE_AK" -eq 1 ] && echo ', sign-in database')$( [ "$HAVE_EV" -eq 1 ] && echo ' and evidence') with the contents of:"
echo "  $ARCHIVE"
if [ "$YES" -ne 1 ]; then
  printf 'Type RESTORE to continue: '
  read -r CONFIRM
  [ "$CONFIRM" = "RESTORE" ] || { echo "Aborted."; exit 1; }
fi

echo "Verifying the backup against scratch databases…"
pg_verify_dump postgres "$DB_USER" "$TMP/database.dump" \
  || { echo "The application database in this backup failed verification — nothing was changed. Send it to support."; exit 1; }
if [ "$HAVE_AK" -eq 1 ]; then
  pg_verify_dump authentik-postgres "$AK_DB_USER" "$TMP/authentik.dump" \
    || { echo "The sign-in database in this backup failed verification — nothing was changed. Send it to support."; exit 1; }
fi
if [ "$HAVE_EV" -eq 1 ]; then
  tar -tf "$TMP/evidence.tar" >/dev/null \
    || { echo "The evidence in this backup is unreadable — nothing was changed. Send it to support."; exit 1; }
fi
echo "Backup verified."

if [ "$DATA_ONLY" -eq 0 ]; then
  echo "Stopping the application and sign-in server…"
  docker compose stop api worker authentik-server authentik-worker
fi

echo "Restoring the application database…"
pg_replace_db postgres "$DB_USER" "$DB_NAME" "$TMP/database.dump"

if [ "$HAVE_AK" -eq 1 ]; then
  echo "Restoring the sign-in database…"
  pg_replace_db authentik-postgres "$AK_DB_USER" "$AK_DB_NAME" "$TMP/authentik.dump"
fi

# Staff email (mail-calendar-spec §11): the mail server's database, owned by its own role.
if [ -f "$TMP/mail.dump" ]; then
  if docker compose exec -T postgres psql -U "$DB_USER" -d postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname = 'stalwart'" | grep -q 1; then
    echo "Restoring the staff mail database…"
    docker compose stop mail webmail >/dev/null 2>&1 || true
    docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -q -U "$DB_USER" -d postgres \
      -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='stalwart' AND pid <> pg_backend_pid()" >/dev/null
    docker compose exec -T postgres dropdb -U "$DB_USER" --if-exists stalwart
    docker compose exec -T postgres createdb -U "$DB_USER" -O stalwart stalwart
    docker compose exec -T postgres pg_restore -U "$DB_USER" -d stalwart --no-owner --role=stalwart --exit-on-error < "$TMP/mail.dump"
    docker compose start mail webmail >/dev/null 2>&1 || true
  else
    echo "NOTE: this backup has staff mail, but staff email isn't set up on this box — mail was not restored."
  fi
fi

if [ "$HAVE_EV" -eq 1 ]; then
  echo "Restoring evidence…"
  evidence_import < "$TMP/evidence.tar"
fi

if [ "$DATA_ONLY" -eq 1 ]; then
  echo "Restore complete (data plane only)."
  exit 0
fi

# The data is back, so a recovery under way must never replace it again, however the rest goes: from here
# the site can come up and be used.
if [ -f "$RECOVERY_MARK" ]; then
  env_set stage restored "$RECOVERY_MARK" || echo "WARNING: couldn't note in $RECOVERY_MARK that the data is back. Don't run bin/recover.sh again: remove that file."
fi

# The sign-in database brought its own signing key back. Read straight from that database, so before
# anything that signs or checks a sign-in is running.
KEY_PROBLEM=0
if [ "$HAVE_AK" -eq 1 ]; then
  export_oidc_signing_key || KEY_PROBLEM=1
fi

# A different key means a different sign-in database: another installation's, without its settings
# (Workforce ADR-0026), or this one's from before its key was changed. There's no telling which, so the
# file goes, and the words allow for both. Settled now, as nothing that can fail below should skip it.
if [ "$OIDC_KEY_CHANGED" -eq 1 ] && [ "$CONFIG_RESTORED" -eq 0 ]; then
  rm -f secrets/initial-admin-password
  cat <<'WORDS'

Signing in after this restore:
  The sign-in accounts have come back from the backup, and their signing key isn't the one this server had.
  - secrets/initial-admin-password can't be relied on now, so it has been removed. It held the password this
    server's own install made up, which normally opens nothing after this. If you changed the sign-in key on
    this server yourself, and that password is written down somewhere, it may still be right.
  - Everyone signs in with the password they had when the backup was made, and that includes admin.
  - If nobody knows the admin password: on the sign-in page choose "Forgot your password?" and give the
    recovery address (ADMIN_RECOVERY_EMAIL). A link is emailed there, if email is working and that
    address is outside this server. If that can't work: ./bin/reset-admin.sh
  - RUNBOOK, "Recovering onto a new server", says what else may need setting again.

WORDS
fi

echo "Starting the sign-in server and the application…"
docker compose start authentik-server authentik-worker
if [ "$OIDC_KEY_CHANGED" -eq 1 ]; then
  echo "Signing-in uses the key that came back with the sign-in database; the application now trusts it."
  docker compose up -d --no-deps --force-recreate api worker
else
  docker compose start api worker
fi
if [ -d "$TMP/branding" ]; then
  echo "Restoring branding…"
  docker compose cp "$TMP/branding/." api:/app/data/branding \
    || echo "  (branding not restored — re-upload it in the admin settings)"
fi
sleep 15
./bin/doctor.sh --gate || { echo "Restore finished but the health check is RED — copy the output above to support."; exit 1; }
if [ "$KEY_PROBLEM" -eq 1 ]; then
  echo "Restore finished, but the sign-in key couldn't be read from the restored database, so nobody may be"
  echo "able to sign in. Run ./bin/refresh-signing-key.sh, and if it fails copy the output above to support."
  exit 1
fi
rm -f "$RECOVERY_MARK"
echo "Restore complete."
