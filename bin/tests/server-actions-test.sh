#!/usr/bin/env bash
# server-actions-test.sh — hermetic self-test of bin/server-actions.sh: requests go in as files, the
# real checks, jobs, backup.sh, staff-mail.sh and healthwatch.sh's mail code run in a throw-away copy
# of the bundle, and only `docker`, `curl`, `rsync` are fakes on PATH that record what reached them.
# No Docker, no network. Run by bin/ci-validate.sh, and in CI again on alpine:3.20 with busybox as the
# backup container is. As root (alpine) it also proves the mailbox's modes for uid 999.
#   ./bin/tests/server-actions-test.sh      exit 0 = all pass
# shellcheck disable=SC2034,SC2317,SC2016
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

PASS=0; FAILN=0
ok()  { PASS=$((PASS + 1)); }
bad() { FAILN=$((FAILN + 1)); printf 'FAIL: %s\n' "$*"; }
check() { if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$3] got [$2]"; fi; }
contains() { case "$2" in *"$3"*) ok ;; *) bad "$1: [$3] not in: $2" ;; esac; }
lacks() { case "$2" in *"$3"*) bad "$1: [$3] must not be in: $2" ;; *) ok ;; esac; }

# --- a bundle of our own
B="$WORK/bundle"
mkdir -p "$B/bin/lib" "$B/backups" "$B/logs" "$B/secrets" "$B/blueprints" "$B/ansible/roles/authentik/templates" "$WORK/fake"
cp "$HERE/../server-actions.sh" "$HERE/../healthwatch.sh" "$HERE/../backup.sh" "$HERE/../staff-mail.sh" "$B/bin/"
cp "$HERE/../lib/common.sh" "$B/bin/lib/"
cp "$HERE/../../ansible/roles/authentik/templates/webmail-app.yaml.j2" "$B/ansible/roles/authentik/templates/"
chmod +x "$B"/bin/*.sh
printf 'compose stand-in\n' > "$B/compose.yaml"

SECRET_PW='s3cret-Pw+with/odd"chars#and$signs'
OLD_PW='old-relay-password'
PING_URL='https://hc-ping.example.test/0f3b1f60-secret-ping?x=1&y=2'
reset_env() {
  cat > "$B/.env" <<ENV
ENV_NAME=test
APP_HOSTNAME=app.example.test
AUTH_HOSTNAME=auth.example.test
GATEWAY_CADDYFILE=./gateway/Caddyfile
DB_NAME=workforce
DB_USER=workforce_app
AK_DB_NAME=authentik
AK_DB_USER=authentik
SMTP_HOST=relay.old.example.test
SMTP_PORT=587
SMTP_USERNAME=olduser
SMTP_PASSWORD='$OLD_PW'
SMTP_STARTTLS=true
SMTP_FROM=noreply@old.example.test
OPS_ALERT_EMAIL=ops@outside.example.net
OPS_HEARTBEAT_URL=
BACKUP_TARGET=
COMPOSE_PROFILES=
ENV
  chmod 600 "$B/.env"
}
reset_env
printf 'deadbeefdeadbeef' > "$B/secrets/mail_lookup_key"
printf 'cafef00dcafef00d' > "$B/secrets/webmail_oidc_secret"

# --- the fakes: each records its arguments, one call to a line, and what's needed comes back
CALLS="$WORK/calls"; : > "$CALLS"
cat > "$WORK/fake/docker" <<'SH'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "$FAKE_CALLS"
case "$*" in
  *"compose config"*) [ -f "$FAKE_DIR/config-fails" ] && exit 1; exit 0 ;;
  *"mail-db-init mail webmail"*) if [ -f "$FAKE_DIR/mail-fails" ]; then echo "Error: cannot expose privileged port 25, you can add 'net.ipv4.ip_unprivileged_port_start=25'"; exit 1; fi ;;
  *"--wait"*api*) [ -f "$FAKE_DIR/api-fails" ] && exit 1 ;;
  *"exec -T postgres pg_dump"*|*"exec -T authentik-postgres pg_dump"*) if [ -f "$FAKE_DIR/slow-backup" ]; then sleep 30; fi; printf 'dump' ;;
  *"compose run"*init*) printf 'evidence' ;;
  *"run --rm -i"*s3*) cat > /dev/null; [ -f "$FAKE_DIR/s3-fails" ] && exit 1 ;;
  *"cat /blueprints/webmail-app.yaml"*) cat "$FAKE_BUNDLE/blueprints/webmail-app.yaml" 2>/dev/null ;;
  *"compose cp"*) exit 1 ;;
esac
exit 0
SH
# Real encryption is bin/tests/backup-encrypt-test.sh's job: this is only so a copy can be made here.
cat > "$WORK/fake/age" <<'SH'
#!/usr/bin/env bash
printf 'age %s\n' "$*" >> "$FAKE_CALLS"
printf 'age-encryption.org/v1\n'; cat
SH
cat > "$WORK/fake/rsync" <<'SH'
#!/usr/bin/env bash
printf 'rsync %s\n' "$*" >> "$FAKE_CALLS"
[ -f "$FAKE_DIR/rsync-fails" ] && exit 1
exit 0
SH
cat > "$WORK/fake/curl" <<'SH'
#!/usr/bin/env bash
# Records its command line, and any config given on stdin or by file, apart: the test checks a
# password reaches the config and not the command line.
printf 'curl %s\n' "$*" >> "$FAKE_CALLS"
conf=""
prev=""
for a in "$@"; do
  if [ "$prev" = --config ]; then conf="$a"; fi
  prev="$a"
done
if [ -n "$conf" ]; then cat "$conf" >> "$FAKE_CURL_CONFIG"; fi
if [ -f "$FAKE_DIR/curl-exit" ]; then
  echo "curl: (67) Login denied" >&2
  exit "$(cat "$FAKE_DIR/curl-exit")"
fi
exit 0
SH
FAKE_CALLS="$CALLS"; FAKE_DIR="$WORK/fake"; FAKE_BUNDLE="$B"; FAKE_CURL_CONFIG="$WORK/curl-config"
: > "$FAKE_CURL_CONFIG"
# Jobs run with a clean environment, so the fakes carry these within them.
for f in docker rsync curl age; do
  { head -n 1 "$WORK/fake/$f"
    printf 'FAKE_CALLS=%s\nFAKE_DIR=%s\nFAKE_BUNDLE=%s\nFAKE_CURL_CONFIG=%s\n' "$FAKE_CALLS" "$FAKE_DIR" "$FAKE_BUNDLE" "$FAKE_CURL_CONFIG"
    tail -n +2 "$WORK/fake/$f"
  } > "$WORK/fake/$f.new"
  mv "$WORK/fake/$f.new" "$WORK/fake/$f"
  chmod +x "$WORK/fake/$f"
done
export PATH="$WORK/fake:$PATH"
export DOCKER_HOST=unix:///nonexistent/docker.sock WORKFORCE_IN_STACK=1 STAFF_MAIL_RETRY_SECS=0
# In a container this runs as root, and the app's uid is a real, separate one: see the end.
export SA_APP_UID=""

SA="$B/bin/server-actions.sh"
REQ="$B/actions/requests"; RES="$B/actions/results"; WRK="$B/actions/work"
LOG="$B/logs/server-actions.log"
mkdir -p "$REQ" "$RES"

# Called in $(...), so the count lives in a file.
echo 0 > "$WORK/n"
new_id() { local n; n=$(( $(cat "$WORK/n") + 1 )); echo "$n" > "$WORK/n"; printf 'aaaaaaaa-0000-4000-8000-%012d' "$n"; }
BY='bbbbbbbb-0000-4000-8000-000000000001'
NOW="$(date +%s)"
# request <id> <action> <params json> [createdAt]
request() {
  jq -n --arg id "$1" --arg action "$2" --argjson params "$3" --argjson created "${4:-$NOW}" --arg by "$BY" \
    '{ schema: 1, id: $id, action: $action, createdAt: $created, requestedBy: $by, params: $params }' > "$REQ/$1.json"
}
once() { NOW="$(date +%s)"; bash "$SA" --once > "$WORK/out" 2>&1; RC=$?; }
state_of() { jq -r .state "$RES/$1.json" 2>/dev/null; }
code_of() { jq -r .code "$RES/$1.json" 2>/dev/null; }
message_of() { jq -r .message "$RES/$1.json" 2>/dev/null; }
data_of() { jq -r ".data.$2" "$RES/$1.json" 2>/dev/null; }
env_of() { (cd "$B" && bash -c '. ./.env; printf "%s" "${'"$1"':-}"'); }
clear_calls() { : > "$CALLS"; : > "$FAKE_CURL_CONFIG"; }
no_commands() { check "$1: nothing ran" "$(wc -l < "$CALLS" | tr -d ' ')" 0; }
ENV_BEFORE=""
remember_env() { ENV_BEFORE="$(cat "$B/.env")"; }
env_unchanged() { check "$1: .env unchanged" "$(cat "$B/.env")" "$ENV_BEFORE"; }

relay_params() { # relay_params <password> [host] [port] [user] [from] [to]
  jq -n --arg password "$1" --arg host "${2-smtp.new.example.test}" --arg port "${3-587}" --arg username "${4-newuser}" \
    --arg from "${5:-noreply@new.example.test}" --arg testAddress "${6:-me@outside.example.net}" \
    '{ host: $host, port: $port, username: $username, password: $password, from: $from, testAddress: $testAddress }'
}
alert_params() { # alert_params <list> [own] [mode] [url]
  jq -n --arg alertAddress "$1" --arg acceptOwnDomain "${2:-false}" --arg heartbeatMode "${3:-keep}" --arg heartbeatUrl "${4:-}" \
    '{ alertAddress: $alertAddress, acceptOwnDomain: $acceptOwnDomain, heartbeatMode: $heartbeatMode, heartbeatUrl: $heartbeatUrl }'
}
mail_params() { # mail_params <webmail> [mailHost] [useOutgoingRelay] [spf]
  jq -n --arg webmailHost "$1" --arg mailHost "${2:-}" --arg useOutgoingRelay "${3:-false}" --arg relaySpfInclude "${4:-}" \
    '{ webmailHost: $webmailHost, mailHost: $mailHost, useOutgoingRelay: $useOutgoingRelay, relaySpfInclude: $relaySpfInclude }'
}

# --- 1. not outside the stack, and an unknown mode
out="$(WORKFORCE_IN_STACK='' bash "$SA" --once 2>&1)"; check "refuses outside the backup container" "$?" 2
contains "says where it runs" "$out" "backup container"
out="$(bash "$SA" --run-anything 2>&1)"; check "an unknown mode is refused" "$?" 2

# --- 2. the heartbeat
once
check "an empty pass exits 0" "$RC" 0
check "heartbeat written" "$(jq -r '.schema, .enabled, .busy' "$RES/helper.json" | tr '\n' ' ')" "1 true false "
check "heartbeat knows the relay" "$(jq -r '.settings.relay.host' "$RES/helper.json")" "relay.old.example.test"
check "heartbeat says it signs in, not as whom" "$(jq -r '.settings.relay.signsIn' "$RES/helper.json")" "true"
check "heartbeat readable by the app" "$(stat -c %a "$RES/helper.json")" "644"
hb="$(cat "$RES/helper.json")"
lacks "no password in the heartbeat" "$hb" "$OLD_PW"
lacks "no user name in the heartbeat" "$hb" "olduser"
check "results folder open to the app" "$(stat -c %a "$RES")" "755"
check "work folder closed" "$(stat -c %a "$WRK")" "700"
check "requests folder closed to others" "$(stat -c %a "$REQ")" "700"

# --- 3. the allow-list
clear_calls; remember_env
for action in rm-rf run-script update restore 'backup-now; touch pwned' '$(touch pwned)' '../../bin/backup.sh' recovery-email BACKUP-NOW ''; do
  id="$(new_id)"; request "$id" "$action" '{}'; once
  check "not on the list [$action]: refused" "$(state_of "$id")" REFUSED
  check "not on the list [$action]: why" "$(code_of "$id")" NOT_ALLOWED
  check "not on the list [$action]: file gone" "$([ -e "$REQ/$id.json" ] && echo yes || echo no)" no
done
no_commands "not on the list"; env_unchanged "not on the list"
[ ! -e "$B/pwned" ] && ok || bad "a metacharacter in an action ran"
[ ! -e "$WORK/pwned" ] && ok || bad "a metacharacter in an action ran (2)"
contains "a refusal is logged" "$(cat "$LOG")" "REFUSED NOT_ALLOWED"
lacks "the hostile name is not logged as it came" "$(cat "$LOG")" 'touch pwned'

# --- 4. the shape: exactly these keys, these types, no control characters
hostile_json() { # hostile_json <label> <raw file contents>
  local id; id="$(new_id)"
  printf '%s' "$(printf '%s' "$2" | sed "s/@ID@/$id/g; s/@NOW@/$NOW/g; s/@BY@/$BY/g")" > "$REQ/$id.json"
  once
  check "shape [$1]: refused" "$(state_of "$id")" REFUSED
  check "shape [$1]: why" "$(code_of "$id")" BAD_SHAPE
  check "shape [$1]: file gone" "$([ -e "$REQ/$id.json" ] && echo yes || echo no)" no
}
clear_calls; remember_env
hostile_json "not JSON" 'not json at all'
hostile_json "empty" ''
hostile_json "half" '{"schema":1,"id":'
hostile_json "an array" '[1,2,3]'
hostile_json "wrong schema" '{"schema":2,"id":"@ID@","action":"backup-now","createdAt":@NOW@,"requestedBy":"@BY@","params":{}}'
hostile_json "an extra key" '{"schema":1,"id":"@ID@","action":"backup-now","createdAt":@NOW@,"requestedBy":"@BY@","params":{},"shell":"x"}'
hostile_json "a missing key" '{"schema":1,"id":"@ID@","action":"backup-now","createdAt":@NOW@,"params":{}}'
hostile_json "params not an object" '{"schema":1,"id":"@ID@","action":"backup-now","createdAt":@NOW@,"requestedBy":"@BY@","params":"x"}'
hostile_json "a number as a param" '{"schema":1,"id":"@ID@","action":"relay-apply","createdAt":@NOW@,"requestedBy":"@BY@","params":{"host":1}}'
hostile_json "an object as a param" '{"schema":1,"id":"@ID@","action":"relay-apply","createdAt":@NOW@,"requestedBy":"@BY@","params":{"host":{"a":"b"}}}'
hostile_json "action not a string" '{"schema":1,"id":"@ID@","action":["backup-now"],"createdAt":@NOW@,"requestedBy":"@BY@","params":{}}'
hostile_json "createdAt a string" '{"schema":1,"id":"@ID@","action":"backup-now","createdAt":"now","requestedBy":"@BY@","params":{}}'
hostile_json "a fractional time" '{"schema":1,"id":"@ID@","action":"backup-now","createdAt":1.5,"requestedBy":"@BY@","params":{}}'
hostile_json "the id not the file name" '{"schema":1,"id":"aaaaaaaa-0000-4000-8000-999999999999","action":"backup-now","createdAt":@NOW@,"requestedBy":"@BY@","params":{}}'
hostile_json "traversal in the id" '{"schema":1,"id":"../../../etc/passwd","action":"backup-now","createdAt":@NOW@,"requestedBy":"@BY@","params":{}}'
hostile_json "metacharacters in requestedBy" '{"schema":1,"id":"@ID@","action":"backup-now","createdAt":@NOW@,"requestedBy":"$(touch pwned)","params":{}}'
hostile_json "a newline in a value" '{"schema":1,"id":"@ID@","action":"relay-apply","createdAt":@NOW@,"requestedBy":"@BY@","params":{"host":"x\nEVIL=1","port":"587","username":"","password":"","from":"a@b.c","testAddress":"a@b.c"}}'
hostile_json "a carriage return" '{"schema":1,"id":"@ID@","action":"relay-apply","createdAt":@NOW@,"requestedBy":"@BY@","params":{"host":"x\rEVIL=1","port":"587","username":"","password":"","from":"a@b.c","testAddress":"a@b.c"}}'
hostile_json "a NUL" '{"schema":1,"id":"@ID@","action":"backup-now\u0000","createdAt":@NOW@,"requestedBy":"@BY@","params":{}}'
hostile_json "a trailing newline in the action" '{"schema":1,"id":"@ID@","action":"backup-now\n","createdAt":@NOW@,"requestedBy":"@BY@","params":{}}'
hostile_json "an escape character" '{"schema":1,"id":"@ID@","action":"alerts-set","createdAt":@NOW@,"requestedBy":"@BY@","params":{"alertAddress":"\u001b[2J"}}'
hostile_json "a hostile param name" '{"schema":1,"id":"@ID@","action":"backup-now","createdAt":@NOW@,"requestedBy":"@BY@","params":{"a b; c":"x"}}'
no_commands "shape"; env_unchanged "shape"
[ ! -e "$B/pwned" ] && ok || bad "a metacharacter in requestedBy ran"

# Params that aren't exactly the action's
id="$(new_id)"; request "$id" backup-now '{"extra":"x"}'; once
check "a param the action doesn't take" "$(code_of "$id")" BAD_SHAPE
id="$(new_id)"; request "$id" relay-apply '{"host":"a.example"}'; once
check "params missing" "$(code_of "$id")" BAD_SHAPE
no_commands "wrong params"

# --- 5. files that aren't files
clear_calls; remember_env
id="$(new_id)"; ln -s "$B/.env" "$REQ/$id.json"; once
check "a symlink to .env: refused" "$(state_of "$id")" REFUSED
check "a symlink to .env: why" "$(code_of "$id")" NOT_A_FILE
check ".env is still there" "$([ -f "$B/.env" ] && echo yes)" yes
lacks "a symlink's target isn't quoted back" "$(cat "$RES/$id.json")" "SMTP_"
id="$(new_id)"; ln -s /etc/passwd "$REQ/$id.json"; once
check "a symlink out of the bundle" "$(code_of "$id")" NOT_A_FILE
id="$(new_id)"; ln -s /nonexistent "$REQ/$id.json"; once
check "a dangling symlink" "$(code_of "$id")" NOT_A_FILE
check "the dangling link is gone" "$([ -L "$REQ/$id.json" ] && echo yes || echo no)" no
id="$(new_id)"; mkdir "$REQ/$id.json"; once
check "a directory" "$(code_of "$id")" NOT_A_FILE
id="$(new_id)"; mkfifo "$REQ/$id.json"; once   # would hang a reader for ever
check "a FIFO" "$(code_of "$id")" NOT_A_FILE
id="$(new_id)"; request "$id" backup-now '{}'; ln "$REQ/$id.json" "$WORK/hardlink-$id"; once
check "a hard link" "$(code_of "$id")" NOT_A_FILE
id="$(new_id)"; head -c 40000 /dev/zero | tr '\0' 'x' > "$REQ/$id.json"; once
check "an oversized file" "$(code_of "$id")" NOT_A_FILE
check "the oversized file is gone" "$([ -e "$REQ/$id.json" ] && echo yes || echo no)" no
no_commands "not files"; env_unchanged "not files"

# Hostile file names: refused and gone, nothing made of them, and the log isn't written to by them
clear_calls; : > "$LOG"
before="$(find "$RES" -type f | wc -l)"
for name in 'not-a-uuid.json' '; touch pwned;.json' '$(touch pwned).json' 'x
y.json' 'aaaaaaaa-0000-4000-8000-000000000001.json.bak' '--help' '-rf'; do
  printf '{}' > "$REQ/$name"
done
ln -s "$B/.env" "$REQ/link-to-env"
once
check "hostile names: all gone" "$(find "$REQ" -mindepth 1 | wc -l | tr -d ' ')" 0
check "hostile names: no result made" "$(find "$RES" -type f | wc -l)" "$before"
check "hostile names: refused in the log" "$(grep -c 'REFUSED BAD_NAME' "$LOG")" 8
check "hostile names: no log line of their own" "$(grep -vcE '^20[0-9-]+T[0-9:]+Z ' "$LOG")" 0
[ ! -e "$B/pwned" ] && ok || bad "a hostile file name ran"
no_commands "hostile names"

# Half-written files the app left: not touched while new, gone when old
printf 'secret' > "$REQ/.tmp-new"
printf 'secret' > "$REQ/.tmp-old"; touch -d '1 hour ago' "$REQ/.tmp-old" 2>/dev/null || touch -d "$(date -u -d "@$(( $(date +%s) - 3600 ))" '+%Y-%m-%d %H:%M:%S')" "$REQ/.tmp-old"
once
check "a new temp file stays" "$([ -e "$REQ/.tmp-new" ] && echo yes || echo no)" yes
check "an old temp file goes" "$([ -e "$REQ/.tmp-old" ] && echo yes || echo no)" no
rm -f "$REQ/.tmp-new"

# --- 6. once only
clear_calls; remember_env
id="$(new_id)"; request "$id" alerts-set "$(alert_params ops@outside.example.net)"; once
check "first time: done" "$(state_of "$id")" SUCCEEDED
first="$(cat "$RES/$id.json")"
clear_calls
request "$id" alerts-set "$(alert_params other@outside.example.net)"; once
check "second time: nothing done" "$(wc -l < "$CALLS" | tr -d ' ')" 0
check "second time: the first result stands" "$(cat "$RES/$id.json")" "$first"
check "second time: file gone" "$([ -e "$REQ/$id.json" ] && echo yes || echo no)" no
contains "second time: logged" "$(cat "$LOG")" "$id - REFUSED ALREADY_SEEN"
check "second time: .env unchanged" "$(env_of OPS_ALERT_EMAIL)" ops@outside.example.net
reset_env

# --- 7. expiry: not picked up in time, never runs later
clear_calls; remember_env
OLD=$(( $(date +%s) - 300 ))
id="$(new_id)"; request "$id" backup-now '{}' "$OLD"; once
check "old request: expired" "$(state_of "$id")" EXPIRED
check "old request: why" "$(code_of "$id")" NOT_PICKED_UP
check "old request: file gone" "$([ -e "$REQ/$id.json" ] && echo yes || echo no)" no
id="$(new_id)"; request "$id" backup-now '{}'; touch -d "@$OLD" "$REQ/$id.json" 2>/dev/null || touch -d "$(date -u -d "@$OLD" '+%Y-%m-%d %H:%M:%S')" "$REQ/$id.json"
once
check "a file that's old whatever it says" "$(state_of "$id")" EXPIRED
id="$(new_id)"; request "$id" relay-apply "$(relay_params "$SECRET_PW")" "$OLD"; once
check "old request with a password: expired" "$(state_of "$id")" EXPIRED
check "old request with a password: file gone" "$([ -e "$REQ/$id.json" ] && echo yes || echo no)" no
id="$(new_id)"; request "$id" backup-now '{}' $(( $(date +%s) + 3600 )); once
check "dated in the future: refused" "$(state_of "$id")" REFUSED
no_commands "expired"; env_unchanged "expired"

# --- 8. the helper's own switch
clear_calls
printf 'SERVER_ACTIONS=off\n' >> "$B/.env"; remember_env
id="$(new_id)"; request "$id" backup-now '{}'; once
check "switched off: refused" "$(state_of "$id")" REFUSED
check "switched off: why" "$(code_of "$id")" SWITCHED_OFF
check "switched off: heartbeat says so" "$(jq -r .enabled "$RES/helper.json")" false
id="$(new_id)"; request "$id" relay-apply "$(relay_params "$SECRET_PW")"; once
check "switched off: a password doesn't stay" "$([ -e "$REQ/$id.json" ] && echo yes || echo no)" no
no_commands "switched off"; env_unchanged "switched off"
reset_env

# --- 9. hostile values in each job's parameters: refused, and they reach no command
hostile_relay() { # hostile_relay <label> <params json>
  local id; id="$(new_id)"
  request "$id" relay-apply "$2"; once
  check "relay value [$1]: refused" "$(state_of "$id")" REFUSED
  check "relay value [$1]: request gone" "$([ -e "$REQ/$id.json" ] && echo yes || echo no)" no
}
clear_calls; remember_env
for v in 'smtp.example.test;touch pwned' '$(touch pwned)' '`touch pwned`' 'a b' 'a|b' 'a&b' '../../etc' 'smtp.example.test/x' 'UPPER.example.test' '-oProxyCommand=touch pwned' '' "a'b" 'a"b'; do
  hostile_relay "host $v" "$(relay_params "$SECRET_PW" "$v")"
done
for v in 465 abc 0 99999 '587;touch pwned' '' '587 ' '$(id)' 0587; do
  hostile_relay "port $v" "$(relay_params "$SECRET_PW" smtp.example.test "$v")"
done
for v in 'a b' 'a;b' '$(touch pwned)' '`x`' "a'b" 'a"b' 'a\b'; do
  hostile_relay "user $v" "$(relay_params "$SECRET_PW" smtp.example.test 587 "$v")"
done
for v in "pass'word1" 'pass\word1' 'endsin\' "pass\${word}1" 'pass#{word}1' 'short' 'caf€wörd1'; do
  hostile_relay "password $v" "$(relay_params "$v")"
done
for v in 'not-an-address' 'a@b' 'a b@c.test' 'a;touch pwned@c.test' '$(touch pwned)@c.test' 'a@c.test,b@c.test' '<a@c.test>' 'Name <a@c.test>'; do
  hostile_relay "from $v" "$(relay_params "$SECRET_PW" smtp.example.test 587 newuser "$v")"
  hostile_relay "to $v" "$(relay_params "$SECRET_PW" smtp.example.test 587 newuser ok@example.test "$v")"
done
hostile_relay "a password with no user" "$(relay_params "$SECRET_PW" smtp.example.test 587 "")"
hostile_relay "a user with no password" "$(relay_params "" smtp.example.test 587 newuser)"
no_commands "relay values"; env_unchanged "relay values"
[ ! -e "$B/pwned" ] && ok || bad "a relay value ran"
lacks "no refused password in the log" "$(cat "$LOG")" "pass'word1"

hostile_mail() { # hostile_mail <label> <params json>
  local id; id="$(new_id)"
  request "$id" staff-mail-on "$2"; once
  check "mail value [$1]: refused" "$(state_of "$id")" REFUSED
}
clear_calls; remember_env
for v in 'webmail.example.test;touch pwned' '$(touch pwned).example.test' '../../etc' 'webmail' '' 'WEBMAIL.example.test' 'webmail .example.test' 'app.example.test' 'auth.example.test' '-x.example.test'; do
  hostile_mail "webmail $v" "$(mail_params "$v")"
done
hostile_mail "mail host" "$(mail_params webmail.example.test '$(id).example.test')"
hostile_mail "relay flag" "$(mail_params webmail.example.test '' 'true;id')"
hostile_mail "spf" "$(mail_params webmail.example.test '' false '; id')"
no_commands "mail values"; env_unchanged "mail values"

hostile_alert() { # hostile_alert <label> <params json> [code]
  local id; id="$(new_id)"
  request "$id" alerts-set "$2"; once
  check "alert value [$1]: refused" "$(state_of "$id")" REFUSED
  [ -z "${3:-}" ] || check "alert value [$1]: why" "$(code_of "$id")" "$3"
}
clear_calls; remember_env
for v in 'not-an-address' 'a@b' 'a b@c.test' 'a@c.test;touch pwned' '$(touch pwned)@c.test' 'a@c.test,' ',a@c.test' 'a@c.test,,b@c.test' "o'brien@c.test" '`id`@c.test' 'a@c.test,b@c.test,c@c.test,d@c.test,e@c.test,f@c.test'; do
  hostile_alert "address $v" "$(alert_params "$v")"
done
for v in 'http://hc-ping.example.test/x' 'https://hc-ping.example.test' 'https://user:pw@hc-ping.example.test/x' "https://hc.example.test/a'b" 'https://hc.example.test/$(touch pwned)' 'https://hc.example.test/a b' 'https://hc.example.test/a;b' 'https://hc.example.test/`id`' 'file:///etc/passwd' 'https://nodots/x'; do
  hostile_alert "ping $v" "$(alert_params ok@outside.example.net false set "$v")"
done
hostile_alert "a mode not on the list" "$(alert_params ok@outside.example.net false 'set;id' '')"
hostile_alert "a URL with keep" "$(alert_params ok@outside.example.net false keep "$PING_URL")"
hostile_alert "an address on this server's own name, not confirmed" "$(alert_params me@app.example.test)" OWN_DOMAIN
hostile_alert "an address on its parent domain, not confirmed" "$(alert_params me@example.test)" OWN_DOMAIN
no_commands "alert values"; env_unchanged "alert values"
[ ! -e "$B/pwned" ] && ok || bad "an alert value ran"

# --- 10. back up now, the whole way through the real backup.sh
clear_calls; reset_env
id="$(new_id)"; request "$id" backup-now '{}'; once
check "backup: succeeded" "$(state_of "$id")" SUCCEEDED
check "backup: no off-site target" "$(data_of "$id" offsite)" NONE
archive="$(data_of "$id" archive)"
check "backup: the archive exists" "$([ -f "$B/backups/$archive" ] && echo yes)" yes
check "backup: its size" "$(data_of "$id" sizeBytes)" "$(stat -c %s "$B/backups/$archive")"
contains "backup: logged" "$(cat "$LOG")" "$id backup-now STARTED"
contains "backup: what it said is in the log" "$(cat "$LOG")" "Retention applied"
contains "backup: and in the nightly's log" "$(cat "$B/backups/cron.log")" "Retention applied"
check "backup: nothing left behind" "$(find "$WRK" -maxdepth 1 -type f ! -name lock | wc -l | tr -d ' ')" 0

# Off-site target, and a failed copy reported without calling the backup a failure
sleep 1
printf 'BACKUP_TARGET=user@backup.example.test:/srv\n' >> "$B/.env"
# A target with no recipient: nothing is sent, and the result says so without the job failing
clear_calls
id="$(new_id)"; request "$id" backup-now '{}'; once
check "no recipient: the backup still stands" "$(state_of "$id")" SUCCEEDED
check "no recipient: it says so" "$(data_of "$id" offsite)" FAILED
lacks "no recipient: nothing sent" "$(cat "$CALLS")" "rsync -az"
id="$(new_id)"; request "$id" offsite-test '{}'; once
check "no recipient, test copy: failed" "$(state_of "$id")" FAILED
contains "no recipient, test copy: why, in words" "$(message_of "$id")" "BACKUP_ENCRYPT_RECIPIENT isn't set"
lacks "no recipient, test copy: nothing sent" "$(cat "$CALLS")" "rsync -az"
check "no recipient: the heartbeat knows" "$(jq -r .settings.offsite.encrypted "$RES/helper.json")" false
sleep 1
printf 'BACKUP_ENCRYPT_RECIPIENT=age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p\n' >> "$B/.env"
id="$(new_id)"; request "$id" backup-now '{}'; once
check "recipient: the heartbeat knows" "$(jq -r .settings.offsite.encrypted "$RES/helper.json")" true
check "backup with a target: succeeded" "$(state_of "$id")" SUCCEEDED
check "backup with a target: copied" "$(data_of "$id" offsite)" OK
sleep 1
touch "$WORK/fake/rsync-fails"
id="$(new_id)"; request "$id" backup-now '{}'; once
check "failed copy: the backup still stands" "$(state_of "$id")" SUCCEEDED
check "failed copy: it says so" "$(data_of "$id" offsite)" FAILED
contains "failed copy: in words" "$(message_of "$id")" "only on this server"
lacks "the target never reaches the result" "$(cat "$RES/$id.json")" "backup.example.test"

# --- 11. test the off-site copy: the same code path
clear_calls
id="$(new_id)"; request "$id" offsite-test '{}'; once
check "off-site test, failing: failed" "$(state_of "$id")" FAILED
check "off-site test, failing: why" "$(code_of "$id")" OFFSITE_FAILED
check "off-site test: what the last run did" "$(data_of "$id" lastCopyBefore)" FAILED
contains "off-site test: same code as the nightly" "$(cat "$CALLS")" "rsync -az"
lacks "off-site test: never the target in the result" "$(cat "$RES/$id.json")" "backup.example.test"
rm -f "$WORK/fake/rsync-fails"
id="$(new_id)"; request "$id" offsite-test '{}'; once
check "off-site test, working: succeeded" "$(state_of "$id")" SUCCEEDED
(
  # The health watch reads the same log: a test copy counts as the last copy.
  cd "$B" && set +euo pipefail
  . ./bin/healthwatch.sh; set +e
  check_val="$(offsite_last_copy)"
  [ "$check_val" = OK ] || echo "offsite_last_copy after a test: $check_val" >> "$WORK/subfail"
)
[ ! -e "$WORK/subfail" ] && ok || { bad "$(cat "$WORK/subfail")"; rm -f "$WORK/subfail"; }
reset_env
id="$(new_id)"; request "$id" offsite-test '{}'; once
check "off-site test, no target: refused" "$(state_of "$id")" REFUSED
check "off-site test, no target: why" "$(code_of "$id")" NO_TARGET
printf 'BACKUP_ENCRYPT_RECIPIENT=age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p\nBACKUP_TARGET=s3://bucket/path\nAWS_ACCESS_KEY_ID=AKIAEXAMPLE\nAWS_SECRET_ACCESS_KEY=topsecretawskey\nAWS_DEFAULT_REGION=eu-west-2\n' >> "$B/.env"
clear_calls
id="$(new_id)"; request "$id" offsite-test '{}'; once
check "off-site test, S3: succeeded" "$(state_of "$id")" SUCCEEDED
lacks "the S3 key isn't logged" "$(cat "$LOG")" "topsecretawskey"
reset_env
rm -f "$B"/backups/*.tar.gz
printf 'BACKUP_TARGET=s3://bucket/path\n' >> "$B/.env"
id="$(new_id)"; request "$id" offsite-test '{}'; once
check "off-site test, nothing to copy: refused" "$(code_of "$id")" NO_BACKUP
reset_env

# A backup already running (the nightly, say)
exec 7>>"$B/backups/.backup.lock"; flock -n 7
id="$(new_id)"; request "$id" backup-now '{}'; once
check "backup while one runs: refused" "$(state_of "$id")" REFUSED
check "backup while one runs: why" "$(code_of "$id")" BUSY
exec 7>&-

# A failed backup, in words
touch "$WORK/fake/mail-fails"; rm -f "$WORK/fake/mail-fails"
sed -i 's/^DB_NAME=.*/DB_NAME=/' "$B/.env"
mv "$WORK/fake/docker" "$WORK/fake/docker.real"
printf '#!/usr/bin/env bash\nprintf "docker %%s\\n" "$*" >> %s\nexit 0\n' "$CALLS" > "$WORK/fake/docker"; chmod +x "$WORK/fake/docker"
id="$(new_id)"; request "$id" backup-now '{}'; once
check "a failed backup: failed" "$(state_of "$id")" FAILED
check "a failed backup: why" "$(code_of "$id")" BACKUP_FAILED
contains "a failed backup: its last words" "$(message_of "$id")" "backup FAILED"
mv -f "$WORK/fake/docker.real" "$WORK/fake/docker"
reset_env

