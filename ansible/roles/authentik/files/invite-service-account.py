# ADR-0017: the Workforce app's invitation credential, converged idempotently inside authentik
# (`ak shell`). Reads the token key from stdin (never argv/env). The account can create, view
# and delete invitations, (ADR-0024) look up a user and make them a password reset link, and
# (ADR-0039) set where a staff account's sign-in codes go and remove its code methods, and (issue 462, contract R.7 and
# R.8) ask the sign-in status interface whether a person is paused, unlock them and read the attack alerts — nothing
# else (no flows, settings, groups, other tokens, and no authentik events: authentik_events.view_event is revoked).
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
# assign_permission became assign_perms in authentik 2025.x; the ladder runs both.
assign = getattr(role, "assign_perms", None) or role.assign_permission
for perm in (
    "authentik_stages_invitation.add_invitation",
    "authentik_stages_invitation.view_invitation",
    "authentik_stages_invitation.delete_invitation",
    "authentik_flows.view_flow",
    # ADR-0024: find a staff member's account and make them a one-time reset link. The recovery
    # flow's own policy refuses superusers, service accounts and authentik Admins.
    "authentik_core.view_user",
    "authentik_core.reset_user_password",
    # authentik 2026.8 also checks POST users/{pk}/recovery/ against the "add" permission
    "authentik_core.add_user",
    # ADR-0039 (Workforce): two-step sign-in. Set a staff account's email to the personal email on their
    # record, with the attribute saying Workforce gave it (sign-in codes go there), and remove a person's
    # code methods when they switch between email and an app or a manager resets them. The app refuses
    # superusers, "authentik Admins" members and service accounts before any of these calls, and authentik
    # itself refuses adding anyone to a superuser group without enable_group_superuser (not given).
    "authentik_core.change_user",
    "authentik_stages_authenticator_email.view_emaildevice",
    "authentik_stages_authenticator_email.delete_emaildevice",
    "authentik_stages_authenticator_totp.view_totpdevice",
    "authentik_stages_authenticator_totp.delete_totpdevice",
    # ADR-0039 review: a reset ends the person's sign-in server sessions (and, with them, their tokens and
    # webmail): DELETE core/authenticated_sessions/bulk_delete/?user_pks=<pk>. Issue 299: that is all it takes;
    # authentik deletes a session's access tokens with it, and no refresh tokens exist (neither app is given the
    # offline_access scope; bin/tests/blueprint-test.sh keeps it so). So no permission on refresh tokens, and the
    # account is no longer switched off and on: authentik lists and deletes refresh tokens only for superusers or
    # their owner anyway, whatever permission this account holds.
    "authentik_core.view_authenticatedsession",
    "authentik_core.delete_authenticatedsession",
    # Workforce issue 290: count failed sign-in code emails (authentik keeps them only as failed send_mail
    # tasks) for Setup -> Email delivery. Read-only; the app shows a count and an error with addresses removed.
    "authentik_tasks.view_task",
):
    assign(perm)

# Workforce issue 462 (the owner's decision 3 of 15 November 2026; contract R.8): no global event access. authentik's
# view_event is global, not per action, and authentik 2026.8.5 keeps the whole body of every email it sends in its
# email_sent event, so with it this credential could read live sign-in codes and password-reset links for every
# organisation. Earlier builds of this script granted it, so it is revoked here, not just no longer granted: from this
# role (globally and on any object), from the account's own managed role, and from its own permissions. Then checked
# in a fresh copy of the account; if anything still gives it (another role, a group), this script fails rather than
# carrying on (the converge stops, and the operator sees why).
from django.contrib.auth.models import Permission
from guardian.models import RoleModelPermission, RoleObjectPermission

VIEW_EVENT = Permission.objects.get(content_type__app_label="authentik_events", codename="view_event")
own_roles = [role] + [r for r in [user.get_managed_role()] if r is not None]
for r in own_roles:
    RoleModelPermission.objects.filter(role=r, permission=VIEW_EVENT).delete()
    RoleObjectPermission.objects.filter(role=r, permission=VIEW_EVENT).delete()
# (authentik 2026.8.5 keeps no per-user permissions: its User sets user_permissions to None.)
if getattr(getattr(user, "user_permissions", None), "remove", None) is not None:
    user.user_permissions.remove(VIEW_EVENT)

