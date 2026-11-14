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

# pg_health_role SERVICE USER — the health watch's role (Workforce issue 447; health-db-init in compose.yaml)
# made on SERVICE if it isn't there, with no login and nothing else, before a dump is restored into it. Dumps
# made since then carry its column grants, and pg_restore stops at a grant to a role that doesn't exist (a fresh
# server, the restore drill), so without it no newer backup would restore. Every other grant in the dump restores
# exactly as before; health-db-init makes the role properly (login, password, its grants afresh) at the next start.
pg_health_role() {
  printf '%s\n' "SELECT 'CREATE ROLE ${HEALTH_DB_ROLE} NOLOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${HEALTH_DB_ROLE}')\\gexec" \
    | docker compose exec -T "$1" psql -X -q -v ON_ERROR_STOP=1 -U "$2" -d postgres >/dev/null
}

# pg_verify_dump SERVICE USER DUMP — restore a custom-format dump into a
# scratch database on SERVICE, then drop it. Non-zero = the dump is unusable.
pg_verify_dump() {
  local svc="$1" user="$2" dump="$3" rc=0
  pg_health_role "$svc" "$user"
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
  pg_health_role "$svc" "$user"
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
# not answering. 2026.8 dropped authentik.__version__ for authentik.VERSION; ask for either. By the Compose
# service, not a container name (review of the controller bundle, finding 4): under the controller the project
# is "workforce", and a fixed workforce-deploy-… name put authentik_version=unknown in every backup's MANIFEST,
# so a recovery couldn't tell which authentik wrote the sign-in database.
authentik_version() {
  docker compose exec -T -w / authentik-server python -c \
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
  # Folders inside need their execute bit: secrets/tls was found at 0600, which the service account
  # can't enter, so a backup run on the host couldn't read it, and a recovery would carry that over.
  find secrets -mindepth 1 -type d ! -name '.recover*' -exec chmod 700 {} +
  # The gateway's certificates (TLS_MODE=certs): caddy runs as a user of its own (Workforce issue 53), so the folder it
  # mounts must let it in. The secrets folder above stays closed to every other account on the host.
  if [ -d secrets/tls ]; then
    chmod 755 secrets/tls
    find secrets/tls -maxdepth 1 -type f -exec chmod 644 {} +
  fi
  # backup_ssh_key is for ssh in the backup container, which refuses a key anyone else could read.
  find secrets -maxdepth 1 -type f ! -name initial-admin-password ! -name backup_ssh_key ! -name '.recover*' -exec chmod 644 {} +
  [ -e secrets/initial-admin-password ] && chmod 400 secrets/initial-admin-password
  [ -e secrets/backup_ssh_key ] && chmod 600 secrets/backup_ssh_key
  return 0
}

# ------------------------------------------------------------------ the key sign-ins are signed with
# The app pins authentik's public signing key in secrets/oidc_signing_pub.pem, so a sign-in database
# from another installation means authentik signs with one key and the app trusts another: everyone
# is locked out while every service looks healthy. Public keys, so safe to compare, but rows and
# messages still say only yes or no.

# oidc_signing_pub — the public key of the Workforce sign-in, as authentik holds it now, or nothing
# when it can't be read. The application by its slug, which is unique (a name is not: this database also has
# "Workforce webmail", and anyone could name another application Workforce), and its provider by this
# installation's client id (secrets/oidc_client_id, which isn't secret: browsers carry it), as the blueprint makes
# them (Workforce issue 453). The id is checked to be plain before it goes in. As the health watch's role when
# doctor.sh has called health_db_client under the controller (its exec, word for word but the id, is one of the
# controller's EXEC_RULES), else as the database's own user.
oidc_signing_pub() {
  local cid
  cid="$(tr -d '[:space:]' < secrets/oidc_client_id 2>/dev/null)" || cid=""
  [[ "$cid" =~ ^[A-Za-z][A-Za-z0-9._-]{2,127}$ ]] || return 1
  docker compose exec -T ${PSQL_ENV[@]+"${PSQL_ENV[@]}"} authentik-postgres psql -X -U "${PSQL_AK_USER:-${AK_DB_USER:-authentik}}" -d "${AK_DB_NAME:-authentik}" -t -A -c \
    "SELECT c.certificate_data FROM authentik_core_application a \
       JOIN authentik_providers_oauth2_oauth2provider p ON p.provider_ptr_id = a.provider_id \
       JOIN authentik_crypto_certificatekeypair c ON c.kp_uuid = p.signing_key_id \
      WHERE a.slug = 'workforce' AND p.client_id = '${cid}'" 2>/dev/null \
    | openssl x509 -pubkey -noout 2>/dev/null
}

# export_oidc_signing_key — write that key to secrets/oidc_signing_pub.pem. Sets OIDC_KEY_CHANGED to
# 1 when the file changed. Returns 1, leaving the file alone, when the key can't be read. Written in
# place because the api's mount of this one file is bound to its inode; a running api still has to be
# recreated to load it (bin/refresh-signing-key.sh).
OIDC_KEY_CHANGED=0
export_oidc_signing_key() {
  local pub old=""
  OIDC_KEY_CHANGED=0
  pub="$(oidc_signing_pub)" || pub=""
  case "$pub" in *"BEGIN PUBLIC KEY"*) ;; *) return 1 ;; esac
  if [ -f secrets/oidc_signing_pub.pem ]; then old="$(cat secrets/oidc_signing_pub.pem)"; fi
  if [ "$pub" != "$old" ]; then
    printf '%s\n' "$pub" > secrets/oidc_signing_pub.pem
    OIDC_KEY_CHANGED=1
  fi
  chmod 644 secrets/oidc_signing_pub.pem
}

