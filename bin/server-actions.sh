#!/usr/bin/env bash
# server-actions.sh — runs the routine jobs people start from Setup in Workforce (Workforce ADR-0031,
# RUNBOOK "Jobs from the app"), so nobody needs a shell on the server for them. The backup container
# runs it from cron. The app gets no docker socket, no shell and no write access to .env or secrets/:
# it can only leave a request here, so the worst a compromised app can do is ask for what's on this
# list. EVERY REQUEST IS HOSTILE until it has been through the checks below.
#
#   actions/requests/<id>.json   the app's folder: writable by uid 999 only, read by this script
#   actions/results/<id>.json    written here, read-only to the app; never holds a secret
#   actions/results/helper.json  "this helper is alive", and the settings the screens show
#   actions/work/                this script's own: lock, the file being read, requests already seen
#   logs/server-actions.log      everything it does, with secrets masked
#
# A request, in full (nothing more, nothing less; every param a string, no control characters):
#   { "schema": 1, "id": "<uuid, the same as the file name>", "action": "<below>",
#     "createdAt": <epoch seconds>, "requestedBy": "<uuid>", "params": { ... } }
#
#   backup-now       (no params)    ./bin/backup.sh
#   offsite-test     (no params)    ./bin/backup.sh --offsite-only
#   staff-mail-on    webmailHost mailHost useOutgoingRelay relaySpfInclude    ./bin/staff-mail.sh on
#   staff-mail-off   (no params)    ./bin/staff-mail.sh off
#   relay-apply      host port username password from testAddress    test send, then save and restart
#   alerts-set       alertAddress acceptOwnDomain heartbeatMode heartbeatUrl    save, then a test alert
#
# A result: { "schema": 1, "id", "action", "state": "RUNNING|SUCCEEDED|FAILED|REFUSED|EXPIRED", "code",
#             "message", "phase", "startedAt", "finishedAt", "deadline", "data": { ... } }
#
#   ./bin/server-actions.sh --tick   cron, once a minute: holds the lock and polls for about a minute
#   ./bin/server-actions.sh --beat   cron, once a minute: "alive", and turns requests away during a job
#   ./bin/server-actions.sh --once   one pass over the requests (by hand and in the self-test)
#   SERVER_ACTIONS=off in .env stops it, whatever the app says: requests get a written refusal.
#
# bin/tests/server-actions-test.sh is the proof of all this; it runs on alpine with busybox as well.
set -uo pipefail
umask 077
export LC_ALL=C   # so that [ -~] means what it says, whatever the locale

SA_DIR="${SA_DIR:-actions}"
SA_LOG="${SA_LOG:-logs/server-actions.log}"
SA_APP_UID="${SA_APP_UID-999}"     # the app's unprivileged user (Dockerfile); empty = don't chown (tests)
SA_MAX_BYTES="${SA_MAX_BYTES:-32768}"
SA_MAX_AGE="${SA_MAX_AGE:-120}"    # a request not picked up in this time expires, and never runs later
SA_TICK_SECS="${SA_TICK_SECS:-55}"
SA_POLL_SECS="${SA_POLL_SECS:-3}"
SA_PER_PASS="${SA_PER_PASS:-25}"   # so a flood of files can't stop this writing its heartbeat
SA_KEEP_DAYS="${SA_KEEP_DAYS:-14}"
SA_KEEP_FILES="${SA_KEEP_FILES:-200}"
SA_KILL_GRACE="${SA_KILL_GRACE:-20}"
SA_REQUESTS="$SA_DIR/requests"; SA_RESULTS="$SA_DIR/results"; SA_WORK="$SA_DIR/work"

# Time limits, in seconds. A job past its limit is stopped and reported as such.
limit_for() {
  case "$1" in
    backup-now|offsite-test) echo "${SA_LIMIT_BACKUP:-14400}" ;;
    staff-mail-on)           echo "${SA_LIMIT_MAIL_ON:-1800}" ;;
    staff-mail-off)          echo "${SA_LIMIT_MAIL_OFF:-600}" ;;
    relay-apply)             echo "${SA_LIMIT_RELAY:-600}" ;;
    alerts-set)              echo "${SA_LIMIT_ALERTS:-180}" ;;
    *)                       echo 60 ;;
  esac
}

now_epoch() { date +%s; }
iso_of() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }
iso_now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# Log lines hold fixed words, checked values and masked text only. Anything else from a request has
# been through safe_token first, so a file name can't write a line of its own.
sa_log() {
  local line
  line="$(iso_now) $*"
  line="$(printf '%s' "$line" | tr -d '\000-\010\013\014\016-\037\177' | tr '\n\r' '  ')"
  mkdir -p "$(dirname "$SA_LOG")" 2>/dev/null
  if [ -f "$SA_LOG" ] && [ "$(wc -c < "$SA_LOG")" -gt 1048576 ]; then mv -f "$SA_LOG" "${SA_LOG}.1"; fi
  printf '%s\n' "$line" >> "$SA_LOG"
}
safe_token() { printf '%s' "$1" | tr -cd 'A-Za-z0-9._-' | cut -c1-64; }

# mask_for_app — stdin to stdout, for anything that wasn't written by this script: what a job printed.
# healthwatch's mask_text hides this server's settings wherever they appear, the small secret files,
# and anything shaped like a credential. On top, the secrets this request brought with it.
SA_REQUEST_SECRETS=()
mask_for_app() {
  local s v
  s="$(cat)"
  for v in "${SA_REQUEST_SECRETS[@]:-}"; do
    [ -n "$v" ] && s="${s//"$v"/(hidden)}"
  done
  # shellcheck disable=SC1091  # sourced in this subshell only; nothing is exported
  printf '%s\n' "$s" | ( . ./.env >/dev/null 2>&1; mask_text )
}

# ------------------------------------------------------------------ the mailbox
# The modes are the design. requests/ belongs to the app's uid, and nobody else (root in this container
# reads it through CAP_DAC_OVERRIDE, under rootless docker too, where this root is the service account).
# results/ and its files are this script's and readable by all: a file the app can't read would look
# like a helper that never answered, as a 0600 secret once looked like a feature that was off.
ensure_mailbox() {
  mkdir -p "$SA_REQUESTS" "$SA_RESULTS" "$SA_WORK/seen" || return 1
  chmod 755 "$SA_DIR" "$SA_RESULTS" 2>/dev/null
  chmod 700 "$SA_WORK" 2>/dev/null
  if [ -n "$SA_APP_UID" ]; then
    chown "$SA_APP_UID:$SA_APP_UID" "$SA_REQUESTS" 2>/dev/null \
      || sa_log "- - mailbox: could not hand ${SA_REQUESTS} to uid ${SA_APP_UID}, so the app can't leave requests"
  fi
  chmod 700 "$SA_REQUESTS" 2>/dev/null
  return 0
}

