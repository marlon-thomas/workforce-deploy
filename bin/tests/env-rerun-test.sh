#!/usr/bin/env bash
# env-rerun-test.sh — hermetic self-test: running the installer again keeps what .env says (Workforce issues 376 and
# 387). The installer renders .env from env.j2 with what install.sh hands Ansible (its WFV_ lines). On a first install
# those come from environments/<env>.env; on a second run from .env itself. This renders a first install, changes
# settings the way bin/staff-mail.sh, Setup -> Email and a person editing .env do, runs the second render with
# install.sh's own WFV_ lines, and checks every setting reads back the same, with none lost or added.
#   ./bin/tests/env-rerun-test.sh      exit 0 = all pass
# Needs python3 with jinja2, which Ansible renders with; without it the test is SKIPPED. No Docker, no network.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"

if ! python3 -c 'import jinja2' 2>/dev/null; then
  echo "env rerun self-test: SKIPPED (no python3 jinja2)"
  exit 0
fi

PASS=0; FAILN=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAILN=$((FAILN+1)); printf 'FAIL: %s: expected [%s] got [%s]\n' "$1" "$3" "$2"; fi; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# install.sh's WFV_ lines as they are, made into exports, so the test uses the installer's own list.
sed -n '/^  WFV_app_hostname=/,/^  python3 -c/p' "$ROOT/bin/install.sh" | sed '$d' \
  | sed -e 's/^  /export /' -e 's/ \\$//' > "$TMP/wfv.sh"
lines="$(grep -c '^export WFV_' "$TMP/wfv.sh")"
[ "$lines" -ge 40 ] || { echo "FAIL: only ${lines} WFV_ lines found in bin/install.sh"; exit 1; }

# render OUT: env.j2 with the WFV_ values in this shell, as Ansible renders it (an unknown variable fails).
render() {
  python3 -I - "$ROOT/ansible/roles/workforce/templates/env.j2" "$1" <<'PY'
import os, shlex, sys
import jinja2
src, out = sys.argv[1:3]
env = jinja2.Environment(undefined=jinja2.StrictUndefined, keep_trailing_newline=True)
env.filters["quote"] = lambda v: shlex.quote(str(v))
values = {k[4:]: v for k, v in os.environ.items() if k.startswith("WFV_")}
with open(out, "w", encoding="utf-8") as f:
    f.write(env.from_string(open(src, encoding="utf-8").read()).render(**values))
PY
}

# --- a first install: the installer's answers and the environment file
(
  set +u
  APP_HOSTNAME=workforce.carehome.example.test AUTH_HOSTNAME=auth.carehome.example.test ENV_NAME=ci
  ACME_EMAIL=ops@elsewhere.example APP_VERSION=0.2.129 GW_IMAGE=caddy:2.8.4 GW_CADDYFILE=./gateway/Caddyfile
  ANSIBLE_SOCK=/run/user/1001/docker.sock RECOVERING=0 AI_PROVIDER=ANTHROPIC AI_MODEL=fictional-model
  . "$TMP/wfv.sh"
  render "$TMP/.env"
) || { echo "FAIL: the first render"; exit 1; }
check "first install: the environment file's AI service reaches .env" "$(env_get AI_PROVIDER "$TMP/.env")" ANTHROPIC
check "first install: no staff email" "$(env_get MAIL_SERVER_URL "$TMP/.env")" ""
check "first install: feedback is named after the environment" "$(env_get FEEDBACK_INSTALLATION "$TMP/.env")" ci

