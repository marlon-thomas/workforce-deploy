#!/usr/bin/env bash
# reset-admin.sh — set a new password for the first administrator
# (deployment-spec §B3). Used when the org's admin lost the password.
#
# Identity verification is procedural (support phone call): the script prints a
# one-time verification phrase; support confirms it on the phone, then the org
# re-runs with the phrase. Prevents trivially self-service resets without
# needing our infrastructure.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .env ] || { echo "No deploy/.env — run install.sh first."; exit 1; }
# shellcheck disable=SC1091
. ./.env

# Rootless-aware docker context: when run as root on a rootless install, talk to the
# service user's daemon socket (compose exec etc. need the right socket).
resolve_docker_context() {
  if [ "$(id -u)" -eq 0 ] && [ -S "/home/workforce_app_sa/.docker/run/docker.sock" ]; then
    export DOCKER_HOST="unix:///home/workforce_app_sa/.docker/run/docker.sock"
  fi
}
resolve_docker_context

if [ "$#" -lt 2 ] || [ "$1" != "--confirm" ] || [ -z "${2:-}" ]; then
  PHRASE="care-angels-$(openssl rand -hex 3)"
  cat <<EOF

Password reset — identity verification required.

This command sets a new password for the 'admin' account. To prevent
unauthorised resets it only works with a one-time phrase:

  1. Call support and ask for an administrator password reset.
  2. Read them this verification phrase: ${PHRASE}
  3. If support confirms your identity, run:

       ./bin/reset-admin.sh --confirm ${PHRASE}

EOF
  exit 0
fi

PHRASE="$2"
case "$PHRASE" in
  care-angels-*) : ;;
  *) echo "The phrase must look like care-angels-xxxxxx — run without arguments to obtain one."; exit 1 ;;
esac

NEW_PW="$(openssl rand -base64 18)"
echo "Setting a new administrator password…"
RESULT="$(docker compose exec -T -e WF_NEW_PW="$NEW_PW" authentik-server sh -c \
  'cd / && /ak-root/venv/bin/python - <<PYEOF
import os, sys
sys.path.insert(0, "/authentik")
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "authentik.root.settings")
import django
django.setup()
from authentik.core.models import User
u = User.objects.get(username="admin")
u.set_password(os.environ["WF_NEW_PW"])
u.save()
print("OK")
PYEOF' 2>&1 | tail -1)"

[ "$RESULT" = "OK" ] || { echo "Reset failed — send ./bin/doctor.sh output to support."; exit 1; }

cat <<EOF

Done. The administrator password is now:

  ${NEW_PW}

Shown once — store it in your password manager now. Sign in at
https://${AUTH_HOSTNAME} (user: admin).
EOF
