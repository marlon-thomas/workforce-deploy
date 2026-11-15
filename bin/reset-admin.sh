#!/usr/bin/env bash
# reset-admin.sh — the emergency administrator ("admin") back in, on an installation WITHOUT the appliance controller
# (deployment-spec §B3; Workforce issue 487). Where the controller runs, use its page instead ("Recover the emergency
# administrator": RUNBOOK, "admin's way back in"); this script is for host installs only.
#
# Identity verification is procedural (support phone call): the script prints a one-time verification phrase;
# support confirms it on the phone, then the org re-runs with the phrase. The real authority is being able to run
# commands on this server.
#
# What it does, in ONE database transaction inside the sign-in server (as the controller's recovery, Workforce issue
# 471; all of it commits together or none of it does):
#   - a new password, 24 random characters, shown here once. It reaches the container on stdin only: never the
#     command line, the environment (which `docker inspect` and the process list show) or a file on disk;
#   - every sign-in method of the account removed: every authenticator device class authentik has loaded (TOTP,
#     static recovery codes, WebAuthn and passkeys, email, SMS, Duo, endpoint and Apple devices in 2026.8.5);
#   - its sessions ended (and any sign-in held between its steps), its API, app-password, recovery and verification
#     tokens, its links to outside sign-in sources, and its OAuth and SAML grants;
#   - issue 462's unlock record (contract R.7.4: wrong passwords before now no longer count for it), by the sign-in
#     server's own clock; source and network holds are untouched;
#   - password resets by email held (attributes.workforce.recovery_mail_held), so a mailbox the organisation has lost
#     can't reset the account again; lift the hold with `./bin/reset-admin.sh --allow-reset-mail` once the mailbox is
#     the organisation's again, or the recovery address has been changed. The sign-in server enforces the hold itself
#     (the Workforce blueprint's workforce-recovery-staff-only refuses a reset link while it is set, final review of
#     the controller bundle, findings 2 and 6); the script checks that the installed set-up does, and says so if it
#     doesn't (an older set-up: then only a Workforce version that checks the hold would);
#   - a record of this recovery (custom_workforce_admin_recovery).
# After the commit it looks three more times, a second apart, and ends anything a request already under way added.
# Unlike the controller it doesn't end admin's sessions inside Workforce itself (the application's own database):
# sign admin out there, or let them expire (Workforce issue 493).
#
#   ./bin/reset-admin.sh                          prints a verification phrase
#   ./bin/reset-admin.sh --confirm <phrase>       the recovery
#   ./bin/reset-admin.sh --allow-reset-mail       lifts the hold on password resets by email
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .env ] || { echo "No .env here. Run ./bin/install.sh first."; exit 1; }
# shellcheck disable=SC1091
. ./.env

# Docker daemon selection (rootless-aware) lives in ONE place: bin/lib/common.sh.
# shellcheck source=lib/common.sh
. ./bin/lib/common.sh
use_docker_socket

# The program run inside authentik-server (`python -c`, the image's python as its PATH finds it: a fixed path broke
# when authentik moved its venv, second review of the controller bundle, finding 2). Its first line on stdin says what
# to do: "reset" (then the password and this recovery's id) or "allow-mail" (then a request id). It prints its counts
# (and, after a reset, "mail hold: enforced", "not enforced" or "unknown"), then one last line: OK, NOT_HELD, NONE,
# REFUSED, FAILED <kind of error> (nothing changed) or UNSURE (the time limit struck while committing). Never the
# password.
# bin/tests/authentik-lock-e2e.sh runs it on the pinned authentik, with a real database.
RESET_PY="$(cat <<'PYEOF'
import os, signal, sys, time
def late(*_):
    raise RuntimeError("took too long")
signal.signal(signal.SIGALRM, late)
signal.alarm(60)
sys.path.insert(0, "/authentik")
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "authentik.root.settings")
import django
django.setup()
import hashlib, uuid
from datetime import timedelta, timezone as tz
from django.apps import apps
from django.db import connection, transaction
from django.utils import timezone
from authentik.core.models import AuthenticatedSession, Session, Token, User, UserSourceConnection
from authentik.events.models import Event
from authentik.stages.authenticator import device_classes

# Issue 462's lock per account (ansible/roles/authentik/templates/password-pause.py: WF_LOCK_ACCOUNT, wf_lock_key).
WF_LOCK_ACCOUNT = 1464225605
WF_KEEP = 31 * 86400
# Every kind of grant authentik 2026.8.5 keeps for a person (models with a user foreign key that let something act as
# them), by label; a label this authentik doesn't have is skipped. The same list as the controller's recovery.
GRANTS = ("authentik_providers_oauth2.AccessToken", "authentik_providers_oauth2.RefreshToken",
          "authentik_providers_oauth2.AuthorizationCode", "authentik_providers_oauth2.DeviceToken",
          "authentik_providers_saml.SAMLSession", "authentik_endpoints_connectors_agent.DeviceAuthenticationToken")
