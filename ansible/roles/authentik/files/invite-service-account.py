# ADR-0017: the Workforce app's invitation credential, converged idempotently inside authentik
# (`ak shell`). Reads the token key from stdin (never argv/env). The account can create, view
# and delete invitations, (ADR-0024) look up a user and make them a password reset link, and
# (ADR-0039) set where a staff account's sign-in codes go and remove its code methods, and (issue 462) read the
# sign-in records and unlock a person's sign-in — nothing else (no flows, settings, groups or other tokens).
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
    # Workforce issue 462: read the sign-in server's records of wrong passwords (custom_workforce_password_try,
    # _right, _alert), to show a manager whether someone is paused and to raise attack alerts. Read-only: no record
    # can be changed or deleted, and the unlock itself is an attribute change_user above already covers.
    # Known exposure (Workforce issue 462 review, finding 5): authentik's view_event is global, not per action, and
    # authentik 2026.8.5 keeps the whole body of every email it sends in its email_sent event (stages/email/tasks.py),
    # so this token can also read live sign-in codes and password-reset links, for every organisation, until the
    # events expire. change_user above already lets this token take an account over (by redirecting its code email),
    # so a leak of it was already a takeover; this widens what a read-only leak exposes. Keep the token where it is
    # (secrets/ak_invite_token, the app's memory) and never log it. RUNBOOK, "Hardening notes".
    "authentik_events.view_event",
):
    assign(perm)

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
