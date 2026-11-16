#!/usr/bin/env bash
# The self-tests of what the appliance controller runs (doctor.sh's health job, healthwatch.sh, backup.sh,
# server-actions.sh and the libraries they read), on the controller's own base image: node:22-alpine, whose sed,
# grep, awk and flock are busybox on musl. GNU tools on a workstation hid two faults there: a regular-expression
# bound over 255 (client_address_read: every record read as "the server's own networks couldn't be read"), and
# `flock -w` (backup.sh --tag pre-update, every update's first step); found by the comparison of Workforce PRs 467
# and 499. Needs Docker and the network (apk adds the controller's own packages). Run by .github/workflows/validate.yml.
#   ./bin/tests/controller-busybox-e2e.sh      exit 0 = all pass
set -euo pipefail
cd "$(dirname "$0")/../.."
# The controller's base, at its pin (Workforce controller/Dockerfile).
IMAGE=node:22-alpine@sha256:0e1754758c2df4cfa3e68d59e2e1b7374bb7fd9ea6328eaaacf15cc934af8202
TESTS="client-address prod-guards lock-wait controller-mode env-file healthwatch server-actions backup-encrypt"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/run.sh" <<SH
set -e
# The controller image's packages (python3 only for the self-tests' own fakes).
apk add -q --no-progress openssl bash curl jq age rsync openssh-client tzdata python3 >/dev/null
for t in sed grep awk flock tr head date; do
  case "\$(readlink -f "\$(command -v "\$t")")" in /bin/busybox) ;; *) echo "FAIL \$t is not busybox here"; exit 1 ;; esac
done
rc=0
for t in $TESTS; do
  if bash "/w/bin/tests/\$t-test.sh" > "/tmp/\$t.log" 2>&1; then echo "ok   \$t (busybox)"
  else echo "FAIL \$t (busybox)"; grep -E 'FAIL|bad regex|unrecognized option|applet not found' "/tmp/\$t.log" | head -20; rc=1; fi
done
exit \$rc
SH
docker run --rm --entrypoint sh -v "$PWD:/w:ro" -v "$WORK:/s:ro" "$IMAGE" /s/run.sh
