# shellcheck shell=bash
# Things that belong to the TEST appliance only, and must never reach production (Workforce, owner 8 November
# 2026): the test inbox page (mailpit's web UI behind the gateway), mailpit itself, and mailpit as a relay. Each
# function prints one line per problem and returns non-zero when there is any. Used by bin/ci-validate.sh (the
# committed files), bin/doctor.sh (a running install), install.sh and update.sh; self-tested in
# bin/tests/prod-guards-test.sh. "The test appliance" is ENV_NAME=test, as everywhere else in this repo.

# profiles_include_mail <COMPOSE_PROFILES> — true when compose would start mailpit: the "mail" profile, or "*" (every
# profile). Compose trims spaces around each entry, so this does too. Split by read, never by an unquoted expansion:
# that globbed "*" into the names of the files in the working folder (doctor.sh's is the bundle), so it passed.
profiles_include_mail() {
  local entry entries=()
  IFS=, read -r -a entries <<< "$1"
  for entry in "${entries[@]}"; do
    entry="$(printf '%s' "$entry" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    case "$entry" in mail|'*') return 0 ;; esac
  done
  return 1
}

# prod_guard_env_file <env file> — a non-test environment file sets nothing test-only.
prod_guard_env_file() {
  local f="$1" bad=0 line key val
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"        # leading whitespace
    case "$line" in export[[:space:]]*) line="${line#export}"; line="${line#"${line%%[![:space:]]*}"}" ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    key="$(printf '%s' "${line%%=*}" | tr -d '[:space:]')"
    val="$(printf '%s' "${line#*=}" | tr -d "[:space:]\"'" | tr '[:upper:]' '[:lower:]')"
    case "$key" in
      TEST_INBOX|TEST_INBOX_HOSTNAME|TEST_INBOX_PASSWORD|TEST_INBOX_HASH)
        echo "$f sets $key: the test inbox is for the TEST appliance only"; bad=1 ;;
      SERVER_ACTIONS_PLAIN_RELAY)
        [ -z "$val" ] || { echo "$f sets SERVER_ACTIONS_PLAIN_RELAY: a relay without STARTTLS is for the TEST appliance only"; bad=1; } ;;
      COMPOSE_PROFILES)
        if profiles_include_mail "$val"; then echo "$f enables the mail (mailpit) profile: it catches all outgoing mail"; bad=1; fi ;;
      SMTP_HOST|SIGNIN_SMTP_HOST|MAIL_RELAY_HOST)
        case "$val" in mailpit|mailpit:*) echo "$f sends $key to mailpit: nothing would be delivered"; bad=1 ;; esac ;;
    esac
  done < "$f"
  return "$bad"
}

# prod_guard_caddyfile <Caddyfile> — a production gateway config never routes to mailpit or the test inbox.
prod_guard_caddyfile() {
  local f="$1"
  # A regular file: busybox's grep (the controller image, the backup container) finds nothing in a folder and says
  # so with 1, not 2, so a folder would pass.
  if [ ! -f "$f" ] || [ ! -r "$f" ]; then
    echo "$f can't be read, so it can't be checked"
    return 1
  fi
  local rc=0
  grep -n -i -E 'mailpit|testmail|TEST_INBOX' "$f" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -gt 1 ]; then
    echo "$f couldn't be searched, so it can't be checked"
    return 1
  fi
  if [ "$rc" -eq 0 ]; then
    echo "$f mentions mailpit or the test inbox: only gateway/Caddyfile.localca (the test CA) may"
    return 1
  fi
  return 0
}

# prod_guard_runtime <env name> <TEST_INBOX> <TEST_INBOX_HOSTNAME> <COMPOSE_PROFILES> <mailpit running: yes|no>
# — on any install that isn't the test appliance, none of the test inbox's parts may be present.
prod_guard_runtime() {
  local env_name="${1:-prod}" inbox="$2" host="$3" profiles="$4" running="$5" bad=0
  [ "$env_name" = test ] && return 0
  [ -z "$inbox" ] || { echo "TEST_INBOX is set on '$env_name': remove it from .env (the TEST appliance only)"; bad=1; }
  [ -z "$host" ] || { echo "TEST_INBOX_HOSTNAME is set on '$env_name': remove it from .env (the TEST appliance only)"; bad=1; }
  if profiles_include_mail "$profiles"; then echo "COMPOSE_PROFILES includes mail on '$env_name': mailpit catches all outgoing mail"; bad=1; fi
  [ "$running" != yes ] || { echo "mailpit is running on '$env_name': stop it (docker compose rm -sf mailpit)"; bad=1; }
  return "$bad"
}

# prod_guard_start <env name> <TEST_INBOX> — install.sh and update.sh refuse to start with the test inbox on
# anywhere but the test appliance.
# prod_guard_start <env name> <TEST_INBOX> [<TEST_INBOX_HOSTNAME> <COMPOSE_PROFILES>]
prod_guard_start() {
  local env_name="${1:-prod}" out
  [ "$env_name" = test ] && return 0
  if ! out="$(prod_guard_runtime "$env_name" "${2:-}" "${3:-}" "${4:-}" no)"; then
    printf '%s\n' "$out"
    echo "This isn't the TEST appliance (ENV_NAME=$env_name): remove those from .env. Nothing was changed."
    return 1
  fi
  return 0
}