ACTED = ("authentik_providers_oauth2.AccessToken", "authentik_providers_oauth2.RefreshToken",
         "authentik_providers_oauth2.AuthorizationCode")

def model(label):
    try:
        return apps.get_model(label)
    except LookupError:
        return None

def held(u):
    """The sessions holding a sign-in for this account between its steps (its flow plan names it)."""
    from authentik.core.sessions import SessionStore
    from authentik.flows.planner import PLAN_CONTEXT_PENDING_USER
    from authentik.flows.views.executor import SESSION_KEY_PLAN
    store, out = SessionStore(), []
    for s in Session.objects.all().only("session_key", "session_data"):
        try:
            plan = store.decode(bytes(s.session_data)).get(SESSION_KEY_PLAN)
        except Exception:
            continue
        who = getattr(plan, "context", {}).get(PLAN_CONTEXT_PENDING_USER) if plan is not None else None
        if getattr(who, "pk", None) == u.pk:
            out.append(s.session_key)
    return out

def sign_ins(u):
    out = {"sessions": AuthenticatedSession.objects.filter(user=u).count(), "held": len(held(u)),
           "tokens": Token.objects.filter(user=u).count(), "sources": UserSourceConnection.objects.filter(user=u).count()}
    for label in GRANTS:
        m = model(label)
        if m is not None:
            out[label] = m.objects.filter(user=u).count() + (m.objects.filter(actor=u).count() if label in ACTED else 0)
    return out

def end_sign_ins(u):
    """Ends them all (the counts of what was there). Sessions first, so a held sign-in has nothing to finish in."""
    found = sign_ins(u)
    Session.objects.filter(session_key__in=held(u)).delete()
    Session.objects.filter(authenticatedsession__user=u).delete()
    AuthenticatedSession.objects.filter(user=u).delete()
    Token.objects.filter(user=u).delete()
    UserSourceConnection.objects.filter(user=u).delete()
    for label in GRANTS:
        m = model(label)
        if m is not None:
            m.objects.filter(user=u).delete()
            if label in ACTED:
                m.objects.filter(actor=u).delete()
    return found

def lock_key(text):
    return int(hashlib.sha256(text.encode("utf-8")).hexdigest()[:8], 16) - 2 ** 31