# ------------------------------------------------------------------ a recovery under way
# bin/recover.sh keeps this while it works, as lines of the form stage=, copy= and size=. Read with
# env_get, never run. The stages: placing (the copy's secrets are going in), installed (the server is
# set up, with an empty install's data), restored (the data is back: it must not be replaced again).
RECOVERY_MARK=state/recovery-in-progress

# recovery_data_not_back — is there a recovery on this server that hasn't got the data back yet?
recovery_data_not_back() { [ -f "$RECOVERY_MARK" ] && [ "$(env_get stage "$RECOVERY_MARK")" != restored ]; }

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

# ------------------------------------------------------------------ the stock gateway image
# GATEWAY_IMAGE in .env wins over compose.yaml's default, so the pin has to be in .env as well (Workforce issue 53):
# install.sh writes this one, and pin_gateway_image repins a .env written before it (update.sh). It is the same as
# the default in compose.yaml and ansible/roles/workforce/templates/env.j2; bin/check-hardening.py checks that.
GATEWAY_STOCK_IMAGE="caddy:2.8.4@sha256:226d1f059b75399fe19182893c7184591c07b97afc8dfcf44eeb80c9a77a530f"

# ------------------------------------------------------------------ re-running the same version
# same_version_fix — what to run to re-apply the settings with the version this server runs. Workforce issue 422:
# install.sh and update.sh use only an image the release key signed, so a server installed before releases were
# signed (no APP_DIGEST in .env) is refused its own version, and must first update to a signed release.
same_version_fix() {
  if [[ "${APP_DIGEST:-}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "./bin/update.sh ${APP_VERSION:-<running version>}"
  else
    echo "./bin/update.sh <first signed release> (this server was installed before releases were signed, so its own version is refused; after that update, ./bin/update.sh <running version> works)"
  fi
}

# ------------------------------------------------------------------ the DNS-01 gateway image
# TLS_MODE=dns01's gateway: caddy with the DuckDNS plugin, built from gateway/Dockerfile by
# .github/workflows/build-gateway.yml. It terminates all TLS and holds the DuckDNS token, and anything that can
# push to the package can move its tag, so it runs by this digest, never by `latest` (Workforce issue 422's
# review). The digest is the one that workflow's run on main (210419d, run 42611283067) pushed; after a rebuild,
# take the digest from the run's summary and move it here in a reviewed change. bin/digest-check.py fails daily
# while `latest` names other bytes than this pin.
GATEWAY_DNS01_IMAGE="ghcr.io/marlon-thomas/workforce-deploy-gateway:latest@sha256:b736e9ab216c9c241d405b96b0a6222dcba15f1b9e323a668030bb188cc5e80c"

# pin_gateway_image — a .env that names stock caddy by its tag alone (installs before issue 53: caddy:2.8.4) gets
# the pinned image, and one that names the DNS-01 build any other way than this bundle's pin (by tag alone, or
# an older digest) gets this bundle's pin. Anything else is left as it is.
pin_gateway_image() {
  [ -f .env ] || return 0
  if grep -qE '^GATEWAY_IMAGE=(docker\.io/(library/)?)?caddy:[^@]*$' .env; then
    sed -i "s|^GATEWAY_IMAGE=.*|GATEWAY_IMAGE=${GATEWAY_STOCK_IMAGE}|" .env
    echo "Pinned the gateway image in .env by its digest: ${GATEWAY_STOCK_IMAGE%%@*}"
  fi
  if grep -qE '^GATEWAY_IMAGE=ghcr\.io/marlon-thomas/workforce-deploy-gateway([:@]|$)' .env \
     && ! grep -qxF "GATEWAY_IMAGE=${GATEWAY_DNS01_IMAGE}" .env; then
    sed -i "s|^GATEWAY_IMAGE=.*|GATEWAY_IMAGE=${GATEWAY_DNS01_IMAGE}|" .env
    echo "Pinned the DNS-01 gateway image in .env by its digest: ${GATEWAY_DNS01_IMAGE##*@}"
  fi
}

# ------------------------------------------------------------------ off-site encryption (age)
# Off-site copies are encrypted with age before they leave the server (RUNBOOK, "Off-site backup
# targets"). This server holds only the public recipient, BACKUP_ENCRYPT_RECIPIENT in .env; the
# private key lives off it, so neither the server nor someone who takes it over can read those copies.
# The backup container has age. A host needs nothing installed: without age it runs in a throw-away
# container of the same image (compose.yaml's backup service, pinned by digest).
AGE_IMAGE="alpine:3.20.10@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc"

age_here() { command -v "${AGE_BIN:-age}" >/dev/null 2>&1; }

# under_controller — true when the appliance controller runs this script (Workforce ADR-0032), with
# its Docker reached through an allow-list proxy rather than the socket.
under_controller() { [ "${WORKFORCE_CONTROLLER:-}" = 1 ]; }

# The health watch's own database role (Workforce issue 447; x-health-db-init in compose.yaml): a login with SELECT
# on the columns doctor.sh reads and nothing else. Under the controller doctor.sh's psql runs as it, and the
# controller's proxy allows no other user there; its password goes to psql in the exec's environment
# (`docker compose exec -e PGPASSWORD` takes it from ours), never on a command line. On today's host layout the
# queries run as each database's own user, as before.
HEALTH_DB_ROLE=workforce_health

# health_db_client — sets PSQL_DB_USER and PSQL_AK_USER (who doctor.sh's psql runs as, on the application and the
# sign-in database) and PSQL_ENV (what its `docker compose exec` adds: the password, by name only).
health_db_client() {
  PSQL_ENV=()
  if under_controller; then
    PSQL_DB_USER="$HEALTH_DB_ROLE"; PSQL_AK_USER="$HEALTH_DB_ROLE"
    PGPASSWORD="$(head -c 256 secrets/health_db_password 2>/dev/null | tr -d '\r\n')" || PGPASSWORD=""
    export PGPASSWORD
    # The containers' own connections are trusted locally today, so an empty one still connects as the role.
    [ -z "$PGPASSWORD" ] || PSQL_ENV=(-e PGPASSWORD)
  else
    PSQL_DB_USER="${DB_USER:-}"; PSQL_AK_USER="${AK_DB_USER:-authentik}"
  fi
}

# ------------------------------------------------------------------ the backup's status, for the health watch
# Under the controller the health job can't list backups/ (Workforce PR 438), so bin/backup.sh leaves what it last
# did in backup-status/last.json (the backup job's folder, which the health job may read), one line:
#   {"schema":1,"lastAt":"…Z","lastAtEpoch":N,"sizeBytes":N,"archive":"name","kept":N,
#    "offsite":{"lastCopy":"OK|FAILED|UNKNOWN","at":"…Z","atEpoch":N}}
# lastAt* and sizeBytes are of the last good archive (null before the first), offsite of the last off-site copy
# (UNKNOWN and null before the first). On today's host layout nothing writes it: the scripts read backups/.
BACKUP_STATUS_FILE="${BACKUP_STATUS_FILE:-backup-status/last.json}"

# backup_status_read — sets BS_LAST_EPOCH, BS_SIZE, BS_ARCHIVE, BS_KEPT, BS_OFFSITE (OK|FAILED|UNKNOWN) and
# BS_OFFSITE_EPOCH from that file, each empty (BS_OFFSITE UNKNOWN) where it is missing or not what backup.sh
# writes: it is another job's file, so nothing in it is used unchecked. Numbers are plain decimal with no
# leading zero (bash would read 0123 as octal, and JSON doesn't allow it), at most 12 or 15 digits, and never a
# time ahead of now. Returns 1 when there is no file, 2 when there is one but it can't be read as it should.
backup_status_read() {
  local j now
  BS_LAST_EPOCH=""; BS_SIZE=""; BS_ARCHIVE=""; BS_KEPT=""; BS_OFFSITE=UNKNOWN; BS_OFFSITE_EPOCH=""
  [ -e "$BACKUP_STATUS_FILE" ] || [ -L "$BACKUP_STATUS_FILE" ] || return 1
  [ ! -L "$BACKUP_STATUS_FILE" ] || return 2
  # The folder is another job's, so what is at that name may change at any moment, into a pipe that would
  # block an open for ever: it is opened and read in a short-lived shell with a time limit, never here. There,
  # one open, then checked through it (where /proc shows it): a plain file, the very one at that name (the same
  # device and inode as the name itself, not followed), so not a link. backup.sh replaces the file by a rename,
  # which can fall between the open and the check: then it is read again (twice at most).
  local try
  for try in 1 2 3; do
    # shellcheck disable=SC2016  # expanded by the inner shell
    j="$(timeout 3 bash -c '
      exec 3<"$1" || exit 1
      if [ -e /proc/self/fd/3 ]; then
        [ -f /proc/self/fd/3 ] || exit 1
        [ "$(stat -L -c "%d:%i" /proc/self/fd/3 2>/dev/null)" = "$(stat -c "%d:%i" "$1" 2>/dev/null)" ] || exit 3
      fi
      head -c 4096 <&3' _ "$BACKUP_STATUS_FILE" 2>/dev/null)" && break
    [ "$?" -eq 3 ] && [ "$try" -lt 3 ] || return 2
  done
  j="$(printf '%s' "$j" | tr -d '\r\n')"
  case "$j" in '{"schema":1,'*) ;; *) return 2 ;; esac
  BS_LAST_EPOCH="$(bs_field "$j" lastAtEpoch '0|[1-9][0-9]{0,11}')"
  BS_SIZE="$(bs_field "$j" sizeBytes '0|[1-9][0-9]{0,14}')"
  BS_ARCHIVE="$(bs_field "$j" archive '"[A-Za-z0-9._-]{1,128}"' | tr -d '"')"
  BS_KEPT="$(bs_field "$j" kept '0|[1-9][0-9]{0,5}')"
  BS_OFFSITE="$(bs_field "$j" lastCopy '"(OK|FAILED|UNKNOWN)"' | tr -d '"')"
  [ -n "$BS_OFFSITE" ] || BS_OFFSITE=UNKNOWN
  BS_OFFSITE_EPOCH="$(bs_field "$j" atEpoch '0|[1-9][0-9]{0,11}')"
  # Never a time ahead of now (five minutes for clocks): it would make an old backup look fresh.
  now="$(date +%s)"
  if [ -n "$BS_LAST_EPOCH" ] && [ "$((10#$BS_LAST_EPOCH))" -gt "$((10#$now + 300))" ]; then BS_LAST_EPOCH=""; fi
  if [ -n "$BS_OFFSITE_EPOCH" ] && [ "$((10#$BS_OFFSITE_EPOCH))" -gt "$((10#$now + 300))" ]; then BS_OFFSITE_EPOCH=""; fi
  return 0
}
# bs_field <json> <key> <value pattern> — the value of "key", only when it is exactly the pattern (alternatives
# are grouped, so `0|[1-9]…` holds for the whole value).
bs_field() { printf '%s' "$1" | sed -nE "s/.*[{,]\"$2\":($3)[,}].*/\\1/p" | head -n 1; }

