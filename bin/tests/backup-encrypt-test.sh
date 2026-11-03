#!/usr/bin/env bash
# backup-encrypt-test.sh — hermetic self-test of off-site encryption: the real bin/backup.sh,
# bin/restore.sh and bin/doctor.sh with docker and rsync as fakes on PATH, which keep what reaches
# them. No Docker, no network. Run by bin/ci-validate.sh, and in CI again on alpine:3.20.
# The fail-closed checks always run. Those that need real encryption use a real `age`, and say
# clearly that they were skipped without one; CI's alpine step has it.
#   ./bin/tests/backup-encrypt-test.sh      exit 0 = all pass
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REAL_AGE="$(command -v age || true)"; REAL_KEYGEN="$(command -v age-keygen || true)"
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK:?}"' EXIT
B="$WORK/bundle"; FAKE="$WORK/fake"; SENT="$WORK/sent"
mkdir -p "$B/secrets" "$B/backups" "$FAKE" "$SENT" "$WORK/ev"
cp -r "$HERE/.." "$B/bin"
printf 'image: goauthentik/server:2026.8.1\n' > "$B/compose.yaml"
PLAIN_MARK='STAFF-AND-CARE-RECORDS-PLAINTEXT'
printf '%s\n' "$PLAIN_MARK" > "$WORK/ev/record.txt"
# The server's settings and secrets, all made up here: they go off-site, and never in a local archive.
SECRET_MARK='FICTITIOUS-SECRET-FILE-CONTENTS'
printf '%s' "$SECRET_MARK" > "$B/secrets/db_password"
mkdir -p "$B/secrets/tls"; printf 'fictitious' > "$B/secrets/tls/tls.key"
printf 'interrupted recovery' > "$B/secrets/.recover-registry"

PASS=0; FAILN=0; SKIPPED=0
ok()  { PASS=$((PASS+1)); }
bad() { FAILN=$((FAILN+1)); printf 'FAIL: %s\n' "$*"; }
check() { if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$3] got [$2]"; fi; }
contains() { case "$2" in *"$3"*) ok ;; *) bad "$1: [$3] not in: $2" ;; esac; }
lacks() { case "$2" in *"$3"*) bad "$1: [$3] should not appear in: $2" ;; *) ok ;; esac; }

# --- the fakes
cat > "$FAKE/docker" <<'SH'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "$FAKE_CALLS"
case "$*" in
  *"exec -T postgres pg_dump"*|*"exec -T authentik-postgres pg_dump"*) printf '%s\n' "$FAKE_MARK" ;;
  *"exec -T postgres psql"*|*"exec -T authentik-postgres psql"*) cat > /dev/null ;;
  *pg_restore*) cat > /dev/null; printf 'pg_restore\n' >> "$FAKE_RESTORES" ;;
  *"compose run"*init*"tar -xf -"*) cat > /dev/null; printf 'evidence\n' >> "$FAKE_RESTORES" ;;
  *"compose run"*init*) tar -C "$FAKE_EV" -cf - . ;;
  *"compose stop"*) printf 'stop\n' >> "$FAKE_RESTORES" ;;
  *"compose cp"*) exit 1 ;;
  *"s3 ls"*) cat "$FAKE_SENT/s3-listing" 2>/dev/null ;;
  *get-object*) if [ -f "$FAKE_SENT/s3-unreadable" ]; then exit 1; fi; cat "$FAKE_SENT/s3-object" ;;
  *"s3 cp -"*)
    if [ -f "$FAKE_SENT/s3-fails" ]; then cat > /dev/null; exit 1; fi
    for a in "$@"; do case "$a" in s3://*) dest="$a" ;; esac; done
    printf '%s\n' "$dest" > "$FAKE_SENT/s3-dest"
    cat > "$FAKE_SENT/s3-object" ;;
  # The helper container for a host without age. It isn't here, as if there were no network.
  *alpine:3.20*) cat > /dev/null; exit 125 ;;
