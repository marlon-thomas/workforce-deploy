#!/usr/bin/env bash
# backup-encrypt-e2e.sh — off-site encryption end to end, with nothing faked but the databases:
#   1. in an alpine:3.20 container like the backup container (same apk packages for this job): the
#      real bin/backup.sh --offsite-only sends a fake archive through real rsync over real ssh to a
#      local sshd, where the key is restricted with rrsync -wo as RUNBOOK says. It's fetched back with
#      a separate key that can read, decrypted, and compared by checksum. The write-only key must not
#      be able to read it. A plaintext copy must not arrive with no recipient.
#   2. on this machine: the same with no age installed, so through the helper container, which also
#      proves its stdout carries binary data and that its key is in memory only; key generation too.
# Needs Docker and the network (it pulls alpine:3.20 and apk packages). Not one of the hermetic
# *-test.sh scripts, so bin/ci-validate.sh doesn't run it; CI runs it as a step of its own.
#   ./bin/tests/backup-encrypt-e2e.sh      exit 0 = all pass
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK:?}"' EXIT

# ------------------------------------------------------------------ inside the container
cat > "$WORK/inside.sh" <<'INSIDE'
#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAILN=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAILN=$((FAILN+1)); printf 'FAIL: %s: expected [%s] got [%s]\n' "$1" "$3" "$2"; fi; }
contains() { case "$2" in *"$3"*) PASS=$((PASS+1)) ;; *) FAILN=$((FAILN+1)); printf 'FAIL: %s: [%s] not in: %s\n' "$1" "$3" "$2" ;; esac; }

# The target account: one key that can only write, as RUNBOOK says, and one (the operator's own) that can read.
ssh-keygen -A >/dev/null
adduser -D -s /bin/sh backups >/dev/null 2>&1
passwd -u backups >/dev/null 2>&1 || true
sed -i 's/^backups:!:/backups:*:/' /etc/shadow
mkdir -p /srv/backups /home/backups/.ssh /opt/workforce-deploy/secrets /opt/workforce-deploy/backups /root/.ssh
chown backups /srv/backups
ssh-keygen -q -t ed25519 -N '' -f /opt/workforce-deploy/secrets/backup_ssh_key
ssh-keygen -q -t ed25519 -N '' -f /root/.ssh/operator
{
  printf 'command="/usr/bin/rrsync -wo /srv/backups",restrict %s\n' "$(cat /opt/workforce-deploy/secrets/backup_ssh_key.pub)"
  cat /root/.ssh/operator.pub
} > /home/backups/.ssh/authorized_keys
chown -R backups /home/backups/.ssh; chmod 700 /home/backups/.ssh; chmod 600 /home/backups/.ssh/authorized_keys
/usr/sbin/sshd -o PasswordAuthentication=no -o StrictModes=yes

cd /opt/workforce-deploy
cp -r /w/bin bin
TARGET='backups@127.0.0.1:'
env_file() {
  cat > .env <<ENV
BACKUP_TARGET=$TARGET
BACKUP_ENCRYPT_RECIPIENT=$1
ENV
}
export DOCKER_HOST=unix:///nonexistent.sock   # the off-site copy to rsync needs no docker

# The small fake archive, with real gzip inside like the real one
mkdir fake; printf 'fictitious care records\n' > fake/database.dump; head -c 500000 /dev/urandom > fake/evidence.tar
NAME=2026-11-02_020000.tar.gz
tar -czf "backups/$NAME" -C fake .
WANT="$(sha256sum < "backups/$NAME" | cut -d' ' -f1)"

# No recipient: nothing arrives, even by real rsync
env_file ""
RC=0; OUT="$(./bin/backup.sh --offsite-only 2>&1)" || RC=$?
check "no recipient: fails" "$RC" 3
contains "no recipient: says why" "$OUT" "nothing was sent"
check "no recipient: nothing arrived" "$(find /srv/backups -type f | wc -l | tr -d ' ')" 0

# A real pair; the private key stays out of the bundle
age-keygen -o /root/key.txt 2>/dev/null
age-keygen -o /root/other.txt 2>/dev/null
env_file "$(age-keygen -y /root/key.txt)"
RC=0; OUT="$(./bin/backup.sh --offsite-only 2>&1)" || { RC=$?; }
check "encrypted copy: sent through the write-only key" "$RC" 0
[ "$RC" -eq 0 ] || printf '%s\n' "$OUT"
ARRIVED="/srv/backups/backups/$NAME.age"
check "arrived as <name>.tar.gz.age" "$([ -f "$ARRIVED" ] && echo yes)" yes
check "only that arrived" "$(find /srv/backups -type f | wc -l | tr -d ' ')" 1
check "it is ciphertext" "$(head -c 21 "$ARRIVED")" "age-encryption.org/v1"
check "no sign of the plain archive on the target" "$(find /srv/backups -name "$NAME" | wc -l | tr -d ' ')" 0
check "the encrypted file was removed from the server" "$([ -e backups/.offsite-send ] && echo left || echo gone)" gone
check "the local archive stays" "$(sha256sum < "backups/$NAME" | cut -d' ' -f1)" "$WANT"