# --- 12. the relay. A test send first; nothing saved unless the relay accepted it
clear_calls; remember_env
echo 67 > "$WORK/fake/curl-exit"
id="$(new_id)"; request "$id" relay-apply "$(relay_params "$SECRET_PW")"; once
check "relay refused: failed" "$(state_of "$id")" FAILED
check "relay refused: why" "$(code_of "$id")" RELAY_REFUSED
contains "relay refused: in words" "$(message_of "$id")" "refused the user name or password"
contains "relay refused: nothing saved" "$(message_of "$id")" "Nothing was saved"
check "relay refused: says so" "$(data_of "$id" saved)" false
env_unchanged "relay refused"
lacks "relay refused: nothing restarted" "$(cat "$CALLS")" "docker compose up"
rm -f "$WORK/fake/curl-exit"
echo 7 > "$WORK/fake/curl-exit"
id="$(new_id)"; request "$id" relay-apply "$(relay_params "$SECRET_PW")"; once
contains "relay unreachable: in words" "$(message_of "$id")" "couldn't reach the relay"
env_unchanged "relay unreachable"
rm -f "$WORK/fake/curl-exit"

clear_calls
id="$(new_id)"; request "$id" relay-apply "$(relay_params "$SECRET_PW")"; once
check "relay accepted: succeeded" "$(state_of "$id")" SUCCEEDED
check "relay accepted: saved" "$(data_of "$id" saved)" true
check "relay saved: host" "$(env_of SMTP_HOST)" smtp.new.example.test
check "relay saved: user" "$(env_of SMTP_USERNAME)" newuser
check "relay saved: STARTTLS" "$(env_of SMTP_STARTTLS)" true
check "relay saved: the password reads back exactly" "$(env_of SMTP_PASSWORD)" "$SECRET_PW"
check "relay saved: in single quotes" "$(grep '^SMTP_PASSWORD=' "$B/.env")" "SMTP_PASSWORD='$SECRET_PW'"
check "relay saved: one line of it" "$(grep -c '^SMTP_PASSWORD=' "$B/.env")" 1
check "relay saved: .env keeps its mode" "$(stat -c %a "$B/.env")" 600
curls="$(grep '^curl' "$CALLS")"
contains "relay: went by STARTTLS" "$curls" "--ssl-reqd"
contains "relay: to the new relay" "$curls" "smtp://smtp.new.example.test:587/"
lacks "relay: password not on a command line" "$(cat "$CALLS")" "$SECRET_PW"
contains "relay: password in curl's config file" "$(cat "$FAKE_CURL_CONFIG")" 'user = "newuser:s3cret-Pw+with/odd\"chars#and$signs"'
# The order: what a restart would kill is never restarted, and the api, which reports the result, goes last.
ups="$(grep '^docker compose up' "$CALLS" | sed 's/docker compose up -d --no-deps --force-recreate //; s/--wait --wait-timeout 300 //')"
check "relay: worker, then api, nothing else" "$(printf '%s' "$ups" | tr '\n' ' ')" "worker api"
lacks "relay: the backup container is never restarted" "$(cat "$CALLS")" " backup"
contains "relay: the api is waited for" "$(cat "$CALLS")" "--wait"
contains "relay: the old alert address hears of it" "$(cat "$CALLS")" "--mail-rcpt ops@outside.example.net"
reset_env

