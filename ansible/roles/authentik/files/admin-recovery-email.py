# ADR-0026 (Workforce): the emergency administrator's recovery address, converged inside authentik
# (`ak shell`). Reads {"mode": "read"|"write", "email": "<address>"} from stdin; prints one line
# "ADMIN_RECOVERY {json}" for the playbook.
#
# Two authentik accounts are involved:
#   admin   - the installer's Administrator, made by the Workforce blueprint. It signs in to
#             Workforce (the emergency administrator account) and is an ordinary internal user.
#   akadmin - authentik's own bootstrap superuser (authentik's system blueprint). It does not sign
#             in to Workforce; its email is replaced too so that no installer-default address that
#             nobody reads is left on an administrator account.
# read  -> their current emails, and how many OTHER accounts already use the address.
# write -> sets the address on both (idempotent: unchanged accounts are not saved).
import json
import sys

from authentik.core.models import User

SIGN_IN = "admin"
BOOTSTRAP = "akadmin"

request = json.loads(sys.stdin.read() or "{}")
email = (request.get("email") or "").strip()
mode = request.get("mode")


def account(username):
    return User.objects.filter(username=username).first()


admin = account(SIGN_IN)
bootstrap = account(BOOTSTRAP)

if mode == "read":
    others = 0
    if email:
        others = User.objects.filter(email__iexact=email).exclude(username__in=[SIGN_IN, BOOTSTRAP]).count()
    print("ADMIN_RECOVERY " + json.dumps({
        "admin": admin.email if admin else None,
        "akadmin": bootstrap.email if bootstrap else None,
        "others": others,
    }))
elif mode == "write":
    if "@" not in email:
        raise SystemExit("no recovery address given")
    changed = []
    for user in (admin, bootstrap):
        if user is not None and (user.email or "") != email:
            user.email = email
            user.save(update_fields=["email"])
            changed.append(user.username)
    print("ADMIN_RECOVERY " + json.dumps({"changed": changed}))
else:
    raise SystemExit("mode must be read or write")
