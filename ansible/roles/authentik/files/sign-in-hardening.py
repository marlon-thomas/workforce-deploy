# Workforce ADR-0039, second security review: settings inside authentik that a blueprint can't make, converged on
# every identity run (`ak shell`, idempotent). Prints "sign-in hardening converged" when done.
#
# 1. The first-run (OOBE) page is closed for good. On a fresh install nothing else sets authentik's Setup flag, so
#    anyone could open /setup, set akadmin's password and be the authentik superuser with no code. The blueprint
#    also refuses the flow and the gateway doesn't route it; this is the third lock.
# 2. Wrong tries keep counting. authentik stops lowering an account's score at its lower limit (-5 by default),
#    which is also where the blueprint's lock starts, so a password stage that cancels on a drop of 1 could still
#    be held open for ever just above the floor. With the floor far below the lock, every wrong try counts.
# 3. The emergency administrator's authenticator apps from before ADR-0039 (added when no code was needed) are
#    removed once; one it adds through its own page afterwards is kept and is then always asked for.
from authentik.core.apps import Setup
from authentik.core.models import User
from authentik.stages.authenticator_totp.models import TOTPDevice
from authentik.tenants.utils import get_current_tenant

if not Setup.get():
    Setup.set(True)
    print("first-run page closed")

tenant = get_current_tenant()
if tenant.reputation_lower_limit > -100:
    tenant.reputation_lower_limit = -100
    tenant.save(update_fields=["reputation_lower_limit"])
    print("wrong tries keep counting below the lock")

admin = User.objects.filter(username="admin").first()
if admin is not None:
    attributes = dict(admin.attributes or {})
    workforce = dict(attributes.get("workforce") or {})
    if not workforce.get("app_reviewed"):
        removed, _ = TOTPDevice.objects.filter(user=admin).delete()
        workforce["app_reviewed"] = True
        attributes["workforce"] = workforce
        admin.attributes = attributes
        admin.save(update_fields=["attributes"])
        print(f"emergency administrator: {removed} old authenticator app(s) removed")

print("sign-in hardening converged")