# Replaced whole, so the app never reads half a file. Readable by the app, whatever the umask.
publish() { # publish <name> < json
  local tmp="$SA_RESULTS/.tmp.$$.$1"
  if cat > "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$SA_RESULTS/$1"; then return 0; fi
  rm -f "$tmp"
  return 1
}

# write_result <id> <action> <state> <code> <message> <phase> <startedAt> <finishedAt> <deadline> <data json>
write_result() {
  jq -n --arg id "$1" --arg action "$2" --arg state "$3" --arg code "$4" --arg message "$5" --arg phase "$6" \
        --arg started "$7" --arg finished "$8" --arg deadline "$9" --argjson data "${10:-"{}"}" \
    '{ schema: 1, id: $id, action: $action, state: $state, code: $code, message: $message,
       phase: (if $phase == "" then null else $phase end),
       startedAt: (if $started == "" then null else $started end),
       finishedAt: (if $finished == "" then null else $finished end),
       deadline: (if $deadline == "" then null else $deadline end),
       data: $data }' | publish "$1.json"
}

# A written refusal or expiry, for a request that never ran.
finish_unrun() { # finish_unrun <id> <action> <REFUSED|EXPIRED> <code> <message>
  write_result "$1" "$2" "$3" "$4" "$5" "" "" "$(iso_now)" "" '{}'
  sa_log "$1 $(safe_token "$2") $3 $4"
}

helper_enabled() { [ "$(env_get SERVER_ACTIONS)" != off ]; }

# What the screens need to show, from .env, never a secret: not the relay's user name or password, not
# the uptime URL, not the off-site target. The alert address is shown, because it's what gets edited.
write_heartbeat() { # write_heartbeat <busy true|false>
  local profiles target kind="" off_configured=false off_encrypted=false mail_on=false private_ca=false port user mail_host smtp_host
  profiles="$(env_get COMPOSE_PROFILES)"
  case ",$profiles," in *,staffmail,*) mail_on=true ;; esac
  target="$(env_get BACKUP_TARGET)"
  if [ -n "$target" ]; then
    off_configured=true
    case "$target" in s3://*) kind=S3 ;; *:*) kind=rsync ;; *) kind=other ;; esac
    if age_recipient_usable "$(env_get BACKUP_ENCRYPT_RECIPIENT)"; then off_encrypted=true; fi
  fi
  case "$(env_get GATEWAY_CADDYFILE)" in *localca*) private_ca=true ;; esac
  smtp_host="$(env_get SMTP_HOST)"; port="$(env_get SMTP_PORT)"; user="$(env_get SMTP_USERNAME)"
  mail_host="$(env_get MAIL_HOSTNAME)"
  jq -n --arg at "$(iso_now)" --argjson busy "$1" \
        --argjson enabled "$(helper_enabled && echo true || echo false)" \
        --arg host "$smtp_host" --arg port "${port:-587}" --argjson signsIn "$([ -n "$user" ] && echo true || echo false)" \
        --arg from "$(env_get SMTP_FROM)" --arg starttls "$(env_get SMTP_STARTTLS)" \
        --arg alerts "$(env_get OPS_ALERT_EMAIL)" --argjson hb "$([ -n "$(env_get OPS_HEARTBEAT_URL)" ] && echo true || echo false)" \
        --argjson mailOn "$mail_on" --arg webmail "$(env_get WEBMAIL_HOSTNAME)" --arg mailHost "$mail_host" \
        --arg mailRelay "$(env_get MAIL_RELAY_HOST)" --argjson privateCa "$private_ca" \
        --argjson offConfigured "$off_configured" --arg offKind "$kind" --argjson offEncrypted "$off_encrypted" \
    '{ schema: 1, at: $at, enabled: $enabled, busy: $busy,
       settings: {
         relay: { host: $host, port: $port, signsIn: $signsIn, from: $from, starttls: ($starttls == "true") },
         alerts: { address: $alerts, heartbeatSet: $hb },
         staffMail: { on: $mailOn, webmailHost: $webmail, mailHost: $mailHost, relayHost: $mailRelay, privateCa: $privateCa },
         offsite: { configured: $offConfigured, kind: (if $offKind == "" then null else $offKind end), encrypted: $offEncrypted } } }' \
    | publish helper.json
}

prune() {
  find "$SA_RESULTS" -maxdepth 1 -type f -name '*-*.json' -mtime "+$SA_KEEP_DAYS" -exec rm -f {} + 2>/dev/null
  find "$SA_WORK/seen" -maxdepth 1 -type f -mtime "+$SA_KEEP_DAYS" -exec rm -f {} + 2>/dev/null
  # A hostile app can make as many results as it likes, so there's a cap as well as an age. The names
  # are all ones this script wrote, so `ls` output is safe to read here.
  # shellcheck disable=SC2012,SC2010
  ls -1t "$SA_RESULTS" 2>/dev/null | grep -E '^[0-9a-f-]{36}\.json$' | tail -n "+$((SA_KEEP_FILES + 1))" \
    | while IFS= read -r old; do rm -f "$SA_RESULTS/$old"; done
  # shellcheck disable=SC2012
  ls -1t "$SA_WORK/seen" 2>/dev/null | tail -n "+$((SA_KEEP_FILES * 2 + 1))" \
    | while IFS= read -r old; do rm -f "$SA_WORK/seen/$old"; done
  find "$SA_RESULTS" -maxdepth 1 -type f -name '.tmp.*' -mmin +60 -exec rm -f {} + 2>/dev/null
  # What the app left half-written. It can hold a password, so it doesn't stay.
  find "$SA_REQUESTS" -maxdepth 1 -name '.*' ! -name . ! -type d -mmin +5 -exec rm -f {} + 2>/dev/null
}

# ------------------------------------------------------------------ checking what a request says
UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
HOST_RE='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$'
DOTTED_HOST_RE='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'
ADDRESS_RE='^[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$'
USER_RE='^[A-Za-z0-9._%+@=-]{1,254}$'
PING_URL_RE='^https://[A-Za-z0-9.-]+\.[A-Za-z0-9-]+(:[0-9]{1,5})?/[A-Za-z0-9._~/%+=?&:-]*$'

