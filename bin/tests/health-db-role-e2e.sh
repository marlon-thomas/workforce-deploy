#!/usr/bin/env bash
# health-db-role-e2e.sh — the health watch's database role (Workforce issue 447; x-health-db-init in compose.yaml),
# against a real PostgreSQL: compose.yaml's own one-shot script, run as compose runs it, on a database laid out
# like the application's and the sign-in server's (only the columns that matter, all fictitious). Proves that the
# role is no superuser, is a member of nothing, can't COPY … TO PROGRAM, can't write or create anything (even with
# its session's read-only default switched off), reads only the columns doctor.sh's queries read (never a
# password hash or a private key), that doctor.sh's queries all run as it, and that running the script again on
# an install that already has the role (one changed by hand, a table added since) puts it right.
# Needs Docker; not part of bin/ci-validate.sh. PG_IMAGE overrides the image (default: compose.yaml's own pin).
#   ./bin/tests/health-db-role-e2e.sh      exit 0 = all pass
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORK="$(mktemp -d)"
N="wfc-health-role-$$"
PG="${N}-pg"
cleanup() { docker rm -f "$PG" >/dev/null 2>&1; docker network rm "$N" >/dev/null 2>&1; rm -rf "$WORK"; }
trap cleanup EXIT

PASS=0; FAILN=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAILN=$((FAILN+1)); printf 'FAIL: %s: expected [%s] got [%s]\n' "$1" "$3" "$2"; fi; }
refused() { # refused <label> <db> <sql> — the role can't do it, for want of the privilege (not merely read-only)
  local out
  if out="$(as_role "$2" "$3" 2>&1)"; then FAILN=$((FAILN+1)); printf 'FAIL: %s: it was allowed (%s)\n' "$1" "$out"
  elif printf '%s' "$out" | grep -Eq 'permission denied|must be superuser|must have|privileges of'; then PASS=$((PASS+1))
  else FAILN=$((FAILN+1)); printf 'FAIL: %s: refused, but not for want of the privilege (%s)\n' "$1" "$out"; fi
}

cat > "$WORK/ci.env" <<'ENV'
APP_HOSTNAME=app.ci.invalid
AUTH_HOSTNAME=auth.ci.invalid
ACME_EMAIL=ci@ci.invalid
DB_NAME=workforce
DB_USER=workforce_app
MINIO_BUCKET=workforce-evidence
AK_DB_NAME=authentik
AK_DB_USER=workforce_app
OIDC_ISSUER=https://auth.ci.invalid/application/o/workforce/
API_IMAGE=ghcr.io/ci/placeholder
APP_VERSION=0.0.0
ENV
( cd "$REPO" && docker compose --env-file "$WORK/ci.env" -f compose.yaml config --format json ) > "$WORK/compose.json" || { echo "compose.yaml did not resolve"; exit 1; }
IMAGE="${PG_IMAGE:-$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["services"]["health-db-init"]["image"])' "$WORK/compose.json")}"
# The one-shot's script and settings, as compose has them ($$ is compose's escape for $).
svc() { python3 -I -c 'import json,sys; s=json.load(open(sys.argv[1]))["services"][sys.argv[2]]; print(s["entrypoint"][2].replace("$$","$") if sys.argv[3]=="script" else s["environment"][sys.argv[3]])' "$WORK/compose.json" "$1" "$2"; }
svc health-db-init script > "$WORK/init.sh"
APP_COLS="$(svc health-db-init HEALTH_COLUMNS)"
AK_COLS="$(svc ak-health-db-init HEALTH_COLUMNS)"
cmp -s "$WORK/init.sh" <(svc ak-health-db-init script) || { echo "the two one-shots don't run the same script"; exit 1; }

mkdir -p "$WORK/secrets"; chmod 755 "$WORK/secrets"
ROLE_PW="fictitious$(od -An -tx1 -N12 /dev/urandom | tr -d ' \n')"
printf 'fictitious-superuser\n' > "$WORK/secrets/db_password"
printf '%s' "$ROLE_PW" > "$WORK/secrets/health_db_password"
chmod 644 "$WORK/secrets/"*

docker network create "$N" >/dev/null || exit 1
docker run -d --name "$PG" --network "$N" --network-alias postgres -e POSTGRES_USER=workforce_app -e POSTGRES_DB=workforce \
  -e POSTGRES_PASSWORD=fictitious-superuser "$IMAGE" >/dev/null || exit 1
