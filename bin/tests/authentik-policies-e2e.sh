#!/usr/bin/env bash
# authentik-policies-e2e.sh — the blueprint's expression policies that reach into authentik's own code, run on the
# pinned authentik image itself (compose.yaml's authentik-server, by digest), and ./bin/reset-admin.sh's program as
# the script runs it there. Second review of the controller bundle, findings 2, 4 and 6:
#   (the wrong-password pause of Workforce issue 462, which replaced the wrong-tries lock, runs on a live authentik
#     with a real database in bin/tests/authentik-lock-e2e.sh)
#   - the emergency administrator's password rule (wf-emergency-password; zxcvbn) and authentik's own
#     change-password page refusing that account (wf-emergency-not-here); nobody else is affected.
#   - reset-admin.sh: its `sh -c` exactly as the script passes it (the image's python, found on its PATH), with the
#     database calls replaced by fakes that record what it did: the password set, the authenticator apps removed,
#     the unlock marker written (issue 462), "OK" last.
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

# The policies' source, from the template, and reset-admin.sh's sh -c argument.
python3 -I - "$REPO/ansible/roles/authentik/templates/workforce-app.yaml.j2" "$REPO/bin/reset-admin.sh" "$WORK" <<'PY' || exit 1
import os, re, sys
template, reset, work = sys.argv[1:4]
text = open(template, encoding="utf-8").read()
for key in ("wf-emergency-password", "wf-emergency-not-here"):
    m = re.search(r"\n    id: " + re.escape(key) + r"\n(?:.*\n)*?      expression: \|\n((?:        .*\n|\n)+)", text)
    if not m:
        sys.exit("FAIL: no expression for " + key + " in the template")
    body = "".join(line[8:] + "\n" for line in m.group(1).splitlines())
    open(os.path.join(work, key + ".py"), "w", encoding="utf-8").write(body)
script = open(reset, encoding="utf-8").read()
m = re.search(r"authentik-server sh -c \\\n  '(.*?)' 2>&1 \| tail -1\)\"", script, re.S)
if not m:
    sys.exit("FAIL: reset-admin.sh's sh -c argument not found")
open(os.path.join(work, "reset-admin.sh-c"), "w", encoding="utf-8").write(m.group(1))
PY

mkdir -p "$WORK/site"
# Run first in every python the container starts: Django set up, and the database replaced by recording fakes.
cat > "$WORK/site/sitecustomize.py" <<'PY'
import atexit, os, sys
sys.path.insert(0, "/")
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "authentik.root.settings")
import django
django.setup()
from authentik.core.models import User
from authentik.stages.authenticator_totp.models import TOTPDevice

RECORD = []

class FakeUser:
    username = "admin"
    attributes = {"workforce": {"codes": "kept"}, "other": 1}
    def set_password(self, pw):
        RECORD.append("password set: " + ("the given one" if pw == os.environ.get("WF_NEW_PW") else "another"))
    def save(self, *a, **kw):
        wf = (self.attributes or {}).get("workforce") or {}
        RECORD.append("user saved; marker %s; kept %s" % ("set" if wf.get("password_unlocked_at") else "missing",
                      wf.get("codes") == "kept" and self.attributes.get("other") == 1))

class Users:
    def get(self, **kw):
        assert kw == {"username": "admin"}, kw
        return FakeUser()

class Devices:
    def filter(self, **kw):
        assert set(kw) == {"user"} and isinstance(kw["user"], FakeUser), kw
        class D:
            def delete(self):
                RECORD.append("authenticator apps deleted")
                return 0, {}
        return D()

User.objects = Users()
TOTPDevice.objects = Devices()
atexit.register(lambda: [print("RECORD", r) for r in RECORD])
PY

cat > "$WORK/policies.py" <<'PY'
import sys
sys.path.insert(0, "/t/site")
import sitecustomize as fakes
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

def run(key, user, ip="192.0.2.10", context=None, groups=()):
    req = PolicyRequest(user)
    req.http_request = RequestFactory().post("/if/flow/default-authentication-flow/", REMOTE_ADDR=ip)
    req.context.update(context or {})
    ev = PolicyEvaluator(key)
    ev.set_policy_request(req)
    ev._globals["ak_is_group_member"] = lambda u, **kw: kw.get("name") in groups
    return ev.evaluate(src[key])   # an error raises (authentik's PolicyException): this test fails

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

PASS=0; FAILN=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAILN=$((FAILN+1)); printf 'FAIL: %s: expected [%s] got [%s]\n' "$1" "$3" "$2"; fi; }
chmod -R a+rX "$WORK"
RUN=(docker run --rm --network none -e AUTHENTIK_SECRET_KEY=e2e-test-only -v "$WORK:/t:ro")

"${RUN[@]}" --entrypoint python "$IMAGE" /t/policies.py > "$WORK/policies.out" 2>&1
POL_RC=$?
grep -E '^(FAIL|authentik policies|Traceback)|Error' "$WORK/policies.out" | grep -v '"level"' | tail -20
[ "$POL_RC" -eq 0 ] || FAILN=$((FAILN+1))

# reset-admin.sh's program, exactly as the script hands it to the container's sh.
"${RUN[@]}" -e WF_NEW_PW=e2e-new-password -e PYTHONPATH=/t/site --entrypoint sh "$IMAGE" -c "$(cat "$WORK/reset-admin.sh-c")" \
  > "$WORK/reset.out" 2>&1
RESET_RC=$?
check "reset-admin.sh: the program runs" "$RESET_RC" 0
check "reset-admin.sh: it ends OK (what the script reads)" "$(grep -v '^RECORD ' "$WORK/reset.out" | grep -v '^{' | tail -1)" OK
check "reset-admin.sh: the given password is set" "$(grep -c '^RECORD password set: the given one$' "$WORK/reset.out")" 1
check "reset-admin.sh: and saved, with the unlock marker, other attributes kept" "$(grep -c '^RECORD user saved; marker set; kept True$' "$WORK/reset.out")" 1
check "reset-admin.sh: authenticator apps removed" "$(grep -c '^RECORD authenticator apps deleted$' "$WORK/reset.out")" 1
check "reset-admin.sh: no record deleted (the marker lifts the pause)" "$(grep -c '^RECORD reputation' "$WORK/reset.out")" 0
[ "$RESET_RC" -eq 0 ] || grep -v '^{' "$WORK/reset.out" | tail -5

echo "reset-admin.sh on the pinned image: ${PASS} passed, ${FAILN} failed"
[ "$FAILN" -eq 0 ]
