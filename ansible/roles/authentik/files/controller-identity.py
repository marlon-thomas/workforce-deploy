# Workforce issue 453 (ADR-0032, delivery step 3): the sign-in server's own set-up when the appliance controller runs the
# suite. The controller can't run this role's Ansible, so it runs this in a one-shot container of authentik's own image
# (`identity-setup` in compose.controller.yaml, `ak shell -c "exec(open(…).read())"`), with only its own folder of the
# controller's volume: authentik's config.yml (its secret key and database password), the invitation token, the
# blueprints the controller rendered from this role's templates, and the scripts below, which are this role's own files,
# run unchanged (ansible/roles/authentik/files). What the role's tasks do in order, this does in order:
#
#   1. wait until authentik is ready for the Workforce blueprint (its own default flows, stages and the self-signed
#      certificate exist: authentik-server and authentik-worker make them at their first start), then apply each
#      blueprint the controller asks for (workforce-app.yaml, webmail-app.yaml), as `manage.py apply_blueprint` does;
#   2. the invitation service account (invite-service-account.py, ADR-0017), its key from /run/secrets on stdin;
#   3. the sign-in hardening (sign-in-hardening.py, ADR-0039), after the blueprint, as the role runs it;
#   4. the emergency administrator's recovery address (admin-recovery-email.py, ADR-0026): read, and written only when
#      the controller says so (it moves the Workforce login first, when the application's database has one);
#   5. the public certificate the Workforce sign-in signs with, for the controller to pin (never a private key).
#
# The request is /workforce-identity/request.json, written by the controller; the answer is one line on stdout,
# "WORKFORCE_IDENTITY {json}", and nothing secret is ever in it: no key, password or address but the administrators'
# (which the controller already knows). A failure is that line with "ok": false and a short reason in our own words,
# never authentik's message (which can quote a blueprint's values), and the container then ends with an error.
# Idempotent: every part changes nothing when run again.
import base64
import contextlib
import io
import json
import re
import sys
import time
from pathlib import Path

HERE = Path("/workforce-identity")
BLUEPRINTS = Path("/blueprints/workforce")
MARK = "WORKFORCE_IDENTITY "
WAIT_SECONDS = 900   # a first start can take minutes before authentik's own default blueprints are all applied
NAME_OK = frozenset("abcdefghijklmnopqrstuvwxyz0123456789-.")


def answer(result):
    sys.stdout.write(MARK + json.dumps(result, sort_keys=True) + "\n")
    sys.stdout.flush()


def fail(reason):
    answer({"ok": False, "error": reason[:200]})
    raise SystemExit(3)


def plain_name(name):
    return isinstance(name, str) and 0 < len(name) <= 64 and set(name) <= NAME_OK and not name.startswith(".")


try:
    request = json.loads((HERE / "request.json").read_text(encoding="utf-8"))
except Exception:
    fail("the controller's request could not be read")
mode = request.get("mode")
if mode not in ("converge", "recovery-write"):
    fail("the controller asked for something this doesn't do")


def run(script, stdin_text=""):
    """One of this role's scripts, as the role runs it with `ak shell`: its stdin given, its stdout returned."""
    if not plain_name(script):
        fail("a script was named strangely")
    from django.db import DatabaseError

    path = HERE / script
    code = compile(path.read_text(encoding="utf-8"), str(path), "exec")
    # Each script is idempotent: one the database refused for now (a deadlock with authentik-worker's own work) is
    # run again, a few times.
    for attempt in range(4):
        out = io.StringIO()
        before = sys.stdin
        sys.stdin = io.StringIO(stdin_text)
        try:
            with contextlib.redirect_stdout(out):
                exec(code, {"__name__": "__workforce_identity__"})
            return out.getvalue()
        except SystemExit:
            fail(f"{script} refused")
        except DatabaseError as exc:
            if attempt == 3:
                fail(f"{script} failed ({type(exc).__name__})")
            time.sleep(5)
        except Exception as exc:  # noqa: BLE001 - said in our words; authentik's own message can quote values
            fail(f"{script} failed ({type(exc).__name__})")
        finally:
            sys.stdin = before


# ------------------------------------------------------------------------------------------------- blueprints

def ready_tenants():
    from authentik.tenants.models import Tenant

    return list(Tenant.objects.filter(ready=True))


# What a blueprint finds that authentik makes itself at its first start: its default flows, stages and prompts (named
# default-…), and the self-signed certificate. A `!Find` that finds nothing gives an empty value, which a required
# field refuses but an optional one (a signing key, a stage's set-up flow) would quietly keep, so these are waited for.
FIND = re.compile(r'!Find \[(authentik_[a-z0-9_]+)\.([a-z0-9_]+), \[(slug|name), "?(default-[a-z0-9-]+|authentik Self-signed Certificate)"?\]\]')


def prerequisites_missing(content):
    from django.apps import apps

    for app_label, model, field, value in sorted(set(FIND.findall(content))):
        if not apps.get_model(app_label, model).objects.filter(**{field: value}).exists():
            return value
    return None


