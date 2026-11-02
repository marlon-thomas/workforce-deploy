#!/usr/bin/env bash
# healthwatch.sh — tell someone OUTSIDE this server when it has a problem (RUNBOOK.md, "Server
# alerts"). The backup container runs it every 15 minutes.
#
# Each run takes ./bin/doctor.sh --plain, remembers which checks FAIL in state/healthwatch.state,
# and emails OPS_ALERT_EMAIL (comma-separated) when
#   - a check newly FAILs (including one that was a WARN)    "[Workforce prod host] 2 checks failing: …"
#   - something still FAILs and the last email is 24 h old   "… reminder: 2 checks still failing: …"
#   - every FAIL has cleared                                 "… resolved: no checks failing"
# The email goes straight to SMTP_HOST:SMTP_PORT with curl — never through Workforce and never
# through this server's own mail server (Stalwart) — so it still arrives when those are what broke.
# OPS_ALERT_EMAIL empty = problems are only logged. Log: logs/healthwatch.log.
#
#   ./bin/healthwatch.sh            one watch run (what the schedule does)
#   ./bin/healthwatch.sh --test     send a test alert now (proves the whole mail path)
#   ./bin/healthwatch.sh --dry-run  run the checks and print what would be sent; sends and saves nothing
#   ./bin/healthwatch.sh --here     (with any of the above) run on this machine, not in the backup
#                                   container — by default a run on the host is handed to the backup
#                                   container, so it uses the same network and tools as the schedule
#
# Exit: 0 all checks pass · 1 checks failing (alerts handled) · 2 usage or configuration error ·
#       3 an email was due but could not be sent (the next run tries again)
set -euo pipefail

HW_STATE_FILE="${HW_STATE_FILE:-state/healthwatch.state}"
HW_LOG_FILE="${HW_LOG_FILE:-logs/healthwatch.log}"
HW_REMIND_SECS=$((24 * 3600))
HW_INVESTIGATE="cd $(pwd) && ./bin/doctor.sh"   # replaced in main() once we are in the bundle

# ------------------------------------------------------------------ small helpers (stubbed in tests)
now_epoch() { date +%s; }
now_text() { date -u '+%Y-%m-%d %H:%M UTC'; }
run_doctor() { ./bin/doctor.sh --plain 2>&1 || true; }

hw_log() { # hw_log <message> — one line to the log (rotated at 1 MB) and to stdout
  local line
  line="$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"
  mkdir -p "$(dirname "$HW_LOG_FILE")"
  if [ -f "$HW_LOG_FILE" ] && [ "$(wc -c < "$HW_LOG_FILE")" -gt 1048576 ]; then
    mv -f "$HW_LOG_FILE" "${HW_LOG_FILE}.1"
  fi
  printf '%s\n' "$line" >> "$HW_LOG_FILE"
  printf '%s\n' "$line"
}

# ------------------------------------------------------------------ reading doctor's output
# parse_rows — doctor --plain output on stdin; prints one STATUS<TAB>check<TAB>detail per check,
# the last row of a check winning (doctor prints "object storage" WARN then OK when it falls back).
# Output that never reached doctor's '# done' line becomes a FAIL "health check" row.
parse_rows() {
  awk -F'\t' '
    /^(OK|WARN|FAIL|SKIP)\t/ { if (!($2 in st)) order[++n] = $2; st[$2] = $1; dt[$2] = $3; next }
    /^# done fails=/         { done = 1; next }
    /^#/                     { next }
    NF                       { last = $0 }
    END {
      for (i = 1; i <= n; i++) printf "%s\t%s\t%s\n", st[order[i]], order[i], dt[order[i]]
      if (!done) {
        why = (last != "") ? " (" substr(last, 1, 160) ")" : ""
        printf "FAIL\thealth check\tdoctor.sh stopped before finishing%s\n", why
      }
    }'
}
labels_with() { # labels_with <STATUS> — rows on stdin; prints the matching check names
  awk -F'\t' -v s="$1" '$1 == s { print $2 }'
}

