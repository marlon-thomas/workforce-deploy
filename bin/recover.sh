#!/usr/bin/env bash
# recover.sh — rebuild Workforce on a brand-new server from one encrypted off-site copy.
# RUNBOOK, "Recovering onto a new server". Needs this repository, the copy, its private key and a GitHub
# token with read:packages, and asks none of the installer's questions.
#
#   as root, from the clone in /opt/workforce-deploy:
#     ./bin/recover.sh --identity <key file, or - to paste it> <copy>.tar.gz.age
#     --registry-token-file <file>   the GitHub token, from a file. Otherwise it's asked for (not shown),
#                                    or read as the line after the key when stdin is a pipe
#     --registry-user <name>         the GitHub user, default marlon-thomas
#     --system-docker                as for install.sh, on a host without rootless Docker
#
#   ./bin/recover.sh --check --identity <key file, or -> <copy>.tar.gz.age
#     does this copy hold what a recovery needs, all of it, checksums matching? Changes nothing, needs
#     no root, and writes nothing down. Exit 0 yes, 3 it holds only data, 6 this key doesn't open it,
#     1 it's damaged.
#
# What it does:
#   1. decrypts the copy's .env and secrets/ into secrets/ (never anywhere else) and puts them in place
#   2. runs install.sh --recovering, which sets up the service user, Docker and everything else using
#      those secrets: it generates nothing new, and keeps that .env
#   3. runs restore.sh for the data
# It can be run again if it stops, with the same copy: state/recovery-in-progress says how far it got.
# Without that file, a server that's already set up is refused, as this would replace its secrets. Once
# the data is back it's never replaced again: from then on, a run only repeats the health check.
#
# The private key is read once, here. It stays in this script's memory, reaches restore.sh through a
# pipe, and is never on a command line, in the environment, in a file or in a log.
set -euo pipefail
HERE="$(cd -P "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/bin/lib/common.sh"

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mXX\033[0m %s\n' "$*"; exit 1; }

IDENTITY=""; CHECK=0; SYSTEM_DOCKER=0; TOKEN_FILE=""; REGISTRY_USER="marlon-thomas"
while [ $# -gt 0 ]; do
  case "$1" in
    --identity) [ $# -ge 2 ] || fail "--identity needs a key file, or - to give the key on stdin."; IDENTITY="$2"; shift 2 ;;
    --check) CHECK=1; shift ;;
    --system-docker) SYSTEM_DOCKER=1; shift ;;
    --registry-token-file) [ $# -ge 2 ] || fail "--registry-token-file needs a file."; TOKEN_FILE="$2"; shift 2 ;;
    --registry-user) [ $# -ge 2 ] || fail "--registry-user needs a name."; REGISTRY_USER="$2"; shift 2 ;;
    -*) fail "Unknown option: $1 (see the top of this script)" ;;
    *) break ;;
  esac
