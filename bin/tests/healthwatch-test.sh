#!/usr/bin/env bash
# healthwatch-test.sh — hermetic self-test of bin/healthwatch.sh: canned doctor output goes through
# the real parsing, decision, state and message code; sending is stubbed (or, for the SMTP argument
# test, curl is a fake on PATH). No Docker, no network, no .env. Run by bin/ci-validate.sh.
#   ./bin/tests/healthwatch-test.sh      exit 0 = all pass
# Variables are read by the sourced script, stubs are called indirectly, test names are literal:
# shellcheck disable=SC2034,SC2317,SC2209
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# shellcheck source=../healthwatch.sh
. "$HERE/../healthwatch.sh"
set +e   # the tests check exit codes themselves

HW_STATE_FILE="$WORK/state/healthwatch.state"
HW_LOG_FILE="$WORK/logs/healthwatch.log"
HW_STATUS_FILE="$WORK/status/health.json"; HW_BACKUP_DIR="$WORK/backups"; HW_SECRETS_DIR="$WORK/secrets"
ENV_NAME="test"; APP_HOSTNAME=app.example.test; SMTP_HOST=relay.example.test; SMTP_PORT=587
SMTP_FROM=workforce@app.example.test; OPS_ALERT_EMAIL="ops@example.test, oncall@example.test"
load_recipients

PASS=0; FAILN=0
ok()  { PASS=$((PASS+1)); }
bad() { FAILN=$((FAILN+1)); printf 'FAIL: %s\n' "$*"; }
check() { if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$3] got [$2]"; fi; }
contains() { case "$2" in *"$3"*) ok ;; *) bad "$1: [$3] not in output: $2" ;; esac; }

