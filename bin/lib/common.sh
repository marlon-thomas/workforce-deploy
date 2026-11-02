# shellcheck shell=bash
# bin/lib/common.sh — shared helpers for the bin/*.sh operator scripts.
# Sourced, never executed:   . "$(dirname "$0")/lib/common.sh"
#
# ONE place decides which Docker daemon a script talks to. Every script used
# to carry its own copy of this discovery and they drifted (root-only checks,
# the docker-context path only, the XDG runtime dir only) — each drift was a
# silent "talking to the wrong/no daemon" bug. Fix it here, once.

# docker_socket — print the path of the Docker daemon socket to use.
# Order: an explicit unix:// DOCKER_HOST wins; as root on a rootless install,
# the service user's daemon (context path, then XDG runtime dir); as any other
# user, their own rootless daemon; finally the system daemon. Returns 1 when
# no socket exists at all.
docker_socket() {
  case "${DOCKER_HOST:-}" in
    unix://*) printf '%s\n' "${DOCKER_HOST#unix://}"; return 0 ;;
  esac
  local su="${SERVICE_USER:-workforce_app_sa}" uid cand
  if [ "$(id -u)" -eq 0 ]; then
    uid="$(id -u "$su" 2>/dev/null || true)"
    set -- "/home/${su}/.docker/run/docker.sock" ${uid:+"/run/user/${uid}/docker.sock"} \
           /var/run/docker.sock
  else
    uid="$(id -u)"
    set -- "${HOME}/.docker/run/docker.sock" "/run/user/${uid}/docker.sock" \
           /var/run/docker.sock
  fi
  for cand in "$@"; do
    if [ -S "$cand" ]; then printf '%s\n' "$cand"; return 0; fi
  done
  return 1
}

# use_docker_socket — export DOCKER_HOST (and XDG_RUNTIME_DIR for a rootless
# runtime-dir socket) for this script and every docker/compose call it makes.
# A non-unix DOCKER_HOST (tcp://, ssh://) set by the operator is left alone.
# Fails loudly — a silent fallback to the wrong daemon is the bug class this
# helper exists to kill.
use_docker_socket() {
  case "${DOCKER_HOST:-}" in
    tcp://*|ssh://*|npipe://*|fd://*) return 0 ;;
  esac
  local sock
  if ! sock="$(docker_socket)"; then
    echo "Cannot find a Docker daemon socket (checked the service user's rootless" \
         "socket, /run/user/<uid>/docker.sock and /var/run/docker.sock). Is the" \
         "daemon running?  loginctl show-user ${SERVICE_USER:-workforce_app_sa}" >&2
    exit 1
  fi
  export DOCKER_HOST="unix://${sock}"
  if [ "$(id -u)" -ne 0 ] && [ "$sock" = "/run/user/$(id -u)/docker.sock" ]; then
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  fi
}

# ------------------------------------------------------------------ data plane
# Shared by backup.sh, restore.sh, update.sh and restore-drill.sh so "what a
# backup contains" and "how it is put back" cannot drift apart. All of them
# run `docker compose` from the bundle root and STREAM data through stdin/
# stdout: no host-path bind mounts, so they behave the same on the host and
# inside the nightly backup container.

# pg_verify_dump SERVICE USER DUMP — restore a custom-format dump into a
# scratch database on SERVICE, then drop it. Non-zero = the dump is unusable.
pg_verify_dump() {
  local svc="$1" user="$2" dump="$3" rc=0
  docker compose exec -T "$svc" psql -v ON_ERROR_STOP=1 -q -U "$user" -d postgres \
    -c "DROP DATABASE IF EXISTS restore_check" -c "CREATE DATABASE restore_check" >/dev/null
  docker compose exec -T "$svc" pg_restore -U "$user" -d restore_check \
    --no-owner --exit-on-error < "$dump" >/dev/null 2>&1 || rc=$?
  docker compose exec -T "$svc" psql -q -U "$user" -d postgres \
    -c "DROP DATABASE IF EXISTS restore_check" >/dev/null || true
  return "$rc"
}

