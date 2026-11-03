#!/usr/bin/env bash
# recovery-test.sh — hermetic self-test of recovering a server: the real bin/recover.sh, install.sh,
# restore.sh, backup.sh and doctor.sh, with docker, ansible, sudo, the package tools and the network as
# fakes on PATH. No Docker, no network, no root, nothing outside its own folder.
# What the fakes can't prove (real containers, real ansible, a real sudo, chown to a real user) is for a
# real recovery on a fresh machine: RUNBOOK, "Recovering onto a new server".
# The parts that need encryption use a real `age` and GNU tar, and say clearly that they were skipped
# without them; CI's alpine step has both.
#   ./bin/tests/recovery-test.sh      exit 0 = all pass
# Everything secret in here is made up for this run. Nothing prints one: a failure names the check only.
set -uo pipefail
exec </dev/null   # whatever needs stdin here gets it on purpose; the fakes must never wait on a terminal
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
REAL_AGE="$(command -v age || true)"; REAL_KEYGEN="$(command -v age-keygen || true)"
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK:?}"' EXIT
FAKE="$WORK/fake"; SENT="$WORK/sent"
mkdir -p "$FAKE" "$SENT" "$WORK/ev" "$WORK/fakehome" "$WORK/tmpd"
SECRET_MARK="FICTITIOUS-DB-PASSWORD-$$"
ENV_MARK="fictitious-relay-password-$$"
TOKEN_MARK="ghp_fictitious_token_$$"
printf 'fictitious care record\n' > "$WORK/ev/record.txt"
head -c 300000 /dev/urandom > "$WORK/ev/scan.bin"   # bigger than one of age's chunks, like any real copy

PASS=0; FAILN=0; SKIPPED=0
ok()  { PASS=$((PASS+1)); }
bad() { FAILN=$((FAILN+1)); printf 'FAIL: %s\n' "$*"; }
check() { if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$3] got [$2]"; fi; }
contains() { case "$2" in *"$3"*) ok ;; *) bad "$1: [$3] not found" ;; esac; }
lacks() { case "$2" in *"$3"*) bad "$1: [$3] should not appear" ;; *) ok ;; esac; }
# never_in <label> <pattern> <file or folder>... — says nothing about what it found.
never_in() { local l="$1" p="$2"; shift 2; if grep -rqF -- "$p" "$@" 2>/dev/null; then bad "$l: it's there"; else ok; fi; }
mode_of() { stat -c %a "$1" 2>/dev/null; }

# --- the fakes
cat > "$FAKE/docker" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *--password-stdin*) cat > "$FAKE_SENT/token-received"; mkdir -p "$HOME/.docker"; printf '{"auths":{"ghcr.io":{"auth":"eDp5"}}}\n' > "$HOME/.docker/config.json" ;;
esac
printf 'docker %s\n' "$*" >> "$FAKE_CALLS"
case "$*" in
  *--password-stdin*) ;;
  *pg_dump*) printf 'fictitious dump\n' ;;
  *certificate_data*) cat "$FAKE_SENT/ak-cert" 2>/dev/null ;;
  *"exec -T postgres psql"*|*"exec -T authentik-postgres psql"*) cat > /dev/null ;;
  *pg_restore*)
    cat > /dev/null
    printf 'pg_restore\n' >> "$FAKE_RESTORES"
    # What's on disk while a restore is under way.
    find "${TMPDIR:-/nonexistent}" > "$FAKE_SENT/tmp-during-restore" 2>/dev/null
    # The sign-in database, for real rather than the scratch check: the key inside it comes back.
    case "$*" in *"-d authentik "*) cp "$FAKE_SENT/backup-cert" "$FAKE_SENT/ak-cert" 2>/dev/null ;; esac ;;
  *"compose run"*init*"tar -xf -"*) cat > /dev/null; printf 'evidence\n' >> "$FAKE_RESTORES" ;;
  *"compose run"*init*) tar -C "$FAKE_EV" -cf - . ;;
  *"compose cp"*) exit 1 ;;
esac
exit 0
SH
cat > "$FAKE/rsync" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in -*) ;; *) if [ -f "$a" ]; then cp "$a" "$FAKE_SENT/rsync-copy"; fi ;; esac; done
find "${TMPDIR:-/nonexistent}" backups > "$FAKE_SENT/disk-during-send" 2>/dev/null
exit 0
SH
cat > "$FAKE/age" <<SH
#!/usr/bin/env bash
printf 'age %s\n' "\$*" >> "\$FAKE_CALLS"
exec "$REAL_AGE" "\$@"
SH
# Like the real one, it drops the environment: what the service user's phase needs must come by its flags.
cat > "$FAKE/sudo" <<'SH'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >> "$FAKE_CALLS"
if [ "${1:-}" = -u ]; then shift 2; fi
if [ "${1:-}" = test ] && [ -f "$FAKE_SENT/copy-unreadable" ]; then exit 1; fi
if [ -f "$FAKE_SENT/no-such-user" ] && [ ! -f "$FAKE_SENT/user-made" ]; then exit 1; fi
keep=(); while IFS= read -r v; do keep+=("$v"); done < <(env | grep '^FAKE_')
exec env -i PATH="$PATH" HOME="$FAKE_FAKEHOME" FAKE_UID=1500 "${keep[@]}" "$@"
SH
cat > "$FAKE/id" <<'SH'
#!/usr/bin/env bash
case "$*" in
  -u) echo "${FAKE_UID:-0}" ;;
  -un) echo workforce_app_sa ;;
  *workforce_app_sa)
    if [ -f "$FAKE_SENT/no-such-user" ] && [ ! -f "$FAKE_SENT/user-made" ]; then exit 1; fi
    case "$*" in -u*) echo 1500 ;; *) echo uid=1500 ;; esac ;;
  *) echo 0 ;;