# --- settings changed afterwards, the way each tool writes them
set_all() { while [ $# -ge 2 ]; do env_set "$1" "$2" "$TMP/.env" || { echo "FAIL: env_set $1"; exit 1; }; shift 2; done; }
# ./bin/staff-mail.sh, switching staff email on
set_all WEBMAIL_HOSTNAME webmail.carehome.example.test WEBMAIL_URL https://webmail.carehome.example.test \
  MAIL_HOSTNAME mail.carehome.example.test MAIL_SERVER_URL http://mail:8080 MAIL_RELAY_HOST smtp.relay.example \
  MAIL_RELAY_PORT 465 MAIL_RELAY_USER relay-user@carehome.example.test MAIL_RELAY_IMPLICIT_TLS true \
  MAIL_RELAY_SPF_INCLUDE spf.relay.example MAIL_TLS_VERIFY false MAIL_SIGN_IN_ALLOW_INVALID_CERTS true \
  COMPOSE_PROFILES staffmail
# Setup -> Email (bin/server-actions.sh), with the password quoted as it stores it
set_all SMTP_HOST smtp.relay.example SMTP_PORT 465 SMTP_USERNAME relay-user@carehome.example.test \
  SMTP_PASSWORD "$(env_single_quote 'fictional pass word')" SMTP_STARTTLS false SMTP_FROM workforce@carehome.example.test
# by hand, as the README says (reports from inside the app, the AI service, alerts)
set_all FEEDBACK_INSTALLATION riverside FEEDBACK_GITHUB_REPO example-org/feedback FEEDBACK_GITHUB_APP_ID 12345 \
  FEEDBACK_GITHUB_INSTALLATION_ID 67890 FEEDBACK_ENGINEER_LOGIN fictional-engineer \
  AI_PROVIDER OPENAI_COMPATIBLE AI_ENDPOINT http://ai-box.lan:8000/v1 AI_MODEL "'fictional model 7b'" AI_REGION uksouth \
  AI_LOCKED true AI_ALLOWED_PROVIDERS ANTHROPIC,OPENAI_COMPATIBLE AI_TRUSTED_ENDPOINTS 10.0.0.0/8,ai-box.lan \
  OPS_ALERT_EMAIL ops@elsewhere.example OPS_HEARTBEAT_URL "'https://ping.example/abc'" \
  ADMIN_RECOVERY_EMAIL recovery@elsewhere.example WORKFORCE_SERVER_HEALTH_VISIBLE false SERVER_ACTIONS off

# --- the installer runs again: the environment file, then .env (which wins), then its gateway fallbacks
(
  set +u
  cd "$TMP" || exit 1
  # shellcheck disable=SC1091
  . "$ROOT/environments/test.env"
  # shellcheck disable=SC1091
  . ./.env
  RECOVERING=0 GW_CADDYFILE="${GATEWAY_CADDYFILE:-}" GW_IMAGE="${GATEWAY_IMAGE:-}" ANSIBLE_SOCK="${DOCKER_SOCK}"
  . "$TMP/wfv.sh"
  render "$TMP/again.env"
) || { echo "FAIL: the second render"; exit 1; }

keys() { grep -oE '^[A-Z_][A-Z0-9_]*=' "$1" | tr -d = | sort | tr '\n' ' '; }
check "the same settings, none lost or added" "$(keys "$TMP/again.env")" "$(keys "$TMP/.env")"
# Read back as the tools read .env (env_get) and as bash and compose do (sourced).
sourced() { ( set +u; . "$1" >/dev/null 2>&1; printf '%s' "${!2}" ); }
for k in $(keys "$TMP/.env"); do
  check "$k kept (as the tools read it)" "$(env_get "$k" "$TMP/again.env")" "$(env_get "$k" "$TMP/.env")"
  check "$k kept (as bash reads it)" "$(sourced "$TMP/again.env" "$k")" "$(sourced "$TMP/.env" "$k")"
done
check "staff email still on" "$(sourced "$TMP/again.env" MAIL_SERVER_URL)" http://mail:8080
check "feedback still filed" "$(sourced "$TMP/again.env" FEEDBACK_GITHUB_APP_ID)" 12345
check "a model with spaces survives" "$(sourced "$TMP/again.env" AI_MODEL)" "fictional model 7b"

# Second review of the controller bundle, findings 5 and 7: an old .env's SIGNIN_SMTP_STARTTLS=false with no sign-in
# route was only the old default. The installer reads it as true, and update.sh sets it to true; next to a route it
# is kept (the test appliance's mail catcher has one).
again_with() { # again_with OUT HOST STARTTLS — the installer's second run, with that sign-in route in .env
  (
    set +u
    cd "$TMP" || exit 1
    . ./again.env
    SIGNIN_SMTP_HOST="$2" SIGNIN_SMTP_STARTTLS="$3"
    RECOVERING=0 GW_CADDYFILE="${GATEWAY_CADDYFILE:-}" GW_IMAGE="${GATEWAY_IMAGE:-}" ANSIBLE_SOCK="${DOCKER_SOCK}"
    . "$TMP/wfv.sh"
    render "$1"
  ) || { echo "FAIL: the render for $2/$3"; exit 1; }
}
again_with "$TMP/old.env" "" false
check "the installer reads an old default false, with no route, as true" "$(env_get SIGNIN_SMTP_STARTTLS "$TMP/old.env")" true
again_with "$TMP/route.env" mailpit false
check "the installer keeps a route's own false (the test appliance's mail catcher)" "$(env_get SIGNIN_SMTP_STARTTLS "$TMP/route.env")" false
printf 'SMTP_HOST=smtp.relay.example\nSIGNIN_SMTP_HOST=\nSIGNIN_SMTP_STARTTLS=false\n' > "$TMP/old-default.env"
signin_starttls_old_default "$TMP/old-default.env"; check "update.sh's fix: it changed" "$?" 0
check "update.sh's fix: true now" "$(env_get SIGNIN_SMTP_STARTTLS "$TMP/old-default.env")" true
check "update.sh's fix: nothing else touched" "$(grep -c . "$TMP/old-default.env")" 3
signin_starttls_old_default "$TMP/old-default.env"; check "update.sh's fix: once only" "$?" 1
printf 'SIGNIN_SMTP_HOST=relay.example\nSIGNIN_SMTP_STARTTLS=false\n' > "$TMP/chosen.env"
signin_starttls_old_default "$TMP/chosen.env"; check "update.sh's fix: a false next to a route is kept" "$(env_get SIGNIN_SMTP_STARTTLS "$TMP/chosen.env")" false
check "update.sh runs it" "$(grep -c '^if signin_starttls_old_default .env; then' "$ROOT/bin/update.sh")" 1

echo "env rerun self-test: ${PASS} passed, ${FAILN} failed"
[ "$FAILN" -eq 0 ]