# The write-only key can't read it back
RC=0; rsync -e "ssh -i secrets/backup_ssh_key -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=backups/.known_hosts" \
  "$TARGET/backups/$NAME.age" /tmp/stolen >/dev/null 2>&1 || RC=$?
check "the write-only key can't fetch it" "$([ "$RC" -ne 0 ] && echo refused || echo fetched)" refused
check "and got nothing" "$([ -e /tmp/stolen ] && echo yes || echo no)" no

# Fetched with the operator's own access, decrypted, compared
mkdir /tmp/fetched
rsync -e "ssh -i /root/.ssh/operator -o StrictHostKeyChecking=accept-new" "backups@127.0.0.1:/srv/backups/backups/$NAME.age" /tmp/fetched/
check "fetched back, decrypted, same checksum" "$(age -d -i /root/key.txt "/tmp/fetched/$NAME.age" | sha256sum | cut -d' ' -f1)" "$WANT"
RC=0; OUT="$(./bin/backup.sh --verify-key /root/key.txt "/tmp/fetched/$NAME.age" 2>&1)" || RC=$?
check "--verify-key: the right key opens the fetched copy" "$RC" 0
contains "--verify-key: says so" "$OUT" "this key opens"
case "$OUT" in *AGE-SECRET-KEY*) check "--verify-key: no key printed" printed none ;; esac
RC=0; ./bin/backup.sh --verify-key /root/other.txt "/tmp/fetched/$NAME.age" >/dev/null 2>&1 || RC=$?
check "--verify-key: the wrong key" "$RC" 6
RC=0; ./bin/backup.sh --verify-key - < /root/key.txt >/dev/null 2>&1 || RC=$?
check "--verify-key: through stdin" "$RC" 0

# restore.sh refuses the wrong key before it needs any database. The right key's whole restore is
# bin/tests/backup-encrypt-test.sh, and the real one with real databases is bin/restore-drill.sh.
RC=0; OUT="$(./bin/restore.sh --identity /root/other.txt "/tmp/fetched/$NAME.age" 2>&1 </dev/null)" || RC=$?
check "restore: the wrong key" "$RC" 1
contains "restore: the wrong key, in words" "$OUT" "This key doesn't open this backup"

printf 'inside the container: %s passed, %s failed\n' "$PASS" "$FAILN"
[ "$FAILN" -eq 0 ]
INSIDE

echo "== real rsync over ssh to a write-only key, in alpine:3.20"
docker run --rm -v "$REPO:/w:ro" -v "$WORK/inside.sh:/inside.sh:ro" alpine:3.20 sh -c \
  'apk add -q --no-progress bash rsync rrsync openssh python3 age >/dev/null && bash /inside.sh'

# ------------------------------------------------------------------ on this machine, without age
echo "== the helper container: no age on this machine"
AGE_BIN=/nonexistent/age
AGE_KEYGEN_BIN=/nonexistent/age-keygen
export AGE_BIN AGE_KEYGEN_BIN
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"
use_docker_socket
PASS=0; FAILN=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAILN=$((FAILN+1)); printf 'FAIL: %s: expected [%s] got [%s]\n' "$1" "$3" "$2"; fi; }

TEXT="$(age_keygen_text)"
KEY="$(printf '%s\n' "$TEXT" | grep -c '^AGE-SECRET-KEY-1')"
RECIPIENT="$(printf '%s\n' "$TEXT" | sed -n 's/^# public key: //p')"
check "generated a key in the helper" "$KEY" 1
check "the recipient is usable" "$(age_recipient_usable "$RECIPIENT" && echo yes)" yes
head -c 2000000 /dev/urandom > "$WORK/blob"
WANT="$(sha256sum < "$WORK/blob" | cut -d' ' -f1)"
age_encrypt "$RECIPIENT" < "$WORK/blob" > "$WORK/blob.age"
check "encrypted in the helper" "$(is_age_file "$WORK/blob.age" && echo yes)" yes
read_age_identity - < <(printf '%s\n' "$TEXT")
check "decrypted in the helper, same checksum" "$(age_decrypt < "$WORK/blob.age" | sha256sum | cut -d' ' -f1)" "$WANT"
TEXT2="$(age_keygen_text)"
read_age_identity - < <(printf '%s\n' "$TEXT2")
OUT="$(age_decrypt < "$WORK/blob.age" 2>&1 >/dev/null || true)"
case "$OUT" in *"no identity matched"*) check "the wrong key in the helper" wrong wrong ;; *) check "the wrong key in the helper" "$OUT" "no identity matched" ;; esac
RC=0; printf 'x' | age_encrypt "age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq" >/dev/null 2>&1 || RC=$?
check "a recipient with a bad checksum fails in the helper" "$([ "$RC" -ne 0 ] && echo failed || echo passed)" failed

printf 'on this machine: %s passed, %s failed\n' "$PASS" "$FAILN"
[ "$FAILN" -eq 0 ]
echo "End-to-end proof passed."