# decide <previous fails> <current fails> <now> <last email epoch> — names are newline-separated.
# Prints alert | reminder | resolved | none.
decide() {
  local prev="$1" cur="$2" now="$3" last="${4:-0}" l
  if [ -n "$cur" ]; then
    while IFS= read -r l; do
      [ -n "$l" ] || continue
      if ! printf '%s\n' "$prev" | grep -Fxq -- "$l"; then echo alert; return 0; fi
    done <<< "$cur"
    if [ $(( now - last )) -ge "$HW_REMIND_SECS" ]; then echo reminder; else echo none; fi
  elif [ -n "$prev" ]; then
    echo resolved
  else
    echo none
  fi
}

# ------------------------------------------------------------------ state
PREV_FAILS=""; LAST_SENT=0
load_state() {
  PREV_FAILS=""; LAST_SENT=0
  [ -f "$HW_STATE_FILE" ] || return 0
  local line v
  while IFS= read -r line; do
    case "$line" in
      last_sent=*) v="${line#*=}"; case "$v" in ''|*[!0-9]*) ;; *) LAST_SENT="$v" ;; esac ;;
      fail=*)      PREV_FAILS="${PREV_FAILS}${line#fail=}"$'\n' ;;
    esac
  done < "$HW_STATE_FILE"
  PREV_FAILS="${PREV_FAILS%$'\n'}"
}
save_state() { # save_state <fails> <last email epoch> <run epoch>
  local tmp="${HW_STATE_FILE}.tmp.$$" l
  mkdir -p "$(dirname "$HW_STATE_FILE")"
  {
    echo "# bin/healthwatch.sh state. Safe to delete: the next run then alerts afresh."
    echo "last_run=$3"
    echo "last_sent=$2"
    while IFS= read -r l; do [ -n "$l" ] && echo "fail=$l"; done <<< "$1"
  } > "$tmp"
  mv -f "$tmp" "$HW_STATE_FILE"
}

# ------------------------------------------------------------------ composing the email
join_names() { # newline-separated names on stdin -> "a, b, c"
  awk 'NF { printf "%s%s", (n++ ? ", " : ""), $0 } END { print "" }'
}
count_lines() { awk 'NF { n++ } END { print n + 0 }'; }

subject_for() { # subject_for <alert|reminder|resolved|test> <current fails>
  local prefix n list what
  prefix="[Workforce ${ENV_NAME:-prod} ${APP_HOSTNAME:-$(hostname)}]"
  n="$(printf '%s\n' "$2" | count_lines)"
  list="$(printf '%s\n' "$2" | join_names)"
  if [ "${#list}" -gt 150 ]; then list="${list:0:147}..."; fi
  if [ "$n" -eq 1 ]; then what="1 check"; else what="$n checks"; fi
  case "$1" in
    alert)    echo "$prefix $what failing: $list" ;;
    reminder) echo "$prefix reminder: $what still failing: $list" ;;
    resolved) echo "$prefix resolved: no checks failing" ;;
    test)     echo "$prefix test alert" ;;
  esac
}

body_for() { # body_for <action> <rows> <previous fails> <last email epoch>
  local action="$1" rows="$2" prev="$3" last="${4:-0}" cur new fails warns
  cur="$(printf '%s\n' "$rows" | labels_with FAIL)"
  fails="$(printf '%s\n' "$rows" | awk -F'\t' '$1 == "FAIL" { printf "  FAIL  %s: %s\n", $2, $3 }')"
  warns="$(printf '%s\n' "$rows" | awk -F'\t' '$1 == "WARN" { printf "  WARN  %s: %s\n", $2, $3 }')"
  echo "Workforce server health watch"
  echo "Server: ${APP_HOSTNAME:-$(hostname)} (environment: ${ENV_NAME:-prod})"
  echo "Time:   $(now_text)"
  echo
  case "$action" in
    alert)
      new="$(printf '%s\n' "$cur" | grep -Fvx -f <(printf '%s\n' "$prev") | join_names || true)"
      echo "A health check on this server has started failing. New since the last email: ${new:-?}."
      ;;
    reminder)
      echo "These checks are still failing. Reminders come at most once a day while anything fails."
      [ "$last" -gt 0 ] && echo "Previous email: $(date -u -d "@$last" '+%Y-%m-%d %H:%M UTC' 2>/dev/null || echo "$last")"
      ;;
    resolved)
      echo "Every check that was failing has recovered: $(printf '%s\n' "$prev" | join_names)."
      ;;
    test)
      echo "This is a test alert, sent by ./bin/healthwatch.sh --test. If you are reading it, alerts"
      echo "from this server reach you. Nothing is wrong (the health checks were not run for this test)."
      ;;
  esac
  echo
  if [ -n "$fails" ]; then echo "Failing:"; printf '%s\n' "$fails"; echo; fi
  if [ -n "$warns" ]; then echo "Warnings:"; printf '%s\n' "$warns"; echo; fi
  echo "To investigate, on the server:"
  echo "  ${HW_INVESTIGATE}"
  echo "The watch log is logs/healthwatch.log in the same folder."
  echo
  echo "-- "
  echo "Sent by bin/healthwatch.sh straight to the outgoing relay (${SMTP_HOST:-none}), not through"
  echo "Workforce or this server's own mail. Set OPS_ALERT_EMAIL in .env to change who receives it."
}

