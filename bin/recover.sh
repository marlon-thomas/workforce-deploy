#!/usr/bin/env bash
# recover.sh — rebuild Workforce on a brand-new server from one encrypted off-site copy.
# RUNBOOK, "Recovering onto a new server". Needs this repository, the copy, its private key and a GitHub
# token with read:packages, and asks none of the installer's questions.
#
#   as root:  ./bin/recover.sh --identity <key file, or - to paste it> <copy>.tar.gz.age
#     --registry-token-file <file>   the GitHub token, from a file. Otherwise it's asked for (not shown),
#                                    or read as the line after the key when stdin is a pipe
#     --registry-user <name>         the GitHub user, default marlon-thomas
#     --system-docker                as for install.sh, on a host without rootless Docker
#
#   ./bin/recover.sh --check --identity <key file, or -> <copy>.tar.gz.age
#     does this copy hold what a recovery needs? Changes nothing, needs no root, and writes nothing
#     down. Exit 0 yes, 3 it holds only data, 6 this key doesn't open it, 1 it's damaged.
#
# What it does:
#   1. decrypts the copy's .env and secrets/ into secrets/ (never anywhere else) and puts them in place
#   2. runs install.sh --recovering, which sets up the service user, Docker and everything else using
#      those secrets: it generates nothing new, and keeps that .env
#   3. runs restore.sh for the data
# It can be run again if it stops: state/recovery-in-progress says how far it got. Without that file,
# a server that's already set up is refused, as this would replace its secrets.
#
# The private key is read once, here. It stays in this script's memory, reaches restore.sh through a
# pipe, and is never on a command line, in the environment, in a file or in a log.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
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
STAGE=""; NAMES=""; PLACED=""
cleanup() {
  [ -z "$STAGE" ] || rm -rf "$STAGE"
  [ -z "$NAMES" ] || rm -f "$NAMES"
  rm -f "$TARGET/secrets/.recover-registry"
}
trap cleanup EXIT

# copy_stream — everything in the copy, decompressed. The status says whether it was all good: age and
# gzip both check what they read, to the very end.
copy_stream() { age_decrypt < "$COPY" 2>/dev/null | gzip -dc 2>/dev/null; }

gnu_tar() { tar --version 2>/dev/null | grep -q GNU; }

# pick_identity — of the keys read, the one that opens this copy. A key file can hold several, and
# stdin, the way to restore.sh, carries one.
pick_identity() {
  local all="$AGE_IDENTITY" key
  while IFS= read -r key; do
    AGE_IDENTITY="$key"
    if [ "$(head -c 262144 "$COPY" | age_decrypt 2>/dev/null | head -c 2 | od -An -tx1 | tr -d ' \n')" = 1f8b ]; then return 0; fi
  done < <(printf '%s\n' "$all")
  AGE_IDENTITY=""
  return 1
}

NO_CONFIG_WORDS="This copy holds the data, but not the server's settings and secrets: it was made before they
   were added to off-site copies. This script can't use it, and nothing was changed. Do this instead:
     ./bin/install.sh                                    (answer its questions as for a new server)
     ./bin/restore.sh --identity - <this copy>           (it repairs signing in, and says what to do)
   RUNBOOK, \"Recovering onto a new server\", says what a restore like that can't bring back."

# --------------------------------------------------------------- --check
if [ "$CHECK" -eq 1 ]; then
  gnu_tar || fail "Checking a copy needs GNU tar."
  age_here || use_docker_socket
  read_age_identity "$IDENTITY" || exit 1
  if ! pick_identity; then echo "This key doesn't open this copy: it needs a different key, or the file is damaged."; exit 6; fi
  NAMES="$(mktemp)"
  set +e
  copy_stream | tar -tif - > "$NAMES" 2>/dev/null
  RC=("${PIPESTATUS[@]}")
  set -e
  if [ "${RC[0]}" -ne 0 ]; then echo "This copy is damaged or incomplete: it couldn't be read to the end."; exit 1; fi
  if grep -qx '.env' "$NAMES" && grep -qx 'secrets/db_password' "$NAMES"; then
    echo "OK: this key opens this copy, and it holds the data, the settings and $(grep -c '^secrets/.*[^/]$' "$NAMES") secret files."
    exit 0
  fi
  echo "$NO_CONFIG_WORDS"
  exit 3
