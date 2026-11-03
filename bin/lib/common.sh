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
# when it can't be read. The exact name: this database also has "Workforce webmail".
oidc_signing_pub() {
  docker compose exec -T authentik-postgres psql -X -U "${AK_DB_USER:-authentik}" -d "${AK_DB_NAME:-authentik}" -t -A -c \
    "SELECT c.certificate_data FROM authentik_core_application a \
       JOIN authentik_providers_oauth2_oauth2provider p ON p.provider_ptr_id = a.provider_id \
       JOIN authentik_crypto_certificatekeypair c ON c.kp_uuid = p.signing_key_id \
      WHERE a.name = 'Workforce'" 2>/dev/null \
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

# ------------------------------------------------------------------ off-site encryption (age)
# Off-site copies are encrypted with age before they leave the server (RUNBOOK, "Off-site backup
# targets"). This server holds only the public recipient, BACKUP_ENCRYPT_RECIPIENT in .env; the
# private key lives off it, so neither the server nor someone who takes it over can read those copies.
# The backup container has age. A host needs nothing installed: without age it runs in a throw-away
# container of the same image.
AGE_IMAGE="alpine:3.20"

age_here() { command -v "${AGE_BIN:-age}" >/dev/null 2>&1; }

# age_container SCRIPT [ARG...] — run SCRIPT with age available, stdin and stdout passed through.
# --log-driver none: otherwise docker keeps what the container prints on disk until it's removed,
# and that is a private key or a decrypted backup. /k is memory, for the key on its way in.
age_container() {
  local script="$1"; shift
  docker run --rm -i --log-driver none --tmpfs /k:mode=0700,size=1m "$AGE_IMAGE" sh -c \
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
  local src="$1" line eof=0 key_re='^AGE-SECRET-KEY-1[0-9A-Z]{58}$'
  AGE_IDENTITY=""
  if [ "$src" = - ]; then
    if [ -t 0 ]; then
      read -rs -p "Paste the private key (AGE-SECRET-KEY-…, not shown): " line || line=""
      echo >&2
      line="${line//[[:space:]]/}"
      if [[ "$line" =~ $key_re ]]; then AGE_IDENTITY="$line"; fi
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