for _ in $(seq 60); do docker exec "$PG" pg_isready -q -U workforce_app -d workforce 2>/dev/null && break; sleep 1; done
sleep 2   # the image's first start restarts the server once its init is done
for _ in $(seq 30); do docker exec "$PG" pg_isready -q -U workforce_app -d workforce 2>/dev/null && break; sleep 1; done
su_sql() { docker exec -i "$PG" psql -X -q -v ON_ERROR_STOP=1 -U workforce_app -d "$1" -tA; }
# Each statement on its own (a script on stdin), so `set default_transaction_read_only = off` holds for the next.
as_role() { docker exec -i "$PG" psql -X -q -v ON_ERROR_STOP=1 -U workforce_health -d "$1" -tA <<< "$2"; }

# The application's tables doctor.sh reads, with a column or two it must not (a relay password, a recipient).
su_sql workforce <<'SQL' || exit 1
CREATE TABLE flyway_schema_history (installed_rank int, version text, success boolean, script text);
INSERT INTO flyway_schema_history VALUES (1, '1', true, 'V1__a.sql'), (2, '161', true, 'V161__b.sql');
CREATE TABLE mail_setting (id int, enabled boolean, staff_domain text, last_sync_error text, relay_password text);
INSERT INTO mail_setting VALUES (1, true, 'staff.example.test', null, 'fictitious-relay');
CREATE TABLE mail_mailbox (id int, kind text, suspended_at timestamptz, sync_error text, address text);
CREATE TABLE notification_delivery (id int, state text, created_at timestamptz, sent_at timestamptz, error_message text, recipient text);
CREATE TABLE mail_event_feed (id int, last_at timestamptz);
INSERT INTO mail_event_feed VALUES (1, now());
SQL
su_sql postgres <<'SQL' || exit 1
CREATE DATABASE authentik;
SQL
su_sql authentik <<'SQL' || exit 1
CREATE TABLE authentik_core_user (id int, username text, email text, password text);
INSERT INTO authentik_core_user VALUES (1, 'admin', 'Admin@example.test', 'pbkdf2_sha256$fictitious');
CREATE TABLE authentik_core_application (name text, provider_id int);
INSERT INTO authentik_core_application VALUES ('Workforce', 1);
CREATE TABLE authentik_providers_oauth2_oauth2provider (provider_ptr_id int, signing_key_id uuid, client_secret text);
INSERT INTO authentik_providers_oauth2_oauth2provider VALUES (1, '00000000-0000-0000-0000-000000000001', 'fictitious-client-secret');
CREATE TABLE authentik_crypto_certificatekeypair (kp_uuid uuid, certificate_data text, key_data text);
INSERT INTO authentik_crypto_certificatekeypair VALUES ('00000000-0000-0000-0000-000000000001', 'fictitious-certificate', 'fictitious-private-key');
SQL

# init <database> <superuser secret> <columns> — the one-shot, as compose runs it: its user, read-only, no capability.
init() {
  docker run --rm --network "$N" --user 999:999 --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges \
    -v "$WORK/secrets:/run/secrets:ro" -e PGHOST=postgres -e PGDATABASE="$1" -e PGUSER=workforce_app -e SUPER_SECRET="$2" \
    -e HEALTH_COLUMNS="$3" -e HEALTH_DATABASES="workforce authentik" --entrypoint /bin/sh "$IMAGE" -c "$(cat "$WORK/init.sh")" 2>&1
}
out="$(init workforce db_password "$APP_COLS")"; check "the application database's one-shot" "$?:$out" "0:the health watch's database role is ready"
out="$(init authentik db_password "$AK_COLS")"; check "the sign-in database's one-shot" "$?:$out" "0:the health watch's database role is ready"

# What it is.
check "no superuser, no other power" "$(su_sql workforce <<< "select rolsuper, rolcreaterole, rolcreatedb, rolreplication, rolbypassrls, rolinherit, rolcanlogin from pg_roles where rolname = 'workforce_health'")" "f|f|f|f|f|f|t"
check "a member of nothing" "$(su_sql workforce <<< "select count(*) from pg_auth_members where member = 'workforce_health'::regrole")" 0
check "read-only sessions, with a time limit" "$(su_sql workforce <<< "select array_to_string(setconfig, ',') from pg_db_role_setting where setrole = 'workforce_health'::regrole")" "default_transaction_read_only=on,statement_timeout=60s"

