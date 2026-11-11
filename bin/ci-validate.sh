#!/usr/bin/env bash
# ci-validate.sh — static validation of the deploy apparatus. Run by
# .github/workflows/validate.yml on every push/PR; run it locally before
# pushing. Touches no host and starts no container.
#   1. bash -n on every shell script
#   2. python byte-compile of every python script (no __pycache__ written)
#   3. `docker compose config -q` for compose.yaml (+ each overlay) against a
#      placeholder env file — catches YAML/interpolation breakage at PR time,
#      not at an appliance's next converge; and bin/check-docreader.py on the
#      resolved file (the docreader's isolation, the api's /tmp size and init)
#   4. settings reach the app: every variable compose.yaml reads is written
#      into .env by env.j2, and every value env.j2 writes is passed in by
#      install.sh (Workforce issue 376)
#   5. shellcheck -S error, when shellcheck is installed
#   6. the release key: cosign.pub, once committed, is one public key, and no private key is
#      tracked anywhere (Workforce issues 353 and 422)
#   7. the hermetic shell self-tests in bin/tests/ (no Docker, no network)
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
  # Workforce ADR-0042 and issue 333: the docreader's isolation and the api's /tmp and init, as compose resolves them.
  if docker compose --env-file "$TMP/ci.env" -f compose.yaml config --format json > "$TMP/compose.json" \
     && python3 -I bin/check-docreader.py "$TMP/compose.json"; then
    echo "ok   docreader isolation and api tmpfs/init"
  else
    bad "docreader isolation or api tmpfs/init"
  fi
  # Workforce ADR-0032 §2: the suite as the appliance controller runs it. No host path, no file secret and no Docker
  # socket; each service only its own folder of the controller's volume, read-only.
  # Every profile the controller can switch on: all of them except the one only today's host layout uses.
  ctl_profiles="$(docker compose --env-file "$TMP/ci.env" -f compose.yaml -f compose.controller.yaml config --profiles | grep -vx host-layout-only | paste -sd, -)"
  if COMPOSE_PROFILES="$ctl_profiles" docker compose --env-file "$TMP/ci.env" -f compose.yaml -f compose.controller.yaml config --format json > "$TMP/controller.json" \
     && python3 -I bin/check-controller-compose.py "$TMP/controller.json"; then
    echo "ok   compose.controller.yaml: no host path, file secret or socket; each service its own folder"
  else
    bad "compose.controller.yaml (bin/check-controller-compose.py, above)"
  fi
  # Workforce issue 422: with APP_DIGEST in .env (install.sh and update.sh write it once the release key's
  # signature checks out), every service of the suite image runs that digest.
  { cat "$TMP/ci.env"; echo "APP_DIGEST=sha256:$(printf '%064d' 0 | tr 0 a)"; } > "$TMP/ci-digest.env"
  if docker compose --env-file "$TMP/ci-digest.env" -f compose.yaml --profile '*' config --format json > "$TMP/digest.json" \
     && python3 -I - "$TMP/digest.json" <<'PY'; then echo "ok   the suite image runs by APP_DIGEST"; else bad "the suite image doesn't run by APP_DIGEST"; fi
import json
import sys

want = "ghcr.io/ci/placeholder:0.0.0@sha256:" + "a" * 64
services = json.load(open(sys.argv[1], encoding="utf-8"))["services"]
suite = {name: s.get("image") for name, s in services.items() if str(s.get("image", "")).startswith("ghcr.io/ci/placeholder")}
wrong = {name: image for name, image in suite.items() if image != want}
for name, image in sorted(wrong.items()):
    print(f"FAIL {name} runs {image}, not {want}")
sys.exit(1 if wrong or not suite else 0)
PY
else
  bad "docker compose is not available — the compose check cannot be skipped"
fi

echo "== settings reach the app"
# compose.yaml reads its settings from .env. The installer renders .env from env.j2, with the values
# install.sh hands Ansible as WFV_*: from environments/<env>.env on a first install, and from .env
# itself when it runs again. A setting missing from either step arrives empty, and a value set in
# .env is lost the next time the installer runs (Workforce issues 376 and 387: the AI, staff email
# and feedback settings). bin/tests/env-rerun-test.sh checks the second run itself.
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

# Written into .env by a script of their own, not by env.j2: bin/test-inbox.sh sets these on the TEST
# appliance only, and deploy_to_test.py runs it on every deploy (prod-guards keep them out of production).
outside_env_j2 = {"TEST_INBOX_HOSTNAME", "TEST_INBOX_HASH"}

failed = False
for name in sorted(read - written - outside_env_j2):
    print(f"FAIL compose.yaml reads ${{{name}}}, which env.j2 never writes into .env")
    failed = True
for name in sorted(inputs - passed):
    print(f"FAIL env.j2 writes {{{{ {name} }}}}, which install.sh never passes in (no WFV_{name})")
    failed = True
sys.exit(1 if failed else 0)
PY

if command -v shellcheck >/dev/null 2>&1; then
  echo "== shellcheck -S error"
  shellcheck -S error -x bin/*.sh bin/lib/*.sh bin/tests/*.sh || bad "shellcheck"
else
  echo "== shellcheck not installed — skipped (CI runners have it)"
fi

echo "== the release key"
# install.sh and update.sh use a Workforce image only by the digest the key behind cosign.pub signed
# (bin/lib/signatures.sh). Until the owner makes the key (Workforce issue 353) there is no cosign.pub,
# and the scripts refuse every image; that is expected here, not a failure.
if [ -e cosign.pub ]; then
  # shellcheck source=lib/signatures.sh
  KEY_PROBLEM="$(. bin/lib/signatures.sh && release_key_problem)"
  if [ -n "$KEY_PROBLEM" ]; then bad "cosign.pub: $KEY_PROBLEM"; else echo "ok   cosign.pub is one public key"; fi
else
  echo "ok   no cosign.pub yet (Workforce issue 353): every Workforce image is refused until it is committed"
fi
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  PRIVATE_KEYS="$(git grep -lE -- '-----BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY-----' -- . 2>/dev/null | grep -v '^bin/ci-validate.sh$' || true)"
  if [ -n "$PRIVATE_KEYS" ]; then bad "a private key is tracked: $PRIVATE_KEYS"; else echo "ok   no private key tracked"; fi
fi

echo "== test-only things stay out of production"
# shellcheck source=lib/prod-guards.sh
. bin/lib/prod-guards.sh
for f in environments/*.env; do
  [ "$(basename "$f")" = test.env ] && continue
  out="$(prod_guard_env_file "$f")" || bad "$out"
done
for f in gateway/Caddyfile*; do
  [ "$f" = gateway/Caddyfile.localca ] && continue
  out="$(prod_guard_caddyfile "$f")" || bad "$out"
done
[ "$RC" -ne 0 ] || echo "ok   no test inbox, mailpit or plain relay outside the TEST appliance"

echo "== self-tests"
for t in bin/tests/*-test.sh; do
  [ -e "$t" ] || continue
  if bash "$t"; then echo "ok   $t"; else bad "self-test: $t"; fi
done

[ "$RC" -eq 0 ] && echo "All deploy-apparatus checks passed." || echo "Validation FAILED."
exit "$RC"
