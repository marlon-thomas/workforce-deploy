# ADR-0026 (Workforce): the emergency administrator's recovery address, converged inside authentik
# (`ak shell`). Reads {"mode": "read"|"write", "email": "<address>"} from stdin; prints one line
# "ADMIN_RECOVERY {json}" for the playbook.
#
# Two authentik accounts are involved, and they must NOT share an address:
#   admin   - the installer's Administrator, made by the Workforce blueprint. It signs in to
#             Workforce (the emergency administrator account) and is an ordinary internal user.
#             It takes the recovery address.
#   akadmin - authentik's own bootstrap superuser (authentik's system blueprint). It does not sign
#             in to Workforce and is never reset by email. It gets "bootstrap_email", an address
#             under the sign-in host that nothing sends to: sign-in finds an account by email or
#             username, so a shared address could resolve to the superuser, and the Workforce
#             subject (the email) would be the same for both.
# read  -> their current emails, and how many OTHER accounts already use the address.
# write -> sets each account's address (idempotent: unchanged accounts are not saved).
import json
import sys

from authentik.core.models import User

SIGN_IN = "admin"
BOOTSTRAP = "akadmin"

request = json.loads(sys.stdin.read() or "{}")
email = (request.get("email") or "").strip()
bootstrap_email = (request.get("bootstrap_email") or "").strip()
mode = request.get("mode")


def account(username):
    return User.objects.filter(username=username).first()


def codes_to(user):
    """Where the sign-in flow may send this account's codes (ADR-0039), or ''."""
    if user is None:
        return ""
    return str(((user.attributes or {}).get("workforce") or {}).get("codes") or "")


admin = account(SIGN_IN)
bootstrap = account(BOOTSTRAP)

if mode == "read":
    others = 0
    if email:
        others = User.objects.filter(email__iexact=email).exclude(username__in=[SIGN_IN, BOOTSTRAP]).count()
    print("ADMIN_RECOVERY " + json.dumps({
        "admin": admin.email if admin else None,
        "admin_codes": codes_to(admin),
        "akadmin": bootstrap.email if bootstrap else None,
        "others": others,
    }))
elif mode == "write":
    if "@" not in email or "@" not in bootstrap_email or email.lower() == bootstrap_email.lower():
        raise SystemExit("needs a recovery address and a different address for the bootstrap account")
    changed = []
    for user, wanted in ((admin, email), (bootstrap, bootstrap_email)):
        if user is not None and (user.email or "") != wanted:
            user.email = wanted
            user.save(update_fields=["email"])
            changed.append(user.username)
    # ADR-0039: the emergency administrator's sign-in codes go to the recovery address, its own code to the
    # installation's contact. The sign-in flow sends codes only to an address stamped here; akadmin gets none.
    if admin is not None and codes_to(admin) != email:
        attributes = dict(admin.attributes or {})
        workforce = dict(attributes.get("workforce") or {})
        workforce["codes"] = email
        attributes["workforce"] = workforce
        admin.attributes = attributes
        admin.save(update_fields=["attributes"])
        if "admin" not in changed:
            changed.append("admin")
    print("ADMIN_RECOVERY " + json.dumps({"changed": changed}))
else:
    raise SystemExit("mode must be read or write")