def iso(t):
    return t.astimezone(tz.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")

def uuid4(text):
    try:
        return str(uuid.UUID(text, version=4)) == text
    except ValueError:
        return False

def record(action, u, at, **context):
    e = Event.new(action, app="workforce", **context)
    e.expires = at + timedelta(seconds=WF_KEEP)
    e.user = {"pk": int(u.pk), "username": str(u.username)}
    e.save()

def mail_hold_enforced():
    """Whether this sign-in server itself refuses a reset link while the hold is set: every brand's recovery flow has
    an enabled, not negated binding of the Workforce blueprint's workforce-recovery-staff-only, which reads it (since the
    final review of the controller bundle), and needs every binding to pass (review of 497af97, finding 3: with "any",
    another binding that passes lets a link through). No recovery flow: no link at all."""
    from authentik.brands.models import Brand
    from authentik.policies.expression.models import ExpressionPolicy
    from authentik.policies.models import PolicyBinding, PolicyEngineMode
    flows = [b.flow_recovery for b in Brand.objects.exclude(flow_recovery=None)]
    return all(f.policy_engine_mode == PolicyEngineMode.MODE_ALL and ExpressionPolicy.objects.filter(
        pk__in=PolicyBinding.objects.filter(target__pbm_uuid=f.pbm_uuid, enabled=True, negate=False).values("policy_id"),
        name="workforce-recovery-staff-only",
        expression__contains='wf.get("recovery_mail_held") is not None').exists() for f in flows)

def forget_recovery_answers():
    """Drops authentik's cached answers of every binding on a recovery flow (review of 497af97, finding 1). authentik
    keeps a policy's answer per account for cache.timeout_policies (300 s by default) and forgets it when a policy or
    binding changes, never an account: without this, a reset link made or checked in the 5 minutes before the hold was
    set lets the next one through, and after the lift a cached refusal stays. Run after the commit, never inside it (a
    request under way would put the old answer back). The same keys authentik's own invalidate_policy_cache drops."""
    from django.core.cache import cache
    from django.db.models import Q
    from authentik.brands.models import Brand
    from authentik.flows.models import Flow, FlowDesignation
    from authentik.policies.models import PolicyBinding
    from authentik.policies.types import CACHE_PREFIX
    targets = set(Flow.objects.filter(designation=FlowDesignation.RECOVERY).values_list("pbm_uuid", flat=True))
    targets |= set(Brand.objects.exclude(flow_recovery=None).values_list("flow_recovery__pbm_uuid", flat=True))
    for b in PolicyBinding.objects.filter(Q(target__pbm_uuid__in=targets) | Q(policy__name="workforce-recovery-staff-only")):
        cache.delete_many(cache.keys(f"{CACHE_PREFIX}{b.policy_binding_uuid.hex}_*") or [])

def mail_held(wf):
    """Whether this workforce attributes value holds resets by email: as the recovery flow's policy reads it (present
    and not null; review of 497af97, finding 2)."""
    return isinstance(wf, dict) and wf.get("recovery_mail_held") is not None

def workforce_attrs(u):
    wf = (u.attributes or {}).get("workforce")
    return dict(wf) if isinstance(wf, dict) else {}

def said(counts):
    return ", ".join("%s %d" % (k, v) for k, v in sorted(counts.items()) if v) or "none"

mode = sys.stdin.readline().strip()
first = User.objects.filter(username="admin", type="internal").first()
if first is None:
    print("NONE")
    sys.exit(0)
committing = False
try:
    if mode == "reset":
        pw = sys.stdin.readline().rstrip("\n")
        rid = sys.stdin.readline().strip()
        if len(pw) < 24 or not uuid4(rid):
            print("REFUSED")
            sys.exit(0)
        with transaction.atomic():
            with connection.cursor() as cursor:
                cursor.execute("SELECT pg_advisory_xact_lock(%s, %s)", [WF_LOCK_ACCOUNT, lock_key("account:%d" % int(first.pk))])
            u = User.objects.select_for_update().get(pk=first.pk)
            at = timezone.now()
            removed = {}
            for m in device_classes():
                removed[m._meta.label] = m.objects.filter(user=u).count()
                m.objects.filter(user=u).delete()
            ended = end_sign_ins(u)
            u.set_password(pw, signal=False)
            u.is_active = True
            wf = workforce_attrs(u)
            wf.pop("password_unlocked_at", None)
            wf.pop("controller_set", None)
            wf["recovery_mail_held"] = {"recovery": rid, "at": iso(at)}
            u.attributes = dict(u.attributes or {}, workforce=wf)
            u.save()
            record("workforce_password_unlock", u, at, wf_unlock_id=rid, wf_user_pk=int(u.pk), wf_at=iso(at), wf_was_paused=False)
            record("workforce_admin_recovery", u, at, wf_recovery_id=rid, wf_at=iso(at), wf_removed=removed, wf_ended=ended,
                   wf_by="reset-admin.sh")
            # Everything is written: from here the COMMIT runs. If the time limit strikes now nobody can say whether
            # it committed, so the answer is UNSURE, never FAILED.
            committing = True
        signal.alarm(0)
        try:
            forget_recovery_answers()
            forgot = True
        except Exception:
            forgot = False
        print("removed sign-in methods: " + said(removed))
        print("ended: " + said(ended))
        try:
            found = {}
            for look in range(3):
                time.sleep(1)
                # A request under way at the commit may have cached the old answer since.
                forget_recovery_answers()
                for k, v in end_sign_ins(User.objects.get(pk=first.pk)).items():
                    found[k] = found.get(k, 0) + v
            print("ended after the change (requests already under way): " + said(found))
            print("still there: " + said(sign_ins(User.objects.get(pk=first.pk))))
        except Exception as e:
            print("looking again after the change failed (%s): run this again to be sure" % type(e).__name__)
        try:
            print("mail hold: " + ("enforced" if forgot and mail_hold_enforced() else "not enforced"))
        except Exception:
            print("mail hold: unknown")
        print("OK")
    elif mode == "allow-mail":
        rid = sys.stdin.readline().strip()
        if not uuid4(rid):
            print("REFUSED")
            sys.exit(0)
        with transaction.atomic():
            with connection.cursor() as cursor:
                cursor.execute("SELECT pg_advisory_xact_lock(%s, %s)", [WF_LOCK_ACCOUNT, lock_key("account:%d" % int(first.pk))])
            u = User.objects.select_for_update().get(pk=first.pk)
            wf = (u.attributes or {}).get("workforce")
            if not mail_held(wf):
                out = "NOT_HELD"
            else:
                at = timezone.now()
                wf = dict(wf)
                was = wf.pop("recovery_mail_held")
                held_by = was.get("recovery") if isinstance(was, dict) else None
                u.attributes = dict(u.attributes or {}, workforce=wf)
                u.save(update_fields=["attributes"])
                record("workforce_admin_recovery_mail_allowed", u, at, wf_request_id=rid, wf_held_by=held_by, wf_at=iso(at),
                       wf_by="reset-admin.sh")
                out = "OK"
            committing = True
        signal.alarm(0)
        if out == "OK":
            try:
                forget_recovery_answers()
            except Exception:
                print("cache: kept")
        print(out)
    else:
        print("REFUSED")
except Exception as e:
    # An error inside the transaction, before its commit, undid all of it. Only the kind of error is said, never its
    # text (which may quote values).
    print("UNSURE" if committing else "FAILED " + type(e).__name__)
PYEOF
)"