encode_header() { # RFC 2047 when the text is not plain ASCII
  if printf '%s' "$1" | LC_ALL=C grep -q '[^ -~]'; then
    printf '=?UTF-8?B?%s?=' "$(printf '%s' "$1" | base64 | tr -d '\n')"
  else
    printf '%s' "$1"
  fi
}
envelope_of() { # "Name <a@b>" or "a@b" -> a@b
  case "$1" in *\<*\>*) local x="${1#*<}"; printf '%s' "${x%%>*}" ;; *) printf '%s' "$1" ;; esac
}
build_message() { # build_message <from> <subject> <bodyfile> <rcpt>... -> RFC 5322 message, CRLF
  local from="$1" subject="$2" body="$3" to=""
  shift 3
  local r; for r in "$@"; do to="${to:+${to}, }${r}"; done
  case "$from" in *\<*) ;; *) from="Workforce health watch <${from}>" ;; esac
  {
    echo "Date: $(date -R)"
    echo "From: ${from}"
    echo "To: ${to}"
    echo "Subject: $(encode_header "$subject")"
    echo "Message-ID: <healthwatch.$(date +%s).$$@${APP_HOSTNAME:-localhost}>"
    echo "MIME-Version: 1.0"
    echo "Content-Type: text/plain; charset=UTF-8"
    echo "Content-Transfer-Encoding: base64"
    echo "Auto-Submitted: auto-generated"
    echo "X-Auto-Response-Suppress: All"
    echo
    crlf < "$body" | base64      # the canonical (CRLF) text, so no relay ever rewrites it
  } | crlf
}
crlf() { awk '{ sub(/\r$/, ""); printf "%s\r\n", $0 }'; }

# ------------------------------------------------------------------ sending (curl over SMTP)
# send_mail <message file> <envelope from> <rcpt>... — straight to SMTP_HOST:SMTP_PORT.
# Port 465 = implicit TLS; SMTP_STARTTLS=true = STARTTLS required; SMTP_USERNAME set = AUTH, with
# the credentials in a 0600 curl config file in a private temp dir (never on curl's command line,
# where `ps` would show them). Prints curl's error (never a credential) and returns non-zero on failure.
send_mail() {
  local msg="$1" from="$2" port scheme tmpd rc=0 u p
  shift 2
  if [ -z "${SMTP_HOST:-}" ]; then echo "SMTP_HOST is empty — nowhere to send"; return 1; fi
  port="${SMTP_PORT:-587}"
  scheme=smtp; [ "$port" = 465 ] && scheme=smtps
  local -a args=(--silent --show-error --connect-timeout 15 --max-time 60
                 --url "${scheme}://${SMTP_HOST}:${port}/${APP_HOSTNAME:-localhost}"
                 --mail-from "$from" --upload-file "$msg")
  if [ "${SMTP_STARTTLS:-false}" = true ] && [ "$scheme" = smtp ]; then args+=(--ssl-reqd); fi
  local r; for r in "$@"; do args+=(--mail-rcpt "$r"); done
  tmpd="$(umask 077 && mktemp -d)"
  if [ -n "${SMTP_USERNAME:-}" ]; then
    u="${SMTP_USERNAME//\\/\\\\}"; u="${u//\"/\\\"}"
    p="${SMTP_PASSWORD:-}"; p="${p//\\/\\\\}"; p="${p//\"/\\\"}"
    ( umask 077; printf 'user = "%s:%s"\n' "$u" "$p" > "$tmpd/auth.conf" )
    args+=(--config "$tmpd/auth.conf")
  fi
  curl "${args[@]}" 2> "$tmpd/err" || rc=$?
  if [ "$rc" -ne 0 ]; then head -c 300 "$tmpd/err" | tr '\n' ' '; echo; fi
  rm -rf "$tmpd"
  return "$rc"
}