# The relay that can't be saved safely goes no further, even after a good test
clear_calls; remember_env
touch "$WORK/fake/config-fails"
id="$(new_id)"; request "$id" relay-apply "$(relay_params "$SECRET_PW")"; once
check "compose can't read it: failed" "$(code_of "$id")" SAVE_FAILED
env_unchanged "compose can't read it"
lacks "compose can't read it: nothing restarted" "$(cat "$CALLS")" "docker compose up"
rm -f "$WORK/fake/config-fails"

# The api not coming back: the old settings go back, and the app is told so
clear_calls; remember_env
touch "$WORK/fake/api-fails"
id="$(new_id)"; request "$id" relay-apply "$(relay_params "$SECRET_PW")"; once
check "api doesn't come back: failed" "$(code_of "$id")" RESTART_FAILED
env_unchanged "api doesn't come back"
contains "api doesn't come back: restarted on the old values" "$(cat "$CALLS")" "--force-recreate worker api"
rm -f "$WORK/fake/api-fails"
check "no snapshot left behind" "$([ -e "$WRK/env.before" ] && echo yes || echo no)" no

# A mail server sending through the same relay follows it
printf 'MAIL_RELAY_HOST=relay.old.example.test\nMAIL_RELAY_USER=olduser\nMAIL_RELAY_PORT=587\n' >> "$B/.env"
printf 'old-password' > "$B/secrets/mail_relay_password"
inode_before="$(stat -c %i "$B/secrets/mail_relay_password")"
id="$(new_id)"; request "$id" relay-apply "$(relay_params "$SECRET_PW")"; once
check "shared relay: follows" "$(env_of MAIL_RELAY_HOST)" smtp.new.example.test
check "shared relay: its password file" "$(cat "$B/secrets/mail_relay_password")" "$SECRET_PW"
check "shared relay: the same file, for the mount" "$(stat -c %i "$B/secrets/mail_relay_password")" "$inode_before"
check "shared relay: readable by the app" "$(stat -c %a "$B/secrets/mail_relay_password")" 644
reset_env
printf 'MAIL_RELAY_HOST=other.relay.example.test\nMAIL_RELAY_USER=someone\n' >> "$B/.env"
printf 'its-own-password' > "$B/secrets/mail_relay_password"
id="$(new_id)"; request "$id" relay-apply "$(relay_params "$SECRET_PW")"; once
check "a relay of its own: left alone" "$(env_of MAIL_RELAY_HOST)" other.relay.example.test
check "a relay of its own: its password left alone" "$(cat "$B/secrets/mail_relay_password")" its-own-password
reset_env

