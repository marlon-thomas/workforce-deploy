# Workforce issue 474 (found by PR 473's live test, 15 November 2026): a sign-in can't outlive a password change.
# authentik checks the password at its password step (20) and signs the person in only at its login step (100), one
# or more requests later (after the code step, for everyone but the emergency administrator). A sign-in held between
# the two used to finish after the password was replaced: by the person, a reset link, an operator, reset-admin.sh or
# the controller's first password (Workforce issue 463). Now:
# - at 24 (reached only once the password stage accepted the password), workforce-password-seen writes into the flow
#   plan a digest of the password hash the password stage itself checked: the account authentik's backend returned,
#   which the stage put in the plan as pending_user. Not read from the database there: the plan's copy is what the
#   step saw, even if the password has changed since. A hash upgrade during the check (authentik re-hashes with newer
#   settings and saves) is in that copy too, so it isn't taken for a change; password_change_date isn't compared,
#   because such an upgrade sets it on the copy but doesn't save it;
# - at 99 (a deny stage, just before the login) and on the login step's own binding (the last check, in the same
#   request as the login), workforce-password-replaced compares that digest with the account's password hash as the
#   database has it now, and refuses on any difference, with authentik's own words for a wrong password, the same
#   whatever the reason, so the refusal says nothing a wrong password wouldn't.
#
# Every account alike, the emergency administrator included (its first password, reset-admin.sh, a reset link: each
# is a change). An account with no usable password ("!" and random characters, as authentik's "disable password"
# leaves it, or none) can't finish a sign-in whose password authentik's own backend checked; and since every such
# value is new, disabling a password is a change too. The same password chosen again is a change as well (a new salt).
#
# workforce-app.yaml.j2 includes this file in those two expression policies and adds the authentik part below it.
# Plain Python (hashlib only), so bin/tests/password-pause-test.sh tests it with python3 alone. A Jinja include:
# never write two braces, or a brace and a percent or hash sign, side by side here.

WF_PLAN_SEEN = "wf_password_seen"                    # the flow plan's key for what the password step saw
WF_INBUILT_BACKEND = "authentik.core.auth.InbuiltBackend"


def wf_password_usable(encoded):
    """Could authentik's own backend accept a password against this stored value? Not when there is none, or when it
    is Django's mark for no usable password (a "!" and random characters)."""
    return isinstance(encoded, str) and encoded != "" and not encoded.startswith("!")


def wf_password_digest(encoded):
    """A digest of a stored password hash (itself salted), so the flow plan keeps no second copy of the hash."""
    import hashlib
    text = encoded if isinstance(encoded, str) else ""
    return hashlib.sha256(("workforce-password-seen|" + text).encode("utf-8")).hexdigest()


def wf_password_seen(pk, encoded, backend):
    """What the password step saw, as kept in the flow plan: the account's pk, the digest of the hash it was checked
    against, and the backend that accepted it. None for an account that isn't saved (pretend_user_exists' unsaved
    user never gets past the password step)."""
    if not isinstance(pk, int) or isinstance(pk, bool):
        return None
    return {"pk": pk, "digest": wf_password_digest(encoded), "backend": str(backend or ""),
            "usable": wf_password_usable(encoded)}


def wf_password_replaced(seen, pending_pk, current):
    """Why this sign-in must not be finished, or None. `seen` is the flow plan's record (wf_password_seen), `pending_pk`
    the pk of the account the plan would sign in now, `current` the account's (pk, password hash, is_active) as the
    database has it now, or None when it is gone. Anything missing or unexpected refuses."""
    if not isinstance(seen, dict) or not isinstance(seen.get("pk"), int) or isinstance(seen.get("pk"), bool):
        return "not-seen"
    if not isinstance(seen.get("digest"), str) or len(seen.get("digest")) != 64:
        return "not-seen"
    if pending_pk != seen["pk"]:
        return "other-account"
    if current is None or len(current) != 3 or current[0] != seen["pk"]:
        return "gone"
    if current[2] is not True:
        return "inactive"
    if seen.get("backend") == WF_INBUILT_BACKEND and (not seen.get("usable") or not wf_password_usable(current[1])):
        return "no-usable-password"
    if wf_password_digest(current[1]) != seen["digest"]:
        return "changed"
    return None