# --- stubs: doctor output, clock, transport
DOCTOR_OUT=""; NOW=1700000000
run_doctor() { printf '%s\n' "$DOCTOR_OUT"; }
now_epoch() { echo "$NOW"; }
SENT_DIR="$WORK/sent"; mkdir -p "$SENT_DIR"; SEND_FAIL=0
send_mail() { # records the message; SEND_FAIL=1 simulates a refusing relay
  if [ "$SEND_FAIL" = 1 ]; then echo "curl: (7) Failed to connect"; return 7; fi
  cp "$1" "$SENT_DIR/$(( $(sent_count) + 1 )).eml"
  printf '%s\n' "$2" > "$SENT_DIR/last.from"
}
SEND_STUB="$(declare -f send_mail)"
sent_count() { find "$SENT_DIR" -name '*.eml' | wc -l | tr -d ' '; }
last_subject() { local f; f="$(ls -1 "$SENT_DIR"/*.eml 2>/dev/null | sort -V | tail -1)"; [ -n "$f" ] && sed -n 's/^Subject: \(.*\)\r$/\1/p' "$f"; }
last_body() { local f; f="$(ls -1 "$SENT_DIR"/*.eml | sort -V | tail -1)"; awk 'p { print } /^\r$/ { p = 1 }' "$f" | tr -d '\r' | base64 -d | tr -d '\r'; }
doctor() { # doctor <row>... — rows as "STATUS|label|detail"; adds the done line
  local r out=""
  for r in "$@"; do out="${out}$(printf '%s\t%s\t%s' "${r%%|*}" "$(echo "$r" | cut -d'|' -f2)" "${r##*|}")"$'\n'; done
  DOCTOR_OUT="# Workforce — health check
${out}# done fails=x"
}
run() { watch_once 0 > "$WORK/out" 2>&1; RC=$?; }

# 1. all green: nothing sent, exit 0, state written
doctor "OK|database|accepting" "WARN|object storage|mc not ready" "OK|object storage|live" "WARN|off-site backup|none"
run
check "green exit" "$RC" 0
check "green sends nothing" "$(sent_count)" 0
contains "green log" "$(cat "$HW_LOG_FILE")" "ok: no checks failing; 1 warning(s)"
contains "state last_run" "$(cat "$HW_STATE_FILE")" "last_run=$NOW"

# 2. parse: the last row of a check wins (object storage WARN then OK = OK)
ROWS="$(printf '%s\n' "$DOCTOR_OUT" | parse_rows)"
check "dedupe warn" "$(printf '%s\n' "$ROWS" | labels_with WARN)" "off-site backup"

# 3. a check fails: one alert, singular subject, exit 1
NOW=$((NOW + 900))
doctor "OK|database|accepting" "FAIL|last backup|30 h old" "WARN|off-site backup|none"
run
check "new fail exit" "$RC" 1
check "new fail sends" "$(sent_count)" 1
check "new fail subject" "$(last_subject)" "[Workforce test app.example.test] 1 check failing: last backup"
contains "body has failing row" "$(last_body)" "FAIL  last backup: 30 h old"
contains "body has warning row" "$(last_body)" "WARN  off-site backup: none"
contains "body has investigate" "$(last_body)" "./bin/doctor.sh"
contains "headers To" "$(cat "$SENT_DIR/1.eml")" "To: ops@example.test, oncall@example.test"
check "envelope from" "$(cat "$SENT_DIR/last.from")" "workforce@app.example.test"

# 4. still failing 15 minutes later: nothing new
NOW=$((NOW + 900)); run
check "repeat exit" "$RC" 1
check "repeat sends nothing" "$(sent_count)" 1

# 5. WARN -> FAIL of another check: alert, plural subject in doctor order
NOW=$((NOW + 900))
doctor "FAIL|mail sync|all 3 mailboxes fail" "FAIL|last backup|31 h old"
run
check "warn->fail sends" "$(sent_count)" 2
check "warn->fail subject" "$(last_subject)" "[Workforce test app.example.test] 2 checks failing: mail sync, last backup"
contains "warn->fail new names" "$(last_body)" "New since the last email: mail sync."

# 6. a day after the last email, still failing: one reminder, then quiet again
NOW=$((NOW + 24 * 3600)); run
check "reminder sends" "$(sent_count)" 3
contains "reminder subject" "$(last_subject)" "reminder: 2 checks still failing: mail sync, last backup"
NOW=$((NOW + 900)); run
check "no second reminder" "$(sent_count)" 3

# 7. one clears: quiet; it comes back: alert again
NOW=$((NOW + 900)); doctor "FAIL|last backup|32 h old"; run
check "partial clear quiet" "$(sent_count)" 3
NOW=$((NOW + 900)); doctor "FAIL|last backup|32 h old" "FAIL|mail sync|again"; run
check "returning fail alerts" "$(sent_count)" 4

# 8. everything clears: resolved once, then quiet
NOW=$((NOW + 900)); doctor "OK|last backup|1 h ago" "WARN|disk space|12% free"; run
check "resolved exit" "$RC" 0
check "resolved sends" "$(sent_count)" 5
check "resolved subject" "$(last_subject)" "[Workforce test app.example.test] resolved: no checks failing"
contains "resolved names" "$(last_body)" "recovered: last backup, mail sync."
NOW=$((NOW + 900)); run
check "after resolved quiet" "$(sent_count)" 5

# 9. relay refuses: exit 3, logged, state unchanged so the next run retries the alert
NOW=$((NOW + 900)); doctor "FAIL|service api|not running (exited)"; SEND_FAIL=1; run
check "send failure exit" "$RC" 3
contains "send failure logged" "$(tail -1 "$HW_LOG_FILE")" "EMAIL FAILED via relay.example.test:587"
check "send failure nothing recorded" "$(grep -c '^fail=' "$HW_STATE_FILE")" 0
NOW=$((NOW + 900)); SEND_FAIL=0; run
check "retry sends" "$(sent_count)" 6
check "retry subject" "$(last_subject)" "[Workforce test app.example.test] 1 check failing: service api"

# 10. doctor stopped early (no '# done'): a synthetic FAIL, with doctor's last words
NOW=$((NOW + 900))
DOCTOR_OUT=$'# Workforce — health check\nOK\tconfiguration\thostname x\nCannot find a Docker daemon socket'
run
contains "crash subject" "$(last_subject)" "health check"
contains "crash detail" "$(last_body)" "doctor.sh stopped before finishing (Cannot find a Docker daemon socket)"

# 11. dry run: prints the email, sends and saves nothing
cp "$HW_STATE_FILE" "$WORK/state.before"
NOW=$((NOW + 900)); doctor "FAIL|disk space|3% free"
watch_once 1 > "$WORK/out" 2>&1; RC=$?
check "dry exit" "$RC" 1
check "dry sends nothing" "$(sent_count)" 7
contains "dry prints subject" "$(cat "$WORK/out")" "Subject: [Workforce test app.example.test] 1 check failing: disk space"
check "dry keeps state" "$(cmp -s "$HW_STATE_FILE" "$WORK/state.before" && echo same)" same

# 12. no recipients: logged only, state advances (no email storm later), exit 1
OPS_ALERT_EMAIL=""; load_recipients
NOW=$((NOW + 900)); run
check "log-only exit" "$RC" 1
check "log-only sends nothing" "$(sent_count)" 7
contains "log-only logged" "$(tail -1 "$HW_LOG_FILE")" "not emailed: OPS_ALERT_EMAIL is empty"
check "log-only state" "$(grep '^fail=' "$HW_STATE_FILE")" "fail=disk space"
check "test alert needs recipients" "$(send_test 0 >/dev/null 2>&1; echo $?)" 2

# 13. recipients: spaces trimmed, junk ignored
OPS_ALERT_EMAIL=" a@example.test ,bad, x<y>@example.test,b@example.test"; load_recipients 2>/dev/null
check "recipients" "${RCPTS[*]}" "a@example.test b@example.test"

# 14. test alert goes out with a test subject; OPS_ALERT_FROM wins over SMTP_FROM
OPS_ALERT_FROM="Ops watch <watch@example.test>"
send_test 0 > /dev/null; RC=$?
check "test alert exit" "$RC" 0
check "test alert subject" "$(last_subject)" "[Workforce test app.example.test] test alert"
check "test alert envelope" "$(cat "$SENT_DIR/last.from")" "watch@example.test"
contains "test alert From" "$(cat "$SENT_DIR/8.eml")" "From: Ops watch <watch@example.test>"
unset OPS_ALERT_FROM

# 15. decide() edge: prev empty, cur empty -> none; a 24 h boundary
check "decide none" "$(decide "" "" 100 0)" none
check "decide remind boundary" "$(decide "a" "a" $((HW_REMIND_SECS + 5)) 5)" reminder
check "decide not yet" "$(decide "a" "a" $((HW_REMIND_SECS + 4)) 5)" none

# 16. the real send_mail with a fake curl: credentials never on the command line
unset -f send_mail
# shellcheck source=../healthwatch.sh
. "$HERE/../healthwatch.sh"; set +e
mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FAKE_DIR/argv"
prev=""
for a in "$@"; do [ "$prev" = --config ] && cp "$a" "$FAKE_DIR/config" && stat -c %a "$a" > "$FAKE_DIR/mode"; prev="$a"; done
exit 0
FAKE
chmod +x "$WORK/bin/curl"
export FAKE_DIR="$WORK"
echo "x" > "$WORK/msg.eml"
SMTP_USERNAME='relay-user'; SMTP_PASSWORD='p"a\ss:w0rd'; SMTP_STARTTLS=true; SMTP_PORT=587
PATH="$WORK/bin:$PATH" send_mail "$WORK/msg.eml" from@example.test a@example.test b@example.test; RC=$?
check "send_mail exit" "$RC" 0
check "password not in argv" "$(grep -c 'w0rd' "$WORK/argv")" 0
contains "starttls required" "$(cat "$WORK/argv")" "--ssl-reqd"
contains "smtp url" "$(cat "$WORK/argv")" "smtp://relay.example.test:587/app.example.test"
check "two recipients" "$(grep -cx -- '--mail-rcpt' "$WORK/argv")" 2
check "config escaped" "$(cat "$WORK/config")" 'user = "relay-user:p\"a\\ss:w0rd"'
check "config mode" "$(cat "$WORK/mode")" 600
SMTP_PORT=465; SMTP_STARTTLS=false; SMTP_USERNAME=""
PATH="$WORK/bin:$PATH" send_mail "$WORK/msg.eml" from@example.test a@example.test
contains "implicit tls" "$(cat "$WORK/argv")" "smtps://relay.example.test:465/"
check "no auth without user" "$(grep -c -- '--config' "$WORK/argv")" 0
check "no starttls flag on 465" "$(grep -c -- '--ssl-reqd' "$WORK/argv")" 0

# 17. a non-ASCII subject is RFC 2047 encoded
check "ascii header" "$(encode_header 'plain')" "plain"
contains "utf8 header" "$(encode_header 'disk — full')" "=?UTF-8?B?"

# 18. the outside heartbeat: the URL goes to curl on stdin (never argv); a failed ping never fails the run
mkdir -p "$WORK/hb"
cat > "$WORK/hb/curl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FAKE_DIR/hb-argv"; cat > "$FAKE_DIR/hb-stdin"; exit "${HB_RC:-0}"
FAKE
chmod +x "$WORK/hb/curl"
OPS_HEARTBEAT_URL="https://hc-ping.example/uuid-123"; HEARTBEAT_NOTE=""
PATH="$WORK/hb:$PATH" heartbeat
check "heartbeat note" "$HEARTBEAT_NOTE" "heartbeat sent"
check "url not in argv" "$(grep -c 'uuid-123' "$WORK/hb-argv")" 0
check "url on stdin" "$(cat "$WORK/hb-stdin")" 'url = "https://hc-ping.example/uuid-123"'
HB_RC=7; export HB_RC; HEARTBEAT_NOTE=""
PATH="$WORK/hb:$PATH" heartbeat; RC=$?
check "failed ping returns 0" "$RC" 0
contains "failed ping noted" "$HEARTBEAT_NOTE" "NOT sent"
unset HB_RC; OPS_HEARTBEAT_URL=""; HEARTBEAT_NOTE=""; rm -f "$WORK/hb-argv"
PATH="$WORK/hb:$PATH" heartbeat
check "no url, no ping" "$( [ -e "$WORK/hb-argv" ] && echo pinged || echo none)" none

# 19. the status file: written atomically, valid JSON, what the app expects, readable by the app
# (test 16 re-read the script, so the stubs go back on.)
run_doctor() { printf '%s\n' "$DOCTOR_OUT"; }
now_epoch() { echo "$NOW"; }
eval "$SEND_STUB"
OPS_ALERT_EMAIL="ops@example.test"; load_recipients
rm -rf "$WORK/status"
mkdir -p "$HW_BACKUP_DIR" "$HW_SECRETS_DIR"
APP_VERSION=0.2.98; BACKUP_TARGET=""; SMTP_USERNAME="relay-user@example.test"; MAIL_RELAY_USER="stalwart-relay"
json_get() { # json_get <python expression over d> — reads the status file with a real JSON parser
  python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1],encoding="utf-8")); print(eval(sys.argv[2]))' "$HW_STATUS_FILE" "$1"
}
rm -f "$HW_STATE_FILE"; NOW=1800000000
printf 'x' > "$HW_BACKUP_DIR/2027-01-13_020000.tar.gz"; touch -d @1799900000 "$HW_BACKUP_DIR/2027-01-13_020000.tar.gz"
printf 'xyz' > "$HW_BACKUP_DIR/2027-01-14_020000.tar.gz"; touch -d @1799990000 "$HW_BACKUP_DIR/2027-01-14_020000.tar.gz"
printf 'unfinished' > "$HW_BACKUP_DIR/2027-01-15_020000.tar.gz.part"
doctor "OK|running version|0.2.98 (configured: 0.2.98)" "OK|database|accepting connections" "WARN|off-site backup|no BACKUP_TARGET"
( umask 077; watch_once 0 > "$WORK/out" 2>&1 ); RC=$?
check "status: exit" "$RC" 0
check "status: schema" "$(json_get 'd["schema"]')" 1
check "status: time" "$(json_get 'd["checkedAt"]')" "2027-01-15T08:00:00Z"
check "status: running" "$(json_get 'd["version"]["running"]')" "0.2.98"
check "status: configured" "$(json_get 'd["version"]["configured"]')" "0.2.98"
check "status: rows" "$(json_get 'len(d["checks"])')" 3
check "status: a row" "$(json_get 'd["checks"][2]')" "{'status': 'WARN', 'check': 'off-site backup', 'detail': 'no BACKUP_TARGET'}"
check "status: backup kept (no .part)" "$(json_get 'd["backup"]["kept"]')" 2
check "status: backup size is the newest" "$(json_get 'd["backup"]["sizeBytes"]')" 3
check "status: backup time" "$(json_get 'd["backup"]["lastAt"]')" "2027-01-15T05:13:20Z"
check "status: no off-site" "$(json_get 'd["backup"]["offsite"]')" "{'configured': False, 'kind': None, 'encrypted': False, 'lastCopy': 'UNKNOWN'}"
check "status: file mode (under umask 077)" "$(stat -c %a "$HW_STATUS_FILE")" 644
check "status: folder mode (under umask 077)" "$(stat -c %a "$(dirname "$HW_STATUS_FILE")")" 755
check "status: no temp left" "$(find "$WORK/status" -name '.health*' | wc -l | tr -d ' ')" 0