# doctor.sh's queries (as controller/src/proxy/policy.mjs lists them) all run as it.
check "migrations" "$(as_role workforce "select coalesce((select version from flyway_schema_history where success and version is not null order by installed_rank desc limit 1),'none')")" 161
check "staff domains" "$(as_role workforce "select staff_domain from mail_setting where staff_domain is not null")" staff.example.test
check "a table that is there" "$(as_role workforce "select to_regclass('mail_mailbox') is not null")" t
check "mail sync" "$(as_role workforce "select (select count(*) from mail_setting where enabled) || '|' || (select count(*) from mail_setting where enabled and last_sync_error is not null) || '|' || (select count(*) from mail_mailbox where sync_error is not null) || '|' || (select count(*) from mail_mailbox where kind = 'BUILT_IN' and suspended_at is null) || '|' || (select count(*) from mail_mailbox where kind = 'BUILT_IN' and suspended_at is null and sync_error is not null)")" "1|0|0|0|0"
check "notifications" "$(as_role workforce "select count(*) filter (where state = 'FAILED' and created_at > now() - interval '24 hours' and coalesce(error_message, '') not like 'no deliverable address%' and coalesce(error_message, '') not like 'pre-#6 row%') || '|' || count(*) filter (where state = 'SENT' and sent_at > now() - interval '24 hours') || '|' || count(*) filter (where state = 'QUEUED' and created_at < now() - interval '1 hour') from notification_delivery")" "0|0|0"
check "the admin's address" "$(as_role authentik "select lower(email) from authentik_core_user where username = 'admin'")" admin@example.test
check "the sign-in certificate" "$(as_role authentik "SELECT c.certificate_data FROM authentik_core_application a JOIN authentik_providers_oauth2_oauth2provider p ON p.provider_ptr_id = a.provider_id JOIN authentik_crypto_certificatekeypair c ON c.kp_uuid = p.signing_key_id WHERE a.name = 'Workforce'")" fictitious-certificate

# What it can't do.
refused "COPY … TO PROGRAM" workforce "copy (select 1) to program 'id'"
refused "COPY … TO PROGRAM, read-only off" workforce "set default_transaction_read_only = off; copy (select 1) to program 'id'"
refused "a server file" workforce "select pg_read_file('/etc/passwd')"
refused "a write" workforce "set default_transaction_read_only = off; update mail_setting set enabled = false"
refused "an insert" workforce "set default_transaction_read_only = off; insert into flyway_schema_history (version) values ('x')"
refused "a table of its own" workforce "set default_transaction_read_only = off; create table mine (x int)"
refused "a role of its own" workforce "set default_transaction_read_only = off; create role mine"
refused "superuser for itself" workforce "set default_transaction_read_only = off; alter role workforce_health superuser"
refused "the relay password" workforce "select relay_password from mail_setting"
refused "a whole row" workforce "select * from mail_setting"
refused "a recipient" workforce "select recipient from notification_delivery"
refused "a password hash" authentik "select password from authentik_core_user"
refused "a private key" authentik "select key_data from authentik_crypto_certificatekeypair"
refused "a client secret" authentik "select client_secret from authentik_providers_oauth2_oauth2provider"

# Its password: a login over the network needs it.
net_login() { docker run --rm --network "$N" -e PGPASSWORD="$1" "$IMAGE" psql -X -h postgres -U workforce_health -d workforce -tAc 'select 1' 2>/dev/null; }
check "over the network with its password" "$(net_login "$ROLE_PW")" 1
check "not with another" "$(net_login wrong-password)" ""