# The sign-in status interface (contract R.7): a property mapping of authentik's own base kind, which authentik's API
# lets a caller test (POST /api/v3/propertymappings/all/<pk>/test/) with an object permission on that one mapping. An
# expression policy can't be given that way (authentik 2026.8.5 refuses an object permission on a policy of another
# app: found while building, 15 November 2026), and its blueprint can't make this kind of mapping, so the code is the
# blueprint's unbound policy workforce-sign-in-status-code, copied here after every apply. Its id is fixed, so the
# application needs no list (authentik can't list a mapping of this kind) and no lookup.
from authentik.core.models import PropertyMapping
from authentik.policies.expression.models import ExpressionPolicy

STATUS_PK = "7ccaf87d-46bb-5dcd-9b0c-7f0df9db4045"
STATUS_NAME = "workforce-sign-in-status"
code = ExpressionPolicy.objects.filter(name="workforce-sign-in-status-code").values_list("expression", flat=True).first()
if not code or "wf_ak_status_answer" not in code:
    raise SystemExit("the sign-in status code (workforce-sign-in-status-code) is missing: apply the Workforce blueprint first")
# The status code loads the shared sign-in code by name when it runs (final review of the controller bundle, findings 1
# and 5); without it every answer is an error, so a converge that can't find it stops here.
if not ExpressionPolicy.objects.filter(name="workforce-sign-in-code", expression__contains="def wf_ak_status_answer(").exists():
    raise SystemExit("the shared sign-in code (workforce-sign-in-code) is missing: apply the Workforce blueprint first")
PropertyMapping.objects.filter(name=STATUS_NAME).exclude(pk=STATUS_PK).delete()
mapping, _ = PropertyMapping.objects.update_or_create(pk=STATUS_PK, defaults={"name": STATUS_NAME, "expression": code})
if type(PropertyMapping.objects.select_subclasses().get(pk=STATUS_PK)) is not PropertyMapping:
    raise SystemExit("the sign-in status interface is not a plain property mapping")
# Testing it needs view (authentik's decorator) and add (its object check maps a POST to "add") on that one object:
# neither lets this account make, change, list or test any other mapping, or delete this one.
for r in own_roles:
    RoleObjectPermission.objects.filter(role=r, content_type__app_label="authentik_core",
                                        permission__codename__endswith="_propertymapping").exclude(object_pk=STATUS_PK).delete()
role.assign_perms(["authentik_core.view_propertymapping", "authentik_core.add_propertymapping"], mapping)

# Workforce issue 462 (contract R.7.4): the unlock marker is no longer an account attribute (this credential could
# write it). Nothing reads attributes.workforce.password_unlocked_at any more; it is removed from every account, so
# nobody takes it for a live control. Idempotent.
for u in User.objects.filter(attributes__workforce__has_key="password_unlocked_at"):
    wf = dict(u.attributes["workforce"])
    wf.pop("password_unlocked_at", None)
    u.attributes = dict(u.attributes, workforce=wf)
    u.save(update_fields=["attributes"])

fresh = User.objects.get(pk=user.pk)
leaks = []
if fresh.is_superuser:
    leaks.append("it is a superuser")
if fresh.has_perm("authentik_events.view_event"):
    leaks.append("it may read every authentik event")
if RoleObjectPermission.objects.filter(role__in=fresh.all_roles(), permission=VIEW_EVENT).exists():
    leaks.append("it may read some authentik events")
if fresh.has_perm("authentik_core.view_propertymapping") or fresh.has_perm("authentik_policies.view_policy"):
    leaks.append("it may read every property mapping or policy")
if leaks:
    raise SystemExit("workforce-invites: " + "; ".join(leaks) + " (a role or group gives it): remove that, then run this again")

Token.objects.update_or_create(
    identifier="workforce-invite-token",
    defaults={
        "user": user,
        "intent": TokenIntents.INTENT_API,
        "expiring": False,
        "key": key,
        "description": "Workforce app: staff invitations (ADR-0017), password reset links (ADR-0024) and sign-in codes (ADR-0039)",
    },
)
print("workforce-invites converged")