# 20. running version unknown (api down): null, not a wrong answer; a version that isn't one is dropped
doctor "FAIL|running version|api down and sign-in unreachable" "OK|database|ok"
APP_VERSION='1.0;rm -rf'; run
check "status: running unknown" "$(json_get 'd["version"]["running"]')" None
check "status: odd version dropped" "$(json_get 'd["version"]["configured"]')" None
APP_VERSION=0.2.98
doctor "OK|running version|0.2.98 (configured: 0.2.98)"; run

# 21. no backups at all: nulls and a zero
mv "$HW_BACKUP_DIR" "$WORK/backups.away"; run
check "status: no backup time" "$(json_get 'd["backup"]["lastAt"]')" None
check "status: no backup size" "$(json_get 'd["backup"]["sizeBytes"]')" None
check "status: none kept" "$(json_get 'd["backup"]["kept"]')" 0
mv "$WORK/backups.away" "$HW_BACKUP_DIR"

# 22. whether the last off-site copy worked, from the nightly log, and the target never appears
BACKUP_TARGET="s3://secret-bucket/customer"
BACKUP_ENCRYPT_RECIPIENT=age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
cron_log() { printf '%s\n' "$@" > "$HW_BACKUP_DIR/cron.log"; }
NIGHT_OK=("Dumping the application database…" "Copying off-site to s3://secret-bucket/customer…" "Retention applied (nightly)")
NIGHT_BAD=("Dumping the application database…" "Copying off-site to s3://secret-bucket/customer…" "Off-site copy failed — check the backup target credentials (backup is still local)." "Retention applied (nightly)")
cron_log "${NIGHT_OK[@]}"; run
check "off-site worked" "$(json_get 'd["backup"]["offsite"]')" "{'configured': True, 'kind': 'S3', 'encrypted': True, 'lastCopy': 'OK'}"
cron_log "${NIGHT_OK[@]}" "${NIGHT_BAD[@]}"; run
check "off-site failed" "$(json_get 'd["backup"]["offsite"]["lastCopy"]')" FAILED
cron_log "${NIGHT_BAD[@]}" "${NIGHT_OK[@]}"; run
check "off-site recovered" "$(json_get 'd["backup"]["offsite"]["lastCopy"]')" OK
cron_log "${NIGHT_OK[@]}" "Dumping the application database…"; run
check "a run in progress keeps the last answer" "$(json_get 'd["backup"]["offsite"]["lastCopy"]')" OK
rm -f "$HW_BACKUP_DIR/cron.log"; run
check "off-site never logged" "$(json_get 'd["backup"]["offsite"]["lastCopy"]')" UNKNOWN
BACKUP_TARGET="backup-user@vault.example.test:/srv/x"; run
check "rsync kind" "$(json_get 'd["backup"]["offsite"]["kind"]')" rsync
check "target not in the file" "$(grep -c 'vault\|backup-user\|secret-bucket' "$HW_STATUS_FILE")" 0

