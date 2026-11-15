#!/usr/bin/env bash
# authentik-policies-e2e.sh — the blueprint's expression policies that reach into authentik's own code, run on the
# pinned authentik image itself (compose.yaml's authentik-server, by digest). Second review of the controller bundle,
# findings 2, 4 and 6:
#   (the wrong-password pause of Workforce issue 462, which replaced the wrong-tries lock, runs on a live authentik
#     with a real database in bin/tests/authentik-lock-e2e.sh)
#   - the emergency administrator's password rule (wf-emergency-password; zxcvbn) and authentik's own
#     change-password page refusing that account (wf-emergency-not-here); nobody else is affected.
#   (./bin/reset-admin.sh's program, which since Workforce issue 487 removes every sign-in method and ends sessions
#     and tokens in one transaction, runs on a real database in bin/tests/authentik-lock-e2e.sh, section 9.)
# Each policy's source is read from the template, so a change there is what gets tested. No database: the queries
# go to fakes that check the model's field names; authentik's own expression evaluator runs the code. Needs Docker,
# no network (the image must be present or pullable). Not part of bin/ci-validate.sh.
# When compose.yaml moves the authentik pin, run this against the new image, then set VERIFIED_AUTHENTIK below to
# the new version: bin/tests/blueprint-test.sh fails until the two agree.
#   ./bin/tests/authentik-policies-e2e.sh      exit 0 = all pass
VERIFIED_AUTHENTIK=2026.8.5
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
IMAGE="${AUTHENTIK_IMAGE:-$(awk '/^  authentik-server:/{on=1} on && /image:/{print $2; exit}' "$REPO/compose.yaml")}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
chmod 755 "$WORK"   # authentik's image runs as uid 1000

case "$IMAGE" in
  *":${VERIFIED_AUTHENTIK}@sha256:"*) : ;;
  *) [ -n "${AUTHENTIK_IMAGE:-}" ] || { echo "FAIL: compose.yaml pins $IMAGE, this test says $VERIFIED_AUTHENTIK"; exit 1; } ;;
esac

# The policies' source, from the template.
python3 -I - "$REPO/ansible/roles/authentik/templates/workforce-app.yaml.j2" "$WORK" <<'PY' || exit 1
import os, re, sys
template, work = sys.argv[1:3]
text = open(template, encoding="utf-8").read()
for key in ("wf-emergency-password", "wf-emergency-not-here"):
    m = re.search(r"\n    id: " + re.escape(key) + r"\n(?:.*\n)*?      expression: \|\n((?:        .*\n|\n)+)", text)
    if not m:
        sys.exit("FAIL: no expression for " + key + " in the template")
    body = "".join(line[8:] + "\n" for line in m.group(1).splitlines())
    open(os.path.join(work, key + ".py"), "w", encoding="utf-8").write(body)
PY

mkdir -p "$WORK/site"
# Run first in every python the container starts: Django set up (no database: the policies here don't query one).
cat > "$WORK/site/sitecustomize.py" <<'PY'
import os, sys
sys.path.insert(0, "/")
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "authentik.root.settings")
import django
django.setup()
PY

cat > "$WORK/policies.py" <<'PY'
import sys
sys.path.insert(0, "/t/site")
import sitecustomize
from django.test import RequestFactory
from authentik.core.models import User
from authentik.policies.expression.evaluator import PolicyEvaluator
from authentik.policies.types import PolicyRequest

passed = failed = 0
def check(name, ok):
    global passed, failed
    if ok:
        passed += 1
    else:
        failed += 1
        print("FAIL:", name)

src = {k: open("/t/%s.py" % k).read() for k in ("wf-emergency-password", "wf-emergency-not-here")}

class Log:
    def __init__(self):
        self.lines = []
    def warning(self, *a, **kw):
        self.lines.append((a, kw))

def run(key, user, ip="192.0.2.10", context=None, groups=()):
    req = PolicyRequest(user)
    req.http_request = RequestFactory().post("/if/flow/default-authentication-flow/", REMOTE_ADDR=ip)
    req.context.update(context or {})
    ev = PolicyEvaluator(key)
    ev.set_policy_request(req)
    ev._globals["ak_is_group_member"] = lambda u, **kw: kw.get("name") in groups
    # Each policy's guard turns an error into a refusal and a log line (Workforce issue 474 review): none may happen
    # here, or a refusal below could be an error rather than the rule.
    log = Log()
    ev._globals["ak_logger"] = log
    result = ev.evaluate(src[key])
    check(key + ": no error inside its guard", not log.lines)
    return result

# User.is_superuser asks the database (a group with superuser rights); here it is what the test says.
User.is_superuser = property(lambda self: getattr(self, "_wf_superuser", False))
def person(name, superuser=False):
    u = User(username=name, type="internal")
    u._wf_superuser = superuser
    return u

admin, pat = person("admin"), person("pat")

# The emergency administrator's password rule (prompt validation: request.user is the pending user).
def pw(user, password, **kw):
    return run("wf-emergency-password", user, context={"prompt_data": {"password": password}}, **kw)
r = pw(admin, "Kestrel12!")
check("admin: 10 characters refused", not r.passing and any("16 characters" in m for m in r.messages))
r = pw(admin, "passwordpassword")
check("admin: 16 easy characters refused", not r.passing and any("too easy" in m for m in r.messages))
check("admin: one letter 16 times refused", not pw(admin, "a" * 16).passing)
check("admin: 'administrator' and digits refused", not pw(admin, "administrator123").passing)
check("admin: four unrelated words accepted", pw(admin, "violet tractor ocean pebble").passing)
check("admin: reset-admin.sh's kind of password accepted", pw(admin, "q8Vw3mZt0RkLx2Nf+7bYc1Hs").passing)
check("staff: 10 characters still fine (the 10-character rule decides)", pw(pat, "Kestrel12!").passing)
check("a superuser called admin: not this rule", pw(person("admin", superuser=True), "Kestrel12!").passing)
check("no password given: refused for admin", not run("wf-emergency-password", admin, context={}).passing)

# authentik's own change-password page.
r = run("wf-emergency-not-here", admin)
check("authentik's change-password page refuses admin", not r.passing and any("account menu" in m for m in r.messages))
check("and lets staff in", run("wf-emergency-not-here", pat).passing)

print("authentik policies on the pinned image: %d passed, %d failed" % (passed, failed))
sys.exit(1 if failed else 0)
PY

FAILN=0
chmod -R a+rX "$WORK"
RUN=(docker run --rm --network none -e AUTHENTIK_SECRET_KEY=e2e-test-only -v "$WORK:/t:ro")

"${RUN[@]}" --entrypoint python "$IMAGE" /t/policies.py > "$WORK/policies.out" 2>&1
POL_RC=$?
grep -E '^(FAIL|authentik policies|Traceback)|Error' "$WORK/policies.out" | grep -v '"level"' | tail -20
[ "$POL_RC" -eq 0 ] || FAILN=$((FAILN+1))

echo "the policies on the pinned image: ${FAILN} failed"
[ "$FAILN" -eq 0 ]
