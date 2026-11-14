#!/usr/bin/env bash
# Self-test for the sign-in server's wrong-password pause, connection throttle, alerts and wrong-code count (Workforce
# issue 462): the decision, against the vectors the application shares. Hermetic: python3 only.
#   ./bin/tests/password-pause-test.sh      exit 0 = all pass
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
exec python3 -I -B "$HERE/password-pause-test.py"
