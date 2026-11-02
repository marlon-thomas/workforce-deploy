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

echo "healthwatch self-test: ${PASS} passed, ${FAILN} failed"
[ "$FAILN" -eq 0 ]
