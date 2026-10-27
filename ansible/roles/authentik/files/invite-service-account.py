# ADR-0017: the Workforce app's invitation credential, converged idempotently inside authentik
# (`ak shell`). Reads the token key from stdin (never argv/env). The account can create, view
# and delete invitations — nothing else (no users, flows, settings or other tokens).
import sys

from authentik.core.models import Group, Token, TokenIntents, User, UserTypes
from authentik.rbac.models import Role

key = sys.stdin.read().strip()
if len(key) < 32:
    raise SystemExit("invite token key missing or too short")

user, _ = User.objects.update_or_create(
    username="workforce-invites",
    defaults={
        "name": "Workforce invitations (service account)",
        "type": UserTypes.SERVICE_ACCOUNT,
        "is_active": True,
        "path": "goauthentik.io/service-accounts",
    },
)
user.set_unusable_password()
user.save()

group, _ = Group.objects.get_or_create(name="workforce-invites")
group.users.add(user)
role, _ = Role.objects.get_or_create(name="workforce-invites")
group.roles.add(role)
for perm in (
    "authentik_stages_invitation.add_invitation",
    "authentik_stages_invitation.view_invitation",
    "authentik_stages_invitation.delete_invitation",
    "authentik_flows.view_flow",
):
    role.assign_permission(perm)

Token.objects.update_or_create(
    identifier="workforce-invite-token",
    defaults={
        "user": user,
        "intent": TokenIntents.INTENT_API,
        "expiring": False,
        "key": key,
        "description": "Workforce app: create and revoke staff invitations (ADR-0017)",
    },
)
print("workforce-invites converged")
