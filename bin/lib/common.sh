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