# helper_args NETWORK — fills the array HELPER with what a helper container (`docker run` of the off-site
# copy or encryption tools) needs under the controller: the project's labels, as a one-off (the backup
# job's allow-list lets it make only those), and one of the project's networks (or none), since the
# controller refuses Docker's shared default network. Empty on today's host layout.
helper_args() {
  HELPER=()
  under_controller || return 0
  HELPER=(--label "com.docker.compose.project=${COMPOSE_PROJECT_NAME:?}" --label com.docker.compose.oneoff=True
          --network "$1")
}

# age_container SCRIPT [ARG...] — run SCRIPT with age available, stdin and stdout passed through.
# --log-driver none: otherwise docker keeps what the container prints on disk until it's removed,
# and that is a private key or a decrypted backup. /k is memory, for the key on its way in.
age_container() {
  local script="$1"; shift
  # Under the controller, age is in its image (age_here), so this runs only on today's host layout; the
  # labels and network are there should it ever be needed there (it fetches age, so it needs a way out).
  helper_args "${COMPOSE_PROJECT_NAME:-x}_back"
  docker run --rm -i "${HELPER[@]}" --log-driver none --tmpfs /k:mode=0700,size=1m "$AGE_IMAGE" sh -c \
    "apk add -q --no-progress age </dev/null >/dev/null 2>&1 || { echo 'Could not install age in a helper container.' >&2; exit 125; }; $script" sh "$@"
}