# The shape, in jq, before a single value reaches this shell: exactly these keys, of exactly these
# types, every value a string, and no control characters in anything. That last is what makes a value
# safe to carry on one line, and means \n and \u0000 can't get as far as .env or a bash variable.
SHAPE='type == "object"
  and (keys == ["action","createdAt","id","params","requestedBy","schema"])
  and .schema == 1
  and (.id | type) == "string" and (.action | type) == "string" and (.requestedBy | type) == "string"
  and (.createdAt | type) == "number" and (.params | type) == "object"
  and ([.params[] | type] | all(. == "string"))
  and ([.. | strings | explode[]] | all(. >= 32 and . != 127))
  and ([.params | keys[]] | all(test("^[A-Za-z]{1,32}$")))'

valid_host() { [ "${#1}" -le 253 ] && [[ "$1" =~ $HOST_RE ]]; }
valid_dotted_host() { [ "${#1}" -le 253 ] && [[ "$1" =~ $DOTTED_HOST_RE ]]; }
valid_address() { [ "${#1}" -le 254 ] && [[ "$1" =~ $ADDRESS_RE ]]; }
valid_port() { [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$1" -le 65535 ]; }

# Something that can't be stored safely is refused, with the reason in words. Printable ASCII only;
# not a single quote or a backslash (env_single_quote); not ${ or #{, because the app's settings
# resolve placeholders in values, so one of those could stop it starting, or worse.
password_problem() {
  local p="$1"
  if [ "${#p}" -lt 6 ] || [ "${#p}" -gt 512 ]; then echo "The password or SMTP key has to be between 6 and 512 characters."; return 0; fi
  if ! [[ "$p" =~ ^[\ -~]+$ ]]; then echo "That password contains a character that can't be stored safely. Create an SMTP key or password with only ordinary letters, numbers and punctuation."; return 0; fi
  case "$p" in
    *\'*) echo "That password contains a single quote ('), which can't be stored safely. Create an SMTP key or password without one."; return 0 ;;
    *\\*) echo "That password contains a backslash (\\), which can't be stored safely. Create an SMTP key or password without one."; return 0 ;;
    *'${'*|*'#{'*) echo "That password contains \${ or #{, which can't be stored safely. Create an SMTP key or password without them."; return 0 ;;
  esac
  return 1
}

# Set by the validators: the refusal. An empty code means fine.
BAD_CODE=""; BAD_MSG=""
refuse_param() { BAD_CODE="${2:-BAD_VALUE}"; BAD_MSG="$1"; return 1; }

validate_mail_on() {
  valid_dotted_host "${P[webmailHost]}" || { refuse_param "That isn't a web address this server can use for webmail, such as webmail.your-organisation.co.uk."; return 1; }
  [ -z "${P[mailHost]}" ] || valid_dotted_host "${P[mailHost]}" || { refuse_param "That isn't a host name for the mail server."; return 1; }
  [ -z "${P[relaySpfInclude]}" ] || valid_dotted_host "${P[relaySpfInclude]}" || { refuse_param "That isn't a domain for the relay's SPF record."; return 1; }
  [[ "${P[useOutgoingRelay]}" =~ ^(true|false)$ ]] || { refuse_param "That isn't a choice about the relay."; return 1; }
  if [ "${P[webmailHost]}" = "$(env_get APP_HOSTNAME)" ] || [ "${P[webmailHost]}" = "$(env_get AUTH_HOSTNAME)" ]; then
    refuse_param "Webmail needs a web address of its own, not the one Workforce or sign-in uses."; return 1
  fi
  if [ "${P[useOutgoingRelay]}" = true ] && [ -z "$(env_get SMTP_HOST)" ]; then
    refuse_param "There's no outgoing email relay on this server yet. Set one up first, or send straight to each domain." NO_RELAY; return 1
  fi
  return 0
}

validate_relay() {
  valid_host "${P[host]}" || { refuse_param "That isn't a host name for the relay."; return 1; }
  valid_port "${P[port]}" || { refuse_param "The port has to be a number, usually 587."; return 1; }
  [ "${P[port]}" != 465 ] || { refuse_param "Workforce sends with STARTTLS, so port 465 won't work. Use the provider's port 587."; return 1; }
  valid_address "${P[from]}" || { refuse_param "The From address isn't an email address."; return 1; }
  valid_address "${P[testAddress]}" || { refuse_param "The address for the test email isn't an email address."; return 1; }
  if [ -n "${P[username]}" ]; then
    [[ "${P[username]}" =~ $USER_RE ]] || { refuse_param "The user name has a character in it that can't be used."; return 1; }
    local problem
    if problem="$(password_problem "${P[password]}")"; then refuse_param "$problem" BAD_PASSWORD; return 1; fi
  elif [ -n "${P[password]}" ]; then
    refuse_param "A password needs a user name to go with it."; return 1
  fi
  return 0
}

validate_alerts() {
  local list="${P[alertAddress]}" a problems n=0
  local -a parts
  [[ "${P[acceptOwnDomain]}" =~ ^(true|false)$ ]] || { refuse_param "That isn't a choice about the alert address."; return 1; }
  if [ -n "$list" ]; then
    case "$list" in *,) refuse_param "One of those isn't an email address."; return 1 ;; esac
    IFS=',' read -r -a parts <<< "$list"
    for a in "${parts[@]}"; do
      n=$((n + 1))
      valid_address "$a" || { refuse_param "One of those isn't an email address."; return 1; }
    done
    [ "$n" -le 5 ] || { refuse_param "Five addresses at most."; return 1; }
    problems="$(alert_address_problems "$list" "$(env_get APP_HOSTNAME)" "$(env_get AUTH_HOSTNAME)")"
    if printf '%s\n' "$problems" | grep -q '^bad:'; then
      refuse_param "That isn't an email address."; return 1
    fi
    if [ -n "$problems" ] && [ "${P[acceptOwnDomain]}" != true ]; then
      refuse_param "$(printf '%s\n' "$problems" | sed -n 's/^own://p' | head -n 1). If this server handles that domain's mail, alerts would stop when it does." OWN_DOMAIN
      return 1
    fi
  fi
  case "${P[heartbeatMode]}" in
    keep|clear)
      [ -z "${P[heartbeatUrl]}" ] || { refuse_param "A ping address came with nothing to do with it."; return 1; } ;;
    set)
      [ "${#P[heartbeatUrl]}" -le 512 ] && [[ "${P[heartbeatUrl]}" =~ $PING_URL_RE ]] \
        || { refuse_param "That isn't an https:// address. Paste the ping address the service gave you."; return 1; } ;;
    *) refuse_param "That isn't a choice about the uptime check."; return 1 ;;
  esac
  return 0
}