# pg_replace_db SERVICE USER DB DUMP — drop DB on SERVICE, recreate it, and
# restore DUMP into it. Callers stop every client of DB first.
pg_replace_db() {
  local svc="$1" user="$2" db="$3" dump="$4"
  docker compose exec -T "$svc" psql -v ON_ERROR_STOP=1 -q -U "$user" -d postgres \
    -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${db}' AND pid <> pg_backend_pid()" >/dev/null
  docker compose exec -T "$svc" dropdb -U "$user" --if-exists "$db"
  docker compose exec -T "$svc" createdb -U "$user" "$db"
  docker compose exec -T "$svc" pg_restore -U "$user" -d "$db" --no-owner --exit-on-error < "$dump"
}

# evidence_export — write the whole evidence bucket to stdout as a tar stream.
# Runs in a throw-away copy of the `init` service: it already has the mc
# client, the data network and the MinIO credentials (as docker secrets).
evidence_export() {
  # shellcheck disable=SC2016  # expanded inside the container, on purpose
  docker compose run --rm --no-deps -T --entrypoint /bin/sh init -c '
    set -eu
    mc alias set local http://object-storage:9000 \
      "$(cat /run/secrets/minio_access)" "$(cat /run/secrets/minio_secret)" >/dev/null
    mkdir -p /tmp/evidence
    mc mirror --quiet "local/${MINIO_BUCKET}" /tmp/evidence >&2
    tar -C /tmp/evidence -cf - .'
}

# evidence_import — replace the evidence bucket's contents with the tar
# stream on stdin (objects absent from the backup are removed: a restore is
# a point-in-time copy, not a merge).
evidence_import() {
  # shellcheck disable=SC2016
  docker compose run --rm --no-deps -T --entrypoint /bin/sh init -c '
    set -eu
    mkdir -p /tmp/evidence
    tar -xf - -C /tmp/evidence
    mc alias set local http://object-storage:9000 \
      "$(cat /run/secrets/minio_access)" "$(cat /run/secrets/minio_secret)" >/dev/null
    mc mb --ignore-existing "local/${MINIO_BUCKET}" >/dev/null
    mc mirror --quiet --overwrite --remove /tmp/evidence "local/${MINIO_BUCKET}" >&2
    mc anonymous set none "local/${MINIO_BUCKET}" >/dev/null'
}

# authentik_version — the version the running authentik server reports, or nothing when it is
# not answering. 2026.8 dropped authentik.__version__ for authentik.VERSION; ask for either.
authentik_version() {
  docker exec -w / workforce-deploy-authentik-server-1 python -c \
    'import authentik as a; print(getattr(a, "VERSION", None) or a.__version__)' 2>/dev/null || true
}

# secret_modes — make the secret files readable inside the containers, keep the folder closed.
# Compose bind-mounts file-based secrets as they are on disk (its `mode:` applies to swarm only),
# and the application runs as an unprivileged user (uid 999), so 0600 files were unreadable to it:
# staff email, invitations/password resets, the AI assistant's key store, push and feedback were
# silently off (found 2026-11-01). The secrets folder itself stays 0700 to the service account, so
# no other account on the host can reach the files. The one-time admin password stays owner-only.
secret_modes() {
  [ -d secrets ] || return 0
  chmod 700 secrets
  # backup_ssh_key is for ssh in the backup container, which refuses a key anyone else could read.
  find secrets -maxdepth 1 -type f ! -name initial-admin-password ! -name backup_ssh_key -exec chmod 644 {} +
  [ -e secrets/initial-admin-password ] && chmod 400 secrets/initial-admin-password
  [ -e secrets/backup_ssh_key ] && chmod 600 secrets/backup_ssh_key
  return 0
}