run_py() { # run_py: RESET_PY in authentik-server, stdin passed through; its output (authentik's JSON log lines left out)
  docker compose exec -T -w / authentik-server python -c "$RESET_PY" 2>&1 | grep -v '^{'
}
uuid() { cat /proc/sys/kernel/random/uuid; }

if [ "${1:-}" = "--allow-reset-mail" ]; then
  OUT="$(printf 'allow-mail\n%s\n' "$(uuid)" | run_py)" || true
  case "$(printf '%s\n' "$OUT" | tail -1)" in
    OK) if printf '%s\n' "$OUT" | grep -qx 'cache: kept'; then
          echo "Password resets by email for 'admin' are allowed again (within 5 minutes: the sign-in server may still refuse until then)."
        else
          echo "Password resets by email for 'admin' are allowed again."
        fi ;;
    NOT_HELD) echo "Password resets by email for 'admin' weren't held: nothing changed." ;;
    *) echo "That didn't work ($(printf '%s\n' "$OUT" | tail -1)) — send ./bin/doctor.sh output to support."; exit 1 ;;
  esac
  exit 0
fi

if [ "$#" -lt 2 ] || [ "$1" != "--confirm" ] || [ -z "${2:-}" ]; then
  PHRASE="care-angels-$(openssl rand -hex 3)"
  cat <<EOF

Password reset — identity verification required.

This command sets a new password for the 'admin' account, removes every sign-in
method it has and ends its sessions. To prevent unauthorised resets it only works
with a one-time phrase:

  1. Call support and ask for an administrator password reset.
  2. Read them this verification phrase: ${PHRASE}
  3. If support confirms your identity, run:

       ./bin/reset-admin.sh --confirm ${PHRASE}

EOF
  exit 0
fi

PHRASE="$2"
case "$PHRASE" in
  care-angels-*) : ;;
  *) echo "The phrase must look like care-angels-xxxxxx — run without arguments to obtain one."; exit 1 ;;
esac

NEW_PW="$(openssl rand -base64 18)"
echo "Setting a new administrator password…"
# printf is the shell's own: the password is in no process's arguments, only on the pipe to the container.
OUT="$(printf 'reset\n%s\n%s\n' "$NEW_PW" "$(uuid)" | run_py)" || true
case "$(printf '%s\n' "$OUT" | tail -1)" in
  OK) : ;;
  UNSURE) echo "Reset unsure: it may or may not have been applied, and the password below isn't shown. Run it again."
          exit 1 ;;
  *) echo "Reset failed ($(printf '%s\n' "$OUT" | tail -1)): nothing was changed. Send ./bin/doctor.sh output to support."
     exit 1 ;;
esac
printf '%s\n' "$OUT" | sed '$d' | grep -v '^mail hold: ' | sed 's/^/  /'
if printf '%s\n' "$OUT" | grep -qx 'mail hold: enforced'; then
  HOLD="Password resets by email
for 'admin' are held: the sign-in server makes no reset link for it until you run
./bin/reset-admin.sh --allow-reset-mail (do that once its email address is one
only your organisation reads)."
else
  HOLD="Password resets by email
for 'admin' are recorded as held, BUT this sign-in server's set-up doesn't enforce
that itself (it is older than this script, its recovery flow was changed, or it
couldn't be checked; or its cached answers couldn't be cleared, which can let a
link through for 5 minutes): whoever reads
admin's recovery email address may still be sent a reset link. Bring the set-up
up to date now (./bin/update.sh), and until then change admin's email address in
Workforce to one only your organisation reads."
fi

cat <<EOF

Done. Every sign-in method on the account has been removed (add an authenticator
app again from Workforce if you want one), its sessions and tokens at the sign-in
server ended, and any pause after wrong passwords lifted. ${HOLD} Workforce's own
sessions for 'admin' aren't ended by this: sign it out there.

The administrator password is now:

  ${NEW_PW}

Shown once and saved nowhere: store it in your password manager now. Sign in at
https://${AUTH_HOSTNAME} (user: admin).
EOF
