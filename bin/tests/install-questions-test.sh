#!/usr/bin/env bash
# install-questions-test.sh — hermetic self-test of the installer's questions
# (bin/lib/questions.sh: off-site backup target and key, outgoing relay, alert address, uptime check) and of
# alert_address_problems (bin/lib/common.sh). Answers come from scripted stdin; no Docker, no network.
#   ./bin/tests/install-questions-test.sh      exit 0 = all pass
# shellcheck disable=SC2034
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"
# shellcheck source=../lib/questions.sh
. "$HERE/../lib/questions.sh"
say()  { :; }
warn() { :; }
read_mandatory() { # same contract as install.sh's: repeat until non-empty
  local __var="$1" __val=""
  while :; do
    if [ "${3:-}" = silent ]; then read -rs -r __val || return 1; else read -r __val || return 1; fi
    [ -n "$__val" ] && { printf -v "$__var" '%s' "$__val"; return 0; }
  done
}

PASS=0; FAILN=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAILN=$((FAILN+1)); printf 'FAIL: %s: expected [%s] got [%s]\n' "$1" "$3" "$2"; fi; }
fresh() { unset SMTP_HOST SMTP_PORT SMTP_USERNAME SMTP_PASSWORD SMTP_STARTTLS SMTP_FROM OPS_ALERT_EMAIL OPS_HEARTBEAT_URL; BASE_DOMAIN=carehome.example.test; APP_HOSTNAME=workforce.carehome.example.test; AUTH_HOSTNAME=auth.carehome.example.test; }

# --- alert_address_problems
check "plain ok" "$(alert_address_problems 'ops@elsewhere.example' workforce.carehome.example.test)" ""
check "not an address" "$(alert_address_problems 'ops@nowhere' workforce.carehome.example.test)" "bad:ops@nowhere is not an email address"
check "own parent domain" "$(alert_address_problems 'ops@carehome.example.test' workforce.carehome.example.test)" "own:ops@carehome.example.test is on carehome.example.test, which this server answers for"
check "spaces and duplicates" "$(alert_address_problems ' a@x.example , a@x.example' h.example.test)" ""
check "never a public suffix" "$(alert_address_problems 'ops@other.co.uk' workforce.co.uk)" ""

# --- relay: a provider from the list, with a login
fresh
ask_relay > /dev/null 2>&1 <<'IN'
3
relay-login@example.test
s3cr3t-key
IN
check "brevo host" "$SMTP_HOST:$SMTP_PORT:$SMTP_STARTTLS" "smtp-relay.brevo.com:587:true"
check "brevo login" "$SMTP_USERNAME" "relay-login@example.test"
check "brevo password" "$SMTP_PASSWORD" "s3cr3t-key"
check "default from" "$SMTP_FROM" "noreply@carehome.example.test"

# --- relay: a password with a single quote is refused, then a usable one accepted
fresh
ask_relay > /dev/null 2>&1 <<'IN'
4
user
it's-bad
good"pass\w$x

IN
check "quote refused" "$SMTP_PASSWORD" 'good"pass\w$x'

# --- relay: one ending in a backslash would stop compose reading .env, so it's refused too
fresh
ask_relay > /dev/null 2>&1 <<'IN'
4
user
ends-in-a-slash\
good-pass

IN
check "trailing backslash refused" "$SMTP_PASSWORD" 'good-pass'

# --- relay: Microsoft 365 sends as the mailbox it signs in as
fresh
ask_relay > /dev/null 2>&1 <<'IN'
1
noreply@carehome.example.test
pw

IN
check "m365 from = mailbox" "$SMTP_FROM" "noreply@carehome.example.test"
check "m365 host" "$SMTP_HOST" "smtp.office365.com"

# --- relay: other, refusing 465 and a bad choice first; IP-allowed relay needs no login
fresh
ask_relay > /dev/null 2>&1 <<'IN'
9
7
smtp.example.net:465
7
smtp.example.net:2525

alerts@carehome.example.test
IN
check "other host/port" "$SMTP_HOST:$SMTP_PORT" "smtp.example.net:2525"
check "no login" "${SMTP_USERNAME}|${SMTP_PASSWORD}" "|"
check "chosen from" "$SMTP_FROM" "alerts@carehome.example.test"

# --- relay: none
fresh
ask_relay > /dev/null 2>&1 <<'IN'

IN
check "no relay" "${SMTP_HOST}" ""

