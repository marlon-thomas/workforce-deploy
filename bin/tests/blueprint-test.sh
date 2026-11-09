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
# A flow needs ANY one of its policies by default, and authentik's own first-run policy passes on a fresh install,
# so the flow itself must need a superuser and ALL of its policies (third review).
first_run_flow = next((e for e in entries if "model: authentik_flows.flow\n" in e and "slug: initial-setup" in e), "")
check("the first-run flow needs a superuser", "authentication: require_superuser" in first_run_flow)
check("and all of its policies", "policy_engine_mode: all" in first_run_flow)
check("and is made here, not found (either blueprint may run first)", "id: wf-first-run-flow" in first_run_flow
      and all(k in first_run_flow for k in ("name: default-oobe-setup", "designation: stage_configuration")))
first_run = next((e for e in entries if "policybinding" in e and "wf-no-first-run" in e), "")
check("the first-run page refuses everyone", "target: !KeyOf wf-first-run-flow" in first_run)
check("its policy says no", any("id: wf-no-first-run" in e and "return False" in e for e in entries))

# Any refusing or negated policy we bind must not be outvoted: its target needs all of its policies to pass.
for e in entries:
    if "policybinding" in e and ("negate: true" in e or "wf-no-first-run" in e):
        m = re.search(r"target: !KeyOf ([\w-]+)", e)
        target = next((t for t in entries if m and ("id: " + m.group(1) + "\n") in t), "")
        check("the target of a refusing binding needs all its policies (%s)" % (m.group(1) if m else "?"),
              "policy_engine_mode: all" in target)

# Second review, finding 6, and its third review: the lock is checked on every password sent, not once per
# sign-in. The password stage runs only while the account isn't locked (re-checked on every request to it)...
pw = binding("default-authentication-flow", "default-authentication-password")
check("the password step is re-checked on every try", "re_evaluate_policies: true" in pw and order(pw) == 20)
check("all of its policies must pass", "policy_engine_mode: all" in pw)
check("one of them: not locked", any("policybinding" in e and "target: !KeyOf wf-password-binding" in e
                                     and "policy: !KeyOf wf-too-many-tries" in e and "negate: true" in e for e in entries))
# ... and nothing goes past it without a password checked in this sign-in (a skipped password step refuses).
guard = binding("default-authentication-flow", "wf-password-not-checked-stage")
check("no password checked, no further", guard and 20 < order(guard) < 25 and "re_evaluate_policies: true" in guard)
guard_policy = next((e for e in entries if "id: wf-password-not-checked\n" in e), "")
check("decided by the password stage's own record", 'plan.context.get("user_backend")' in guard_policy)
check("an error refuses too", any("target: !KeyOf wf-password-not-checked-binding" in e and "failure_result: true" in e
                                  for e in entries))
password = next((e for e in entries if "name: default-authentication-password }" in e), "")
check("a wrong password can be retyped (authentik's default)", "failed_attempts_before_cancel: 5" in password)
# Wrong codes count too; after too many, even a right code doesn't sign anyone in.
after_code = binding("default-authentication-flow", "wf-too-many-tries-after-code")
check("the lock again after the code", after_code and 30 < order(after_code) < 100 and "re_evaluate_policies: true" in after_code)
check("with the same lock", any("target: !KeyOf wf-too-many-tries-after-code-binding" in e
                                and "policy: !KeyOf wf-too-many-tries" in e for e in entries))

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
# Issue 299: ending a person's sessions at the sign-in server revokes all their tokens only while no app is given a
# refresh token; authentik gives one only with the offline_access scope, so neither provider may map it.
for t in workforce-app webmail-app; do
  check "$t: no refresh tokens (no offline_access scope)" \
    "$(grep -v '^ *#' "$REPO/ansible/roles/authentik/templates/$t.yaml.j2" | grep -c 'offline_access')" 0
done
# Issue 299: the emergency administrator can't remove its own app on authentik's page: the delete button is hidden there.
check "authentik's MFA page offers no delete" "$(grep -c '^ak-user-settings-mfa ak-forms-delete-bulk' "$REPO/branding/authentik-custom.css")" 1
# Issue 290: the sign-in page with "Send a new code": authentik's own page, extended, from its custom-template folder.
FLOW="$REPO/branding/authentik-templates/if/flow.html"
check "the sign-in page extends authentik's own" "$(head -1 "$FLOW")" '{% extends "if/flow.html" %}'
check "and adds only its script" "$(grep -c '{% block scripts %}' "$FLOW")" 1
check "it limits new codes" "$(grep -c 'var MOST = 3;' "$FLOW")" 1
check "and ends with asking the manager" "$(grep -c 'ask your manager to check your email address' "$FLOW")" 1
check "authentik's server reads it" "$(grep -c '\./branding/authentik-templates:/templates:ro' "$REPO/compose.yaml")" 2
check "the code email is still there" "$(test -f "$REPO/branding/authentik-templates/workforce-sign-in-code.html" && echo yes)" yes
if command -v node >/dev/null 2>&1; then
  JS_DIR="$(mktemp -d)"; JS="$JS_DIR/new-code.js"   # a .js name: node refuses mktemp's own suffix
  python3 -I -c 'import re, sys; t = open(sys.argv[1], encoding="utf-8").read(); m = re.search(r"<script data-id=\"workforce-new-code\">(.*?)</script>", t, re.S); sys.stdout.write(m.group(1) if m and "{{" not in m.group(1) and "{%" not in m.group(1) else "(")' "$FLOW" > "$JS"
  if node --check "$JS"; then check "its script is valid JavaScript, with no template tags in it" ok ok
  else check "its script is valid JavaScript, with no template tags in it" bad ok; fi
  rm -rf "$JS_DIR"
fi
# Issue 290: the mail server's reports reach the api, inside.
check "the api and the worker tell the mail server where to report" "$(grep -c 'MAIL_EVENTS_URL: http://api:8080/api/public/mail/events' "$REPO/compose.yaml")" 2
for f in "$REPO"/gateway/Caddyfile "$REPO"/gateway/Caddyfile.duckdns "$REPO"/gateway/Caddyfile.localca; do
  check "$(basename "$f"): the reports' address isn't reachable from outside" "$(grep -c 'respond /api/public/mail/\* 404' "$f")" 1
done
echo "gateway and converge self-test: ${PASS} passed, ${FAILN} failed"
[ "$FAILN" -eq 0 ] && [ "$PY_RC" -eq 0 ]
