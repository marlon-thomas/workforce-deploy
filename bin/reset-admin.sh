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

[ -f .env ] || { echo "No .env here. Run ./bin/install.sh first."; exit 1; }
# shellcheck disable=SC1091
. ./.env

# Docker daemon selection (rootless-aware) lives in ONE place: bin/lib/common.sh.
# shellcheck source=lib/common.sh
. ./bin/lib/common.sh
use_docker_socket

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
# `python` as the image's PATH finds it (its venv): a fixed path broke when authentik moved its
# venv (second review of the controller bundle, finding 2). bin/tests/authentik-policies-e2e.sh runs this
# program on the pinned authentik.
RESULT="$(docker compose exec -T -e WF_NEW_PW="$NEW_PW" authentik-server sh -c \
  'cd / && python - <<PYEOF
import os, sys
sys.path.insert(0, "/authentik")
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "authentik.root.settings")
import django
django.setup()
import uuid
from datetime import timedelta
from django.utils import timezone
from authentik.core.models import User
from authentik.events.models import Event
u = User.objects.get(username="admin")
u.set_password(os.environ["WF_NEW_PW"])
wf = dict((u.attributes or {}).get("workforce") or {})
wf.pop("password_unlocked_at", None)
u.attributes = dict(u.attributes or {}, workforce=wf)
u.save()
# Workforce issue 462 (contract R.7.4): wrong passwords before this moment no longer count, on every source: the same
# unlock record an "Unlock sign-in" in Workforce makes for staff (by this server's clock, never an attribute). The new
# password moves the marker too. Source and network holds are untouched.
t = timezone.now()
e = Event.new("workforce_password_unlock", app="workforce", wf_unlock_id=str(uuid.uuid4()), wf_user_pk=u.pk,
              wf_at=t.strftime("%Y-%m-%dT%H:%M:%S.%fZ"), wf_was_paused=False)
e.expires = t + timedelta(days=31)
e.user = {"pk": u.pk, "username": u.username}
e.save()
# Workforce ADR-0039 §5: an authenticator app added to the emergency administrator is required once added, and this
# server step is the only way to remove it (a lost phone mustn't lose the last-resort account).
from authentik.stages.authenticator_totp.models import TOTPDevice
TOTPDevice.objects.filter(user=u).delete()
print("OK")
PYEOF' 2>&1 | tail -1)"

[ "$RESULT" = "OK" ] || { echo "Reset failed — send ./bin/doctor.sh output to support."; exit 1; }

cat <<EOF

Done. Any authenticator app on the account has been removed too (add one again from
Workforce if you want it), and any pause after wrong passwords lifted. The administrator
password is now:

  ${NEW_PW}

Shown once — store it in your password manager now. Sign in at
https://${AUTH_HOSTNAME} (user: admin).
EOF

# Same recoverable-record discipline as the installer (#15): the print above
# scrolls away; the file survives until deliberately removed.
mkdir -p secrets
printf '%s\n' "$NEW_PW" > secrets/initial-admin-password
chmod 400 secrets/initial-admin-password
echo 'Also saved to ./secrets/initial-admin-password — move it somewhere safe, then delete the file.'