# 22b. a target with no usable recipient sends nothing, whatever an older run logged: the file says so
NO_KEY_LINE="Off-site copy failed — nothing was sent: BACKUP_ENCRYPT_RECIPIENT isn't set, and backups never leave this server unencrypted (backup is still local)."
cron_log "${NIGHT_OK[@]}"; BACKUP_ENCRYPT_RECIPIENT=""; run
check "no recipient: not encrypted" "$(json_get 'd["backup"]["offsite"]')" "{'configured': True, 'kind': 'rsync', 'encrypted': False, 'lastCopy': 'FAILED'}"
BACKUP_ENCRYPT_RECIPIENT="ssh-ed25519 AAAA"; run
check "bad recipient: not encrypted" "$(json_get 'd["backup"]["offsite"]["encrypted"]')" False
check "bad recipient: failed" "$(json_get 'd["backup"]["offsite"]["lastCopy"]')" FAILED
# The log's own answer, for a run that refused to send: no "Copying off-site" line in it.
cron_log "Dumping the application database…" "$NO_KEY_LINE" "Retention applied (nightly)"
check "a refused run reads as FAILED" "$(offsite_last_copy)" FAILED
cron_log "Testing the off-site copy with x…" "$NO_KEY_LINE" "Off-site copy test finished."
check "a refused test reads as FAILED" "$(offsite_last_copy)" FAILED
cron_log "Dumping the application database…" "Retention applied (nightly)"
check "a run with no off-site step is still UNKNOWN" "$(offsite_last_copy)" UNKNOWN
# Encrypted is false with no target, even with a recipient set: nothing is going anywhere.
BACKUP_TARGET=""; BACKUP_ENCRYPT_RECIPIENT=age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p; run
check "no target: not encrypted" "$(json_get 'd["backup"]["offsite"]["encrypted"]')" False
BACKUP_ENCRYPT_RECIPIENT=""; rm -f "$HW_BACKUP_DIR/cron.log"