# age_recipient_usable RECIPIENT — is it an age public key that age can encrypt to? Only the X25519
# form, which needs no plugin on this server. Where age is here, it's asked as well, since that
# also checks the key's checksum.
age_recipient_usable() {
  [[ "${1:-}" =~ ^age1[qpzry9x8gf2tvdw0s3jn54khce6mua7l]{58}$ ]] || return 1
  if age_here; then printf 'x' | "${AGE_BIN:-age}" -r "$1" >/dev/null 2>&1 || return 1; fi
  return 0
}

# offsite_encryption_problem RECIPIENT — why nothing can go off-site, in words; nothing when it can.
offsite_encryption_problem() {
  if [ -z "${1:-}" ]; then
    echo "BACKUP_ENCRYPT_RECIPIENT isn't set"
  elif ! age_recipient_usable "$1"; then
    echo "BACKUP_ENCRYPT_RECIPIENT isn't a usable age public key (age1…)"
  fi
}

# age_encrypt RECIPIENT — stdin to stdout.
age_encrypt() {
  if age_here; then
    "${AGE_BIN:-age}" -r "$1"
  else
    # shellcheck disable=SC2016  # expanded inside the container
    age_container 'exec age -r "$1"' "$1"
  fi
}

# age_keygen_text — a new key pair as age-keygen prints it, on stdout only, so nothing is on disk.
age_keygen_text() {
  if command -v "${AGE_KEYGEN_BIN:-age-keygen}" >/dev/null 2>&1; then
    "${AGE_KEYGEN_BIN:-age-keygen}" 2>/dev/null
  else
    ( use_docker_socket; age_container 'exec age-keygen 2>/dev/null' </dev/null )
  fi
}