# --- relay: from the environment file, no questions asked
fresh; SMTP_HOST=mailpit; SMTP_PORT=1025
ask_relay > /dev/null 2>&1 < /dev/null
check "env relay kept" "$SMTP_HOST:$SMTP_PORT" "mailpit:1025"

# --- alert address: bad, then own domain declined, then accepted elsewhere; heartbeat set
fresh
ask_alert_address > /dev/null 2>&1 <<'IN'
not-an-address
ops@carehome.example.test
n
ops@elsewhere.example
https://hc-ping.example/abc-123
IN
check "alert address" "$OPS_ALERT_EMAIL" "ops@elsewhere.example"
check "heartbeat" "$OPS_HEARTBEAT_URL" "https://hc-ping.example/abc-123"

# --- alert address: own domain confirmed (mail hosted elsewhere); no heartbeat
fresh
ask_alert_address > /dev/null 2>&1 <<'IN'
it@carehome.example.test
y

IN
check "own domain confirmed" "$OPS_ALERT_EMAIL" "it@carehome.example.test"
check "no heartbeat" "${OPS_HEARTBEAT_URL}" ""

# --- alert address: pre-filled from the environment file, Enter keeps it; '-' clears a heartbeat
fresh; OPS_ALERT_EMAIL=ops-alerts@example.test; OPS_HEARTBEAT_URL=https://hc-ping.example/old
ask_alert_address > /dev/null 2>&1 <<'IN'

-
IN
check "kept default" "$OPS_ALERT_EMAIL" "ops-alerts@example.test"
check "heartbeat cleared" "${OPS_HEARTBEAT_URL}" ""

# --- heartbeat: a non-https answer is refused
fresh
ask_heartbeat > /dev/null 2>&1 <<'IN'
hc-ping.example/abc
https://hc-ping.example/abc
IN
check "https only" "$OPS_HEARTBEAT_URL" "https://hc-ping.example/abc"

# --- recovery email: a list refused, own domain declined, then an outside address; pre-fill kept
fresh; unset ADMIN_RECOVERY_EMAIL
ask_recovery_email > /dev/null 2>&1 <<'IN'
a@x.example,b@x.example
admin@carehome.example.test
n
me@elsewhere.example
IN
check "recovery email" "$ADMIN_RECOVERY_EMAIL" "me@elsewhere.example"
ADMIN_RECOVERY_EMAIL=recovery@example.test
ask_recovery_email > /dev/null 2>&1 <<'IN'

IN
check "recovery kept" "$ADMIN_RECOVERY_EMAIL" "recovery@example.test"

# --- question 4. Stand-ins for age-keygen: not real keys, and only the shape is checked here. A real
# pair goes through this in bin/tests/backup-encrypt-e2e.sh.
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK:?}"' EXIT
PUB=age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
SECRET="AGE-SECRET-KEY-1QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ"
cat > "$WORK/keygen" <<SH
#!/bin/sh
printf '# created: 2026-11-02T10:00:00Z\n# public key: $PUB\n$SECRET\n'
SH
chmod +x "$WORK/keygen"
export AGE_KEYGEN_BIN="$WORK/keygen" AGE_BIN=/nonexistent/age
count_of() { grep -cF "$1" "$2"; }
q4() { unset BACKUP_TARGET BACKUP_ENCRYPT_RECIPIENT; }

# No target: no more questions, and nothing is read for them (the next question's answer stays)
q4
ask_backup_target > /dev/null 2>&1 <<'IN'

IN
check "q4 local only: rc" "$?" 0
check "q4 local only: target" "$BACKUP_TARGET" ""
check "q4 local only: no recipient" "$BACKUP_ENCRYPT_RECIPIENT" ""

# A target and a pasted public key; rubbish is refused first
q4
ask_backup_target > /dev/null 2>"$WORK/err" <<IN
backups@vault.example.test:
AGE-SECRET-KEY-1NOTAPUBLICKEY
ssh-ed25519 AAAA
$PUB
IN
check "q4 pasted: rc" "$?" 0
check "q4 pasted: target" "$BACKUP_TARGET" "backups@vault.example.test:"
check "q4 pasted: recipient" "$BACKUP_ENCRYPT_RECIPIENT" "$PUB"
check "q4 pasted: rubbish refused, twice" "$(count_of "isn't an age public key" "$WORK/err")" 2
check "q4 pasted: the refusal doesn't repeat what was typed" "$(count_of AGE-SECRET "$WORK/err")" 0