expected_params() { # the allow-list: an action not named here has no params and no job
  case "$1" in
    backup-now|offsite-test|staff-mail-off) echo "" ;;
    staff-mail-on) echo "mailHost,relaySpfInclude,useOutgoingRelay,webmailHost" ;;
    relay-apply)   echo "from,host,password,port,testAddress,username" ;;
    alerts-set)    echo "acceptOwnDomain,alertAddress,heartbeatMode,heartbeatUrl" ;;
    *) return 1 ;;
  esac
}

validate_params() {
  BAD_CODE=""; BAD_MSG=""
  case "$1" in
    staff-mail-on) validate_mail_on ;;
    relay-apply)   validate_relay ;;
    alerts-set)    validate_alerts ;;
    *) return 0 ;;
  esac
}

# ------------------------------------------------------------------ one request
declare -A P=()

# handle_request <path in requests/> — never runs anything until the file has passed every check.
handle_request() {
  local path="$1" name id claim stats size links mtime now action created by keys expected k age
  name="${path##*/}"
  claim="$SA_WORK/claim.$$"
  rm -rf -- "$claim"
  # First, out of the app's reach, so nothing can be swapped between a check and a read. A symbolic
  # link moves as itself, and isn't followed. From here on the app can't touch this file.
  if ! mv -f -- "$path" "$claim" 2>/dev/null; then
    sa_log "- - could not claim $(safe_token "$name")"
    return 0
  fi
  if ! [[ "$name" =~ ^[0-9a-f-]{36}\.json$ ]] || ! [[ "${name%.json}" =~ $UUID_RE ]]; then
    rm -rf -- "$claim"
    sa_log "- - REFUSED BAD_NAME $(safe_token "$name")"
    return 0
  fi
  id="${name%.json}"
  if [ -e "$SA_WORK/seen/$id" ]; then
    # Each is processed once. This goes no further and leaves the first result as it was.
    rm -rf -- "$claim"
    sa_log "$id - REFUSED ALREADY_SEEN"
    return 0
  fi
  : > "$SA_WORK/seen/$id"
  if [ -L "$claim" ]; then
    rm -f -- "$claim"
    finish_unrun "$id" unknown REFUSED NOT_A_FILE "That request couldn't be read, so nothing was done."
    return 0
  fi
  if ! [ -f "$claim" ]; then
    rm -rf -- "$claim"
    finish_unrun "$id" unknown REFUSED NOT_A_FILE "That request couldn't be read, so nothing was done."
    return 0
  fi
  stats="$(stat -c '%s %h %Y' -- "$claim" 2>/dev/null)" || stats="0 0 0"
  read -r size links mtime <<< "$stats"
  if [ "$size" -gt "$SA_MAX_BYTES" ] || [ "$links" != 1 ]; then
    rm -f -- "$claim"
    finish_unrun "$id" unknown REFUSED NOT_A_FILE "That request couldn't be read, so nothing was done."
    return 0
  fi
  if ! jq -e "$SHAPE" "$claim" >/dev/null 2>&1; then
    rm -f -- "$claim"
    finish_unrun "$id" unknown REFUSED BAD_SHAPE "That request wasn't in the right form, so nothing was done."
    return 0
  fi
  # Safe to read now: one value to a line, each a string with no control characters.
  { IFS= read -r k; IFS= read -r action; IFS= read -r created; IFS= read -r by; IFS= read -r keys; } < <(
    jq -r '.id, .action, (.createdAt | tostring), .requestedBy, (.params | keys | join(","))' "$claim" 2>/dev/null)
  if [ "$k" != "$id" ] || ! [[ "$by" =~ $UUID_RE ]] || ! [[ "$created" =~ ^[0-9]{1,12}$ ]]; then
    rm -f -- "$claim"
    finish_unrun "$id" unknown REFUSED BAD_SHAPE "That request wasn't in the right form, so nothing was done."
    return 0
  fi
  if ! expected="$(expected_params "$action")"; then
    rm -f -- "$claim"
    finish_unrun "$id" not-allowed REFUSED NOT_ALLOWED "That isn't something the server's helper does, so nothing was done."
    sa_log "$id - not on the list: $(safe_token "$action")"
    return 0
  fi
  if [ "$keys" != "$expected" ]; then
    rm -f -- "$claim"
    finish_unrun "$id" "$action" REFUSED BAD_SHAPE "That request wasn't in the right form, so nothing was done."
    return 0
  fi
  P=()
  if [ -n "$expected" ]; then
    local -a names
    IFS=',' read -r -a names <<< "$expected"
    for k in "${names[@]}"; do
      P["$k"]="$(jq -r --arg k "$k" '.params[$k]' "$claim" 2>/dev/null)"
    done
  fi
  # Gone as soon as it's been read: it can hold a password, which from here is only in this process.
  rm -f -- "$claim"
  SA_REQUEST_SECRETS=("${P[password]:-}" "${P[heartbeatUrl]:-}")

  now="$(now_epoch)"
  age=$((now - mtime))
  if [ "$age" -gt "$SA_MAX_AGE" ] || [ $((now - created)) -gt "$SA_MAX_AGE" ]; then
    finish_unrun "$id" "$action" EXPIRED NOT_PICKED_UP "The server's helper didn't pick this up in time, so it won't run."
    forget_request; return 0
  fi
  if [ $((created - now)) -gt 60 ] || [ "$age" -lt -60 ]; then
    finish_unrun "$id" "$action" REFUSED BAD_SHAPE "That request wasn't in the right form, so nothing was done."
    forget_request; return 0
  fi
  if ! helper_enabled; then
    finish_unrun "$id" "$action" REFUSED SWITCHED_OFF "Whoever runs this server has switched these jobs off (SERVER_ACTIONS in its settings)."
    forget_request; return 0
  fi
  if ! validate_params "$action"; then
    finish_unrun "$id" "$action" REFUSED "$BAD_CODE" "$BAD_MSG"
    forget_request; return 0
  fi
  run_action "$id" "$action" "$by"
  forget_request
}

forget_request() { P=(); SA_REQUEST_SECRETS=(); }