# An install that already has it, changed by hand, with a table added since: the next start puts it right.
su_sql workforce <<'SQL' >/dev/null || exit 1
ALTER ROLE workforce_health SUPERUSER CREATEROLE VALID UNTIL '2000-01-01';
GRANT pg_execute_server_program, pg_write_server_files TO workforce_health;
GRANT INSERT, UPDATE ON mail_setting TO workforce_health;
GRANT SELECT ON mail_mailbox TO workforce_health;
-- By another grantor, which a plain REVOKE by the owner leaves: a privilege and a membership.
CREATE ROLE someone_else;
GRANT SELECT ON mail_setting TO someone_else WITH GRANT OPTION;
GRANT pg_read_server_files TO someone_else WITH ADMIN OPTION;
SET ROLE someone_else;
GRANT SELECT ON mail_setting TO workforce_health;
GRANT pg_read_server_files TO workforce_health;
RESET ROLE;
-- A role that would get its privileges, settings of its own, a schema privilege and a table it owns.
CREATE ROLE borrower IN ROLE workforce_health;
ALTER ROLE workforce_health SET default_transaction_read_only = off;
ALTER ROLE workforce_health IN DATABASE workforce SET statement_timeout = 0;
GRANT CREATE ON SCHEMA public TO workforce_health;
CREATE TABLE owned_by_it (x int);
ALTER TABLE owned_by_it OWNER TO workforce_health;
-- A function it owns that runs as its owner: it must be dropped, never handed to the superuser.
CREATE FUNCTION runs_as_owner() RETURNS int LANGUAGE sql SECURITY DEFINER AS 'select 1';
ALTER FUNCTION runs_as_owner() OWNER TO workforce_health;
-- A procedure, by another grantor (REVOKE … ON FUNCTION would fail on it).
CREATE PROCEDURE a_procedure() LANGUAGE sql AS 'select 1';
REVOKE ALL ON PROCEDURE a_procedure() FROM PUBLIC;
GRANT EXECUTE ON PROCEDURE a_procedure() TO someone_else WITH GRANT OPTION;
SET ROLE someone_else; GRANT EXECUTE ON PROCEDURE a_procedure() TO workforce_health; RESET ROLE;
CREATE TABLE mail_send_alert (address text, kind text, first_at timestamptz, body text);
SQL
# And in another database of the server, which this one-shot makes no grants in.
su_sql postgres <<'SQL' >/dev/null || exit 1
CREATE DATABASE elsewhere;
SQL
su_sql elsewhere <<'SQL' >/dev/null || exit 1
CREATE TABLE secrets_here (x text);
GRANT SELECT ON secrets_here TO workforce_health;
CREATE TABLE its_own (x int);
ALTER TABLE its_own OWNER TO workforce_health;
SQL
ROLE_PW="fictitious$(od -An -tx1 -N12 /dev/urandom | tr -d ' \n')"; printf '%s' "$ROLE_PW" > "$WORK/secrets/health_db_password"
out="$(init workforce db_password "$APP_COLS")"; check "again, on an existing install" "$?:$out" "0:the health watch's database role is ready"
check "again: no superuser" "$(su_sql workforce <<< "select rolsuper, rolcreaterole from pg_roles where rolname = 'workforce_health'")" "f|f"
check "again: a member of nothing, whoever granted it" "$(su_sql workforce <<< "select count(*) from pg_auth_members where member = 'workforce_health'::regrole")" 0
check "again: nobody a member of it" "$(su_sql workforce <<< "select count(*) from pg_auth_members where roleid = 'workforce_health'::regrole")" 0
check "again: its own settings only, in no database apart" "$(su_sql workforce <<< "select setdatabase, array_to_string(setconfig, ',') from pg_db_role_setting where setrole = 'workforce_health'::regrole")" "0|default_transaction_read_only=on,statement_timeout=60s"
check "again: no expiry" "$(su_sql workforce <<< "select coalesce(rolvaliduntil::text, 'none') from pg_roles where rolname = 'workforce_health'")" infinity
check "again: owns nothing" "$(su_sql workforce <<< "select count(*) from pg_class where relowner = 'workforce_health'::regrole")" 0
check "again: what it owned is gone, not the superuser's" "$(su_sql workforce <<< "select count(*) from pg_proc where proname = 'runs_as_owner'")" 0
check "again: owns no routine anywhere here" "$(su_sql workforce <<< "select count(*) from pg_proc where proowner = 'workforce_health'::regrole")" 0
refused "again: not another grantor's procedure" workforce "set default_transaction_read_only = off; call a_procedure()"
refused "again: nothing in another database either" elsewhere "select x from secrets_here"
check "again: owns nothing there" "$(su_sql elsewhere <<< "select count(*) from pg_class where relowner = 'workforce_health'::regrole")" 0
check "again: the sign-in database's columns kept" "$(as_role authentik "select lower(email) from authentik_core_user where username = 'admin'")" admin@example.test
refused "again: not another grantor's whole row" workforce "select * from mail_setting"
refused "again: no server files" workforce "select pg_read_file('/etc/passwd')"
refused "again: no table of its own" workforce "set default_transaction_read_only = off; create table mine (x int)"
refused "again: no write" workforce "set default_transaction_read_only = off; update mail_setting set enabled = false"
refused "again: no whole table" workforce "select * from mail_mailbox"
check "again: the new table's columns" "$(as_role workforce "select count(distinct address) from mail_send_alert where kind = 'LIMIT_REACHED' and first_at > now() - interval '24 hours'")" 0
refused "again: not its other columns" workforce "select body from mail_send_alert"
check "again: the new password" "$(net_login "$ROLE_PW")" 1
# And a third time, with nothing changed: the same, and no error.
out="$(init workforce db_password "$APP_COLS")"; check "a third time" "$?:$out" "0:the health watch's database role is ready"

echo "health-db-role e2e: ${PASS} passed, ${FAILN} failed"
[ "$FAILN" -eq 0 ]