# No user name: the provider allows this server by its address
clear_calls
id="$(new_id)"; request "$id" relay-apply "$(relay_params "" smtp.ip-allowed.example.test 587 "")"; once
check "no user name: succeeded" "$(state_of "$id")" SUCCEEDED
check "no user name: no login sent" "$(wc -c < "$FAKE_CURL_CONFIG" | tr -d ' ')" 0
check "no user name: no password stored" "$(env_of SMTP_PASSWORD)" ""
reset_env

# The one exception: only if .env says so, and only exactly that relay
clear_calls
id="$(new_id)"; request "$id" relay-apply "$(relay_params "" mailpit 1025 "" workforce@example.test)"; once
contains "mailpit, not allowed: STARTTLS still demanded" "$(cat "$CALLS")" "--ssl-reqd"
reset_env
printf 'SERVER_ACTIONS_PLAIN_RELAY=mailpit:1025\n' >> "$B/.env"
clear_calls
id="$(new_id)"; request "$id" relay-apply "$(relay_params "" mailpit 1025 "" workforce@example.test)"; once
lacks "mailpit, allowed: no STARTTLS" "$(grep '^curl' "$CALLS")" "--ssl-reqd"
check "mailpit, allowed: stored as it is" "$(env_of SMTP_STARTTLS)" false
clear_calls
id="$(new_id)"; request "$id" relay-apply "$(relay_params "" mailpit 1026 "" workforce@example.test)"; once
contains "another port: STARTTLS still demanded" "$(cat "$CALLS")" "--ssl-reqd"
reset_env