def apply_blueprint(name):
    """As authentik's `apply_blueprint` command: validated first, applied in one transaction, for each tenant."""
    from django.db import DatabaseError

    from authentik.blueprints.v1.importer import Importer

    if not plain_name(name):
        fail("a blueprint was named strangely")
    content = (BLUEPRINTS / name).read_text(encoding="utf-8")
    deadline = time.monotonic() + WAIT_SECONDS
    while True:
        tenants = ready_tenants()
        missing = prerequisites_missing(content) if tenants else "a ready tenant"
        problem = missing
        if not missing:
            try:
                for tenant in tenants:
                    with tenant:
                        importer = Importer.from_string(content)
                        valid, _logs = importer.validate()
                        if not valid:
                            problem = "it isn't valid yet"
                            break
                        if not importer.apply():
                            problem = "authentik didn't apply it"
                            break
                else:
                    return
            except DatabaseError as exc:
                # authentik-worker applies the same file by itself (its blueprint discovery), and two applications at
                # once can deadlock or collide: PostgreSQL undoes one, and it is tried again.
                problem = f"the database refused it for now ({type(exc).__name__})"
        if time.monotonic() >= deadline:
            fail(f"{name} could not be applied: {problem}")
        time.sleep(5)


def workforce_provider_ok():
    """The Workforce sign-in exactly as the blueprint makes it, or None: the application by its slug (unique, as the
    blueprint identifies it; a name is not), its provider named Workforce with this installation's client id, a signing
    key and its flows. The key pinned for the api is only ever this provider's: another application that happens to
    be called Workforce, with a provider of its own, is never taken for it."""
    from authentik.core.models import Application
    from authentik.providers.oauth2.models import OAuth2Provider

    client_id = request.get("client_id")
    if not isinstance(client_id, str) or not client_id:
        fail("the controller's request names no client id")
    app = Application.objects.filter(slug="workforce").first()
    if app is None or app.provider_id is None:
        return None
    provider = OAuth2Provider.objects.filter(pk=app.provider_id).first()
    if provider is None or provider.name != "Workforce" or provider.client_id != client_id:
        return None
    if provider.signing_key is None or provider.authorization_flow_id is None:
        return None
    return provider


# ------------------------------------------------------------------------------------------------ recovery

def recovery_read(email):
    out = run("admin-recovery-email.py", json.dumps({"mode": "read", "email": email}))
    lines = [line for line in out.splitlines() if line.startswith("ADMIN_RECOVERY ")]
    if len(lines) != 1:
        fail("the administrators' addresses could not be read")
    now = json.loads(lines[0][len("ADMIN_RECOVERY "):])
    return {"admin": now.get("admin"), "akadmin": now.get("akadmin"), "others": int(now.get("others") or 0)}


def wait_for_bootstrap():
    """authentik's own superuser (akadmin) is made by its bootstrap blueprint, which its worker applies at its first
    start: written before it exists, it would keep its default address. Waited for, as the blueprint's own objects."""
    from authentik.core.models import User

    deadline = time.monotonic() + WAIT_SECONDS
    while not User.objects.filter(username="akadmin").exists():
        if time.monotonic() >= deadline:
            fail("authentik's own administrator (akadmin) was never made")
        time.sleep(5)


def recovery_write(recovery):
    email = recovery.get("email") or ""
    bootstrap = recovery.get("bootstrap_email") or ""
    wait_for_bootstrap()
    before = recovery_read(email)
    # Checked again here, at the moment of writing: another account may have taken the address meanwhile.
    if before["others"]:
        return before, False
    if before["admin"] == email and before["akadmin"] in (None, bootstrap):
        return before, False
    run("admin-recovery-email.py", json.dumps({"mode": "write", "email": email, "bootstrap_email": bootstrap}))
    return recovery_read(email), True


# ---------------------------------------------------------------------------------------------------- main

recovery = request.get("recovery") or {}
result = {"ok": True, "mode": mode}

if mode == "converge":
    names = request.get("blueprints") or []
    if not isinstance(names, list) or "workforce-app.yaml" not in names:
        fail("the controller's request names no Workforce blueprint")
    for name in names:
        apply_blueprint(name)
    if workforce_provider_ok() is None:
        fail("the Workforce sign-in is not as its blueprint makes it (its application, its provider and client id, a signing key, a flow)")
    result["blueprints"] = names

    token = Path("/run/secrets/ak_invite_token").read_text(encoding="utf-8").strip()
    if "workforce-invites converged" not in run("invite-service-account.py", token):
        fail("the invitation service account was not converged")
    del token
    result["invitations"] = True

    if "sign-in hardening converged" not in run("sign-in-hardening.py"):
        fail("the sign-in hardening was not converged")
    result["hardening"] = True

if recovery.get("email"):
    if recovery.get("write"):
        now, written = recovery_write(recovery)
        result["recovery"] = {**now, "written": written}
    else:
        result["recovery"] = {**recovery_read(recovery["email"]), "written": False}

provider = workforce_provider_ok()
if provider is None:
    fail("the Workforce sign-in is not as its blueprint makes it, so no signing key was read")
pem = provider.signing_key.certificate_data or ""
if "BEGIN CERTIFICATE" not in pem:
    fail("the Workforce sign-in's signing key has no certificate")
# The certificate only (public): the controller takes the public key from it, as bin/lib/common.sh does with openssl.
result["certificate"] = base64.b64encode(pem.encode("ascii")).decode("ascii")
answer(result)