esac
SH
cat > "$FAKE/chown" <<'SH'
#!/usr/bin/env bash
printf 'chown %s\n' "$*" >> "$FAKE_CALLS"
SH
cat > "$FAKE/curl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *ifconfig.me*) echo 203.0.113.9 ;;
  *http_code*) echo 200 ;;
esac
SH
cat > "$FAKE/getent" <<'SH'
#!/usr/bin/env bash
if [ -f "$FAKE_SENT/dns-here" ]; then echo "203.0.113.9 $2"; else echo "198.51.100.1 $2"; fi
SH
# The playbook: what a converge on a fresh sign-in server does to the signing key, and nothing else.
cat > "$FAKE/ansible-playbook" <<'SH'
#!/usr/bin/env bash
printf 'ansible-playbook\n' >> "$FAKE_CALLS"
if [ -f "$FAKE_SENT/ansible-fails" ]; then rm -f "$FAKE_SENT/ansible-fails"; exit 2; fi
for a in "$@"; do case "$a" in @*) cp "${a#@}" "$FAKE_SENT/vars.json" ;; esac; done
cp "$FAKE_SENT/fresh-cert" "$FAKE_SENT/ak-cert"
cat "$FAKE_SENT/fresh-pub" > secrets/oidc_signing_pub.pem
SH
for t in adduser usermod apt-get dnf loginctl systemctl ansible-galaxy dockerd-rootless-setuptool.sh sleep; do
  printf '#!/usr/bin/env bash\nprintf "%s %%s\\n" "$*" >> "$FAKE_CALLS"\n' "$t" > "$FAKE/$t"