# ------------------------------------------------------------------ running one job
# As its own process, with a clean environment and a time limit: nothing of this process's reaches it
# except what's on the list, and every value goes through a pipe, never a command line or a shell.
# In a session of its own, so that the limit stops everything it started: busybox's `timeout` signals
# only the process it ran, which left a timed-out backup.sh carrying on underneath.
run_action() {
  local id="$1" action="$2" by="$3" limit started deadline out rc k res job until_epoch timed_out=0
  limit="$(limit_for "$action")"
  started="$(iso_now)"; deadline="$(iso_of $(($(now_epoch) + limit)))"
  out="$SA_WORK/$id.out"; res="$SA_WORK/$id.res"
  printf '%s %s\n' "$id" "$action" > "$SA_WORK/running"
  write_result "$id" "$action" RUNNING "" "" "" "$started" "" "$deadline" '{}'
  sa_log "$id $action STARTED by $by (limit ${limit}s)"
  {
    for k in "${!P[@]}"; do printf '%s=%s\n' "$k" "${P[$k]}"; done
  } | env -i PATH="$PATH" HOME="${HOME:-/root}" TZ="${TZ:-Europe/London}" \
        ${COMPOSE_PROJECT_NAME:+COMPOSE_PROJECT_NAME="$COMPOSE_PROJECT_NAME"} \
        ${DOCKER_HOST:+DOCKER_HOST="$DOCKER_HOST"} \
        WORKFORCE_IN_STACK=1 SA_DIR="$SA_DIR" SA_LOG="$SA_LOG" STAFF_MAIL_RETRY_SECS="${STAFF_MAIL_RETRY_SECS:-10}" \
        SA_JOB_ID="$id" SA_JOB_ACTION="$action" SA_JOB_STARTED="$started" SA_JOB_DEADLINE="$deadline" SA_JOB_RESULT="$res" \
        setsid bash "${BASH_SOURCE[0]}" --job > "$out" 2>&1 9>&- &
  job=$!
  until_epoch=$(($(now_epoch) + limit))
  while kill -0 "$job" 2>/dev/null; do
    if [ "$(now_epoch)" -ge "$until_epoch" ]; then
      timed_out=1
      kill -TERM -- "-$job" 2>/dev/null
      until_epoch=$(($(now_epoch) + SA_KILL_GRACE))
      while kill -0 "$job" 2>/dev/null && [ "$(now_epoch)" -lt "$until_epoch" ]; do sleep 1; done
      kill -KILL -- "-$job" 2>/dev/null
      break
    fi
    sleep 1
  done
  wait "$job" 2>/dev/null
  rc=$?
  # The job's own words go in the log, masked; what the app sees is only what's in the result.
  [ -s "$out" ] && mask_for_app < "$out" | sed "s/^/$id $action | /" | while IFS= read -r k; do sa_log "$k"; done
  rm -f -- "$out"
  rm -f "$SA_WORK/running"
  # A job that got as far as changing settings, then was stopped: back they go. Its snapshot goes too,
  # because it holds the old password.
  if [ -f "$SA_WORK/env.before" ]; then
    mv -f "$SA_WORK/env.before" .env
    sa_log "$id $action restored .env: the job stopped before it finished"
  fi
  local state code message data
  if [ "$timed_out" -eq 0 ] && [ "$rc" -lt 128 ] && [ -s "$res" ] && jq -e '(.state | type) == "string" and (.code | type) == "string" and (.message | type) == "string" and (.data | type) == "object"' "$res" >/dev/null 2>&1; then
    state="$(jq -r .state "$res")"; code="$(jq -r .code "$res")"
    message="$(jq -r .message "$res" | mask_for_app)"
    data="$(jq -c .data "$res")"
  elif [ "$timed_out" -eq 1 ]; then
    state=FAILED; code=TIMED_OUT; data='{}'
    message="This took longer than the time allowed (${limit} seconds) and was stopped."
  else
    state=FAILED; code=JOB_FAILED; data='{}'
    message="This stopped before it finished. The server's log has the reason."
  fi
  rm -f -- "$res"
  write_result "$id" "$action" "$state" "$code" "$message" "" "$started" "$(iso_now)" "$deadline" "$data"
  sa_log "$id $action $state $code"
}

# ------------------------------------------------------------------ the jobs (a process of their own)
job_result() { # job_result <state> <code> <message> [data json]
  local data="${4:-}"
  [ -n "$data" ] || data='{}'
  jq -n --arg state "$1" --arg code "$2" --arg message "$3" --argjson data "$data" \
    '{ state: $state, code: $code, message: $message, data: $data }' > "$SA_JOB_RESULT"
}

# A job that's going to restart the app says so first, for whoever is watching when it goes away.
job_phase() { write_result "$SA_JOB_ID" "$SA_JOB_ACTION" RUNNING "" "" "$1" "$SA_JOB_STARTED" "" "$SA_JOB_DEADLINE" '{}'; }

last_words() { # the last line a script printed, for the log's reason; masked by run_action
  tail -n 1 "$1" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | cut -c1-300
}

# snapshot_env / restore_env — what a job that changes settings goes back to when it can't finish.
snapshot_env() { cp -p .env "$SA_WORK/env.before"; }
restore_env() {
  [ -f "$SA_WORK/env.before" ] && mv -f "$SA_WORK/env.before" .env
}
discard_snapshot() { rm -f "$SA_WORK/env.before"; }

# notify_change <addresses> <what> — a note to whoever gets the alerts, by the working relay, because
# someone with a stolen session could change these. Best effort: never fails the job.
notify_change() {
  local list="$1" what="$2" body
  [ -n "$list" ] || return 0
  OPS_ALERT_EMAIL="$list"
  load_recipients 2>/dev/null
  [ "${#RCPTS[@]}" -gt 0 ] || return 0
  body="$(mktemp)"
  {
    echo "Workforce server notice"
    echo "Server: ${APP_HOSTNAME:-$(hostname)} (environment: ${ENV_NAME:-prod})"
    echo "Time:   $(now_text)"
    echo
    echo "$what, from Setup in Workforce. The organisation's audit trail says who did it."
    echo "If you weren't expecting this, look at it now: logs/server-actions.log on the server has the"
    echo "details, and SERVER_ACTIONS=off in .env stops these jobs whatever the app asks for."
  } > "$body"
  deliver "[Workforce ${ENV_NAME:-prod} ${APP_HOSTNAME:-}] server setting changed" "$body" >/dev/null 2>&1 || true
  rm -f "$body"
}