# --- 13. alerts
clear_calls
id="$(new_id)"; request "$id" alerts-set "$(alert_params new@outside.example.net,two@outside.example.net false set "$PING_URL")"; once
check "alerts: succeeded" "$(state_of "$id")" SUCCEEDED
check "alerts: saved" "$(env_of OPS_ALERT_EMAIL)" new@outside.example.net,two@outside.example.net
check "alerts: the ping address reads back exactly" "$(env_of OPS_HEARTBEAT_URL)" "$PING_URL"
check "alerts: test sent" "$(data_of "$id" testSent)" true
check "alerts: ping answered" "$(data_of "$id" ping)" sent
contains "alerts: to the new addresses" "$(cat "$CALLS")" "--mail-rcpt two@outside.example.net"
contains "alerts: the old address hears of it" "$(cat "$CALLS")" "--mail-rcpt ops@outside.example.net"
lacks "alerts: no restart" "$(cat "$CALLS")" "docker compose up"
lacks "alerts: ping address not on a command line" "$(cat "$CALLS")" "secret-ping"
lacks "alerts: ping address not in the result" "$(cat "$RES/$id.json")" "secret-ping"
lacks "alerts: ping address not in the log" "$(cat "$LOG")" "secret-ping"
check "alerts: heartbeat knows it's set, not what it is" "$(jq -r .settings.alerts.heartbeatSet "$RES/helper.json")" true
lacks "alerts: heartbeat doesn't say what it is" "$(cat "$RES/helper.json")" "secret-ping"
# keep and clear
id="$(new_id)"; request "$id" alerts-set "$(alert_params new@outside.example.net false keep)"; once
check "alerts, keep: the ping stays" "$(env_of OPS_HEARTBEAT_URL)" "$PING_URL"
id="$(new_id)"; request "$id" alerts-set "$(alert_params new@outside.example.net false clear)"; once
check "alerts, clear: the ping goes" "$(env_of OPS_HEARTBEAT_URL)" ""
# none: allowed, and says what that means
id="$(new_id)"; request "$id" alerts-set "$(alert_params "")"; once
check "alerts, none: succeeded" "$(state_of "$id")" SUCCEEDED
contains "alerts, none: says what that means" "$(message_of "$id")" "only written to the server's log"
# confirmed on the server's own domain
id="$(new_id)"; request "$id" alerts-set "$(alert_params me@example.test true)"; once
check "alerts, own domain confirmed: saved" "$(env_of OPS_ALERT_EMAIL)" me@example.test
# the test failing: saved, and it says the test didn't go
echo 7 > "$WORK/fake/curl-exit"
id="$(new_id)"; request "$id" alerts-set "$(alert_params third@outside.example.net)"; once
check "alerts, test fails: still saved" "$(env_of OPS_ALERT_EMAIL)" third@outside.example.net
check "alerts, test fails: says so" "$(code_of "$id")" TEST_NOT_SENT
check "alerts, test fails: not sent" "$(data_of "$id" testSent)" false
rm -f "$WORK/fake/curl-exit"
reset_env