# ------------------------------------------------------------------ recipients and sender
RCPTS=()
load_recipients() {
  RCPTS=()
  local raw="${OPS_ALERT_EMAIL:-}" a
  local -a parts
  raw="${raw// /}"
  IFS=',' read -r -a parts <<< "$raw"
  for a in "${parts[@]}"; do
    [ -n "$a" ] || continue
    case "$a" in
      *[\<\>\"\'\;]*|*@*@*) echo "Ignoring '$a' in OPS_ALERT_EMAIL: not a plain address" >&2; continue ;;
      ?*@?*.?*) RCPTS+=("$a") ;;
      *) echo "Ignoring '$a' in OPS_ALERT_EMAIL: not an email address" >&2 ;;
    esac
  done
}
sender() { printf '%s' "${OPS_ALERT_FROM:-${SMTP_FROM:-healthwatch@${APP_HOSTNAME:-localhost}}}"; }

# deliver <subject> <bodyfile> — 0 when sent or nobody to send to; 1 on a failed send.
DELIVER_NOTE=""
deliver() {
  local subject="$1" body="$2" msg out from
  if [ "${#RCPTS[@]}" -eq 0 ]; then
    DELIVER_NOTE="not emailed: OPS_ALERT_EMAIL is empty"; return 0
  fi
  from="$(sender)"
  msg="$(umask 077 && mktemp)"
  build_message "$from" "$subject" "$body" "${RCPTS[@]}" > "$msg"
  if out="$(send_mail "$msg" "$(envelope_of "$from")" "${RCPTS[@]}")"; then
    DELIVER_NOTE="emailed ${RCPTS[*]}"; rm -f "$msg"; return 0
  fi
  DELIVER_NOTE="EMAIL FAILED via ${SMTP_HOST:-?}:${SMTP_PORT:-587}: ${out:-no detail}"
  rm -f "$msg"
  return 1
}

print_dry() { # print_dry <subject> <bodyfile>
  local to="(nobody — OPS_ALERT_EMAIL is empty; it would only be logged)"
  [ "${#RCPTS[@]}" -gt 0 ] && to="${RCPTS[*]}"
  echo "----- would send (via ${SMTP_HOST:-<no SMTP_HOST>}:${SMTP_PORT:-587}) -----"
  echo "From:    $(sender)"
  echo "To:      $to"
  echo "Subject: $1"
  echo
  cat "$2"
  echo "----- end -----"
}