# Generated: the private key is shown exactly once, with the warning, and SAVED is required
q4
( cd "$WORK" && ask_backup_target > "$WORK/out" 2>"$WORK/err" <<'IN'
s3://bucket/path

yes
saved
SAVED
IN
  printf '%s\n%s\n%s\n' "$?" "$BACKUP_TARGET" "$BACKUP_ENCRYPT_RECIPIENT" > "$WORK/result"
)
check "q4 generated: rc" "$(sed -n 1p "$WORK/result")" 0
check "q4 generated: target" "$(sed -n 2p "$WORK/result")" "s3://bucket/path"
check "q4 generated: recipient is the public half" "$(sed -n 3p "$WORK/result")" "$PUB"
check "q4 generated: the key shown once" "$(count_of "$SECRET" "$WORK/out")" 1
check "q4 generated: and not in stderr" "$(count_of "$SECRET" "$WORK/err")" 0
check "q4 generated: the warning" "$(count_of "OFF-SITE BACKUPS CAN'T BE RESTORED" "$WORK/out")" 1
check "q4 generated: store it off this server" "$(count_of "OFF this" "$WORK/out")" 1
check "q4 generated: not confirmed twice" "$(count_of "It won't be shown again" "$WORK/err")" 2
check "q4 generated: the public key is not the private" "$(printf '%s' "$(sed -n 3p "$WORK/result")" | grep -c SECRET)" 0
# Nothing in the folder it ran in, or anywhere under this test's folder, but the test's own files.
check "q4 generated: written nowhere" "$(grep -rlF "$SECRET" "$WORK" 2>/dev/null | grep -v -e '/keygen$' -e '/out$' | wc -l | tr -d ' ')" 0

# Generated, and the answers stop before SAVED: no key is accepted, and the installer stops
q4
ask_backup_target > "$WORK/out" 2>/dev/null <<'IN'
s3://bucket/path

no
IN
check "q4 never confirmed: rc" "$?" 1
check "q4 never confirmed: no recipient" "$BACKUP_ENCRYPT_RECIPIENT" ""

# age-keygen and its helper container both unavailable: says so, then a pasted key still works
q4
( export AGE_KEYGEN_BIN=/nonexistent/keygen DOCKER_HOST="unix://$WORK/no.sock" PATH="$WORK/nodocker:$PATH"
  mkdir -p "$WORK/nodocker"; printf '#!/bin/sh\nexit 1\n' > "$WORK/nodocker/docker"; chmod +x "$WORK/nodocker/docker"
  ask_backup_target > /dev/null 2>"$WORK/err" <<IN
backups@vault.example.test:

$PUB
IN
  printf '%s\n%s\n' "$?" "$BACKUP_ENCRYPT_RECIPIENT" > "$WORK/result"
)
check "q4 can't generate: rc" "$(sed -n 1p "$WORK/result")" 0
check "q4 can't generate: pasted instead" "$(sed -n 2p "$WORK/result")" "$PUB"
check "q4 can't generate: says so" "$(count_of "Couldn't generate" "$WORK/err")" 1

# - : a target with no off-site copies yet
q4
ask_backup_target > /dev/null 2>&1 <<'IN'
backups@vault.example.test:
-
IN
check "q4 none yet: rc" "$?" 0
check "q4 none yet: target kept" "$BACKUP_TARGET" "backups@vault.example.test:"
check "q4 none yet: no recipient" "$BACKUP_ENCRYPT_RECIPIENT" ""

# Pre-filled from the environment file: no question
q4; BACKUP_ENCRYPT_RECIPIENT="$PUB"
ask_backup_target > /dev/null 2>&1 <<'IN'
backups@vault.example.test:
IN
check "q4 pre-filled: rc" "$?" 0
check "q4 pre-filled: recipient" "$BACKUP_ENCRYPT_RECIPIENT" "$PUB"

# A target with the answers ending there: the installer stops rather than guess
q4
ask_backup_target > /dev/null 2>&1 <<'IN'
backups@vault.example.test:
IN
check "q4 answers end: rc" "$?" 1
unset AGE_KEYGEN_BIN AGE_BIN

echo "install questions self-test: ${PASS} passed, ${FAILN} failed"
[ "$FAILN" -eq 0 ]