done
COPY="${1:-}"
[ -n "$IDENTITY" ] && [ -n "$COPY" ] || fail "Usage: ./bin/recover.sh --identity <key file, or -> <copy>.tar.gz.age"
[ -f "$COPY" ] || fail "No such file: $COPY"
case "$COPY" in /*) ;; *) COPY="$PWD/$COPY" ;; esac
is_age_file "$COPY" || fail "$COPY isn't an encrypted off-site copy. A backup from a server's backups/ folder holds no settings
   or secrets, so there's nothing here to recover a server from. Install, then restore it:
   ./bin/install.sh and ./bin/restore.sh (RUNBOOK, \"Recovering onto a new server\")."

SERVICE_USER="${SERVICE_USER:-workforce_app_sa}"
TARGET="${WORKFORCE_TARGET:-/opt/workforce-deploy}"   # the variable is for bin/tests/recovery-test.sh
MARK="$TARGET/state/recovery-in-progress"
COPY_NAME="$(basename "$COPY")"; COPY_SIZE="$(wc -c < "$COPY" | tr -d ' ')"
STAGE=""; PLACED=""; ERRORS="$(mktemp)"
# Whatever happens in here, the exit code stays the one this script chose. Nobody but root can reach
# secrets/, so a --check by anyone else can't tidy it, and has no need to.
cleanup() {
  local rc=$?
  if [ -n "$STAGE" ]; then rm -rf "$STAGE" 2>/dev/null || true; fi
  rm -f "$ERRORS" 2>/dev/null || true
  rm -f "$TARGET/secrets/.recover-registry" 2>/dev/null || true
  exit "$rc"
}
trap cleanup EXIT

# copy_stream — everything in the copy, decompressed. The status says whether it was all good: age and
# gzip both check what they read, to the very end.
copy_stream() { age_decrypt < "$COPY" 2>/dev/null | gzip -dc 2>/dev/null; }

gnu_tar() { tar --version 2>/dev/null | grep -q GNU; }

# pick_identity — of the keys read, the one that opens this copy. A key file can hold several, and
# stdin, the way to restore.sh, carries one. Returns 6 if age says none of them is the key for it, and 1
# if something else is wrong, as nobody should conclude from a damaged file that the key is lost.
pick_identity() {
  local all="$AGE_IDENTITY" key wrong_key=0
  while IFS= read -r key; do
    AGE_IDENTITY="$key"
    if [ "$(head -c 262144 "$COPY" | age_decrypt 2>"$ERRORS" | head -c 2 | od -An -tx1 | tr -d ' \n')" = 1f8b ]; then return 0; fi
    if grep -q 'no identity matched' "$ERRORS"; then wrong_key=1; fi
  done < <(printf '%s\n' "$all")
  AGE_IDENTITY=""
  if [ "$wrong_key" -eq 1 ]; then return 6; fi
  return 1
}

WRONG_KEY_WORDS="This key doesn't open this copy: it needs a different key (an older one, if the key has been rotated
   since). Nothing was changed."
CANT_OPEN_WORDS="This copy couldn't be opened: it's damaged, or age couldn't run here. That doesn't mean the key is
   wrong. Nothing was changed. Fetch it again, or use an earlier one."
DAMAGED_WORDS="This copy is damaged or incomplete: something in it is missing or doesn't match its checksums, or it
   couldn't be read to the end (is this disk full?). Nothing was changed. Fetch it again, or use an earlier one."

NO_CONFIG_WORDS="This copy holds the data, but not the server's settings and secrets: it was made before they
   were added to off-site copies. This script can't use it, and nothing was changed. Do this instead:
     ./bin/install.sh                                    (answer its questions as for a new server)
     ./bin/restore.sh --identity - <this copy>           (it repairs signing in, and says what to do)
   RUNBOOK, \"Recovering onto a new server\", says what a restore like that can't bring back."

# --------------------------------------------------------------- --check
if [ "$CHECK" -eq 1 ]; then
  gnu_tar || fail "Checking a copy needs GNU tar."
  # A check changes nothing, so it installs nothing: on a new server, say what it needs.
  age_here || docker_socket >/dev/null 2>&1 || fail "Checking a copy needs age, and this server has neither age nor Docker yet. Install it first (apt-get install age), or go straight to the recovery, which installs it."
  age_here || use_docker_socket
  read_age_identity "$IDENTITY" || exit 1
  PICKED=0; pick_identity || PICKED=$?
  if [ "$PICKED" -eq 6 ]; then echo "$WRONG_KEY_WORDS"; exit 6; fi
  if [ "$PICKED" -ne 0 ]; then echo "$CANT_OPEN_WORDS"; exit 1; fi
  # Each file goes through this as tar reaches it, so nothing is written down: the settings and secrets
  # are only ever a checksum, in memory here.
  # shellcheck disable=SC2016  # expanded by the shell tar runs
  LOOK_AT='case "$TAR_FILENAME" in
    secrets/.config-manifest) sed "s/^/M /" ;;
    .env|secrets/*) printf "H %s  %s\n" "$(sha256sum | cut -d" " -f1)" "$TAR_FILENAME" ;;
    *) cat >/dev/null; printf "D %s\n" "$TAR_FILENAME" ;;
  esac'
  SEEN="$(copy_stream | tar -xif - --to-command="$LOOK_AT" 2>/dev/null; echo "RC ${PIPESTATUS[*]}")"
  read -r _ RC_STREAM RC_TAR <<< "$(printf '%s\n' "$SEEN" | tail -n 1)"
  if [ "$RC_STREAM" -ne 0 ] || [ "$RC_TAR" -ne 0 ]; then echo "$DAMAGED_WORDS"; exit 1; fi
  if ! printf '%s\n' "$SEEN" | grep -qx 'D database.dump'; then echo "$DAMAGED_WORDS"; exit 1; fi
  if ! printf '%s\n' "$SEEN" | grep -q '^H .*  \.env$'; then
    # The manifest comes first, so with it and no .env the settings were cut off rather than never there.
    if printf '%s\n' "$SEEN" | grep -q '^M '; then echo "$DAMAGED_WORDS"; exit 1; fi
    echo "$NO_CONFIG_WORDS"; exit 3
  fi
  WANT="$(printf '%s\n' "$SEEN" | sed -n 's/^M //p' | sort -u)"
  HAVE="$(printf '%s\n' "$SEEN" | sed -n 's/^H //p' | sort -u)"
  if [ -z "$WANT" ] || [ "$WANT" != "$HAVE" ]; then echo "$DAMAGED_WORDS"; exit 1; fi
  echo "OK: this key opens this copy, and it holds the data, the settings and $(printf '%s\n' "$HAVE" | grep -c '  secrets/') secret files, all matching their checksums."
  exit 0
fi

# --------------------------------------------------------------- recovering
[ "$(id -u)" -eq 0 ] || fail "Run this as root: it sets up Docker and the service user."
if [ "$HERE" != "$(cd -P "$TARGET" 2>/dev/null && pwd)" ]; then
  fail "Run this from the clone in its final place, so that nothing lying beside this one gets copied there:
     git clone https://github.com/marlon-thomas/workforce-deploy.git $TARGET
     cd $TARGET && ./bin/recover.sh --identity - $COPY
   Nothing was changed."
fi
ALREADY_WORDS="This server is already set up, and this would replace its secrets. Nothing was changed.
   To put data back on a working server: ./bin/restore.sh --identity - $COPY"
STAGE_NOW=""
if [ -f "$MARK" ]; then
  # Secrets from one copy with data from another would leave a server that looks fine and isn't.
  MARK_COPY="$(env_get copy "$MARK")"; MARK_SIZE="$(env_get size "$MARK")"
  [ -n "$MARK_COPY" ] || fail "$ALREADY_WORDS"
  if [ "$MARK_COPY" != "$COPY_NAME" ] || [ "$MARK_SIZE" != "$COPY_SIZE" ]; then
    fail "This recovery started from $MARK_COPY ($MARK_SIZE bytes), and this is $COPY_NAME ($COPY_SIZE bytes). Nothing was changed.
   That copy's secrets are already in place here, and they only go with that copy's data. Run this again with
   that copy. If it's the one that's bad, start again on a new, empty server with the copy you want."
  fi
  STAGE_NOW="$(env_get stage "$MARK")"
elif [ -f "$TARGET/.env" ] || [ -s "$TARGET/secrets/db_password" ]; then
  fail "$ALREADY_WORDS"
fi

# as_service_user COMMAND... — as the account that runs everything, with its Docker.
as_service_user() {
  local sock
  sock="$(docker_socket || echo "/run/user/$(id -u "$SERVICE_USER")/docker.sock")"
  sudo -u "$SERVICE_USER" env HOME="/home/${SERVICE_USER}" XDG_RUNTIME_DIR="/run/user/$(id -u "$SERVICE_USER")" \
    DOCKER_HOST="unix://${sock}" "$@"
}

finished() {
  local mins host
  mins=$(( (SECONDS + 59) / 60 ))
  host="$(env_get APP_HOSTNAME "$TARGET/.env")"
  rm -f "$MARK"
  cat <<DONE

------------------------------------------------------------------------
  Recovered from: ${COPY_NAME} (this run took about ${mins} minutes)
  https://${host} is back, as it was when that copy was made.
  Anything entered after that is gone.

  A person should now check (RUNBOOK, "Recovering onto a new server"):
    - sign in with a real account, and look at People and the training matrix
    - open an evidence file, and webmail if staff email was on
    - look at Setup -> Server health
    - from $TARGET as $SERVICE_USER, run: docker compose exec -T -w $TARGET backup ./bin/backup.sh
      and see a new copy reach the target
------------------------------------------------------------------------
DONE
}

DATA_BACK_WORDS="The data is back. It won't be replaced again, by this or by running this again, as people may be
   using it by now. The health check above says what's still wrong. Fix that, then run this same command
   again: it only repeats the check, and finishes."

# The data is back already. People may be using it, so nothing past here may touch it.
if [ "$STAGE_NOW" = restored ]; then
  say "The data went back earlier, so it won't be touched. Repeating the health check…"
  ( cd "$TARGET" && as_service_user ./bin/doctor.sh --gate ) </dev/null || fail "$DATA_BACK_WORDS"
  finished
  exit 0
fi

# What it takes to read the copy, on a server that has nothing yet. Docker comes later, from the
# installer, and needs the settings that are inside the copy, so age has to be here first.
ensure_tools() {
  local need=""
  age_here || need="age"
  gnu_tar || need="$need tar"
  for tool in sudo openssl curl gzip; do command -v "$tool" >/dev/null 2>&1 || need="$need $tool"; done
  [ -n "$need" ] || return 0
  say "Installing what this needs:$need…"
  # shellcheck disable=SC2086  # a word list on purpose
  if command -v apt-get >/dev/null 2>&1; then
    # A fresh server's own updates can hold the lock for minutes.
    apt-get update -qq >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq -o DPkg::Lock::Timeout=300 $need >/dev/null 2>&1 || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q $need >/dev/null 2>&1 || true
  fi
  age_here || fail "Couldn't install age, which this needs to open the copy. Install it, then run this again."
  gnu_tar || fail "Couldn't install GNU tar, which this needs to read the copy. Install it, then run this again."
}
ensure_tools

read_age_identity "$IDENTITY" || fail "Nothing was changed."
PICKED=0; pick_identity || PICKED=$?
if [ "$PICKED" -eq 6 ]; then fail "$WRONG_KEY_WORDS"; fi
if [ "$PICKED" -ne 0 ]; then fail "$CANT_OPEN_WORDS"; fi

# Asked now, while someone is here, and not part-way through.
REGISTRY_TOKEN=""
if ! sudo -u "$SERVICE_USER" sh -c 'grep -q ghcr.io ~/.docker/config.json' 2>/dev/null; then
  if [ -n "$TOKEN_FILE" ]; then
    [ -r "$TOKEN_FILE" ] || fail "Can't read the token file: $TOKEN_FILE"
    IFS= read -r REGISTRY_TOKEN < "$TOKEN_FILE" || true
  elif [ -t 0 ]; then
    read -rs -p "GitHub token (read:packages, not shown): " REGISTRY_TOKEN || true
    echo >&2
  else
    IFS= read -r REGISTRY_TOKEN || true
  fi
  REGISTRY_TOKEN="${REGISTRY_TOKEN//[[:space:]]/}"
  [ -n "$REGISTRY_TOKEN" ] || fail "The images come from GitHub's registry, so this needs a token with read:packages:
   --registry-token-file <file>, or paste it when asked. Nothing was changed."
fi

mkdir -p "$TARGET/secrets" "$TARGET/state"
chmod 700 "$TARGET/secrets"

if [ ! -f "$TARGET/.env" ]; then
  say "Opening the copy (it's read to the end, so a large one takes a few minutes)…"
  STAGE="$(mktemp -d "$TARGET/secrets/.recover.XXXXXX")"   # mode 0700, and inside the closed folder
  set +e
  copy_stream | tar -xipf - -C "$STAGE" --no-same-owner .env secrets >/dev/null 2>"$ERRORS"
  RC=("${PIPESTATUS[@]}")
  set -e
  [ "${RC[0]}" -eq 0 ] || fail "$DAMAGED_WORDS"
  if [ ! -f "$STAGE/.env" ]; then
    # The manifest comes first, so with it and no .env the settings were cut off rather than never there.
    [ ! -e "$STAGE/secrets/.config-manifest" ] || fail "$DAMAGED_WORDS"
    # tar also fails when what it was asked for isn't there, as in an older copy. Anything else it says
    # is a real problem, and not to be mistaken for that.
    if grep -v -e 'Not found in archive' -e 'Exiting with failure status' "$ERRORS" | grep -q .; then fail "$DAMAGED_WORDS"; fi
    fail "$NO_CONFIG_WORDS"
  fi
  # All of it, or none. An install would quietly regenerate a missing secret, and the recovery would look
  # like it worked, with whatever that secret protected gone.
  [ "${RC[1]}" -eq 0 ] || fail "$DAMAGED_WORDS"
  [ -f "$STAGE/secrets/.config-manifest" ] || fail "$DAMAGED_WORDS"
  ( cd "$STAGE" && sha256sum -c secrets/.config-manifest ) >/dev/null 2>&1 || fail "$DAMAGED_WORDS"
  rm -f "$STAGE/secrets/.config-manifest"

  say "Putting the settings and secrets back…"
  printf 'stage=placing\ncopy=%s\nsize=%s\n' "$COPY_NAME" "$COPY_SIZE" > "$MARK"
  cp -a "$STAGE/secrets/." "$TARGET/secrets/"
  ( cd "$TARGET" && secret_modes )
  # Last, because a .env is what tells the installer there's nothing to ask or generate.
  ( umask 077; cp "$STAGE/.env" "$TARGET/.env.recovering" )
  mv -f "$TARGET/.env.recovering" "$TARGET/.env"
  rm -rf "$STAGE"; STAGE=""
fi

if [ "$(env_get stage "$MARK")" != installed ]; then
  if [ -n "$REGISTRY_TOKEN" ]; then
    ( umask 077; printf '%s\n%s\n' "$REGISTRY_USER" "$REGISTRY_TOKEN" > "$TARGET/secrets/.recover-registry" )
    REGISTRY_TOKEN=""
  fi
  FLAGS=(--recovering)
  ENV_NAME_RESTORED="$(env_get ENV_NAME "$TARGET/.env")"
  if [ -n "$ENV_NAME_RESTORED" ] && [ -f "$TARGET/environments/${ENV_NAME_RESTORED}.env" ]; then FLAGS+=(--env "$ENV_NAME_RESTORED"); fi
  if [ "$SYSTEM_DOCKER" -eq 1 ]; then FLAGS+=(--system-docker); fi
  say "Setting up the server with those settings: Docker, then every service (this takes a while)…"
  # No stdin: nothing here is meant to ask anything, so a question fails rather than waits for ever.
  bash "$TARGET/bin/install.sh" "${FLAGS[@]}" </dev/null \
    || fail "Setting up the server stopped; the lines above say why. Fix that, then run this same command again: it carries on."
  env_set stage installed "$MARK"
fi
rm -f "$TARGET/secrets/.recover-registry"

# The service user runs the restore, and a copy in root's home is out of its reach.
USE_COPY="$COPY"
if ! sudo -u "$SERVICE_USER" test -r "$COPY" 2>/dev/null; then
  PLACED="$TARGET/backups/$(basename "$COPY")"
  mkdir -p "$TARGET/backups"
  ln -f "$COPY" "$PLACED" 2>/dev/null || cp "$COPY" "$PLACED"
  chown "$SERVICE_USER:$SERVICE_USER" "$PLACED"
  USE_COPY="$PLACED"
fi
say "Putting the data back…"
if ! printf '%s\n' "$AGE_IDENTITY" | as_service_user "$TARGET/bin/restore.sh" --yes --config-restored --identity - "$USE_COPY"; then
  if [ "$(env_get stage "$MARK")" = restored ]; then fail "$DATA_BACK_WORDS"; fi
  fail "Putting the data back stopped before anything was replaced; the lines above say why. Fix that, then run this same
   command again: it skips the setup and tries this again. If the sign-in version was the problem, run what it says as
   $SERVICE_USER first."
fi
AGE_IDENTITY=""
if [ -n "$PLACED" ]; then rm -f "$PLACED"; fi
finished