fi

# --------------------------------------------------------------- recovering
[ "$(id -u)" -eq 0 ] || fail "Run this as root: it sets up Docker and the service user."
if [ ! -f "$MARK" ] && { [ -f "$TARGET/.env" ] || [ -s "$TARGET/secrets/db_password" ]; }; then
  fail "This server is already set up, and this would replace its secrets. Nothing was changed.
   To put data back on a working server: ./bin/restore.sh --identity - $COPY"
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
pick_identity || fail "This key doesn't open this copy: it needs a different key (an older one, if the key has been
   rotated since), or the file is damaged. Nothing was changed."

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

if [ "$HERE" != "$TARGET" ]; then
  say "Moving the bundle to $TARGET…"
  mkdir -p "$TARGET"
  cp -a "$HERE/." "$TARGET/"
fi
mkdir -p "$TARGET/secrets" "$TARGET/state"
chmod 700 "$TARGET/secrets"

if [ ! -f "$TARGET/.env" ]; then
  say "Opening the copy (it's read to the end, so a large one takes a few minutes)…"
  STAGE="$(mktemp -d "$TARGET/secrets/.recover.XXXXXX")"   # mode 0700, and inside the closed folder
  set +e
  copy_stream | tar -xipf - -C "$STAGE" --no-same-owner .env secrets >/dev/null 2>&1
  RC=("${PIPESTATUS[@]}")
  set -e
  if [ "${RC[0]}" -ne 0 ]; then fail "This copy is damaged or incomplete: it couldn't be read to the end. Nothing was changed. Fetch it again, or use an earlier one."; fi
  if [ ! -f "$STAGE/.env" ] || [ ! -s "$STAGE/secrets/db_password" ]; then fail "$NO_CONFIG_WORDS"; fi

  say "Putting the settings and secrets back…"
  : > "$MARK"
  cp -a "$STAGE/secrets/." "$TARGET/secrets/"
  ( cd "$TARGET" && secret_modes )
  # Last, because a .env is what tells the installer there's nothing to ask or generate.
  ( umask 077; cp "$STAGE/.env" "$TARGET/.env.recovering" )
  mv -f "$TARGET/.env.recovering" "$TARGET/.env"
  rm -rf "$STAGE"; STAGE=""
fi

if [ "$(cat "$MARK")" != installed ]; then
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
  printf 'installed\n' > "$MARK"
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
SOCK="$(docker_socket || echo "/run/user/$(id -u "$SERVICE_USER")/docker.sock")"
if ! printf '%s\n' "$AGE_IDENTITY" | sudo -u "$SERVICE_USER" env HOME="/home/${SERVICE_USER}" \
      XDG_RUNTIME_DIR="/run/user/$(id -u "$SERVICE_USER")" DOCKER_HOST="unix://${SOCK}" \
      "$TARGET/bin/restore.sh" --yes --config-restored --identity - "$USE_COPY"; then
  fail "Putting the data back stopped; the lines above say why. Fix that, then run this same command again: it skips the
   setup and tries this again. If the sign-in version was the problem, run what it says as $SERVICE_USER first."
fi
AGE_IDENTITY=""
if [ -n "$PLACED" ]; then rm -f "$PLACED"; fi
rm -f "$MARK"

MINS=$(( (SECONDS + 59) / 60 ))
HOST="$(env_get APP_HOSTNAME "$TARGET/.env")"
cat <<DONE

------------------------------------------------------------------------
  Recovered in about ${MINS} minutes, from: $(basename "$COPY")
  https://${HOST} is back, as it was when that copy was made.
  Anything entered after that is gone.

  A person should now check (RUNBOOK, "Recovering onto a new server"):
    - sign in with a real account, and look at People and the training matrix
    - open an evidence file, and webmail if staff email was on
    - look at Setup -> Server health
    - from $TARGET as $SERVICE_USER, run ./bin/backup.sh and see a new copy reach the target
------------------------------------------------------------------------
DONE