# ------------------------------------------------------------------ the .env file
# env_get KEY [FILE] — print KEY's value from the file WITHOUT running it: the last line wins, as it
# would when sourced, and one pair of surrounding quotes is taken off. Prints nothing when unset.
env_get() {
  local key="$1" file="${2:-.env}" line value="" v
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$key="*) value="${line#*=}" ;;
    esac
  done < "$file"
  case "$value" in
    \'*\') v="${value#\'}"; value="${v%\'}" ;;
    \"*\") v="${value#\"}"; value="${v%\"}" ;;
  esac
  printf '%s' "$value"
}

# env_set KEY VALUE [FILE] — replace KEY's line, or add it, byte for byte: everything else in the
# file, and its mode and owner, stay as they are. A temp file and a rename, so nothing ever sees half
# a file. VALUE goes in exactly as given, so a caller with a value that isn't a plain word quotes it
# first (env_single_quote). A value with a line break could add a setting of its own: refused.
env_set() {
  local key="$1" value="$2" file="${3:-.env}" tmp line found=0
  case "$key" in ''|*[!A-Za-z0-9_]*) return 2 ;; esac
  case "$value" in *$'\n'*|*$'\r'*) return 2 ;; esac
  [ -f "$file" ] || return 1
  tmp="${file}.tmp.$$"
  ( umask 077; : > "$tmp" ) || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$key="*)
        [ "$found" -eq 1 ] || printf '%s=%s\n' "$key" "$value"
        found=1 ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
  [ "$found" -eq 1 ] || printf '%s=%s\n' "$key" "$value" >> "$tmp"
  chmod "$(stat -c %a "$file")" "$tmp" 2>/dev/null || true
  chown "$(stat -c %u:%g "$file")" "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$file"
}

# env_single_quote VALUE — VALUE as .env must hold anything that isn't a plain word. compose and bash
# both read single quotes literally, so $, #, spaces and double quotes are safe. Two things can't be
# held: a single quote, and a backslash (compose takes \' as not closing the quote, so a value ending
# in a backslash stops the whole stack starting). Returns 1 for those, and for a line break.
env_single_quote() {
  case "$1" in
    *\'*|*\\*|*$'\n'*|*$'\r'*) return 1 ;;
  esac
  printf "'%s'" "$1"
}

# alert_address_problems "<comma-separated list>" <host>... — checks server-alert addresses
# (OPS_ALERT_EMAIL, bin/healthwatch.sh) before the installer saves them. Prints one line per problem:
#   bad:<message>  the list can't be used (re-ask)
#   own:<message>  an address is on a domain this server answers for — fine only if that domain's
#                  mail is handled elsewhere (e.g. Microsoft 365), so the installer asks to confirm
# Prints nothing when the list is fine. Hosts are the app/sign-in names; their parent domains count.
alert_address_problems() {
  local addrs="${1// /}" a dom h p hosted="" seen=""
  shift
  local -a list
  for h in "$@"; do
    h="$(printf '%s' "$h" | tr '[:upper:]' '[:lower:]')"
    case "$h" in ""|*.localhost|localhost) continue ;; esac
    hosted="${hosted} ${h}"
    p="${h#*.}"
    case "$p" in *.*) ;; *) continue ;; esac                       # never a bare TLD
    case "$p" in co.uk|org.uk|me.uk|ltd.uk|plc.uk|net.uk|ac.uk|gov.uk|nhs.uk|com.au|net.au|org.au|co.nz|org.nz|co.za) continue ;; esac
    hosted="${hosted} ${p}"
  done
  IFS=',' read -r -a list <<< "$addrs"
  for a in "${list[@]}"; do
    [ -n "$a" ] || continue
    if ! printf '%s' "$a" | grep -Eq '^[^@[:space:]",;<>]+@[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$'; then
      printf 'bad:%s is not an email address\n' "$a"; continue
    fi
    case ",${seen}," in *",${a},"*) continue ;; esac
    seen="${seen:+${seen},}${a}"
    dom="$(printf '%s' "${a##*@}" | tr '[:upper:]' '[:lower:]')"
    for h in $hosted; do
      if [ "$dom" = "$h" ] || [ "${dom%".${h}"}" != "$dom" ]; then
        printf 'own:%s is on %s, which this server answers for\n' "$a" "$h"; break
      fi
    done
  done
}