# --- 14. staff email, through the real staff-mail.sh, as it runs in the backup container
clear_calls
id="$(new_id)"; request "$id" staff-mail-on "$(mail_params webmail.example.test '' true spf.relay.example.test)"; once
check "mail on: succeeded" "$(state_of "$id")" SUCCEEDED
check "mail on: profile" "$(env_of COMPOSE_PROFILES)" staffmail
check "mail on: webmail host" "$(env_of WEBMAIL_HOSTNAME)" webmail.example.test
check "mail on: mail host defaults to it" "$(env_of MAIL_HOSTNAME)" webmail.example.test
check "mail on: uses the outgoing relay" "$(env_of MAIL_RELAY_HOST)" relay.old.example.test
check "mail on: and its user" "$(env_of MAIL_RELAY_USER)" olduser
check "mail on: spf" "$(env_of MAIL_RELAY_SPF_INCLUDE)" spf.relay.example.test
check "mail on: relay password given to the mail server" "$(cat "$B/secrets/mail_relay_password")" "$OLD_PW"
check "mail on: certificates checked on a real server" "$(env_of MAIL_TLS_VERIFY)" true
for s in mail_admin_password mail_db_password webmail_des_key; do
  check "mail on: $s readable by the app" "$(stat -c %a "$B/secrets/$s")" 644
done
check "mail on: the sign-in server's settings rendered" "$(grep -c 'meta_launch_url: https://webmail.example.test/' "$B/blueprints/webmail-app.yaml")" 1
contains "mail on: with the keys" "$(cat "$B/blueprints/webmail-app.yaml")" "client_secret: cafef00dcafef00d"
lacks "mail on: no template left in it" "$(cat "$B/blueprints/webmail-app.yaml")" "{{"
lacks "mail on: nor blocks" "$(cat "$B/blueprints/webmail-app.yaml")" "{%"
contains "mail on: applied" "$(cat "$CALLS")" "apply_blueprint /blueprints/webmail-app.yaml"
contains "mail on: mail server started" "$(cat "$CALLS")" "docker compose up -d mail-db-init mail webmail"
contains "mail on: app restarted" "$(cat "$CALLS")" "docker compose up -d --force-recreate api worker gateway"
lacks "mail on: backup container left alone" "$(cat "$CALLS")" " backup"
check "mail on: settings shown" "$(jq -r .settings.staffMail.on "$RES/helper.json")" true
lacks "mail on: no key in the log" "$(cat "$LOG")" "cafef00dcafef00d"
lacks "mail on: no relay password in the log" "$(cat "$LOG")" "$OLD_PW"
lacks "mail on: no relay password in the result" "$(cat "$RES/$id.json")" "$OLD_PW"