# 23. nothing like a secret survives, whatever a row says; JSON survives what the rows hold
printf 'mail-relay-password-value\n' > "$HW_SECRETS_DIR/mail_relay_password"
printf 'short\n' > "$HW_SECRETS_DIR/too_short"
OPS_HEARTBEAT_URL="https://hc-ping.example/ping-uuid-123"
SMTP_PASSWORD='smtp-p@ss'
rm -f "$HW_STATE_FILE"
doctor "WARN|ops alerts|to ops@example.test, boss@care.example (watch ran 3 min ago)" \
       "OK|outgoing email|relay relay.example.test:587 as relay-user@example.test and stalwart-relay" \
       "OK|admin recovery email|a•••@outside.example (outside this server)" \
       "FAIL|odd|url https://user:hunter2@host.example/x then password=abc123, token: qqq" \
       "FAIL|leak|mail-relay-password-value and smtp-p@ss and https://hc-ping.example/ping-uuid-123" \
       "FAIL|hash|0123456789abcdef0123456789abcdef0123 end" \
       'WARN|quotes|say "hi" back\slash'
run
STATUS_TEXT="$(cat "$HW_STATUS_FILE")"
for leak in ops@example.test boss@care relay-user@ stalwart-relay hunter2 'user:' abc123 qqq mail-relay-password-value 'smtp-p@ss' ping-uuid 0123456789abcdef; do
  check "no leak: $leak" "$(printf '%s' "$STATUS_TEXT" | grep -cF -- "$leak")" 0