esac
exit 0
SH
# In front of the real tar: fails when asked to pack the server's settings, while that's being tested.
REAL_TAR="$(command -v tar)"
cat > "$FAKE/tar" <<SH
#!/usr/bin/env bash
case "\$* " in *" .env secrets "*)
  if [ -f "\$FAKE_SENT/config-unreadable" ]; then echo "tar: secrets/x: Permission denied" >&2; exit 2; fi
  # Readable when first looked at, then not: the read-through passes and the real one fails.
  if [ -f "\$FAKE_SENT/config-fails-later" ]; then
    if [ -f "\$FAKE_SENT/config-read-once" ]; then echo "tar: secrets/x: Permission denied" >&2; exit 2; fi
    touch "\$FAKE_SENT/config-read-once"
  fi ;;
esac
exec "$REAL_TAR" "\$@"
SH
cat > "$FAKE/rsync" <<'SH'
#!/usr/bin/env bash
printf 'rsync %s\n' "$*" >> "$FAKE_CALLS"
if [ -f "$FAKE_SENT/rsync-fails" ]; then exit 1; fi
for a in "$@"; do case "$a" in -*) ;; *) if [ -f "$a" ]; then cp "$a" "$FAKE_SENT/rsync-$(basename "$a")"; fi ;; esac; done
exit 0
SH
# In front of the real age: everything it's asked to do goes in the log, which must never hold a key.
cat > "$FAKE/age" <<SH
#!/usr/bin/env bash
printf 'age %s\n' "\$*" >> "\$FAKE_CALLS"
exec "$REAL_AGE" "\$@"
SH
chmod +x "$FAKE/docker" "$FAKE/rsync" "$FAKE/age" "$FAKE/tar"
[ -n "$REAL_AGE" ] || rm -f "$FAKE/age"

export PATH="$FAKE:$PATH"
export DOCKER_HOST="unix://$WORK/no-such.sock" FAKE_CALLS="$WORK/calls" FAKE_SENT="$SENT" FAKE_EV="$WORK/ev" \
       FAKE_MARK="$PLAIN_MARK" FAKE_RESTORES="$WORK/restores"
: > "$FAKE_CALLS"; : > "$FAKE_RESTORES"

# With a real age, always a real key pair, made for this run. Without one, a well-formed public key.
RECIPIENT=age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
if [ -n "$REAL_KEYGEN" ]; then
  "$REAL_KEYGEN" -o "$WORK/key.txt" 2>/dev/null
  "$REAL_KEYGEN" -o "$WORK/other-key.txt" 2>/dev/null
  RECIPIENT="$("$REAL_KEYGEN" -y "$WORK/key.txt")"
fi

set_env() { # set_env <target> <recipient>
  cat > "$B/.env" <<ENV
DB_NAME=workforce
DB_USER=workforce_app
AK_DB_NAME=authentik
AK_DB_USER=authentik
APP_VERSION=0.0.0
APP_HOSTNAME=app.example.test
AUTH_HOSTNAME=auth.example.test
BACKUP_TARGET=$1
BACKUP_ENCRYPT_RECIPIENT=$2
AWS_ACCESS_KEY_ID=AKIAEXAMPLE
AWS_SECRET_ACCESS_KEY=exampleawssecret
AWS_DEFAULT_REGION=eu-west-2
ENV
  find "$SENT" -type f -delete
  find "$B/backups" -maxdepth 1 -name '*.tar.gz' -delete
  : > "$FAKE_CALLS"; : > "$FAKE_RESTORES"
}
run_backup() { ( cd "$B" && bash ./bin/backup.sh "$@" ) > "$WORK/out" 2>&1; }
nothing_sent() { # nothing_sent <label>
  lacks "$1: rsync not run" "$(cat "$FAKE_CALLS")" "rsync "
  lacks "$1: S3 not run" "$(cat "$FAKE_CALLS")" "s3 cp"
  check "$1: nothing arrived" "$(find "$SENT" -type f | wc -l | tr -d ' ')" 0
}
RSYNC_T='backup@vault.example.test:'; S3_T='s3://bucket/some/path'
BAD_FORMAT='ssh-ed25519 not-a-recipient'
BAD_CHECKSUM="age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"

