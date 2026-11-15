# Workforce issue 462 (ADR-0039, amendment of 14 November 2026; contract section 3.7): wrong sign-in codes keep a
# count of their own, by account, apart from wrong passwords and from the "Send a new code" limit. Five wrong codes
# for one account within 15 minutes, then a 15-minute wait from the fifth; a code typed while it lasts isn't recorded,
# so the wait isn't stretched. By account, because only someone who already has the password reaches the code step.
# An unlock in Workforce doesn't lift it (it lifts wrong passwords only); a new password doesn't either.
#
# workforce-app.yaml.j2 includes this file (after password-pause.py, whose WF_WINDOW, wf_held_until and
# wf_code_request it uses) in the expression policies workforce-code-try and workforce-codes-paused. Plain Python;
# bin/tests/password-pause-test.sh tests it with python3 alone. A Jinja include: never two braces, or a brace and a
# percent or hash sign, side by side. Since 15 November 2026 a right code also completes a sign-in (wf_signs_in),
# which the policy records as custom_workforce_signed_in (contract R.2, R.4).

WF_CODE_PAUSE_AFTER = 5            # wrong codes for one account within WF_WINDOW
WF_CODE_KEEP = 3600                # each code record is kept this long, whatever the event retention
WF_CODE_TRY = "workforce_code_try"
WF_CODE_RIGHT = "workforce_code_right"
WF_PLAN_CODE_TRY = "wf_code_try"   # the flow plan's key for this sign-in's newest code try
WF_LOCK_CODES = 1464225603         # first key of the per-account advisory lock for codes (the second is the pk)


def wf_codes_paused(tries, right, now):
    """Are this account's codes paused? `tries` are (seconds, try id) of its code tries, `right` the ids marked right.
    Returns the end of the wait, or None."""
    wrong = [at for at, tid in tries if tid not in right and now - 2 * WF_WINDOW <= at <= now]
    return wf_held_until(wrong, WF_CODE_PAUSE_AFTER, now)


def wf_signs_in(person, plan):
    """Does a right code here complete a sign-in that counts (contract R.2): an active internal account, not a service
    account, whose password was checked in this sign-in (the flow plan's user_backend)?"""
    return (person is not None and getattr(person, "is_active", False) and getattr(person, "type", None) == "internal"
            and plan is not None and bool(plan.context.get("user_backend")))
