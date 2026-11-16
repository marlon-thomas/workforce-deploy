#!/usr/bin/env bash
# Self-test for lock_wait (bin/lib/common.sh): backup.sh --tag waits up to an hour for another backup's lock. Busybox's
# flock (the controller image, whose backup job runs `backup.sh --tag pre-update` as every update's first step) has
# no -w, so `flock -w` failed there at once and every update stopped at its backup. Hermetic: temp files only.
#   ./bin/tests/lock-wait-test.sh      exit 0 = all pass
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
command -v flock >/dev/null 2>&1 || { echo "lock wait self-test: no flock here, skipped"; exit 0; }
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS=0; FAILN=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAILN=$((FAILN+1)); printf 'FAIL: %s: expected [%s] got [%s]\n' "$1" "$3" "$2"; fi; }
L="$WORK/.backup.lock"
# hold <seconds> — another backup holding the lock that long (started once it has it).
hold() { ( exec 9>>"$L"; flock -n 9 || exit 1; : > "$WORK/held"; sleep "$1" ) & while [ ! -e "$WORK/held" ]; do sleep 0.1; done; rm -f "$WORK/held"; }

exec 8>>"$L"
check "free: taken at once" "$(lock_wait 8 0 && echo taken)" taken
flock -u 8
hold 4; HOLDER=$!
check "held longer than the wait: 1" "$(lock_wait 8 1; echo $?)" 1
check "let go during the wait: taken" "$(lock_wait 8 10 && echo taken)" taken
wait "$HOLDER" 2>/dev/null
check "no -w in the backup's lock" "$(grep -c 'flock -w' "$HERE/../backup.sh")" 0

echo "lock wait self-test: ${PASS} passed, ${FAILN} failed"
[ "$FAILN" -eq 0 ]