job_backup_now() {
  local tmp rc archive="" size="null" offsite=NONE
  tmp="$(mktemp)"
  mkdir -p backups
  # Into the nightly's log as well: the health watch reads the off-site result from it.
  bash ./bin/backup.sh 2>&1 | tee -a backups/cron.log > "$tmp"
  rc="${PIPESTATUS[0]}"
  cat "$tmp"
  case "$rc" in
    0)
      archive="$(sed -n 's#^Wrote backups/\([^ ]*\) .*#\1#p' "$tmp" | tail -n 1)"
      if [ -n "$archive" ] && [ -f "backups/$archive" ]; then size="$(stat -c %s "backups/$archive")"; fi
      if grep -q '^Off-site copy failed' "$tmp"; then offsite=FAILED
      elif grep -q '^Copying off-site to ' "$tmp"; then offsite=OK; fi
      local words="The backup finished."
      [ "$offsite" != FAILED ] || words="The backup finished, but the off-site copy failed, so this backup is only on this server."
      job_result SUCCEEDED OK "$words" "$(jq -n --argjson size "$size" --arg archive "$archive" --arg offsite "$offsite" \
        '{ sizeBytes: $size, archive: $archive, offsite: $offsite }')"
      ;;
    75) job_result REFUSED BUSY "A backup is already running. Try again when it has finished." ;;
    *)  job_result FAILED BACKUP_FAILED "The backup didn't finish: $(last_words "$tmp")" ;;
  esac
  rm -f "$tmp"
}

job_offsite_test() {
  local tmp rc before kind data
  tmp="$(mktemp)"
  before="$(offsite_last_copy)"
  case "${BACKUP_TARGET:-}" in s3://*) kind=S3 ;; *:*) kind=rsync ;; *) kind=other ;; esac
  mkdir -p backups
  bash ./bin/backup.sh --offsite-only 2>&1 | tee -a backups/cron.log > "$tmp"
  rc="${PIPESTATUS[0]}"
  cat "$tmp"
  data="$(jq -n --arg kind "$kind" --arg before "$before" '{ kind: $kind, lastCopyBefore: $before }')"
  case "$rc" in
    0) job_result SUCCEEDED OK "The test copy of the newest backup reached the off-site target." "$data" ;;
    # The last line is always "finished", so the reason comes from the line that gives it.
    3) job_result FAILED OFFSITE_FAILED "The copy to the off-site target failed: $(sed -n 's/^Off-site copy failed — //p' "$tmp" | tail -n 1 | cut -c1-300)" "$data" ;;
    4) job_result REFUSED NO_TARGET "No off-site target is set on this server. Whoever runs it sets BACKUP_TARGET." ;;
    5) job_result REFUSED NO_BACKUP "There's no backup to copy yet. Run one first." ;;
    75) job_result REFUSED BUSY "A backup is running. Try again when it has finished." ;;
    *) job_result FAILED OFFSITE_FAILED "The test didn't finish: $(last_words "$tmp")" "$data" ;;
  esac
  rm -f "$tmp"
}

job_staff_mail_on() {
  local tmp rc
  local -a args=(on --webmail-host "${P[webmailHost]}")
  [ -z "${P[mailHost]}" ] || args+=(--mail-host "${P[mailHost]}")
  local old_alerts="${OPS_ALERT_EMAIL:-}"
  snapshot_env
  if [ "${P[useOutgoingRelay]}" = true ]; then
    args+=(--relay "${SMTP_HOST}:${SMTP_PORT:-587}")
    [ -z "${SMTP_USERNAME:-}" ] || args+=(--relay-user "$SMTP_USERNAME")
    [ "${SMTP_PORT:-587}" != 465 ] || args+=(--relay-implicit-tls)
    # In place: the mail server's mount of this one file is bound to its inode.
    ( umask 077; printf '%s' "${SMTP_PASSWORD:-}" > secrets/mail_relay_password )
  fi
  [ -z "${P[relaySpfInclude]}" ] || args+=(--relay-spf-include "${P[relaySpfInclude]}")
  # Worked out here and not asked for: it says to trust a private CA, so it only follows this server.
  case "${GATEWAY_CADDYFILE:-}" in *localca*) args+=(--private-ca) ;; esac
  job_phase STARTING_MAIL
  tmp="$(mktemp)"
  bash ./bin/staff-mail.sh "${args[@]}" > "$tmp" 2>&1
  rc=$?
  cat "$tmp"
  if [ "$rc" -eq 0 ]; then
    discard_snapshot
    notify_change "$old_alerts" "Staff email was switched on, with webmail at ${P[webmailHost]}"
    job_result SUCCEEDED OK "Staff email is on. Next: choose the staff domain below, switch mailboxes on, then add the DNS records it shows." \
      "$(jq -n --arg webmail "${P[webmailHost]}" '{ on: true, webmailHost: $webmail }')"
    rm -f "$tmp"
    return 0
  fi
  local code=MAIL_FAILED words
  words="Staff email couldn't be switched on, and the settings have been put back: $(last_words "$tmp")"
  if grep -qiE 'privileged port|ip_unprivileged_port_start|bind.*:25\b|address already in use' "$tmp"; then
    code=PORT_25
    words="The mail server couldn't use port 25, so the settings have been put back. Whoever runs this server needs to run this once as root: sysctl -w net.ipv4.ip_unprivileged_port_start=25, and make sure nothing else is using port 25."
  fi
  rm -f "$tmp"
  restore_env
  docker compose stop mail webmail >/dev/null 2>&1 || true
  docker compose up -d --no-deps api worker gateway >/dev/null 2>&1 || true
  job_result FAILED "$code" "$words"
}

job_staff_mail_off() {
  local tmp rc old_alerts="${OPS_ALERT_EMAIL:-}"
  tmp="$(mktemp)"
  job_phase STOPPING_MAIL
  bash ./bin/staff-mail.sh off > "$tmp" 2>&1
  rc=$?
  cat "$tmp"
  if [ "$rc" -eq 0 ]; then
    notify_change "$old_alerts" "Staff email was switched off"
    job_result SUCCEEDED OK "Staff email is off. Mailboxes and their mail are kept, and switching it on again picks up where it left off." '{"on":false}'
  else
    job_result FAILED MAIL_FAILED "Staff email couldn't be switched off: $(last_words "$tmp")"
  fi
  rm -f "$tmp"
}

# What a refusing relay said, in words. curl's own exit codes, so nothing it printed needs trusting.
relay_words() { # relay_words <curl exit code>
  case "$1" in
    6)  echo "The relay's host name wasn't found." ;;
    7|28) echo "Workforce couldn't reach the relay at that host and port. Check them, and that the provider allows this server." ;;
    35|60|58|77) echo "The relay's secure connection (TLS) couldn't be set up." ;;
    64) echo "The relay doesn't offer STARTTLS, which Workforce needs." ;;
    67) echo "The relay refused the user name or password." ;;
    55|56|52) echo "The relay stopped responding part way through." ;;
    *)  echo "The relay didn't accept the test email." ;;
  esac
}