done
check "address masked to its domain" "$(json_get 'd["checks"][0]["detail"]')" "to o•••@example.test, b•••@care.example (watch ran 3 min ago)"
check "already masked stays" "$(json_get 'd["checks"][2]["detail"]')" "a•••@outside.example (outside this server)"
check "plain words stay" "$(json_get '"relay.example.test:587" in d["checks"][1]["detail"]')" True
check "quotes and backslashes" "$(json_get 'd["checks"][6]["detail"]')" 'say "hi" back\slash'
contains "the email still has the real detail" "$(last_body)" "boss@care.example"
SMTP_USERNAME=""; SMTP_PASSWORD=""; MAIL_RELAY_USER=""; OPS_HEARTBEAT_URL=""

# 24. doctor's last words stay out of the file: they could be anything
rm -f "$HW_STATE_FILE"
DOCTOR_OUT=$'# Workforce — health check\nOK\tconfiguration\thostname x\nsome error with hunter2 in it'
run
check "stopped early: the fact" "$(json_get 'd["checks"][1]["check"]')" "health check"
check "stopped early: not the words" "$(grep -c hunter2 "$HW_STATUS_FILE")" 0
contains "stopped early: still emailed in full" "$(last_body)" "some error with hunter2 in it"

# 25. a dry run writes no status file
rm -f "$HW_STATUS_FILE"; doctor "OK|database|ok"
watch_once 1 > "$WORK/out" 2>&1
check "dry run writes nothing" "$( [ -e "$HW_STATUS_FILE" ] && echo written || echo none)" none

