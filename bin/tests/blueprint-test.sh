#!/usr/bin/env bash
# Self-test for the Workforce authentik blueprint's sign-in rules (ADR-0039 and its security review): plain text
# checks on the template, no authentik needed. Hermetic.
#   ./bin/tests/blueprint-test.sh      exit 0 = all pass
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$HERE/../../ansible/roles/authentik/templates/workforce-app.yaml.j2"

PY_RC=0
python3 -I - "$T" <<'PY' || PY_RC=1
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
entries = re.split(r"\n  - ", text)
passed = failed = 0

def check(name, ok):
    global passed, failed
    if ok:
        passed += 1
    else:
        failed += 1
        print("FAIL:", name)

def binding(target, stage):
    """The text of the flowstagebinding entry for this target and stage key, or ''."""
    for e in entries:
        if "flowstagebinding" in e and target in e and ("stage: !KeyOf " + stage) in e:
            return e
        if "flowstagebinding" in e and target in e and ("[name, " + stage + "]") in e:
            return e
    return ""

def order(e):
    m = re.search(r"order:\s*(\d+)", e)
    return int(m.group(1)) if m else None

# Finding 1: neither enrolment nor a password reset signs anyone in; both go on to the ordinary sign-in.
for flow in ("wf-enrollment-flow", "wf-recovery-flow"):
    b = binding(flow, "wf-enrollment-login")
    check(flow + ": its sign-in binding is removed", "state: absent" in b)
    check(flow + ": then the ordinary sign-in", order(binding(flow, "wf-to-sign-in")) is not None)

# Finding 6: the wrong-tries lock comes before the password (20), after the account is identified (10).
lock = binding("default-authentication-flow", "wf-too-many-tries-stage")
check("the lock is before the password", lock and 10 < order(lock) < 20)
codes_lock = binding("default-authentication-flow", "wf-too-many-tries-codes")
check("and again before the code step", codes_lock and order(codes_lock) < 30)

# Finding 7: the emergency administrator's skip decides alone (authentik's default policy is also bound there).
step = binding("default-authentication-flow", "default-authentication-mfa-validation")
check("the code step's policies must all pass", "policy_engine_mode: all" in step)

# Finding 31: the skip is only while the emergency administrator has no authenticator app.
skip = next((e for e in entries if "id: wf-not-emergency" in e), "")
check("the skip asks about an authenticator app", "TOTPDevice" in skip and "confirmed=True" in skip)
check("its own app page is for it alone",
      any("workforce-emergency-authenticator-app" in e and "flow" in e for e in entries)
      and any("wf-emergency-app-flow" in e and "wf-only-emergency" in e for e in entries))

# Finding 17: people can't change their own username (nor their email: ADR-0017).
settings = next((e for e in entries if "name: default-user-settings }" in e), "")
check("no username field in the user's own settings", "field-username" not in settings and "field-email" not in settings)

# Second review, finding 1: authentik's first-run page refuses everyone (and the gateway doesn't route it).
first_run = next((e for e in entries if "[slug, initial-setup]" in e and "policybinding" in e), "")
check("the first-run page refuses everyone", "wf-no-first-run" in first_run)
check("its policy says no", any("id: wf-no-first-run" in e and "return False" in e for e in entries))

# Second review, finding 6: every wrong password restarts the sign-in, so the lock is checked again each time.
password = next((e for e in entries if "name: default-authentication-password }" in e), "")
check("a wrong password restarts the sign-in", "failed_attempts_before_cancel: 1" in password)

print("blueprint self-test: %d passed, %d failed" % (passed, failed))
sys.exit(1 if failed else 0)
PY

# Outside the blueprint: the gateway, the converge and the operator's recovery (second review).
REPO="$HERE/../.."
PASS=0; FAILN=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAILN=$((FAILN+1)); printf 'FAIL: %s: expected [%s] got [%s]\n' "$1" "$3" "$2"; fi; }
for f in "$REPO"/gateway/Caddyfile "$REPO"/gateway/Caddyfile.duckdns "$REPO"/gateway/Caddyfile.localca; do
  auth="$(awk '/^\{\$AUTH_HOSTNAME\}/{on=1} on{print} on&&/^\}/{exit}' "$f")"
  check "$(basename "$f"): code methods can't be changed from outside (finding 14)" "$(printf '%s' "$auth" | grep -c 'path /api/v3/authenticators/\*')" 1
  check "$(basename "$f"): only reading them" "$(printf '%s' "$auth" | grep -c 'not method GET HEAD')" 1
  check "$(basename "$f"): no first-run page (finding 1)" "$(printf '%s' "$auth" | grep -c 'respond /if/flow/initial-setup\* 404')" 1
done
check "the converge closes the first-run page" "$(grep -c 'Setup.set(True)' "$REPO/ansible/roles/authentik/files/sign-in-hardening.py")" 1
check "and moves the score's floor below the lock" "$(grep -c 'reputation_lower_limit = -100' "$REPO/ansible/roles/authentik/files/sign-in-hardening.py")" 1
check "the converge runs it" "$(grep -c "ak shell -c \"exec(open(./tmp/sign-in-hardening.py.)" "$REPO/ansible/roles/authentik/tasks/main.yml")" 1
check "the operator's recovery removes the emergency administrator's app (new problem 6)" \
  "$(grep -c 'TOTPDevice.objects.filter(user=u).delete()' "$REPO/bin/reset-admin.sh")" 1
check "the staff relay's password reaches authentik only without a sign-in route (new problem 8)" \
  "$(grep -c 'SMTP_PASSWORD: ${SIGNIN_SMTP_HOST:-${SMTP_PASSWORD:-}}' "$REPO/compose.yaml")" 1
echo "gateway and converge self-test: ${PASS} passed, ${FAILN} failed"
[ "$FAILN" -eq 0 ] && [ "$PY_RC" -eq 0 ]