# --- 1. no recipient: nothing leaves, the log says why, the local backup stands
for T in "$RSYNC_T" "$S3_T"; do
  set_env "$T" ""
  run_backup; RC=$?
  check "no recipient, $T: backup succeeds" "$RC" 0
  nothing_sent "no recipient, $T"
  contains "no recipient, $T: why" "$(cat "$WORK/out")" "Off-site copy failed — nothing was sent: BACKUP_ENCRYPT_RECIPIENT isn't set"
  contains "no recipient, $T: never unencrypted" "$(cat "$WORK/out")" "never leave this server unencrypted"
  check "no recipient, $T: local archive" "$(find "$B/backups" -maxdepth 1 -name '*.tar.gz' | wc -l | tr -d ' ')" 1
  run_backup --offsite-only; RC=$?
  check "no recipient, $T: the test copy fails" "$RC" 3
  nothing_sent "no recipient, $T, test copy"
done

# --- 2. a bad recipient is the same
set_env "$RSYNC_T" "'$BAD_FORMAT'"
run_backup; check "bad format: backup succeeds" "$?" 0
nothing_sent "bad format"
contains "bad format: why" "$(cat "$WORK/out")" "isn't a usable age public key"
set_env "$S3_T" "'$BAD_FORMAT'"
run_backup; nothing_sent "bad format, S3"
# Well formed with a wrong checksum: real age refuses it; without age, the helper can't encrypt.
set_env "$RSYNC_T" "$BAD_CHECKSUM"
run_backup; check "bad checksum: backup succeeds" "$?" 0
nothing_sent "bad checksum"
set_env "$S3_T" "$BAD_CHECKSUM"
run_backup; nothing_sent "bad checksum, S3"
contains "bad checksum, S3: says so" "$(cat "$WORK/out")" "Off-site copy failed — nothing was sent"

# --- 3. no age here and the helper container can't start: fail closed, with a good recipient too
export AGE_BIN=/nonexistent/age
for T in "$RSYNC_T" "$S3_T"; do
  set_env "$T" "$RECIPIENT"
  run_backup; check "no age at all: backup succeeds" "$?" 0
  nothing_sent "no age at all, $T"
  contains "no age at all, $T: says so" "$(cat "$WORK/out")" "age can't encrypt"
done
unset AGE_BIN

# --- 4. no target: no off-site code runs at all
set_env "" ""
run_backup; check "no target: backup succeeds" "$?" 0
nothing_sent "no target"
lacks "no target: no complaint" "$(cat "$WORK/out")" "Off-site"
run_backup --offsite-only; check "no target: the test copy says so" "$?" 4

# --- the local archive never holds the server's settings or secrets, whatever else happens
set_env "" ""
run_backup
LOCAL_ONLY="$(find "$B/backups" -maxdepth 1 -name '*.tar.gz' | head -1)"
LOCAL_NAMES="$(tar -tzf "$LOCAL_ONLY")"
lacks "local archive: no .env" "$LOCAL_NAMES" ".env"
lacks "local archive: no secrets/" "$LOCAL_NAMES" "secrets"
check "local archive: no secret anywhere in it" "$(gzip -dc "$LOCAL_ONLY" | grep -c "$SECRET_MARK")" 0
check "local archive: nothing from .env in it" "$(gzip -dc "$LOCAL_ONLY" | grep -c exampleawssecret)" 0

