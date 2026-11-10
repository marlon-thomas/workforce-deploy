#!/usr/bin/env bash
# ci-validate.sh — static validation of the deploy apparatus. Run by
# .github/workflows/validate.yml on every push/PR; run it locally before
# pushing. Touches no host and starts no container.
#   1. bash -n on every shell script
#   2. python byte-compile of every python script (no __pycache__ written)
#   3. `docker compose config -q` for compose.yaml (+ each overlay) against a
#      placeholder env file — catches YAML/interpolation breakage at PR time,
#      not at an appliance's next converge
#   4. settings reach the app: every variable compose.yaml reads is written
#      into .env by env.j2, and every value env.j2 writes is passed in by
#      install.sh (Workforce issue 376)
#   5. shellcheck -S error, when shellcheck is installed
#   6. the hermetic shell self-tests in bin/tests/ (no Docker, no network)
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

echo "== settings reach the app"
# compose.yaml reads its settings from .env. The installer renders .env from env.j2, with the values
# install.sh hands Ansible as WFV_*: from environments/<env>.env on a first install, and from .env
# itself when it runs again. A setting missing from either step arrives empty, and a value set in
# .env is lost the next time the installer runs (Workforce issue 376: the AI settings).
if python3 -I - <<'PY'; then echo "ok   compose.yaml <- env.j2 <- install.sh"; else bad "settings wiring (see above)"; fi
import re
import sys

compose = open("compose.yaml", encoding="utf-8").read()
env_j2 = open("ansible/roles/workforce/templates/env.j2", encoding="utf-8").read()
install = open("bin/install.sh", encoding="utf-8").read()

# ${VAR...} is read from .env; $${VAR} is the container's own shell, not compose's.
read = set(re.findall(r"(?<!\$)\$\{([A-Z_][A-Z0-9_]*)", compose))
written = set(re.findall(r"(?m)^([A-Z_][A-Z0-9_]*)=", env_j2))
inputs = set(re.findall(r"\{\{\s*([a-z_][a-z0-9_]*)", env_j2))
passed = set(re.findall(r"\bWFV_([a-z0-9_]+)=", install))

# Known gaps, written into .env by other tools or by hand, and lost when the installer runs again:
# Workforce issue 387. Remove each one here when it is wired through.
NOT_WRITTEN_YET = {
    "MAIL_HOSTNAME", "MAIL_SERVER_URL", "MAIL_TLS_VERIFY", "MAIL_SIGN_IN_ALLOW_INVALID_CERTS",
    "MAIL_RELAY_HOST", "MAIL_RELAY_PORT", "MAIL_RELAY_USER", "MAIL_RELAY_IMPLICIT_TLS",
    "MAIL_RELAY_SPF_INCLUDE", "WEBMAIL_HOSTNAME", "WEBMAIL_URL",
}
NOT_PASSED_YET = {
    "feedback_installation", "feedback_github_repo", "feedback_github_app_id",
    "feedback_github_installation_id", "feedback_engineer_login",
}

failed = False
for name in sorted(read - written - NOT_WRITTEN_YET):
    print(f"FAIL compose.yaml reads ${{{name}}}, which env.j2 never writes into .env")
    failed = True
for name in sorted(inputs - passed - NOT_PASSED_YET):
    print(f"FAIL env.j2 writes {{{{ {name} }}}}, which install.sh never passes in (no WFV_{name})")
    failed = True
for name in sorted(NOT_WRITTEN_YET & written):
    print(f"FAIL {name} is written by env.j2 now: take it out of NOT_WRITTEN_YET")
    failed = True
for name in sorted(NOT_PASSED_YET & passed):
    print(f"FAIL WFV_{name} is passed now: take it out of NOT_PASSED_YET")
    failed = True
sys.exit(1 if failed else 0)
PY

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