job_relay_apply() {
  local host="${P[host]}" port="${P[port]}" user="${P[username]}" pass="${P[password]}" from="${P[from]}" to="${P[testAddress]}"
  local starttls=true old_host="${SMTP_HOST:-}" old_user="${SMTP_USERNAME:-}" old_pass="${SMTP_PASSWORD:-}"
  local old_alerts="${OPS_ALERT_EMAIL:-}" quoted body msg out rc
  [ "${SERVER_ACTIONS_PLAIN_RELAY:-}" != "${host}:${port}" ] || starttls=false

  # 1. The test send, with these values and nothing saved. In this process only: not exported.
  SMTP_HOST="$host"; SMTP_PORT="$port"; SMTP_USERNAME="$user"; SMTP_PASSWORD="$pass"
  # shellcheck disable=SC2034  # read by send_mail, from healthwatch.sh
  SMTP_STARTTLS="$starttls"
  job_phase TESTING_RELAY
  body="$(mktemp)"; msg="$(mktemp)"
  {
    echo "This is a test email from the Workforce server at ${APP_HOSTNAME:-this server}."
    echo
    echo "Someone is setting up its outgoing email. If you weren't expecting this, you can ignore it,"
    echo "or tell whoever runs Workforce: nothing is saved until this has been accepted."
  } > "$body"
  build_message "$from" "[Workforce ${ENV_NAME:-prod} ${APP_HOSTNAME:-}] test email" "$body" "$to" > "$msg"
  out="$(send_mail "$msg" "$from" "$to")"
  rc=$?
  rm -f "$body" "$msg"
  if [ "$rc" -ne 0 ]; then
    echo "test send failed (curl exit $rc): $out"
    job_result FAILED RELAY_REFUSED "$(relay_words "$rc") Nothing was saved." \
      "$(jq -n --arg host "$host" --arg port "$port" '{ host: $host, port: $port, saved: false }')"
    return 0
  fi
  echo "test send accepted by ${host}:${port}"

  # 2. Save, by the one rule .env has for values like this, and check it reads back the same.
  if ! quoted="$(env_single_quote "$pass")"; then
    job_result FAILED BAD_PASSWORD "That password can't be stored safely. Nothing was saved."
    return 0
  fi
  snapshot_env
  env_set SMTP_HOST "$host" && env_set SMTP_PORT "$port" && env_set SMTP_USERNAME "$user" \
    && env_set SMTP_PASSWORD "$quoted" && env_set SMTP_STARTTLS "$starttls" && env_set SMTP_FROM "$from"
  rc=$?
  # A mail server sending through the same relay follows it.
  local shared=false
  if [ "$rc" -eq 0 ] && [ -n "${MAIL_RELAY_HOST:-}" ] && [ "${MAIL_RELAY_HOST}" = "$old_host" ] && [ "${MAIL_RELAY_USER:-}" = "$old_user" ]; then
    shared=true
    env_set MAIL_RELAY_HOST "$host" && env_set MAIL_RELAY_PORT "$port" && env_set MAIL_RELAY_USER "$user"
    rc=$?
  fi
  if [ "$rc" -eq 0 ] && ! ( . ./.env >/dev/null 2>&1; [ "${SMTP_PASSWORD:-}" = "$pass" ] && [ "${SMTP_HOST:-}" = "$host" ] ); then
    rc=1
  fi
  if [ "$rc" -eq 0 ] && ! docker compose config -q >/dev/null 2>&1; then
    rc=1
  fi
  if [ "$rc" -ne 0 ]; then
    restore_env
    job_result FAILED SAVE_FAILED "The relay accepted the test, but the setting couldn't be saved. Nothing has changed."
    return 0
  fi
  # In place, as the mail server's mount of this one file is bound to its inode. The app reads it too.
  [ "$shared" = false ] || { printf '%s' "$pass" > secrets/mail_relay_password; chmod 644 secrets/mail_relay_password; }

  # 3. Restart what read the old values at start. Never the backup container, which this is running
  # in: it and the health watch read .env at every run, so they need no restart, and restarting it
  # would stop this job part way. The worker first, the api last: when the app comes back and reads
  # the result, everything else is already done.
  job_phase RESTARTING
  docker compose up -d --no-deps --force-recreate worker
  rc=$?
  if [ "$rc" -eq 0 ]; then
    docker compose up -d --no-deps --force-recreate --wait --wait-timeout 300 api
    rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    restore_env
    [ "$shared" = false ] || printf '%s' "$old_pass" > secrets/mail_relay_password
    docker compose up -d --no-deps --force-recreate worker api >/dev/null 2>&1 || true
    job_result FAILED RESTART_FAILED "The relay accepted the test, but Workforce didn't start properly with the new settings, so the old ones have been put back."
    return 0
  fi
  discard_snapshot
  OPS_ALERT_EMAIL="$old_alerts"
  SMTP_HOST="$host"
  notify_change "$old_alerts" "The outgoing email relay was changed to ${host}:${port}"
  job_result SUCCEEDED OK "The relay accepted the test email to ${to}, and the new settings are in use." \
    "$(jq -n --arg host "$host" --arg port "$port" --arg from "$from" '{ host: $host, port: $port, from: $from, saved: true }')"
}

