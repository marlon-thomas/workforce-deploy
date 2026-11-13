#!/usr/bin/env bash
# Self-test for the scripts under the appliance controller (Workforce ADR-0032, slice 2c): a helper container
# gets the project's one-off labels and a project network there, and nothing extra on today's host layout;
# the ADR-0031 helper hands no folder to anyone there; the branding copy doesn't use `compose cp` there.
# Hermetic: no Docker, no network.
#   ./bin/tests/controller-mode-test.sh      exit 0 = all pass
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"

PASS=0; FAILN=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAILN=$((FAILN+1)); printf 'FAIL: %s: expected [%s] got [%s]\n' "$1" "$3" "$2"; fi; }

unset WORKFORCE_CONTROLLER
helper_args workforce-deploy_back
check "host layout: no extra arguments" "${#HELPER[@]}" 0

export WORKFORCE_CONTROLLER=1 COMPOSE_PROJECT_NAME=workforce-deploy
helper_args workforce-deploy_back
check "controller: labels and network" "${HELPER[*]}" "--label com.docker.compose.project=workforce-deploy --label com.docker.compose.oneoff=True --network workforce-deploy_back"
helper_args none
check "controller: no network" "${HELPER[*]: -1}" "none"

# The ADR-0031 helper, under the controller, chowns nothing and needs the mailbox the controller made.
grep -q 'if \[ "${WORKFORCE_CONTROLLER:-}" = 1 \]; then' "$HERE/../server-actions.sh"; check "server-actions: a controller branch in ensure_mailbox" "$?" 0
# Every `docker run` in the backup's off-site copy passes the helper arguments; the branding copy, the one
# with no network, says its labels itself.
runs="$(grep -c 'docker run --rm' "$HERE/../backup.sh")"
with="$(grep -c 'docker run --rm[ -i]* "${HELPER\[@\]}"' "$HERE/../backup.sh")"
check "backup.sh: every docker run but the branding copy's has the helper arguments" "$with" "$((runs - 1))"
grep -q -- '--label com.docker.compose.oneoff=True --network none --log-driver none' "$HERE/../backup.sh"
check "backup.sh: the branding copy is a one-off with no network, whose output Docker doesn't keep" "$?" 0
# Nothing runs commands in the api under the controller (Workforce PR 438): the branding comes from its volume.
! grep -q 'exec -T api' "$HERE/../backup.sh"; check "backup.sh: nothing exec'd in the api" "$?" 0
grep -q 'source=${COMPOSE_PROJECT_NAME}_app_data,target=/d,readonly' "$HERE/../backup.sh"; check "backup.sh: the branding read from the api's volume, read-only" "$?" 0