# off
clear_calls
id="$(new_id)"; request "$id" staff-mail-off '{}'; once
check "mail off: succeeded" "$(state_of "$id")" SUCCEEDED
check "mail off: profile gone" "$(env_of COMPOSE_PROFILES)" ""
check "mail off: app told" "$(env_of MAIL_SERVER_URL)" ""
contains "mail off: stopped" "$(cat "$CALLS")" "docker compose stop mail webmail"
lacks "mail off: backup container left alone" "$(cat "$CALLS")" " backup"
reset_env

# The private CA: from this server's own settings, and never from the request
sed -i 's#^GATEWAY_CADDYFILE=.*#GATEWAY_CADDYFILE=./gateway/Caddyfile.localca#' "$B/.env"
clear_calls
id="$(new_id)"; request "$id" staff-mail-on "$(mail_params webmail.example.test)"; once
check "private CA server: not verifying" "$(env_of MAIL_TLS_VERIFY)" false
check "private CA server: heartbeat knows" "$(jq -r .settings.staffMail.privateCa "$RES/helper.json")" true
reset_env

# Port 25 not open: the settings go back, and the words say what to do
clear_calls; remember_env
touch "$WORK/fake/mail-fails"
id="$(new_id)"; request "$id" staff-mail-on "$(mail_params webmail.example.test)"; once
check "port 25: failed" "$(state_of "$id")" FAILED
check "port 25: why" "$(code_of "$id")" PORT_25
contains "port 25: what to do" "$(message_of "$id")" "ip_unprivileged_port_start=25"
env_unchanged "port 25"
contains "port 25: mail stopped again" "$(cat "$CALLS")" "docker compose stop mail webmail"
rm -f "$WORK/fake/mail-fails"
# No relay yet, and it was asked for
sed -i 's/^SMTP_HOST=.*/SMTP_HOST=/' "$B/.env"
clear_calls; remember_env
id="$(new_id)"; request "$id" staff-mail-on "$(mail_params webmail.example.test '' true)"; once
check "no relay yet: refused" "$(code_of "$id")" NO_RELAY
no_commands "no relay yet"; env_unchanged "no relay yet"
reset_env

# --- 15. one at a time, and a time limit
clear_calls; remember_env
touch "$WORK/fake/slow-backup"
first="$(new_id)"; request "$first" backup-now '{}'
SA_LIMIT_BACKUP=2 SA_KILL_GRACE=2 bash "$SA" --once > "$WORK/out" 2>&1 &
slow=$!
for _ in $(seq 1 30); do [ -f "$WRK/running" ] && break; sleep 0.2; done
check "a job in progress is marked" "$([ -f "$WRK/running" ] && echo yes || echo no)" yes
check "a job in progress: RUNNING" "$(state_of "$first")" RUNNING
contains "a job in progress: has a deadline" "$(jq -r .deadline "$RES/$first.json")" "T"
# Another comes in. --beat says busy and refuses it; a second holder can't start.
second="$(new_id)"; request "$second" relay-apply "$(relay_params "$SECRET_PW")"
bash "$SA" --beat > "$WORK/out2" 2>&1
check "while busy: refused" "$(state_of "$second")" REFUSED
check "while busy: why" "$(code_of "$second")" BUSY
check "while busy: the password doesn't stay" "$([ -e "$REQ/$second.json" ] && echo yes || echo no)" no
check "while busy: heartbeat says so" "$(jq -r .busy "$RES/helper.json")" true
third="$(new_id)"; request "$third" backup-now '{}'
bash "$SA" --once > "$WORK/out3" 2>&1
check "while busy: a second run refuses it too" "$(code_of "$third")" BUSY
wait "$slow"
# It stops the whole job, not just its first process: nothing the job started goes on to do more.
clear_calls
sleep 3
no_commands "over the limit: nothing carries on"
check "over the limit: failed" "$(state_of "$first")" FAILED
check "over the limit: why" "$(code_of "$first")" TIMED_OUT
contains "over the limit: in words" "$(message_of "$first")" "longer than the time allowed"
check "over the limit: the marker is gone" "$([ -e "$WRK/running" ] && echo yes || echo no)" no
rm -f "$WORK/fake/slow-backup"
env_unchanged "over the limit"

# A job that was running when the container restarted: reported, not rerun, settings back
lost="$(new_id)"
remember_env
cp -p "$B/.env" "$WRK/env.before"
printf 'SMTP_HOST=half.way.example.test\n' >> "$B/.env"
printf '%s relay-apply\n' "$lost" > "$WRK/running"
write_running="$(jq -n --arg id "$lost" '{schema:1,id:$id,action:"relay-apply",state:"RUNNING",code:"",message:"",phase:null,startedAt:null,finishedAt:null,deadline:null,data:{}}')"
printf '%s\n' "$write_running" > "$RES/$lost.json"
clear_calls
once
check "interrupted: failed" "$(state_of "$lost")" FAILED
check "interrupted: why" "$(code_of "$lost")" INTERRUPTED
check "interrupted: marker gone" "$([ -e "$WRK/running" ] && echo yes || echo no)" no
env_unchanged "interrupted"
no_commands "interrupted"

# The lock is the kernel's: a killed holder leaves nothing behind
(
  exec 9>"$WRK/lock"; flock -n 9; sleep 2
) &
holder=$!
sleep 0.3
blocked="$(new_id)"; request "$blocked" backup-now '{}'
bash "$SA" --once > "$WORK/out4" 2>&1
check "someone else holds the lock, no job: left for them" "$([ -e "$REQ/$blocked.json" ] && echo yes || echo no)" yes
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
sleep 2.2
once
check "the lock freed itself" "$(state_of "$blocked")" SUCCEEDED

# --- 16. the password, everywhere it might have been left. Every relay above used it.
sweep="$(grep -rIl -- "$SECRET_PW" "$B/logs" "$B/actions" "$B/backups" 2>/dev/null)"
check "the password is in no log, result or work file" "$sweep" ""
sweep="$(grep -rIl -- "secret-ping" "$B/logs" "$B/actions" "$B/backups" 2>/dev/null)"
check "the ping address is in no log, result or work file" "$sweep" ""
check "no request is left" "$(find "$REQ" -mindepth 1 | wc -l | tr -d ' ')" 0
check "nothing but the lock and the seen list is left in work/" "$(find "$WRK" -maxdepth 1 -type f ! -name lock | wc -l | tr -d ' ')" 0
check "the log is the owner's only" "$(stat -c %a "$LOG")" 600

# Text a job printed that carries a secret is masked before it reaches a log or a result
(
  cd "$B" && set +euo pipefail
  . ./bin/lib/common.sh
  . ./bin/healthwatch.sh; set +e
  . ./bin/server-actions.sh; set +e
  SA_REQUEST_SECRETS=("$SECRET_PW")
  masked="$(printf 'the relay said %s and %s then password=abc' "$SECRET_PW" "$OLD_PW" | mask_for_app)"
  case "$masked" in *"$SECRET_PW"*|*"$OLD_PW"*|*abc*) echo "not masked: $masked" >> "$WORK/subfail" ;; esac
)
[ ! -e "$WORK/subfail" ] && ok || { bad "$(cat "$WORK/subfail")"; rm -f "$WORK/subfail"; }