job_alerts_set() {
  local list="${P[alertAddress]}" mode="${P[heartbeatMode]}" url="${P[heartbeatUrl]}" old_alerts="${OPS_ALERT_EMAIL:-}" quoted rc=0
  if ! env_set OPS_ALERT_EMAIL "$list"; then
    job_result FAILED SAVE_FAILED "The setting couldn't be saved. Nothing has changed."
    return 0
  fi
  case "$mode" in
    set)
      quoted="$(env_single_quote "$url")" && env_set OPS_HEARTBEAT_URL "$quoted" || rc=1 ;;
    clear)
      env_set OPS_HEARTBEAT_URL "" || rc=1 ;;
  esac
  if [ "$rc" -ne 0 ]; then
    job_result FAILED SAVE_FAILED "The alert address was saved, but the uptime check's address couldn't be."
    return 0
  fi
  # The watch reads .env at every run, so there's nothing to restart. The old address hears of it.
  if [ "$list" != "$old_alerts" ]; then
    notify_change "$old_alerts" "The address server alerts go to was changed"
  fi
  # shellcheck disable=SC1091
  . ./.env
  local ping=none sent=false note="" words
  if [ -n "${OPS_HEARTBEAT_URL:-}" ]; then
    HEARTBEAT_NOTE=""
    heartbeat
    case "$HEARTBEAT_NOTE" in "heartbeat sent") ping=sent ;; *) ping=failed ;; esac
  fi
  load_recipients 2>/dev/null
  if [ "${#RCPTS[@]}" -eq 0 ]; then
    words="Saved. There's no alert address now, so problems are only written to the server's log."
  elif send_test 0 >/dev/null 2>&1; then
    sent=true
    words="Saved, and a test alert was sent to ${list}. Check that it arrives."
  else
    note="$DELIVER_NOTE"
    echo "test alert failed: $note"
    words="Saved, but the test alert couldn't be sent. Check the outgoing email relay. The server's log has the reason."
  fi
  [ "$ping" != failed ] || words="$words The uptime check's address didn't answer."
  job_result SUCCEEDED "$([ "$sent" = true ] || [ "${#RCPTS[@]}" -eq 0 ] && echo OK || echo TEST_NOT_SENT)" "$words" \
    "$(jq -n --argjson sent "$sent" --arg ping "$ping" --argjson hb "$([ -n "${OPS_HEARTBEAT_URL:-}" ] && echo true || echo false)" \
        '{ testSent: $sent, ping: $ping, heartbeatSet: $hb }')"
}

sa_job() {
  local line
  declare -gA P=()
  while IFS= read -r line; do P["${line%%=*}"]="${line#*=}"; done
  # shellcheck disable=SC1091  # in this job's own process; not exported, so `docker compose` still reads .env itself
  . ./.env
  case "$SA_JOB_ACTION" in
    backup-now)     job_backup_now ;;
    offsite-test)   job_offsite_test ;;
    staff-mail-on)  job_staff_mail_on ;;
    staff-mail-off) job_staff_mail_off ;;
    relay-apply)    job_relay_apply ;;
    alerts-set)     job_alerts_set ;;
    *) exit 2 ;;
  esac
}

# ------------------------------------------------------------------ passes
pass_over_requests() {
  local f n=0
  for f in "$SA_REQUESTS"/*; do
    if [ -e "$f" ] || [ -L "$f" ]; then
      n=$((n + 1))
      [ "$n" -le "$SA_PER_PASS" ] || break
      handle_request "$f"
    fi
  done
}

# A job was running when this script last stopped (the container restarted, say). Whoever asked is
# told; nothing starts it again.
recover_interrupted() {
  local id action
  [ -f "$SA_WORK/running" ] || return 0
  read -r id action < "$SA_WORK/running"
  rm -f "$SA_WORK/running"
  [[ "$id" =~ $UUID_RE ]] || return 0
  # A settings job that stopped part way leaves the snapshot: put .env back.
  if [ -f "$SA_WORK/env.before" ]; then
    mv -f "$SA_WORK/env.before" .env
    sa_log "$id $(safe_token "$action") restored .env after an interrupted job"
  fi
  rm -f "$SA_WORK/$id.out" "$SA_WORK/$id.res"
  write_result "$id" "$(safe_token "$action")" FAILED INTERRUPTED "The server's helper was restarted while this was running, so it didn't finish." "" "" "$(iso_now)" "" '{}'
  sa_log "$id $(safe_token "$action") FAILED INTERRUPTED"
}

# While a job runs, anything else that arrives gets a written refusal, not a long wait until it expires.
refuse_while_running() {
  local f name id n=0
  [ -f "$SA_WORK/running" ] || return 0
  for f in "$SA_REQUESTS"/*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    n=$((n + 1)); [ "$n" -le "$SA_PER_PASS" ] || break
    name="${f##*/}"; id="${name%.json}"
    rm -rf -- "$f"
    if [[ "$id" =~ $UUID_RE ]] && [ ! -e "$SA_WORK/seen/$id" ]; then
      : > "$SA_WORK/seen/$id"
      finish_unrun "$id" unknown REFUSED BUSY "Another job is running on this server. Try again when it has finished."
    else
      sa_log "- - REFUSED BUSY $(safe_token "$name")"
    fi
  done
}

sa_usage() { sed -n '2,33p' "${BASH_SOURCE[0]}"; }

sa_main() {
  local mode="${1:-}" started
  cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
  # shellcheck source=lib/common.sh
  . ./bin/lib/common.sh
  # Its mail, masking and off-site reading are what this uses, so the two can't drift. It only defines
  # functions when sourced, but it does turn on -e, which this script doesn't want.
  # shellcheck source=healthwatch.sh
  . ./bin/healthwatch.sh
  set +e
  if [ "$mode" = --job ]; then
    sa_job
    exit $?
  fi
  case "$mode" in
    --tick|--beat|--once) ;;
    *) sa_usage; exit 2 ;;
  esac
  if [ "${WORKFORCE_IN_STACK:-}" != 1 ]; then
    echo "This runs in the backup container, by itself. To see what it's doing: tail logs/server-actions.log" >&2
    exit 2
  fi
  [ -f .env ] || { echo "No .env here — run ./bin/install.sh first." >&2; exit 2; }
  command -v jq >/dev/null 2>&1 || { sa_log "- - jq is missing: docker compose up -d backup puts it back"; exit 2; }
  ensure_mailbox || { sa_log "- - the mailbox folders can't be made"; exit 2; }

  if [ "$mode" = --beat ]; then
    if [ -f "$SA_WORK/running" ]; then
      write_heartbeat true
      refuse_while_running
    else
      write_heartbeat false
    fi
    exit 0
  fi

  exec 9>"$SA_WORK/lock" || exit 2
  # Busybox's flock is enough, and the kernel lets go of it however this ends.
  if ! flock -n 9; then
    refuse_while_running
    exit 0
  fi
  recover_interrupted
  prune
  write_heartbeat false
  if [ "$mode" = --once ]; then
    pass_over_requests
    write_heartbeat false
    exit 0
  fi
  started="$(now_epoch)"
  local beat="$started"
  while :; do
    pass_over_requests
    [ $(($(now_epoch) - started)) -lt "$SA_TICK_SECS" ] || break
    sleep "$SA_POLL_SECS"
    if [ $(($(now_epoch) - beat)) -ge 20 ]; then
      write_heartbeat false
      beat="$(now_epoch)"
    fi
  done
  write_heartbeat false
}

# Run when executed; only define the functions when sourced (bin/tests/server-actions-test.sh).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  sa_main "$@"
fi