# ------------------------------------------------------------------ one watch run
# watch_once <dry 0|1> — returns the exit code described at the top.
watch_once() {
  local dry="$1" out rows cur warns action now subject body rc=0 sent_at summary
  now="$(now_epoch)"
  out="$(run_doctor)"
  rows="$(printf '%s\n' "$out" | parse_rows)"
  cur="$(printf '%s\n' "$rows" | labels_with FAIL)"
  warns="$(printf '%s\n' "$rows" | labels_with WARN | count_lines)"
  load_state
  action="$(decide "$PREV_FAILS" "$cur" "$now" "$LAST_SENT")"
  if [ -n "$cur" ]; then
    summary="failing: $(printf '%s\n' "$cur" | join_names); ${warns} warning(s)"
  else
    summary="ok: no checks failing; ${warns} warning(s)"
  fi

  if [ "$dry" -eq 1 ]; then
    echo "$summary"
    echo "decision: $action (previously failing: $(printf '%s\n' "$PREV_FAILS" | join_names | sed 's/^$/nothing/'))"
    if [ "$action" != none ]; then
      body="$(mktemp)"
      body_for "$action" "$rows" "$PREV_FAILS" "$LAST_SENT" > "$body"
      print_dry "$(subject_for "$action" "$cur")" "$body"
      rm -f "$body"
    fi
    [ -z "$cur" ] || return 1
    return 0
  fi

  if [ "$action" = none ]; then
    save_state "$cur" "$LAST_SENT" "$now"
    hw_log "$summary"
  else
    subject="$(subject_for "$action" "$cur")"
    body="$(mktemp)"
    body_for "$action" "$rows" "$PREV_FAILS" "$LAST_SENT" > "$body"
    if deliver "$subject" "$body"; then
      sent_at="$now"
      save_state "$cur" "$sent_at" "$now"
    else
      rc=3
      DELIVER_NOTE="${DELIVER_NOTE} (the next run tries again)"
      save_state "$PREV_FAILS" "$LAST_SENT" "$now"   # unchanged: the next run decides the same
    fi
    rm -f "$body"
    hw_log "$summary — $action: \"$subject\" — $DELIVER_NOTE"
  fi
  [ "$rc" -eq 0 ] || return "$rc"
  [ -z "$cur" ] || return 1
  return 0
}

send_test() { # send_test <dry 0|1>
  local body subject rc=0
  if [ "${#RCPTS[@]}" -eq 0 ]; then
    echo "OPS_ALERT_EMAIL is empty — set it in .env (comma-separated, no spaces) to an address" >&2
    echo "outside this server, then run this again." >&2
    return 2
  fi
  subject="$(subject_for test "")"
  body="$(mktemp)"
  body_for test "" "" 0 > "$body"
  if [ "$1" -eq 1 ]; then print_dry "$subject" "$body"; rm -f "$body"; return 0; fi
  deliver "$subject" "$body" || rc=3
  rm -f "$body"
  hw_log "test alert: \"$subject\" — $DELIVER_NOTE"
  return "$rc"
}

# ------------------------------------------------------------------ entry point
usage() { sed -n '2,22p' "${BASH_SOURCE[0]}"; }

main() {
  local mode=watch dry=0 here=0 arg
  for arg in "$@"; do
    case "$arg" in
      --test)    mode="test" ;;
      --dry-run) dry=1 ;;
      --here)    here=1 ;;
      -h|--help) usage; return 0 ;;
      *) echo "Unknown option: $arg" >&2; usage >&2; return 2 ;;
    esac
  done
  cd "$(dirname "${BASH_SOURCE[0]}")/.."
  umask 077
  if [ ! -f .env ]; then echo "No .env here — run ./bin/install.sh first." >&2; return 2; fi
  # shellcheck disable=SC1091
  . ./.env
  HW_INVESTIGATE="cd $(pwd) && ./bin/doctor.sh"

  # On the host, hand the run to the backup container: the schedule runs there, and only there
  # do compose-network relay names (the test appliance's `mailpit`) resolve.
  if [ "$here" -eq 0 ] && [ "${WORKFORCE_IN_STACK:-}" != 1 ]; then
    # shellcheck source=lib/common.sh
    . ./bin/lib/common.sh
    use_docker_socket
    # shellcheck disable=SC2016  # expanded inside the container
    if docker compose exec -T backup sh -c 'command -v curl && [ "${WORKFORCE_IN_STACK:-}" = 1 ]' >/dev/null 2>&1; then
      exec docker compose exec -T -w /opt/workforce-deploy backup ./bin/healthwatch.sh "$@"
    fi
    echo "(the backup container is not running the health watch yet — docker compose up -d backup;" >&2
    echo " running here instead)" >&2
  fi

  mkdir -p "$(dirname "$HW_STATE_FILE")" "$(dirname "$HW_LOG_FILE")"
  if command -v flock >/dev/null 2>&1; then
    exec 9> "$(dirname "$HW_STATE_FILE")/healthwatch.lock"
    if ! flock -n 9; then echo "Another health watch run is in progress — skipped."; return 0; fi
  fi
  load_recipients
  if [ "$mode" = test ]; then send_test "$dry"; else watch_once "$dry"; fi
}

# Run when executed; only define the functions when sourced (bin/tests/healthwatch-test.sh).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
