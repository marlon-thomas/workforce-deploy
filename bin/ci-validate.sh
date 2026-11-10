#!/usr/bin/env bash
# ci-validate.sh — static validation of the deploy apparatus. Run by
# .github/workflows/validate.yml on every push/PR; run it locally before
# pushing. Touches no host and starts no container.
#   1. bash -n on every shell script
#   2. python byte-compile of every python script (no __pycache__ written)
#   3. `docker compose config -q` for compose.yaml (+ each overlay) against a
#      placeholder env file — catches YAML/interpolation breakage at PR time,
#      not at an appliance's next converge
#   4. shellcheck -S error, when shellcheck is installed
#   5. the hermetic shell self-tests in bin/tests/ (no Docker, no network)
set -euo pipefail
cd "$(dirname "$0")/.."

RC=0
bad() { printf 'FAIL %s\n' "$*"; RC=1; }

echo "== bash -n"
for f in bin/*.sh bin/lib/*.sh bin/tests/*.sh; do
  [ -e "$f" ] || continue
  bash -n "$f" || bad "syntax: $f"
done

echo "== python compile"
for f in bin/*.py; do
  [ -e "$f" ] || continue
  python3 -I -c 'import sys; compile(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1], "exec")' "$f" \
    || bad "python: $f"
done

echo "== docker compose config"
if docker compose version >/dev/null 2>&1; then
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  # Placeholders only — every key compose interpolates without a default.
  cat > "$TMP/ci.env" <<'ENV'
APP_HOSTNAME=app.ci.invalid
AUTH_HOSTNAME=auth.ci.invalid
ACME_EMAIL=ci@ci.invalid
DB_NAME=workforce
DB_USER=workforce_app
MINIO_BUCKET=workforce-evidence
AK_DB_NAME=authentik
AK_DB_USER=authentik
OIDC_ISSUER=https://auth.ci.invalid/application/o/workforce/
API_IMAGE=ghcr.io/ci/placeholder
APP_VERSION=0.0.0
ENV
  # Workforce issue 53: every image pinned by digest, and each service's least privilege, as compose resolves them
  # with every profile on (bin/check-hardening.py says which service, and why).
  resolved=()
  for overlay in "" compose.smoke.yaml compose.dev.yaml; do
    out="$TMP/resolved${overlay:+-$overlay}.json"
    if docker compose --env-file "$TMP/ci.env" -f compose.yaml ${overlay:+-f "$overlay"} --profile '*' config --format json > "$out" 2>/dev/null; then
      resolved+=("$out")
    fi
  done
  if [ "${#resolved[@]}" -gt 0 ] && python3 -I bin/check-hardening.py "${resolved[@]}"; then
    echo "ok   images pinned by digest, least privilege per service"
  else
    bad "image pins or least privilege (bin/check-hardening.py, above)"
  fi
  for overlay in "" compose.smoke.yaml compose.dev.yaml; do
    label="compose.yaml${overlay:+ + $overlay}"
    if docker compose --env-file "$TMP/ci.env" -f compose.yaml ${overlay:+-f "$overlay"} config -q; then
      echo "ok   $label"
    else
      bad "compose config: $label"
    fi
  done
else
  bad "docker compose is not available — the compose check cannot be skipped"
fi

if command -v shellcheck >/dev/null 2>&1; then
  echo "== shellcheck -S error"
  shellcheck -S error -x bin/*.sh bin/lib/*.sh bin/tests/*.sh || bad "shellcheck"
else
  echo "== shellcheck not installed — skipped (CI runners have it)"
fi

echo "== self-tests"
for t in bin/tests/*-test.sh; do
  [ -e "$t" ] || continue
  if bash "$t"; then echo "ok   $t"; else bad "self-test: $t"; fi
done

[ "$RC" -eq 0 ] && echo "All deploy-apparatus checks passed." || echo "Validation FAILED."
exit "$RC"