# Workforce issue 447: under the controller doctor.sh's psql runs as the health watch's read-only role, its password
# in the environment only; on today's host layout as the database's own user, as before.
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/secrets"; printf 'fictitious-role-password\n' > "$WORK/secrets/health_db_password"
(
  cd "$WORK" || exit 1
  DB_USER=workforce_app; AK_DB_USER=authentik
  unset WORKFORCE_CONTROLLER PGPASSWORD; health_db_client
  check "host layout: psql as the database's user" "$PSQL_DB_USER $PSQL_AK_USER ${#PSQL_ENV[@]} ${PGPASSWORD:-none}" "workforce_app authentik 0 none"
  export WORKFORCE_CONTROLLER=1; health_db_client
  check "controller: psql as the health role" "$PSQL_DB_USER $PSQL_AK_USER" "workforce_health workforce_health"
  check "controller: the password by name only" "${PSQL_ENV[*]}" "-e PGPASSWORD"
  check "controller: the password from its secret" "$PGPASSWORD" "fictitious-role-password"
  rm secrets/health_db_password; health_db_client
  check "controller: no secret, no -e" "${#PSQL_ENV[@]}" 0
  echo "$PASS $FAILN" > "$WORK/counts"
)
read -r PASS FAILN < "$WORK/counts"
# Every psql doctor.sh (and common.sh's signing-key check) runs takes its user from health_db_client.
check "doctor.sh: no psql as a fixed user" "$(grep -c 'psql[^|]*-U "\${DB_USER\|psql[^|]*-U "\${AK_DB_USER' "$HERE/../doctor.sh")" 0
check "doctor.sh: each psql as PSQL_DB_USER or PSQL_AK_USER" "$(grep -c 'psql.*-U "\${PSQL_\(DB\|AK\)_USER}"' "$HERE/../doctor.sh")" 4
grep -q 'psql -X -U "${PSQL_AK_USER:-${AK_DB_USER:-authentik}}"' "$HERE/../lib/common.sh"; check "common.sh: the signing-key check too" "$?" 0

# The backup's status for the health watch: written by backup.sh under the controller, read back by common.sh.
eval "$(sed -n '/^backup_status_write() {/,/^}/p; /^backup_status_offsite() {/,/^}/p' "$HERE/../backup.sh")"
(
  cd "$WORK" || exit 1
  umask 077
  mkdir -p backups backup-status; : > backups/a.tar.gz; : > backups/b.tar.gz
  export WORKFORCE_CONTROLLER=1
  BACKUP_STATUS_FILE=backup-status/last.json
  BS_LAST_EPOCH=1700000000; BS_SIZE=4096; BS_ARCHIVE=2023-11-14_221320.tar.gz; BS_OFFSITE=UNKNOWN; BS_OFFSITE_EPOCH=""
  backup_status_write >/dev/null
  check "status: written 0644" "$(stat -c %a backup-status/last.json)" 644
  check "status: no temporary file left" "$(find backup-status -name '.*' | wc -l | tr -d ' ')" 0
  check "status: valid JSON, as described" "$(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["schema"], d["lastAt"], d["sizeBytes"], d["archive"], d["kept"], d["offsite"])' backup-status/last.json)" \
    "1 2023-11-14T22:13:20Z 4096 2023-11-14_221320.tar.gz 2 {'lastCopy': 'UNKNOWN', 'at': None, 'atEpoch': None}"
  BS_LAST_EPOCH=""; BS_SIZE=""; backup_status_read
  check "status: read back" "$BS_LAST_EPOCH $BS_SIZE $BS_ARCHIVE $BS_KEPT $BS_OFFSITE" "1700000000 4096 2023-11-14_221320.tar.gz 2 UNKNOWN"
  backup_status_offsite 1 >/dev/null; backup_status_read
  check "status: a failed off-site copy keeps the archive's" "$BS_OFFSITE $BS_LAST_EPOCH" "FAILED 1700000000"
  case "$BS_OFFSITE_EPOCH" in ''|*[!0-9]*) check "status: off-site time" "$BS_OFFSITE_EPOCH" "a number" ;; *) check "status: off-site time" ok ok ;; esac
  backup_status_offsite 0 >/dev/null; backup_status_read
  check "status: then a good one" "$BS_OFFSITE" OK
  BS_ARCHIVE='bad name"},"x":{'; backup_status_write >/dev/null
  check "status: an odd archive name is left out, the file still JSON" "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["archive"])' backup-status/last.json)" None
  # Somewhere it can't write (the helper's runs): said, and nothing else stops.
  chmod 555 backup-status
  if [ ! -w backup-status ]; then
    out="$(backup_status_write)"; rc=$?
    check "status: unwritable is not an error" "$rc" 0
    case "$out" in *"could not be written"*) check "status: unwritable is said" ok ok ;; *) check "status: unwritable is said" "$out" "could not be written" ;; esac
  fi
  chmod 755 backup-status
  # Today's host layout: nothing written.
  rm -f backup-status/last.json; unset WORKFORCE_CONTROLLER; backup_status_write
  check "host layout: no status file" "$(ls backup-status | wc -l | tr -d ' ')" 0
  # What another job's file can't make the reader take: a link, or values not of backup.sh's shape.
  export WORKFORCE_CONTROLLER=1
  ln -s ../backups/a.tar.gz backup-status/last.json
  backup_status_read; check "status: a link is not read" "$?" 2
  rm -f backup-status/last.json
  backup_status_read; check "status: none at all" "$?" 1
  # Numbers as backup.sh writes them, and nothing else: no leading zero (bash reads 0999 as octal, JSON refuses
  # it), not too long, not empty.
  w() { printf '%s\n' "$1" > backup-status/last.json; backup_status_read; }
  w '{"schema":1,"lastAtEpoch":0999,"sizeBytes":007,"kept":0123,"offsite":{"lastCopy":"OK","atEpoch":0}}'
  check "status: leading zeros are not taken" "[$BS_LAST_EPOCH][$BS_SIZE][$BS_KEPT][$BS_OFFSITE_EPOCH]" "[][][][0]"
  w '{"schema":1,"lastAtEpoch":1700000000000000,"sizeBytes":9999999999999999,"kept":1234567,"offsite":{"lastCopy":"OK"}}'
  check "status: too long is not taken" "[$BS_LAST_EPOCH][$BS_SIZE][$BS_KEPT]" "[][][]"
  w '{"schema":1,"lastAtEpoch":,"sizeBytes":"","kept":null,"offsite":{"lastCopy":""}}'
  check "status: empty is not taken" "[$BS_LAST_EPOCH][$BS_SIZE][$BS_KEPT][$BS_OFFSITE]" "[][][][UNKNOWN]"
  w '{"schema":1,"lastAtEpoch":1700000000,"sizeBytes":0,"kept":0,"offsite":{"lastCopy":"OK"}}'
  check "status: plain numbers are" "[$BS_LAST_EPOCH][$BS_SIZE][$BS_KEPT]" "[1700000000][0][0]"
  # backup.sh replacing the file by a rename, again and again, while it is read: never "unreadable".
  w '{"schema":1,"lastAtEpoch":1700000000,"sizeBytes":1,"kept":1,"offsite":{"lastCopy":"OK"}}'
  ( for _ in $(seq 40); do
      printf '%s\n' '{"schema":1,"lastAtEpoch":1700000000,"sizeBytes":1,"kept":1,"offsite":{"lastCopy":"OK"}}' > backup-status/.t
      mv -f backup-status/.t backup-status/last.json; sleep 0.05
    done ) &
  writer=$!
  unreadable=0
  for _ in $(seq 60); do backup_status_read || unreadable=$((unreadable + 1)); done
  wait "$writer"
  check "status: a rename meanwhile is read again, not unreadable" "$unreadable" 0
  # A pipe where the file should be (another job's folder: it could be swapped in at any moment): the read gives
  # up within seconds and says it couldn't read it, rather than hold the health watch until its time limit.
  rm -f backup-status/last.json
  if mkfifo backup-status/last.json 2>/dev/null; then
    t0="$(date +%s)"
    BACKUP_STATUS_FILE=backup-status/last.json
    # The check before the open passes for a pipe made after it; here the open itself meets the pipe.
    timeout 20 bash -c '. "$1"; export WORKFORCE_CONTROLLER=1; BACKUP_STATUS_FILE=backup-status/last.json
      backup_status_read; echo "rc=$?"' _ "$HERE/../lib/common.sh" > fifo.out 2>&1
    check "status: a pipe is not waited on" "$(cat fifo.out)" "rc=2"
    check "status: given up within seconds" "$( [ $(( $(date +%s) - t0 )) -le 10 ] && echo yes)" yes
    rm -f backup-status/last.json fifo.out
  fi
  echo "$PASS $FAILN" > "$WORK/counts"
)
read -r PASS FAILN < "$WORK/counts"

echo "controller-mode self-test: ${PASS} passed, ${FAILN} failed"
[ "$FAILN" -eq 0 ]