done
printf '#!/usr/bin/env bash\ntouch "$FAKE_SENT/user-made"\n' > "$FAKE/adduser"
printf '#!/usr/bin/env bash\nprintf "passwd\\n" >> "$FAKE_CALLS"\n' > "$FAKE/passwd"
printf '#!/usr/bin/env bash\necho inactive\n' > "$FAKE/ufw"
chmod +x "$FAKE"/*
[ -n "$REAL_AGE" ] || rm -f "$FAKE/age"

export PATH="$FAKE:$PATH"
export DOCKER_HOST="unix://$WORK/no-such.sock" FAKE_CALLS="$WORK/calls" FAKE_SENT="$SENT" FAKE_EV="$WORK/ev" FAKE_RESTORES="$WORK/restores" FAKE_FAKEHOME="$WORK/fakehome"
: > "$FAKE_CALLS"; : > "$FAKE_RESTORES"
reset_logs() { : > "$FAKE_CALLS"; : > "$FAKE_RESTORES"; }

# Two sign-in servers' keys: the one in the backup, and the one a fresh install makes.
make_cert() { # make_cert <cert file> <public key file>
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$WORK/k.tmp" -subj /CN=test -days 2 -out "$1" 2>/dev/null
  openssl x509 -in "$1" -pubkey -noout > "$2"
  rm -f "$WORK/k.tmp"
}
make_cert "$SENT/backup-cert" "$SENT/backup-pub"
make_cert "$SENT/fresh-cert" "$SENT/fresh-pub"
sum_of() { sha256sum < "$1" | cut -d' ' -f1; }

# --- a server, as it stood: a bundle with its settings and secrets
make_server() { # make_server <dir> <target> <recipient>
  local d="$1"
  mkdir -p "$d/secrets/tls" "$d/backups" "$d/environments" "$d/ansible"
  cp -r "$REPO/bin" "$d/bin"
  printf 'image: goauthentik/server:2026.8.1\n' > "$d/compose.yaml"
  printf 'TLS_MODE=certs\n' > "$d/environments/test.env"
  mv "$d/bin/doctor.sh" "$d/bin/doctor-real.sh"
  printf '#!/usr/bin/env bash\nprintf "doctor %%s\\n" "$*" >> "$FAKE_CALLS"\n[ ! -f "$FAKE_SENT/doctor-red" ]\n' > "$d/bin/doctor.sh"
  chmod +x "$d/bin/doctor.sh"
  cat > "$d/.env" <<ENV
ENV_NAME=test
DB_NAME=workforce
DB_USER=workforce_app
AK_DB_NAME=authentik
AK_DB_USER=authentik
API_IMAGE=ghcr.io/example/workforce-suite
APP_VERSION=0.0.0
APP_HOSTNAME=app.example.test
AUTH_HOSTNAME=auth.example.test
ACME_EMAIL=ops@example.test
SMTP_PASSWORD='${ENV_MARK}'
MAIL_SERVER_URL=http://mail:8080
FEEDBACK_GITHUB_APP_ID=12345
BACKUP_TARGET=$2
BACKUP_ENCRYPT_RECIPIENT=$3
DOCKER_SOCK=/run/user/4242/docker.sock
ENV
  chmod 600 "$d/.env"
  printf '%s' "$SECRET_MARK" > "$d/secrets/db_password"
  for s in minio_access minio_secret ak_db_password ak_secret oidc_client_id ai_credential_key mail_lookup_key webmail_oidc_secret; do
    printf 'fictitious-%s-%s' "$s" "$$" > "$d/secrets/$s"
  done
  openssl rand -hex 32 > "$d/secrets/oidc_client_secret"
  printf 'http://authentik-server:9000/application/o/workforce/jwks/' > "$d/secrets/oidc_jwks_uri"
  : > "$d/secrets/ai_api_key"
  # Like the real one, too big to fit in a pipe's buffer: reading only the data must not kill what feeds it.
  head -c 300000 /dev/urandom > "$d/secrets/api-truststore.jks"
  printf 'the first admin password' > "$d/secrets/initial-admin-password"; chmod 400 "$d/secrets/initial-admin-password"
  printf 'fictitious ssh key' > "$d/secrets/backup_ssh_key"; chmod 600 "$d/secrets/backup_ssh_key"
  printf 'fictitious tls key' > "$d/secrets/tls/tls.key"; chmod 600 "$d/secrets/tls/tls.key"
  cp "$SENT/backup-pub" "$d/secrets/oidc_signing_pub.pem"
  ( cd "$d" && . ./bin/lib/common.sh && secret_modes )
}
# A new server's clone: the public repo and nothing else.
make_clone() { # make_clone <dir>
  local d="$1"
  mkdir -p "$d/secrets" "$d/environments" "$d/ansible"
  cp -r "$REPO/bin" "$d/bin"
  printf 'image: goauthentik/server:2026.8.1\n' > "$d/compose.yaml"
  printf 'TLS_MODE=certs\n' > "$d/environments/test.env"
  mv "$d/bin/doctor.sh" "$d/bin/doctor-real.sh"
  printf '#!/usr/bin/env bash\nprintf "doctor %%s\\n" "$*" >> "$FAKE_CALLS"\n[ ! -f "$FAKE_SENT/doctor-red" ]\n' > "$d/bin/doctor.sh"
  chmod +x "$d/bin/doctor.sh"
}

# ------------------------------------------------------------------ the rule for secrets' modes
# The real shell of the real tasks, run on a folder of its own, with their paths moved there.
ROLE="$REPO/ansible/roles/workforce/tasks/main.yml"
task_shell() { # task_shell <the start of the task's name> <folder>
  awk -v name="$1" '
    index($0, "- name: " name) == 1 { found = 1; next }
    found && /^  ansible\.builtin\.shell: \|/ { body = 1; next }
    body && /^    / { print substr($0, 5); next }
    body { exit }' "$ROLE" \
    | sed -e "s|/opt/workforce-deploy|$2|g" -e "s|{{ service_user }}|workforce_app_sa|g"
}
D="$WORK/modes"; mkdir -p "$D/secrets"; cp -r "$REPO/bin" "$D/bin"
for t in "Generate the web-push VAPID keypair" "Create the AI assistant secrets" "Secret files readable"; do
  task_shell "$t" "$D" > "$WORK/task.sh"
  [ -s "$WORK/task.sh" ] || bad "no such task in the role: $t"
  bash "$WORK/task.sh" > /dev/null 2>"$WORK/task.err" || bad "task failed: $t: $(cat "$WORK/task.err")"
done
printf 'x' > "$D/secrets/initial-admin-password"; printf 'x' > "$D/secrets/backup_ssh_key"
task_shell "Secret files readable" "$D" > "$WORK/task.sh"; bash "$WORK/task.sh"
for f in ai_credential_key ai_api_key feedback_github_key mail_admin_password mail_db_password mail_lookup_key \
         mail_relay_password webmail_oidc_secret webmail_des_key push_vapid_public push_vapid_private; do
  check "fresh install: $f is readable by the containers" "$(mode_of "$D/secrets/$f")" 644
done
check "the secrets folder stays closed" "$(mode_of "$D/secrets")" 700
check "the admin password stays owner-only" "$(mode_of "$D/secrets/initial-admin-password")" 400
check "the backup ssh key stays owner-only" "$(mode_of "$D/secrets/backup_ssh_key")" 600
# Every run, not just the first: a resume with these present, and the values don't change.
BEFORE="$(cat "$D"/secrets/ai_credential_key "$D"/secrets/mail_db_password "$D"/secrets/push_vapid_private | sha256sum)"
chmod 600 "$D"/secrets/ai_credential_key "$D"/secrets/mail_db_password
for t in "Generate the web-push VAPID keypair" "Create the AI assistant secrets" "Secret files readable"; do
  task_shell "$t" "$D" > "$WORK/task.sh"; bash "$WORK/task.sh" > /dev/null
done
check "resume: readable again" "$(mode_of "$D/secrets/ai_credential_key"):$(mode_of "$D/secrets/mail_db_password")" 644:644
check "resume: nothing regenerated" "$(cat "$D"/secrets/ai_credential_key "$D"/secrets/mail_db_password "$D"/secrets/push_vapid_private | sha256sum)" "$BEFORE"
# ansible splits a shell task's text on quotes before running it, comments included, so one stray
# apostrophe fails the playbook while bash is perfectly happy with the same text.
for t in "Export authentik's JWT" "Secret files readable"; do
  task_shell "$t" "$D" > "$WORK/task.sh"
  check "$t: quotes balance, for ansible" "$(( $(tr -cd "'" < "$WORK/task.sh" | wc -c) % 2 )):$(( $(tr -cd '"' < "$WORK/task.sh" | wc -c) % 2 ))" 0:0
done
check "the role makes no secret 0600 by hand" "$(grep -c 'chmod 600' "$ROLE")" 0
MODES_LINE="$(grep -n 'name: Secret files readable' "$ROLE" | cut -d: -f1)"
UP_LINE="$(grep -n 'name: Application plane up' "$ROLE" | cut -d: -f1)"
check "the rule runs before the app starts" "$([ "${MODES_LINE:-99999}" -lt "${UP_LINE:-0}" ] && echo yes)" yes
contains "install.sh applies the rule after converging" "$(sed -n '/^run_ansible_site()/,/^}/p' "$REPO/bin/install.sh")" "secret_modes"

# ------------------------------------------------------------------ the doctor's row
B="$WORK/server"; make_server "$B" "" ""
doctor_row() { ( cd "$B" && bash ./bin/doctor-real.sh --plain --smoke 2>/dev/null ) | awk -F'\t' '$2 == "sign-in key" { print $1 "|" $3 }'; }
cp "$SENT/backup-cert" "$SENT/ak-cert"
contains "doctor: the keys match" "$(doctor_row)" "OK|the application trusts"
contains "doctor: exact name, not Workforce webmail" "$(grep -m1 certificate_data "$FAKE_CALLS")" "a.name = 'Workforce'"
lacks "doctor: not a pattern" "$(grep -m1 certificate_data "$FAKE_CALLS")" "LIKE"
cp "$SENT/fresh-cert" "$SENT/ak-cert"
ROW="$(doctor_row)"
contains "doctor: they differ" "$ROW" "FAIL|the sign-in server uses a different key"
contains "doctor: the fix, in words" "$ROW" "nobody can sign in: run ./bin/refresh-signing-key.sh"
lacks "doctor: never the key itself" "$ROW" "BEGIN"
( cd "$B" && bash ./bin/doctor-real.sh --plain --smoke >/dev/null 2>&1 ); RC=$?
[ "$RC" -gt 0 ] && ok || bad "doctor: a mismatch counts as a failure"
mv "$B/secrets/oidc_signing_pub.pem" "$WORK/pem.keep"
contains "doctor: no copy of the key" "$(doctor_row)" "FAIL|the application has no copy"
mv "$WORK/pem.keep" "$B/secrets/oidc_signing_pub.pem"
rm -f "$SENT/ak-cert"
contains "doctor: can't read the database is only a WARN" "$(doctor_row)" "WARN|not checked"

# ------------------------------------------------------------------ a full restore and signing in
restore() { ( cd "$B" && TMPDIR="$WORK/tmpd" bash ./bin/restore.sh "$@" ) > "$WORK/out" 2>&1; }
cp "$SENT/backup-cert" "$SENT/ak-cert"
( cd "$B" && bash ./bin/backup.sh ) > "$WORK/out" 2>&1; check "backup: made" "$?" 0
ARCHIVE="$(find "$B/backups" -maxdepth 1 -name '*.tar.gz' | head -1)"
LOCAL_NAMES="$(tar -tzf "$ARCHIVE")"
lacks "the local archive: no .env" "$LOCAL_NAMES" ".env"
lacks "the local archive: no secrets/" "$LOCAL_NAMES" "secrets"
gzip -dc "$ARCHIVE" > "$WORK/plain.tar"
never_in "the local archive: no secret anywhere in it" "$SECRET_MARK" "$WORK/plain.tar"
never_in "the local archive: nothing from .env in it" "$ENV_MARK" "$WORK/plain.tar"

# The same server's own backup: its key, its password file, a plain start.
reset_logs
restore --yes "$ARCHIVE"; check "same server: restored" "$?" 0
check "same server: the key is unchanged" "$(sum_of "$B/secrets/oidc_signing_pub.pem")" "$(sum_of "$SENT/backup-pub")"
contains "same server: a plain start" "$(cat "$FAKE_CALLS")" "compose start api worker"
lacks "same server: no recreate" "$(cat "$FAKE_CALLS")" "force-recreate"
check "same server: the password file stays" "$([ -e "$B/secrets/initial-admin-password" ] && echo yes)" yes
lacks "same server: nothing about passwords" "$(cat "$WORK/out")" "Forgot your password"

# A fresh install, then someone else's backup. The file holds the throwaway password.
to_fresh_install() { cp "$SENT/fresh-cert" "$SENT/ak-cert"; cat "$SENT/fresh-pub" > "$B/secrets/oidc_signing_pub.pem"; chmod 600 "$B/secrets/initial-admin-password" 2>/dev/null; printf 'the throwaway password' > "$B/secrets/initial-admin-password"; chmod 400 "$B/secrets/initial-admin-password"; }
to_fresh_install; reset_logs
restore --yes "$ARCHIVE"; check "no config: restored" "$?" 0
check "no config: the app trusts the restored key" "$(sum_of "$B/secrets/oidc_signing_pub.pem")" "$(sum_of "$SENT/backup-pub")"
check "no config: still world-readable, inside the closed folder" "$(mode_of "$B/secrets/oidc_signing_pub.pem")" 644
contains "no config: api and worker load it" "$(cat "$FAKE_CALLS")" "up -d --no-deps --force-recreate api worker"
lacks "no config: not just started" "$(cat "$FAKE_CALLS")" "compose start api worker"
check "no config: the throwaway password is gone" "$([ -e "$B/secrets/initial-admin-password" ] && echo left || echo gone)" gone
contains "no config: says what to do" "$(cat "$WORK/out")" 'Forgot your password?'
contains "no config: and the break-glass" "$(cat "$WORK/out")" "./bin/reset-admin.sh"
contains "doctor agrees afterwards" "$(doctor_row)" "OK|the application trusts"

# Came with its config (bin/recover.sh): the same key work, but that password file is the real record.
to_fresh_install; reset_logs
restore --yes --config-restored "$ARCHIVE"; check "with config: restored" "$?" 0
check "with config: the key" "$(sum_of "$B/secrets/oidc_signing_pub.pem")" "$(sum_of "$SENT/backup-pub")"
contains "with config: api and worker load it" "$(cat "$FAKE_CALLS")" "force-recreate api worker"
check "with config: the password file stays" "$([ -e "$B/secrets/initial-admin-password" ] && echo yes)" yes
lacks "with config: nothing about passwords" "$(cat "$WORK/out")" "Forgot your password"

# --data-only: no sign-in work at all
to_fresh_install; reset_logs
restore --yes --data-only "$ARCHIVE"; check "data only: restored" "$?" 0
check "data only: the key file is left alone" "$(sum_of "$B/secrets/oidc_signing_pub.pem")" "$(sum_of "$SENT/fresh-pub")"
check "data only: the password file is left alone" "$([ -e "$B/secrets/initial-admin-password" ] && echo yes)" yes
lacks "data only: nothing restarted" "$(cat "$FAKE_CALLS")" "force-recreate"

# The key can't be read: the restore says so rather than leaving people locked out in silence.
to_fresh_install; reset_logs
cp "$SENT/backup-cert" "$WORK/backup-cert.keep"; rm -f "$SENT/backup-cert" "$SENT/ak-cert"
restore --yes "$ARCHIVE"; check "unreadable key: the restore fails" "$?" 1
contains "unreadable key: what to do" "$(cat "$WORK/out")" "./bin/refresh-signing-key.sh"
check "unreadable key: the file is left alone" "$(sum_of "$B/secrets/oidc_signing_pub.pem")" "$(sum_of "$SENT/fresh-pub")"
cp "$WORK/backup-cert.keep" "$SENT/backup-cert"

# The doctor's fix
to_fresh_install; cp "$SENT/backup-cert" "$SENT/ak-cert"; reset_logs
( cd "$B" && bash ./bin/refresh-signing-key.sh ) > "$WORK/out" 2>&1; check "refresh: works" "$?" 0
check "refresh: the key" "$(sum_of "$B/secrets/oidc_signing_pub.pem")" "$(sum_of "$SENT/backup-pub")"
contains "refresh: api and worker load it" "$(cat "$FAKE_CALLS")" "force-recreate api worker"
rm -f "$SENT/ak-cert"; to_fresh_install; rm -f "$SENT/ak-cert"
( cd "$B" && bash ./bin/refresh-signing-key.sh ) > "$WORK/out" 2>&1; check "refresh: can't read it" "$?" 1
contains "refresh: says so" "$(cat "$WORK/out")" "Couldn't read the key"

# ------------------------------------------------------------------ what needs real encryption
HAVE_GNU=0; tar --version 2>/dev/null | grep -q GNU && HAVE_GNU=1
if [ -z "$REAL_AGE" ] || [ -z "$REAL_KEYGEN" ] || [ "$HAVE_GNU" -eq 0 ]; then
  SKIPPED=1
  echo "SKIP: this needs a real age and GNU tar, so the recovery itself did not run here (CI's alpine step runs it)."
else
  "$REAL_KEYGEN" -o "$WORK/key.txt" 2>/dev/null
  "$REAL_KEYGEN" -o "$WORK/other-key.txt" 2>/dev/null
  KEY_LINE="$(grep '^AGE-SECRET-KEY-' "$WORK/key.txt")"
  RECIPIENT="$("$REAL_KEYGEN" -y "$WORK/key.txt")"
  printf '%s\n' "$TOKEN_MARK" > "$WORK/token.txt"

  # --- the copy, from the real backup.sh
  O="$WORK/old-server"
  make_server "$O" "backup@vault.example.test:" "$RECIPIENT"
  cp "$SENT/backup-cert" "$SENT/ak-cert"
  ( cd "$O" && TMPDIR="$WORK/tmpd" bash ./bin/backup.sh ) > "$WORK/out" 2>&1; check "copy: backup" "$?" 0
  COPY="$WORK/copy.tar.gz.age"; cp "$SENT/rsync-copy" "$COPY"
  check "copy: encrypted" "$(head -c 21 "$COPY")" "age-encryption.org/v1"
  never_in "copy: no secret readable in the file" "$SECRET_MARK" "$COPY"
  lacks "copy: only ciphertext on disk while it's sent" "$(grep -v '\.age$' "$SENT/disk-during-send" | grep -E 'db_password|\.env')" "db_password"
  ARCHIVE_O="$(find "$O/backups" -maxdepth 1 -name '*.tar.gz' | head -1)"
  never_in "copy: the local archive holds no secret" "$SECRET_MARK" "$ARCHIVE_O"
  check "copy: the wrong key can't open it" "$("$REAL_AGE" -d -i "$WORK/other-key.txt" "$COPY" 2>/dev/null | wc -c | tr -d ' ')" 0
  "$REAL_AGE" -d -i "$WORK/key.txt" "$COPY" | gzip -dc | tar -tif - > "$WORK/names"
  grep -qx '.env' "$WORK/names" && ok || bad "copy: holds .env"
  grep -qx 'secrets/db_password' "$WORK/names" && ok || bad "copy: holds the secrets"
  grep -qx 'secrets/tls/tls.key' "$WORK/names" && ok || bad "copy: holds what's in folders under secrets/"
  grep -qx 'database.dump' "$WORK/names" && ok || bad "copy: holds the data"
  # A copy from before this existed: the same data, no config.
  "$REAL_AGE" -r "$RECIPIENT" -o "$WORK/old-format.tar.gz.age" "$ARCHIVE_O"

  # restore-drill.sh's way of reading one part, which needs Incus to run for real.
  eval "$(sed -n '/^archive_part()/,/^}/p' "$REPO/bin/restore-drill.sh")"
  archive_stream() { "$REAL_AGE" -d -i "$WORK/key.txt" "$COPY"; }
  check "drill: a part of a new copy" "$(archive_part database.dump)" "fictitious dump"
  archive_part evidence.tar >/dev/null; check "drill: every step happy, past the config" "$?" 0
  archive_part no-such-part >/dev/null 2>&1; [ "$?" -ne 0 ] && ok || bad "drill: a missing part is noticed"
  archive_part secrets/db_password >/dev/null 2>&1; [ "$?" -ne 0 ] && ok || bad "drill: the config isn't a part"

  # --- recover.sh --check
  rchk() { bash "$REPO/bin/recover.sh" --check "$@" > "$WORK/out" 2>&1; }
  rchk --identity "$WORK/key.txt" "$COPY"; check "--check: a good copy" "$?" 0
  contains "--check: says what's in it" "$(cat "$WORK/out")" "holds the data, the settings and"
  rchk --identity "$WORK/key.txt" "$WORK/old-format.tar.gz.age"; check "--check: an older copy" "$?" 3
  rchk --identity "$WORK/other-key.txt" "$COPY"; check "--check: the wrong key" "$?" 6
  head -c "$(( $(wc -c < "$COPY") - 100 ))" "$COPY" > "$WORK/cut.tar.gz.age"
  rchk --identity "$WORK/key.txt" "$WORK/cut.tar.gz.age"; check "--check: cut short" "$?" 1

  # --- a recovery, start to finish
  T="$WORK/opt-workforce"; N="$WORK/clone"; make_clone "$N"
  recover() { ( cd "$N" && WORKFORCE_TARGET="$T" TMPDIR="$WORK/tmpd" bash ./bin/recover.sh "$@" ) > "$WORK/out" 2>&1; }
  new_server() { rm -rf "$T"; rm -f "$WORK/fakehome/.docker/config.json" "$SENT/user-made" "$SENT/token-received" "$SENT/vars.json"; touch "$SENT/no-such-user"; cp "$SENT/fresh-cert" "$SENT/ak-cert"; reset_logs; }
  # What must come back exactly as it was: .env apart from the socket, and every secret.
  same_as_old() { # same_as_old <label>
    check "$1: .env is as it was, but for the socket" "$(grep -v '^DOCKER_SOCK=' "$T/.env" | sha256sum)" "$(grep -v '^DOCKER_SOCK=' "$O/.env" | sha256sum)"
    check "$1: every secret is as it was" "$(cd "$T/secrets" && find . -type f ! -name .gitkeep | sort | xargs sha256sum | sha256sum)" "$(cd "$O/secrets" && find . -type f | sort | xargs sha256sum | sha256sum)"
  }
  new_server
  recover --identity "$WORK/key.txt" --registry-token-file "$WORK/token.txt" "$COPY"; RC=$?
  check "recover: works" "$RC" 0
  [ "$RC" -eq 0 ] || tail -n 15 "$WORK/out"
  same_as_old "recover"
  check "recover: .env mode" "$(mode_of "$T/.env")" 600
  check "recover: secrets folder mode" "$(mode_of "$T/secrets")" 700
  check "recover: a secret the containers read" "$(mode_of "$T/secrets/db_password")" 644
  check "recover: the admin password" "$(mode_of "$T/secrets/initial-admin-password")" 400
  check "recover: the backup ssh key" "$(mode_of "$T/secrets/backup_ssh_key")" 600
  check "recover: a key in a folder" "$(mode_of "$T/secrets/tls/tls.key")" 600
  contains "recover: all of it given to the service user" "$(cat "$FAKE_CALLS")" "chown -R workforce_app_sa:workforce_app_sa $T"
  check "recover: asks for no password" "$(grep -c '^passwd' "$FAKE_CALLS")" 0
  contains "recover: the service user was made" "$(cat "$WORK/out")" "created (sudo member)"
  contains "recover: says the password can come later" "$(cat "$WORK/out")" "passwd workforce_app_sa"
  check "recover: the token reached the registry" "$(sum_of "$SENT/token-received")" "$(sum_of "$WORK/token.txt")"
  never_in "recover: the token is on no command line" "$TOKEN_MARK" "$FAKE_CALLS"
  never_in "recover: the token isn't printed" "$TOKEN_MARK" "$WORK/out"
  check "recover: the token's file is gone" "$([ -e "$T/secrets/.recover-registry" ] && echo left || echo gone)" gone
  never_in "recover: the token is nowhere in the bundle" "$TOKEN_MARK" "$T"
  never_in "recover: the key is on no command line" "$KEY_LINE" "$FAKE_CALLS"
  never_in "recover: the key isn't printed" "$KEY_LINE" "$WORK/out"
  never_in "recover: the key is nowhere in the bundle" "$KEY_LINE" "$T"
  never_in "recover: no secret is printed" "$SECRET_MARK" "$WORK/out"
  contains "recover: ansible keeps that .env" "$(cat "$SENT/vars.json")" '"keep_env": "true"'
  contains "recover: the environment file is used" "$(grep -m1 'install.sh' "$FAKE_CALLS")" "--env test"
  contains "recover: and the service user's phase is told" "$(grep -m1 'install.sh' "$FAKE_CALLS")" "--recovering"
  lacks "recover: the old machine's socket is gone" "$(cat "$T/.env")" "DOCKER_SOCK=/run/user/4242/docker.sock"
  check "recover: exactly one socket line" "$(grep -c '^DOCKER_SOCK=' "$T/.env")" 1
  check "recover: the signing key is the backup's" "$(sum_of "$T/secrets/oidc_signing_pub.pem")" "$(sum_of "$SENT/backup-pub")"
  contains "recover: api and worker load it" "$(cat "$FAKE_CALLS")" "force-recreate api worker"
  check "recover: the password file is the real one's" "$(cat "$T/secrets/initial-admin-password")" "the first admin password"
  contains "recover: the data went back" "$(cat "$FAKE_RESTORES")" "evidence"
  contains "recover: the key reached restore.sh by a pipe" "$(grep -m1 'restore.sh' "$FAKE_CALLS")" "--identity - "
  check "recover: no leftovers in secrets/" "$(find "$T/secrets" -maxdepth 1 -name '.recover*' | wc -l | tr -d ' ')" 0
  check "recover: nothing in progress" "$([ -e "$T/state/recovery-in-progress" ] && echo yes || echo no)" no
  check "recover: nothing in the temp folder" "$(find "$WORK/tmpd" -mindepth 1 | wc -l | tr -d ' ')" 0
  contains "recover: says how long" "$(cat "$WORK/out")" "Recovered in about"
  contains "recover: says what a person should check" "$(cat "$WORK/out")" "sign in with a real account"

  # Done, so it won't run over itself.
  reset_logs
  recover --identity "$WORK/key.txt" --registry-token-file "$WORK/token.txt" "$COPY"; check "afterwards: refused" "$?" 1
  contains "afterwards: in words" "$(cat "$WORK/out")" "already set up"
  check "afterwards: nothing ran" "$(grep -c 'install.sh\|restore.sh' "$FAKE_CALLS")" 0
  same_as_old "afterwards"

  # Everything through stdin, as a pipe: the key, then the token. The token is the next line.
  new_server
  printf '%s\n%s\n' "$KEY_LINE" "$TOKEN_MARK" > "$WORK/stdin"
  recover --identity - "$COPY" < "$WORK/stdin"; RC=$?
  check "stdin: works" "$RC" 0
  [ "$RC" -eq 0 ] || tail -n 15 "$WORK/out"
  check "stdin: the token" "$(sum_of "$SENT/token-received")" "$(sum_of "$WORK/token.txt")"
  same_as_old "stdin"
  never_in "stdin: the key is on no command line" "$KEY_LINE" "$FAKE_CALLS"

  # A key file with an older key first. Only one can go to restore.sh, and it must be the right one.
  new_server
  cat "$WORK/other-key.txt" "$WORK/key.txt" > "$WORK/two-keys.txt"
  recover --identity "$WORK/two-keys.txt" --registry-token-file "$WORK/token.txt" "$COPY"; check "two keys: works" "$?" 0
  contains "two keys: restored" "$(cat "$FAKE_RESTORES")" "evidence"

  # A copy in root's home, which the service user can't read: lent to it, then taken back.
  new_server; touch "$SENT/copy-unreadable"
  recover --identity "$WORK/key.txt" --registry-token-file "$WORK/token.txt" "$COPY"; check "out of reach: works" "$?" 0
  contains "out of reach: restored from the bundle's folder" "$(grep -m1 'restore.sh' "$FAKE_CALLS")" "$T/backups/copy.tar.gz.age"
  check "out of reach: taken back" "$([ -e "$T/backups/copy.tar.gz.age" ] && echo left || echo gone)" gone
  check "out of reach: the operator's copy stays" "$([ -f "$COPY" ] && echo yes)" yes
  rm -f "$SENT/copy-unreadable"

  # --- it stops: a run again carries on
  new_server; touch "$SENT/ansible-fails"
  recover --identity "$WORK/key.txt" --registry-token-file "$WORK/token.txt" "$COPY"; check "setup fails: stops" "$?" 1
  contains "setup fails: says to run it again" "$(cat "$WORK/out")" "run this same command again"
  check "setup fails: marked" "$([ -e "$T/state/recovery-in-progress" ] && echo yes)" yes
  check "setup fails: nothing restored yet" "$(cat "$FAKE_RESTORES")" ""
  check "setup fails: the token's file is gone" "$([ -e "$T/secrets/.recover-registry" ] && echo left || echo gone)" gone
  printf 'SOMETHING_THE_OPERATOR_FIXED=1\n' >> "$T/.env"
  recover --identity "$WORK/key.txt" --registry-token-file "$WORK/token.txt" "$COPY"; check "setup fails: run again" "$?" 0
  contains "run again: doesn't put .env back over a fix" "$(cat "$T/.env")" "SOMETHING_THE_OPERATOR_FIXED=1"
  contains "run again: restored" "$(cat "$FAKE_RESTORES")" "evidence"
  check "run again: done" "$([ -e "$T/state/recovery-in-progress" ] && echo yes || echo no)" no

  new_server; touch "$SENT/doctor-red"
  recover --identity "$WORK/key.txt" --registry-token-file "$WORK/token.txt" "$COPY"; check "red health check: stops" "$?" 1
  rm -f "$SENT/doctor-red"
  if [ "$(cat "$T/state/recovery-in-progress" 2>/dev/null)" != installed ]; then
    # The red came in the install's own check, before the restore: run again from there.
    recover --identity "$WORK/key.txt" --registry-token-file "$WORK/token.txt" "$COPY"; check "red install check: run again" "$?" 0
  else
    bad "red health check: expected it to stop in the install's own check"
  fi

  # Restore stops after the setup: a run again skips the setup and needs no token.
  new_server
  sed -i 's/^\[ ! -f "\$FAKE_SENT\/doctor-red" \]$/[ ! -f "$FAKE_SENT\/doctor-red" ] \&\& { [ "$1" != --gate ] || [ ! -f "$FAKE_SENT\/restore-red" ] || ! grep -q certificate_data "$FAKE_CALLS"; }/' "$N/bin/doctor.sh"
  touch "$SENT/restore-red"
  recover --identity "$WORK/key.txt" --registry-token-file "$WORK/token.txt" "$COPY"; RC=$?
  check "restore stops: stops" "$RC" 1
  check "restore stops: the setup is marked done" "$(cat "$T/state/recovery-in-progress" 2>/dev/null)" installed
  rm -f "$SENT/restore-red"; reset_logs
  recover --identity "$WORK/key.txt" --registry-token-file "$WORK/token.txt" "$COPY"; check "restore stops: run again" "$?" 0
  check "run again: the setup isn't repeated" "$(grep -c '^ansible-playbook' "$FAKE_CALLS")" 0
  contains "run again: restored" "$(cat "$FAKE_RESTORES")" "evidence"

  # --- what it refuses, changing nothing
  new_server
  recover --identity "$WORK/key.txt" --registry-token-file "$WORK/token.txt" "$WORK/old-format.tar.gz.age"; check "older copy: refused" "$?" 1
  contains "older copy: says it holds only data" "$(cat "$WORK/out")" "holds the data, but not the server's settings and secrets"
  contains "older copy: the alternative" "$(cat "$WORK/out")" "./bin/install.sh"
  contains "older copy: the alternative, 2" "$(cat "$WORK/out")" "./bin/restore.sh --identity -"
  check "older copy: no .env" "$([ -e "$T/.env" ] && echo yes || echo no)" no
  check "older copy: nothing ran" "$(grep -c 'install.sh\|restore.sh' "$FAKE_CALLS")" 0
  check "older copy: nothing in secrets/" "$(find "$T/secrets" -mindepth 1 ! -name .gitkeep | wc -l | tr -d ' ')" 0

  new_server
  recover --identity "$WORK/other-key.txt" --registry-token-file "$WORK/token.txt" "$COPY"; check "wrong key: refused" "$?" 1
  contains "wrong key: in words" "$(cat "$WORK/out")" "doesn't open this copy"
  check "wrong key: nothing moved" "$([ -e "$T" ] && echo yes || echo no)" no

  new_server
  recover --identity "$WORK/key.txt" --registry-token-file "$WORK/token.txt" "$WORK/cut.tar.gz.age"; check "cut short: refused" "$?" 1
  contains "cut short: in words" "$(cat "$WORK/out")" "damaged or incomplete"
  check "cut short: no .env" "$([ -e "$T/.env" ] && echo yes || echo no)" no

  new_server
  recover --identity "$WORK/key.txt" --registry-token-file "$WORK/token.txt" "$ARCHIVE_O"; check "a plain archive: refused" "$?" 1
  contains "a plain archive: in words" "$(cat "$WORK/out")" "isn't an encrypted off-site copy"

  new_server; : > "$WORK/empty"
  recover --identity "$WORK/key.txt" --registry-token-file "$WORK/empty" "$COPY"; check "no token: refused" "$?" 1
  contains "no token: in words" "$(cat "$WORK/out")" "read:packages"
  check "no token: nothing moved" "$([ -e "$T" ] && echo yes || echo no)" no

  # Not root: nothing happens
  new_server
  ( cd "$N" && FAKE_UID=1500 WORKFORCE_TARGET="$T" bash ./bin/recover.sh --identity "$WORK/key.txt" "$COPY" ) > "$WORK/out" 2>&1; check "not root: refused" "$?" 1
  contains "not root: in words" "$(cat "$WORK/out")" "as root"

  # --- no environment file (a customer's own server): the questions' DNS check still happens
  new_server; rm -f "$SENT/dns-here"; mv "$N/environments/test.env" "$WORK/test.env.keep"
  recover --identity "$WORK/key.txt" --registry-token-file "$WORK/token.txt" "$COPY"; check "DNS elsewhere: stops" "$?" 1
  contains "DNS elsewhere: says what to change" "$(cat "$WORK/out")" "Change the A records"
  check "DNS elsewhere: before converging" "$(grep -c '^ansible-playbook' "$FAKE_CALLS")" 0
  touch "$SENT/dns-here"
  recover --identity "$WORK/key.txt" --registry-token-file "$WORK/token.txt" "$COPY"; check "DNS here: carries on" "$?" 0
  mv "$WORK/test.env.keep" "$N/environments/test.env"

  # --- an older copy still restores, by restore.sh, as an ordinary archive would
  B="$WORK/server"; to_fresh_install
  restore --yes --identity "$WORK/key.txt" "$WORK/old-format.tar.gz.age"; check "older copy, restore.sh: works" "$?" 0
  check "older copy, restore.sh: signing in repaired" "$(sum_of "$B/secrets/oidc_signing_pub.pem")" "$(sum_of "$SENT/backup-pub")"
  check "older copy, restore.sh: the throwaway password is gone" "$([ -e "$B/secrets/initial-admin-password" ] && echo left || echo gone)" gone

  # --- a new copy through restore.sh on another server: it ignores the config
  to_fresh_install
  ENV_BEFORE="$(sum_of "$B/.env")"; DB_BEFORE="$(sum_of "$B/secrets/db_password")"
  printf 'something else' > "$B/secrets/db_password"; DB_BEFORE="$(sum_of "$B/secrets/db_password")"
  rm -f "$SENT/tmp-during-restore"
  restore --yes --data-only --identity "$WORK/key.txt" "$COPY"; check "--data-only, new copy: works" "$?" 0
  check "--data-only: .env untouched" "$(sum_of "$B/.env")" "$ENV_BEFORE"
  check "--data-only: secrets untouched" "$(sum_of "$B/secrets/db_password")" "$DB_BEFORE"
  lacks "--data-only: the config never reached the disk" "$(cat "$SENT/tmp-during-restore")" "db_password"
  lacks "--data-only: .env never reached the disk" "$(cat "$SENT/tmp-during-restore")" "/.env"
  contains "--data-only: the data did" "$(cat "$SENT/tmp-during-restore")" "database.dump"
  restore --yes --identity "$WORK/key.txt" "$COPY"; check "full, new copy: works" "$?" 0
  check "full, new copy: secrets still untouched" "$(sum_of "$B/secrets/db_password")" "$DB_BEFORE"
  check "full, new copy: the config never reached the disk" "$(grep -c 'db_password' "$SENT/tmp-during-restore")" 0
fi

echo "recovery self-test: ${PASS} passed, ${FAILN} failed$([ "$SKIPPED" -eq 1 ] && echo ', the recovery itself SKIPPED (no age or GNU tar)')"
[ "$FAILN" -eq 0 ]