# --- 17. the .env helpers, on what would hurt
(
  cd "$B" && set +euo pipefail
  . ./bin/lib/common.sh
  f="$WORK/env-test"
  printf 'A=1\n# a comment, kept\nB=two\nA=1again\n' > "$f"; chmod 640 "$f"
  env_set A new "$f" || echo "env_set failed" >> "$WORK/subfail"
  [ "$(cat "$f")" = "A=new
# a comment, kept
B=two" ] || echo "env_set: every line but the one stays, duplicates go: $(cat "$f")" >> "$WORK/subfail"
  [ "$(stat -c %a "$f")" = 640 ] || echo "env_set keeps the mode" >> "$WORK/subfail"
  env_set C added "$f"; grep -qx 'C=added' "$f" || echo "env_set adds" >> "$WORK/subfail"
  env_set D 'x
EVIL=1' "$f" && echo "env_set took a line break" >> "$WORK/subfail"
  grep -q EVIL "$f" && echo "a line break got in" >> "$WORK/subfail"
  env_set 'BAD KEY' x "$f" && echo "env_set took a bad key" >> "$WORK/subfail"
  env_single_quote "it's" >/dev/null && echo "a single quote was quoted" >> "$WORK/subfail"
  env_single_quote 'back\slash' >/dev/null && echo "a backslash was quoted" >> "$WORK/subfail"
  env_single_quote 'x
y' >/dev/null && echo "a newline was quoted" >> "$WORK/subfail"
  [ "$(env_single_quote 'a$b c"d#e')" = "'a\$b c\"d#e'" ] || echo "single quote shape" >> "$WORK/subfail"
  printf 'K='"'"'lit$eral'"'"'\nL="dq"\nM=plain\n' > "$f"
  [ "$(env_get K "$f")" = 'lit$eral' ] || echo "env_get K" >> "$WORK/subfail"
  [ "$(env_get L "$f")" = dq ] || echo "env_get L" >> "$WORK/subfail"
  [ "$(env_get M "$f")" = plain ] || echo "env_get M" >> "$WORK/subfail"
  [ -z "$(env_get NOPE "$f")" ] || echo "env_get NOPE" >> "$WORK/subfail"
  # shellcheck disable=SC2016
  printf 'P=$(touch %s/pwned-by-get)\n' "$WORK" > "$f"
  env_get P "$f" >/dev/null
  [ ! -e "$WORK/pwned-by-get" ] || echo "env_get ran something" >> "$WORK/subfail"
)
[ ! -e "$WORK/subfail" ] && ok || { bad "$(cat "$WORK/subfail")"; rm -f "$WORK/subfail"; }

# compose must read what's stored, byte for byte, as bash does. Where there's docker compose (not on
# alpine) the real parser is used.
if command -v /usr/bin/docker >/dev/null 2>&1 && /usr/bin/docker compose version >/dev/null 2>&1; then
  printf "services:\n  a:\n    image: x\n    environment:\n      P: \${P:-}\n" > "$WORK/c.yaml"
  printf "P='%s'\n" "$SECRET_PW" > "$WORK/c.env"
  got="$(/usr/bin/docker compose --env-file "$WORK/c.env" -f "$WORK/c.yaml" config --format json 2>&1 | jq -r .services.a.environment.P)"
  # compose's own output escapes $ as $$
  check "compose reads the stored password exactly" "${got//\$\$/\$}" "$SECRET_PW"
fi

# --- 18. pruning
for i in 1 2 3; do printf '{}' > "$RES/cccccccc-0000-4000-8000-00000000000$i.json"; done
touch -d "@$(( $(date +%s) - 86400 * 20 ))" "$RES/cccccccc-0000-4000-8000-000000000001.json" 2>/dev/null \
  || touch -d "$(date -u -d "@$(( $(date +%s) - 86400 * 20 ))" '+%Y-%m-%d %H:%M:%S')" "$RES/cccccccc-0000-4000-8000-000000000001.json"
once
check "an old result goes" "$([ -e "$RES/cccccccc-0000-4000-8000-000000000001.json" ] && echo yes || echo no)" no
check "a new result stays" "$([ -e "$RES/cccccccc-0000-4000-8000-000000000002.json" ] && echo yes || echo no)" yes
check "the heartbeat stays" "$([ -e "$RES/helper.json" ] && echo yes || echo no)" yes
for i in $(seq 1 12); do printf '{}' > "$RES/dddddddd-0000-4000-8000-0000000000$(printf %02d "$i").json"; done
SA_KEEP_FILES=5 bash "$SA" --once > /dev/null 2>&1
check "a flood of results is capped" "$(find "$RES" -type f -name '*-*-*.json' | wc -l | tr -d ' ')" 5
# A flood of requests doesn't stop the heartbeat being written, and goes down a batch at a time
for i in $(seq 1 30); do printf 'x' > "$REQ/flood-$i.json"; done
SA_PER_PASS=10 bash "$SA" --once > /dev/null 2>&1
check "a flood of requests: one batch a pass" "$(find "$REQ" -mindepth 1 | wc -l | tr -d ' ')" 20
find "$REQ" -mindepth 1 -delete

# --- 19. the tick: picks up what arrives while it polls, and lets go by itself
tick="$(new_id)"
( sleep 1; NOW="$(date +%s)"; request "$tick" alerts-set "$(alert_params ops@outside.example.net)" ) &
SA_TICK_SECS=3 SA_POLL_SECS=1 bash "$SA" --tick > /dev/null 2>&1
wait
check "tick: picked it up" "$(state_of "$tick")" SUCCEEDED
reset_env

# --- 20. as root, as in the backup container: the modes do what they're meant to for uid 999.
# Rootless docker's root works the same way inside its namespace. Only in a throw-away alpine
# container, because it adds a user to /etc/passwd.
if [ "$(id -u)" = 0 ] && [ -f /.dockerenv ] && [ -f /etc/alpine-release ]; then
  APP_USER="$(awk -F: '$3 == 999 { print $1; exit }' /etc/passwd)"
  if [ -z "$APP_USER" ]; then
    APP_USER=wfapp
    echo 'wfapp:x:999:999::/tmp:/bin/sh' >> /etc/passwd
  fi
  export SA_APP_UID=999
  once
  check "root: requests belong to the app's uid" "$(stat -c '%u %a' "$REQ")" "999 700"
  chmod 755 "$B" "$B/actions" 2>/dev/null; chmod 755 "$WORK"
  as_app() { su -s /bin/sh "$APP_USER" -c "$1" 2>/dev/null; }
  # Without this, every "can't" below would pass because su itself failed.
  check "root: really running as the app's uid" "$(as_app 'id -u')" 999
  as_app "touch '$REQ/.probe' && rm '$REQ/.probe'"; check "root: the app can write a request" "$?" 0
  as_app "cat '$RES/helper.json' > /dev/null"; check "root: the app can read a result" "$?" 0
  as_app "touch '$RES/x'"; check "root: the app can't write a result" "$([ $? -ne 0 ] && echo refused)" refused
  as_app "cat '$B/.env'" > /dev/null; check "root: the app can't read .env" "$([ $? -ne 0 ] && echo refused)" refused
  as_app "ls '$WRK'" > /dev/null; check "root: the app can't see the work folder" "$([ $? -ne 0 ] && echo refused)" refused
  as_app "touch '$B/secrets/x'"; check "root: the app can't write secrets" "$([ $? -ne 0 ] && echo refused)" refused
  # What the api does: its own 0600 file, which this root still reads, and deletes.
  id="$(new_id)"; request "$id" alerts-set "$(alert_params ops@outside.example.net)"
  chown 999:999 "$REQ/$id.json"; chmod 600 "$REQ/$id.json"
  once
  check "root: a 0600 request from uid 999 is read" "$(state_of "$id")" SUCCEEDED
  check "root: and deleted" "$([ -e "$REQ/$id.json" ] && echo yes || echo no)" no
  check "root: its result can be read by uid 999" "$(as_app "cat '$RES/$id.json'" | jq -r .state)" SUCCEEDED
  export SA_APP_UID=""
fi

echo "server-actions self-test: ${PASS} passed, ${FAILN} failed"
[ "$FAILN" -eq 0 ]