# --- 5. the doctor's row and its --gate (the real doctor.sh; everything it reaches is a fake)
doctor_row() { # doctor_row [args] — the off-site row from --plain
  ( cd "$B" && bash ./bin/doctor.sh --plain --smoke "$@" 2>/dev/null ) | awk -F'\t' '$2 == "off-site backup" { print $1 "|" $3 }'
}
set_env "$RSYNC_T" ""
ROW="$(doctor_row)"
contains "doctor, no recipient: FAIL" "$ROW" "FAIL|nothing is going off-site"
contains "doctor, no recipient: plain words" "$ROW" "BACKUP_ENCRYPT_RECIPIENT isn't set"
contains "doctor --gate, no recipient: at most WARN" "$(doctor_row --gate)" "WARN|nothing is going off-site"
set_env "$S3_T" "'$BAD_FORMAT'"
contains "doctor, bad recipient: FAIL" "$(doctor_row)" "FAIL|nothing is going off-site: BACKUP_ENCRYPT_RECIPIENT isn't a usable"
set_env "$S3_T" "$RECIPIENT"
contains "doctor, recipient set: OK" "$(doctor_row)" "OK|configured (S3, encrypted)"
printf 'Dumping the application database…\nOff-site copy failed — backup is still local.\nRetention applied\n' > "$B/backups/cron.log"
contains "doctor, last copy failed: WARN" "$(doctor_row)" "WARN|the last off-site copy failed"
printf 'Testing the off-site copy with x…\nCopying off-site to y…\nOff-site copy test finished.\n' >> "$B/backups/cron.log"
contains "doctor, a good test copy clears it" "$(doctor_row)" "OK|configured (S3, encrypted)"
find "$B/backups" -maxdepth 1 -name cron.log -delete
set_env "" ""
contains "doctor, no target: still a WARN" "$(doctor_row)" "WARN|no BACKUP_TARGET"

# --- what follows needs real encryption
if [ -z "$REAL_AGE" ] || [ -z "$REAL_KEYGEN" ]; then
  SKIPPED=1
  echo "SKIP: age isn't installed here, so the encrypted round trips did not run (CI's alpine step runs them)."