# 26. a failed write never stops the watch: the alert goes, the state is saved, the heartbeat is
#     sent, the exit code is the watch's own, and the log says so
NOW=$((NOW + 900)); rm -f "$HW_STATE_FILE"
printf 'a file where the folder should be\n' > "$WORK/blocker"
HW_STATUS_FILE="$WORK/blocker/health.json"
mkdir -p "$WORK/hb2"
cat > "$WORK/hb2/curl" <<'FAKE'
#!/usr/bin/env bash
cat > /dev/null; touch "$FAKE_DIR/hb2-pinged"; exit 0
FAKE
chmod +x "$WORK/hb2/curl"; rm -f "$WORK/hb2-pinged"
OPS_HEARTBEAT_URL="https://hc-ping.example/x"
BEFORE="$(sent_count)"
doctor "FAIL|service api|not running (exited)"
# Under the script's own set -e, as the schedule runs it.
( set -euo pipefail; PATH="$WORK/hb2:$PATH" watch_once 0 ) > "$WORK/out" 2>&1; RC=$?
check "failed write: exit is the watch's" "$RC" 1
check "failed write: alert sent" "$(sent_count)" "$((BEFORE + 1))"
check "failed write: state saved" "$(grep '^fail=' "$HW_STATE_FILE")" "fail=service api"
check "failed write: heartbeat sent" "$( [ -e "$WORK/hb2-pinged" ] && echo yes || echo no)" yes
contains "failed write: logged" "$(tail -1 "$HW_LOG_FILE")" "status file NOT written"
OPS_HEARTBEAT_URL=""

# 27. the same when the rename fails or the JSON can't be built: the last good file stays whole
HW_STATUS_FILE="$WORK/status2/health.json"; mkdir -p "$WORK/status2"
rm -f "$HW_STATE_FILE"
doctor "OK|database|ok"; run
GOOD="$(cat "$HW_STATUS_FILE")"
mkdir -p "$WORK/nomv"
cat > "$WORK/nomv/mv" <<FAKE
#!/bin/sh
case "\$*" in *health.json*) exit 1 ;; esac
exec $(command -v mv) "\$@"
FAKE
chmod +x "$WORK/nomv/mv"
NOW=$((NOW + 900)); doctor "OK|database|changed"
PATH="$WORK/nomv:$PATH" run
check "failed rename: exit" "$RC" 0
check "failed rename: old file whole" "$(cat "$HW_STATUS_FILE")" "$GOOD"
check "failed rename: no temp left" "$(find "$WORK/status2" -name '.health*' | wc -l | tr -d ' ')" 0
contains "failed rename: logged" "$(tail -1 "$HW_LOG_FILE")" "status file NOT written"
real_status_json="$(declare -f status_json)"
status_json() { return 1; }
NOW=$((NOW + 900)); run
check "failed build: exit" "$RC" 0
check "failed build: old file whole" "$(cat "$HW_STATUS_FILE")" "$GOOD"
eval "$real_status_json"

# 28. compose: the folder (a mounted file would pin the old copy after a rename), read-only, api only
COMPOSE="$HERE/../../compose.yaml"
check "mounted once" "$(grep -c '\./status' "$COMPOSE")" 1
contains "mounted read-only, as a folder" "$(grep '\./status' "$COMPOSE")" "- ./status:/run/workforce-status:ro"
check "mounted in the api" "$(awk '/^  [a-z][a-z-]*:$/ { svc = $1 } /\.\/status:/ { print svc }' "$COMPOSE")" "api:"
check "the page's setting reaches the api" "$(grep -cF 'WORKFORCE_SERVER_HEALTH_VISIBLE: ${WORKFORCE_SERVER_HEALTH_VISIBLE:-true}' "$COMPOSE")" 1

echo "healthwatch self-test: ${PASS} passed, ${FAILN} failed"
[ "$FAILN" -eq 0 ]