# read_age_identity <file, or - for stdin> — the private key into AGE_IDENTITY, which is never
# exported, never an argument and never printed. A file can hold several keys, as age's can, for
# archives made before a rotation. From stdin it stops after the first key, so whatever follows is
# still there to read. Says why and returns 1 if there's no key.
AGE_IDENTITY=""
read_age_identity() {
  local src="$1" line eof=0 prompt key_re='^AGE-SECRET-KEY-1[0-9A-Z]{58}$'
  AGE_IDENTITY=""
  if [ "$src" = - ]; then
    if [ -t 0 ]; then
      # A whole key file may be pasted, and its first lines are comments. Whatever isn't read here goes
      # to the next thing reading this terminal, which is root's shell, and into its history.
      prompt="Paste the private key (the line starting AGE-SECRET-KEY-1, not shown; Ctrl-D to stop): "
      while [ "$eof" -eq 0 ]; do
        IFS= read -rs -p "$prompt" line || eof=1
        prompt=""
        line="${line//[[:space:]]/}"
        if [[ "$line" =~ $key_re ]]; then AGE_IDENTITY="$line"; break; fi
        case "$line" in
          ""|"#"*) ;;
          *) echo >&2; echo "That line isn't the key, and it hasn't been kept. Paste the line starting AGE-SECRET-KEY-1." >&2 ;;
        esac
      done
      echo >&2
      while IFS= read -rs -t 0.2 line; do :; done   # the rest of the paste, if there was more
      line=""
    else
      while [ "$eof" -eq 0 ]; do
        IFS= read -r line || eof=1
        line="${line//[[:space:]]/}"
        if [[ "$line" =~ $key_re ]]; then AGE_IDENTITY="$line"; break; fi
      done
    fi
    [ -n "$AGE_IDENTITY" ] || { echo "That isn't an age private key (they start AGE-SECRET-KEY-1)." >&2; return 1; }
    return 0
  fi
  [ -f "$src" ] && [ -r "$src" ] || { echo "Can't read the key file: $src" >&2; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line//[[:space:]]/}"
    if [[ "$line" =~ $key_re ]]; then AGE_IDENTITY="${AGE_IDENTITY:+${AGE_IDENTITY}$'\n'}${line}"; fi
  done < "$src"
  [ -n "$AGE_IDENTITY" ] || { echo "There's no age private key in $src (they start AGE-SECRET-KEY-1)." >&2; return 1; }
}

# age_decrypt — stdin to stdout, with the key from read_age_identity. Printed by bash's own printf,
# so it reaches age through a pipe and is on no command line. age's own error goes to stderr; "no
# identity matched" is the wrong key.
age_decrypt() {
  if age_here; then
    "${AGE_BIN:-age}" -d -i <(printf '%s\n' "$AGE_IDENTITY")
  else
    # The key comes first on stdin, up to a blank line; the archive follows it.
    # shellcheck disable=SC2016  # expanded inside the container
    { printf '%s\n\n' "$AGE_IDENTITY"; cat; } | age_container \
      'umask 077; while IFS= read -r l && [ -n "$l" ]; do printf "%s\n" "$l" >> /k/id; done; exec age -d -i /k/id'
  fi
}

# is_age_file FILE — is it age's format, whatever it's called?
is_age_file() { [ "$(head -c 21 "$1" 2>/dev/null | tr -d '\000')" = "age-encryption.org/v1" ]; }