else
  decrypt() { "$REAL_AGE" -d -i "$WORK/key.txt" "$1"; }
  sum() { sha256sum | cut -d' ' -f1; }
  newest_local() { find "$B/backups" -maxdepth 1 -name '*.tar.gz' | sort | tail -n 1; }
  send_dir_state() { if [ -e "$B/backups/.offsite-send" ]; then echo left; else echo gone; fi; }

  # --- 6. rsync: only ciphertext reaches it, under the new name, and it decrypts to the same bytes
  set_env "$RSYNC_T" "$RECIPIENT"
  run_backup; check "rsync: backup succeeds" "$?" 0
  LOCAL="$(newest_local)"; NAME="$(basename "$LOCAL")"
  SENT_FILE="$SENT/rsync-$NAME.age"
  check "rsync: sent as <name>.tar.gz.age" "$([ -f "$SENT_FILE" ] && echo yes)" yes
  check "rsync: one file arrived" "$(find "$SENT" -type f | wc -l | tr -d ' ')" 1
  check "rsync: age's format" "$(head -c 21 "$SENT_FILE")" "age-encryption.org/v1"
  check "rsync: not the plain archive" "$(cmp -s "$SENT_FILE" "$LOCAL" && echo same || echo different)" different
  # The data first, byte for byte; the second gzip member after it holds the settings and secrets.
  first_part() { head -c "$(wc -c < "$LOCAL")" | sum; }
  config_part() { tail -c +"$(( $(wc -c < "$LOCAL") + 1 ))"; }
  check "rsync: the data, byte for byte" "$(decrypt "$SENT_FILE" | first_part)" "$(sum < "$LOCAL")"
  CONFIG_NAMES="$(decrypt "$SENT_FILE" | config_part | tar -tzf -)"
  contains "rsync: the copy holds .env" "$CONFIG_NAMES" ".env"
  contains "rsync: the copy holds the secrets" "$CONFIG_NAMES" "secrets/db_password"
  contains "rsync: and the folders under them" "$CONFIG_NAMES" "secrets/tls/tls.key"
  lacks "rsync: not what an interrupted recovery left" "$CONFIG_NAMES" ".recover"
  check "rsync: the secret is in there" "$(decrypt "$SENT_FILE" | config_part | tar -xzOf - secrets/db_password)" "$SECRET_MARK"
  check "rsync: no secret readable in the file" "$(grep -c "$SECRET_MARK" "$SENT_FILE")" 0
  check "rsync: only the right key opens it" "$("$REAL_AGE" -d -i "$WORK/other-key.txt" "$SENT_FILE" 2>/dev/null | wc -c | tr -d ' ')" 0
  check "rsync: the local archive still holds none" "$(gzip -dc "$LOCAL" | grep -c "$SECRET_MARK")" 0
  check "rsync: the local archive is still gzip" "$(head -c 2 "$LOCAL" | od -An -tx1 | tr -d ' \n')" 1f8b
  check "rsync: the encrypted file is gone" "$(send_dir_state)" gone
  contains "rsync: to the same place" "$(cat "$FAKE_CALLS")" "$RSYNC_T/backups/"
  contains "rsync: logged as before" "$(cat "$WORK/out")" "Copying off-site to $RSYNC_T"
  check "rsync: the data inside" "$(decrypt "$SENT_FILE" | tar -xzOf - ./database.dump 2>/dev/null || decrypt "$SENT_FILE" | tar -xzOf - database.dump)" "$PLAIN_MARK"

  # --- 7. the test copy sends the same way; a failed rsync leaves nothing behind
  find "$SENT" -name 'rsync-*' -delete
  run_backup --offsite-only; check "rsync test copy: works" "$?" 0
  check "rsync test copy: sent encrypted" "$(head -c 21 "$SENT_FILE")" "age-encryption.org/v1"
  contains "rsync test copy: sends the same thing" "$(decrypt "$SENT_FILE" | config_part | tar -tzf -)" "secrets/db_password"
  touch "$SENT/rsync-fails"
  run_backup --offsite-only; check "rsync fails: the test copy says so" "$?" 3
  check "rsync fails: the encrypted file is gone" "$(send_dir_state)" gone
  find "$SENT" -name rsync-fails -delete

  # An unreadable secret mustn't stop the data leaving, or pass for a good copy.
  touch "$SENT/config-unreadable"
  find "$SENT" -name 'rsync-*' -delete
  run_backup --offsite-only; check "unreadable config: the test copy fails" "$?" 3
  contains "unreadable config: in words" "$(cat "$WORK/out")" "Off-site copy failed — the data went off-site"
  check "unreadable config: the data still went" "$(decrypt "$SENT_FILE" | sum)" "$(sum < "$LOCAL")"
  find "$SENT" -name config-unreadable -delete

  # --- 8. S3: a stream, ciphertext only, and no file on the way
  set_env "$S3_T" "$RECIPIENT"
  run_backup; check "S3: backup succeeds" "$?" 0
  LOCAL="$(newest_local)"; NAME="$(basename "$LOCAL")"
  check "S3: sent as <name>.tar.gz.age" "$(cat "$SENT/s3-dest")" "$S3_T/$NAME.age"
  check "S3: age's format" "$(head -c 21 "$SENT/s3-object")" "age-encryption.org/v1"
  check "S3: the data, byte for byte" "$(decrypt "$SENT/s3-object" | first_part)" "$(sum < "$LOCAL")"
  contains "S3: the copy holds the secrets" "$(decrypt "$SENT/s3-object" | config_part | tar -tzf -)" "secrets/db_password"
  check "S3: no temp file" "$(send_dir_state)" gone
  check "S3: nothing left in secrets/" "$(find "$B/secrets" -maxdepth 1 -name '.config-manifest' | wc -l | tr -d ' ')" 0
  # It goes wrong part-way, with the data already on its way: not a credentials problem.
  touch "$SENT/config-fails-later"
  run_backup --offsite-only; check "S3, the config fails part-way: the test copy fails" "$?" 3
  contains "S3, the config fails part-way: in words" "$(cat "$WORK/out")" "Off-site copy failed — the server's settings couldn't be read"
  lacks "S3, the config fails part-way: not the credentials" "$(cat "$WORK/out")" "credentials"
  check "S3, the config fails part-way: nothing left in secrets/" "$(find "$B/secrets" -maxdepth 1 -name '.config-manifest' | wc -l | tr -d ' ')" 0
  find "$SENT" \( -name config-fails-later -o -name config-read-once \) -delete
  run_backup --offsite-only; check "S3: a good copy again" "$?" 0
  touch "$SENT/s3-fails"
  run_backup --offsite-only; check "S3 fails: the test copy says so" "$?" 3
  contains "S3 fails: blames the credentials" "$(cat "$WORK/out")" "credentials"
  find "$SENT" -name s3-fails -delete
  cp "$SENT/s3-object" "$WORK/copy.tar.gz.age"; cp "$LOCAL" "$WORK/plain.tar.gz"

  # --- 9. --verify-key
  KEY_LINE="$(grep '^AGE-SECRET-KEY-' "$WORK/key.txt")"
  verify() { ( cd "$B" && bash ./bin/backup.sh --verify-key "$@" ) > "$WORK/out" 2>&1; }
  set_env "$RSYNC_T" "$RECIPIENT"
  verify "$WORK/key.txt"; check "verify: the right key" "$?" 0
  contains "verify: says what it proved" "$(cat "$WORK/out")" "matches BACKUP_ENCRYPT_RECIPIENT"
  contains "verify: says rsync can't read back" "$(cat "$WORK/out")" "can't read copies back"
  verify "$WORK/other-key.txt"; check "verify: the wrong key" "$?" 6
  contains "verify: wrong key in plain words" "$(cat "$WORK/out")" "does NOT match"
  verify - < "$WORK/key.txt"; check "verify: from stdin" "$?" 0
  verify "$WORK/key.txt" "$WORK/copy.tar.gz.age"; check "verify: a fetched copy opens" "$?" 0
  contains "verify: a fetched copy, in words" "$(cat "$WORK/out")" "this key opens"
  printf 'not a key\n' > "$WORK/nokey.txt"
  verify "$WORK/nokey.txt"; check "verify: not a key file" "$?" 1
  verify "$WORK/no-such-file"; check "verify: no such file" "$?" 1
  lacks "the key is never on a command line" "$(cat "$FAKE_CALLS")" "AGE-SECRET-KEY"
  lacks "the key is never printed" "$(cat "$WORK/out")" "AGE-SECRET-KEY-1"
  : > "$WORK/empty"
  # A copy made for another key: the pair is fine, but this copy needs the older key.
  "$REAL_AGE" -r "$("$REAL_KEYGEN" -y "$WORK/other-key.txt")" -o "$WORK/old.tar.gz.age" "$WORK/plain.tar.gz"
  verify "$WORK/key.txt" "$WORK/old.tar.gz.age"; check "verify: a copy for an older key" "$?" 6
  contains "verify: an older key, in words" "$(cat "$WORK/out")" "different key"
  verify "$WORK/key.txt" "$WORK/empty"; check "verify: not a copy" "$?" 1
  # Only the start of a big copy is read: age stops at the cut, and that's still an answer.
  head -c 1048576 /dev/urandom > "$WORK/big.bin"; gzip -c "$WORK/big.bin" > "$WORK/big.tar.gz"
  "$REAL_AGE" -r "$RECIPIENT" -o "$WORK/big.tar.gz.age" "$WORK/big.tar.gz"
  verify "$WORK/key.txt" "$WORK/big.tar.gz.age"; check "verify: the start of a big copy" "$?" 0
  # An S3 target that can be read back, then one that can't
  set_env "$S3_T" "$RECIPIENT"
  printf '2026-11-01 02:00:00 9 2026-11-01_020000.tar.gz\n2026-11-02 02:00:00 9 2026-11-02_020000.tar.gz.age\n2026-11-01 02:00:00 9 2026-11-01_020000.tar.gz.age\n' > "$SENT/s3-listing"
  cp "$WORK/copy.tar.gz.age" "$SENT/s3-object"
  verify "$WORK/key.txt"; check "verify, S3: the newest copy" "$?" 0
  contains "verify, S3: opened it" "$(cat "$WORK/out")" "opens the newest copy"
  contains "verify, S3: the newest encrypted one" "$(cat "$FAKE_CALLS")" "some/path/2026-11-02_020000.tar.gz.age"
  cp "$WORK/old.tar.gz.age" "$SENT/s3-object"
  verify "$WORK/key.txt"; check "verify, S3: for an older key" "$?" 6
  touch "$SENT/s3-unreadable"
  verify "$WORK/key.txt"; check "verify, S3: write-only is fine" "$?" 0
  contains "verify, S3: write-only, in words" "$(cat "$WORK/out")" "normal with a write-only key"
  set_env "$RSYNC_T" ""
  verify "$WORK/key.txt"; check "verify: no recipient to check" "$?" 1

  # --- 10. restore
  restore() { ( cd "$B" && bash ./bin/restore.sh "$@" ) > "$WORK/out" 2>&1; }
  set_env "" ""
  restore --yes --data-only --identity "$WORK/key.txt" "$WORK/copy.tar.gz.age"; check "restore: the right key, from a file" "$?" 0
  contains "restore: verified" "$(cat "$WORK/out")" "Backup verified."
  contains "restore: restored" "$(cat "$WORK/out")" "Restore complete"
  contains "restore: the databases went back" "$(cat "$FAKE_RESTORES")" "pg_restore"
  : > "$FAKE_RESTORES"; : > "$FAKE_CALLS"
  restore --yes --data-only --identity - "$WORK/copy.tar.gz.age" < "$WORK/key.txt"; check "restore: the right key, from stdin" "$?" 0
  contains "restore from stdin: restored" "$(cat "$WORK/out")" "Restore complete"
  lacks "restore: no key in the output" "$(cat "$WORK/out")" "AGE-SECRET-KEY"
  lacks "restore: no key on a command line" "$(cat "$FAKE_CALLS")" "AGE-SECRET-KEY"
  printf '%s\nRESTORE\n' "$KEY_LINE" > "$WORK/answers"
  restore --data-only --identity - "$WORK/copy.tar.gz.age" < "$WORK/answers"; check "restore: the key, then the confirmation" "$?" 0
  printf '%s\nno\n' "$KEY_LINE" > "$WORK/answers"
  restore --data-only --identity - "$WORK/copy.tar.gz.age" < "$WORK/answers"; check "restore: declined" "$?" 1

  : > "$FAKE_RESTORES"; : > "$FAKE_CALLS"
  restore --yes --data-only --identity "$WORK/other-key.txt" "$WORK/copy.tar.gz.age"; check "restore: the wrong key" "$?" 1
  contains "restore: the wrong key, in words" "$(cat "$WORK/out")" "This key doesn't open this backup"
  contains "restore: the wrong key changes nothing" "$(cat "$WORK/out")" "Nothing was changed"
  check "restore: the wrong key touches no data" "$(cat "$FAKE_RESTORES")" ""
  lacks "restore: the wrong key starts nothing" "$(cat "$FAKE_CALLS")" "compose"

  restore --yes --data-only "$WORK/copy.tar.gz.age"; check "restore: no key given" "$?" 1
  contains "restore: no key given, in words" "$(cat "$WORK/out")" "This backup is encrypted"
  restore --yes --data-only --identity "$WORK/nokey.txt" "$WORK/copy.tar.gz.age"; check "restore: not a key" "$?" 1
  contains "restore: not a key, in words" "$(cat "$WORK/out")" "no age private key"
  check "restore: and nothing is touched" "$(cat "$FAKE_RESTORES")" ""

  # Cut short, and not encrypted at all
  head -c 400 "$WORK/copy.tar.gz.age" > "$WORK/cut.tar.gz.age"
  restore --yes --data-only --identity "$WORK/key.txt" "$WORK/cut.tar.gz.age"; check "restore: cut short" "$?" 1
  contains "restore: cut short, in words" "$(cat "$WORK/out")" "damaged or incomplete"
  printf 'x' > "$WORK/not-encrypted.tar.gz.age"
  restore --yes --data-only --identity "$WORK/key.txt" "$WORK/not-encrypted.tar.gz.age"; check "restore: named .age, isn't" "$?" 1
  check "restore: still nothing touched" "$(cat "$FAKE_RESTORES")" ""

  # A copy with the config in: every check above reads the data only, and the config stays unread.
  check "restore: the copy holds the config" "$(decrypt "$WORK/copy.tar.gz.age" | tail -c +"$(( $(wc -c < "$WORK/plain.tar.gz") + 1 ))" | tar -tzf - | grep -c 'secrets/db_password')" 1
  printf 'changed since the backup' > "$B/secrets/db_password"
  restore --yes --data-only --identity "$WORK/key.txt" "$WORK/copy.tar.gz.age"; check "restore: a copy with config" "$?" 0
  check "restore: --data-only ignores the config" "$(cat "$B/secrets/db_password")" "changed since the backup"
  printf '%s' "$SECRET_MARK" > "$B/secrets/db_password"
  # A copy from before the config was added: one gzip member, as they all were.
  "$REAL_AGE" -r "$RECIPIENT" -o "$WORK/older-format.tar.gz.age" "$WORK/plain.tar.gz"
  restore --yes --data-only --identity "$WORK/key.txt" "$WORK/older-format.tar.gz.age"; check "restore: an older copy" "$?" 0
  contains "restore: an older copy, verified" "$(cat "$WORK/out")" "Backup verified."
  : > "$FAKE_RESTORES"

  # The same check as a plain one: a decrypted archive that doesn't match its MANIFEST is refused.
  mkdir "$WORK/tamper"; tar -xzf "$WORK/plain.tar.gz" -C "$WORK/tamper"
  printf 'tampered' >> "$WORK/tamper/database.dump"
  tar -czf "$WORK/tampered.tar.gz" -C "$WORK/tamper" .
  "$REAL_AGE" -r "$RECIPIENT" -o "$WORK/tampered.tar.gz.age" "$WORK/tampered.tar.gz"
  restore --yes --data-only --identity "$WORK/key.txt" "$WORK/tampered.tar.gz.age"; check "restore: fails its MANIFEST" "$?" 1
  contains "restore: the MANIFEST, in words" "$(cat "$WORK/out")" "do not match its MANIFEST"
  check "restore: and nothing is touched there either" "$(cat "$FAKE_RESTORES")" ""

  # A plain archive restores as it always did, and a key given for it does no harm.
  restore --yes --data-only "$WORK/plain.tar.gz"; check "restore: a plain archive" "$?" 0
  contains "restore: a plain archive, restored" "$(cat "$WORK/out")" "Restore complete"
  restore --yes --data-only --identity "$WORK/key.txt" "$WORK/plain.tar.gz"; check "restore: a plain archive with a key" "$?" 0
  contains "restore: says it wasn't needed" "$(cat "$WORK/out")" "wasn't needed"
fi

echo "backup encryption self-test: ${PASS} passed, ${FAILN} failed$([ "$SKIPPED" -eq 1 ] && echo ', encrypted round trips SKIPPED (no age)')"
[ "$FAILN" -eq 0 ]
