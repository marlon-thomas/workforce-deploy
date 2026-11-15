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

# Workforce issue 462 review of 15 November 2026, finding 1: the password stage checks a password with exactly one
# hash for a real name and for one nobody has. authentik 2026.8.5's TokenBackend hashes again for an unknown name only
# (an oracle for which names exist), so it is never among the backends.
pw_stage = next((e for e in entries if "authentik_stages_password.passwordstage" in e
                 and "name: default-authentication-password" in e), "")
check("the password stage is restated", "authentik.core.auth.InbuiltBackend" in pw_stage)
check("without TokenBackend (an extra hash for unknown names only)",
      "authentik.core.auth.TokenBackend" not in pw_stage)

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

# Any refusing policy we bind on a gate must not be outvoted: its target needs all of its policies to pass.
for e in entries:
    if "policybinding" in e and ("wf-no-first-run" in e or "wf-password-may-try" in e or "wf-password-unchanged" in e):
        m = re.search(r"target: !KeyOf ([\w-]+)", e)
        target = next((t for t in entries if m and ("id: " + m.group(1) + "\n") in t), "")
        check("the target of a refusing binding needs all its policies (%s)" % (m.group(1) if m else "?"),
              "policy_engine_mode: all" in target)

# Second review, finding 6, and its third review: the lock is checked on every password sent, not once per
# sign-in. The password stage runs only while the account isn't locked (re-checked on every request to it)...
pw = binding("default-authentication-flow", "default-authentication-password")
check("the password step is re-checked on every try", "re_evaluate_policies: true" in pw and order(pw) == 20)
check("all of its policies must pass", "policy_engine_mode: all" in pw)
check("one of them: may try (issue 462), a yes for go on, never negated (issue 474 review, finding 2)",
      any("policybinding" in e and "target: !KeyOf wf-password-binding" in e and "policy: !KeyOf wf-password-may-try" in e
          and "negate" not in e and "failure_result: false" in e for e in entries))
check("the old negated policy is removed (its binding goes with it)",
      any("name: workforce-password-try }" in e and "state: absent" in e for e in entries)
      and not any("id: wf-password-try\n" in e for e in entries))
# ... and nothing goes past it without a password checked in this sign-in (a skipped password step refuses).
guard = binding("default-authentication-flow", "wf-password-not-checked-stage")
check("no password checked, no further", guard and 22 < order(guard) < 25 and "re_evaluate_policies: true" in guard)
guard_policy = next((e for e in entries if "id: wf-password-not-checked\n" in e), "")
check("decided by the password stage's own record", 'plan.context.get("user_backend")' in guard_policy)
check("an error refuses too", any("target: !KeyOf wf-password-not-checked-binding" in e and "failure_result: true" in e
                                  for e in entries))
password = next((e for e in entries if "name: default-authentication-password }" in e), "")
check("a wrong password can be retyped (authentik's default)", "failed_attempts_before_cancel: 5" in password)
# Wrong codes count too; after too many, even a right code doesn't sign anyone in.
after_code = binding("default-authentication-flow", "wf-too-many-tries-after-code")
check("the lock again after the code", after_code and 30 < order(after_code) < 100 and "re_evaluate_policies: true" in after_code)
check("by the wrong codes' own count, an error refusing", any("target: !KeyOf wf-too-many-tries-after-code-binding" in e
      and "policy: !KeyOf wf-codes-paused" in e and "failure_result: true" in e for e in entries))

# Workforce issue 462 (contract 3.1): wrong passwords pause one account on one connection; codes count apart.
def bound(binding_id, policy):
    return next((e for e in entries if "policybinding" in e and "target: !KeyOf " + binding_id + "," in e
                 and "policy: !KeyOf " + policy + " " in e), "")
check("15: the source held, before the password", order(binding("default-authentication-flow", "wf-connection-throttled-stage")) == 15
      and "failure_result: true" in bound("wf-connection-throttled-binding", "wf-password-throttled"))
check("16: the /48 tightened, before the password (contract R.6)", order(binding("default-authentication-flow",
      "wf-network-tightened-stage")) == 16 and "failure_result: true" in bound("wf-network-tightened-binding", "wf-network-tightened"))
check("17: the pair paused, before the password", order(binding("default-authentication-flow", "wf-too-many-tries-stage")) == 17
      and "failure_result: true" in bound("wf-too-many-tries-binding", "wf-password-paused"))
check("21: not checked and the source held: its words", order(binding("default-authentication-flow",
      "wf-connection-throttled-after-stage")) == 21 and bound("wf-connection-throttled-after-binding", "wf-password-not-checked-throttled"))
check("22: not checked and the /48 tightened: its words", order(binding("default-authentication-flow",
      "wf-network-tightened-after-stage")) == 22 and bound("wf-network-tightened-after-binding", "wf-password-not-checked-network"))
right = binding("default-authentication-flow", "wf-password-right-stage")
check("24: the try marked right, after the password and its guard", order(right) == 24 and "re_evaluate_policies: true" in right
      and "evaluate_on_plan: false" in right and bound("wf-password-right-binding", "wf-password-right"))
check("29: wrong codes, before the code step", "failure_result: true" in bound("wf-too-many-tries-codes-binding", "wf-codes-paused"))
check("30: each code typed recorded, never skipping the code step (it passes, an error too)",
      "failure_result: true" in bound("wf-code-step-binding", "wf-code-try"))
check("the old locks are removed", all(any(k in e and "state: absent" in e for e in entries) for k in
      ("name: workforce-too-many-tries }", "name: workforce-too-many-tries-by-account }")))
for key in ("wf-password-paused", "wf-password-may-try", "wf-password-right", "wf-code-try", "wf-codes-paused"):
    policy = next((e for e in entries if "id: " + key + "\n" in e), "")
    body = "\n".join(l for l in policy.splitlines() if not l.strip().startswith("#"))
    check(key + ": authentik's reputation score isn't read", "Reputation" not in body and "update_score" not in body)
    check(key + ": the address is authentik's own, through wf_ak_subject", "wf_ak_subject(request)" in body
          or "wf_ak_decide(request)" in body)
try_policy = next((e for e in entries if "id: wf-password-may-try\n" in e), "")
check("a try is recorded only for a request the stage checks", "wf_password_request(http.method, http.data)" in try_policy)
check("under the try's locks (the connection's, its /48's unless proven, the pair's)",
      "wf_ak_lock(cursor, *wf_ak_try_locks(account, conn, proven))" in try_policy
      and "proven = wf_ak_proven_now(conn, cfg, timezone.now().timestamp())" in try_policy)
pp = open(sys.argv[1].replace("workforce-app.yaml.j2", "password-pause.py"), encoding="utf-8").read()
check("the /48's lock, between the connection's and the pair's (review finding 4)",
      'return (WF_LOCK_CONN, "conn:" + conn), net, (WF_LOCK_PAIR, "pair:" + account + "|" + conn)' in pp
      and 'net = (WF_LOCK_NET, "net:" + wf_network_key(conn)) if ":" in conn and not proven else None' in pp)
check("in one transaction", "transaction.atomic" in try_policy)
ident = next((e for e in entries if "name: default-authentication-identification }" in e), "")
check("a name nobody has goes on like a real one", "pretend_user_exists: true" in ident)
check("the password step shows every name as typed (review finding 1)", "show_matched_user: false" in ident)
# Fix round (contract 3.8): a pause and a throttle each have their own words, the same for any name.
pause_words = "Too many wrong passwords for this name, from this connection. Wait 15 minutes, then try again."
throttle_words = "Too many wrong passwords from this connection. Wait 15 minutes, or use another connection"
network_words = "Too many wrong passwords from this network. Wait 15 minutes, or use another connection"
for stage, words in (("wf-too-many-tries-stage", pause_words), ("wf-password-not-checked-stage", pause_words),
                     ("wf-connection-throttled-stage", throttle_words), ("wf-connection-throttled-after-stage", throttle_words),
                     ("wf-network-tightened-stage", network_words), ("wf-network-tightened-after-stage", network_words)):
    e = next((x for x in entries if "id: " + stage + "\n" in x), "")
    check(stage + ": its words", words in " ".join(e.split()))
for key in ("wf-password-throttled", "wf-password-not-checked-throttled", "wf-network-tightened", "wf-password-not-checked-network"):
    policy = next((e for e in entries if "id: " + key + "\n" in e), "")
    check(key + ": the address is authentik's own, through wf_ak_decide", "wf_ak_decide(request)" in policy)
check("the source's and the network's words win over the pair's (an unlock lifts only the pair)",
      'decision["rule"] == "network"' in next((e for e in entries if "id: wf-network-tightened\n" in e), "")
      and 'decision["source"] and' in next((e for e in entries if "id: wf-password-throttled\n" in e), ""))
# Contract R.7: the sign-in status code is bound nowhere (never part of a sign-in), logs no execution, catches every
# error, and the decisions never read an account attribute (the application's credential can write those).
status = next((e for e in entries if "id: wf-sign-in-status-code\n" in e), "")
check("the status code: present, its execution not logged", "execution_logging: false" in status
      and "return wf_ak_status_answer(request)" in status and 'return {"v": 1, "known": False, "why": "error"}' in status)
check("bound nowhere", not any("policybinding" in e and "wf-sign-in-status-code" in e for e in entries))
check("no decision reads the old unlock attribute", "password_unlocked_at" not in pp.split("# ---- the sign-in status interface")[0]
      .split("def wf_marker")[0] and "attributes" not in pp.split("def wf_ak_marker")[1].split("def ")[0])
signed = next((e for e in entries if "id: wf-codes-paused\n" in e), "")
check("a completed sign-in (password and code) is recorded at 31 (contract R.2)",
      "wf_ak_record(WF_SIGNED, WF_KEEP_SIGNED, address, person, wf_user_pk=int(pk), wf_conn=conn)" in signed
      and "if marked and not paused and wf_signs_in(person, plan):" in signed)
# Contract 3.9: authentik's user-settings page can't write attributes.workforce (only the name and locale fields).
settings_stage = next((e for e in entries if "name: default-user-settings }" in e), "")
check("the user's own settings have only authentik's name and locale fields (attributes.settings.locale)",
      re.findall(r"\[name, (default-user-settings-field-[a-z]+)\]", settings_stage)
      == ["default-user-settings-field-name", "default-user-settings-field-locale"])
probe = next((e for e in entries if "id: wf-client-address-flow\n" in e), "")
check("the address check: a flow anyone may open, with no stages", "authentication: none" in probe
      and not any("flowstagebinding" in e and "wf-client-address-flow" in e for e in entries))
check("whose one policy always refuses with the address", bound("wf-client-address-flow", "wf-client-address-policy")
      and any("id: wf-client-address-policy" in e and "return False" in e and "workforce-client-address=" in e for e in entries))

# Workforce issue 474: a sign-in held between the password step and the login can't finish once the password changed.
seen_b = bound("wf-password-right-binding", "wf-password-seen")
check("474: 24 records what the password step saw (an error refuses there)",
      order(right) == 24 and "order: 1," in seen_b and "failure_result: true" in seen_b and "negate" not in seen_b)
check("474: before the code step, the only stage that could replace the plan's account",
      order(right) < order(binding("default-authentication-flow", "default-authentication-mfa-validation")) == 30)
seen_p = next((e for e in entries if "id: wf-password-seen\n" in e), "")
seen_ak = "\n".join(l for l in seen_p.split("---- the authentik part ----")[-1].splitlines() if not l.strip().startswith("#"))
check("474: from the flow plan's account (the backend's own, as checked), never the database",
      'person = plan.context.get("pending_user")' in seen_ak and 'getattr(person, "password", None)' in seen_ak
      and "objects" not in seen_ak)
check("474: recorded once, only once a password was checked, and it refuses only on an error",
      'not plan.context.get("user_backend") or WF_PLAN_SEEN in plan.context' in seen_ak
      and "return True" not in seen_ak.split("except Exception")[0])
replaced_p = next((e for e in entries if "id: wf-password-replaced\n" in e), "")
check("474: the check compares with the account as the primary database has it now",
      'User.objects.using("default").filter(pk=seen["pk"]).values_list("pk", "password", "is_active").first()' in replaced_p
      and "return wf_password_replaced(seen, pending_pk, current) is not None" in replaced_p)
check("474: no flow plan refuses", "if plan is None:\n                return True" in replaced_p)
for key in ("wf-password-seen", "wf-password-replaced"):
    e = next((x for x in entries if "id: " + key + "\n" in x), "")
    check("474: " + key + " includes the rule", "{% include 'password-unchanged.py' %}" in e)
deny_474 = binding("default-authentication-flow", "wf-password-replaced-stage")
check("474: 99, just before the login, re-checked when reached, an error refusing", order(deny_474) == 99
      and "re_evaluate_policies: true" in deny_474 and "evaluate_on_plan: false" in deny_474
      and "failure_result: true" in bound("wf-password-replaced-binding", "wf-password-replaced"))
login_b = binding("default-authentication-flow", "default-authentication-login")
check("474: the login step's own binding: 100, re-checked when reached, all its policies",
      order(login_b) == 100 and "re_evaluate_policies: true" in login_b and "evaluate_on_plan: false" in login_b
      and "policy_engine_mode: all" in login_b and "id: wf-login-binding\n" in login_b)
login_pb = bound("wf-login-binding", "wf-password-unchanged")
check("474: the same comparison there, as a yes for sign in, never negated (review finding 1)",
      bool(login_pb) and "negate" not in login_pb and "failure_result: false" in login_pb)
check("474: the negated binding it replaces is removed", "state: absent" in bound("wf-login-binding", "wf-password-replaced"))
unchanged_p = next((e for e in entries if "id: wf-password-unchanged\n" in e), "")
check("474: workforce-password-unchanged: the same comparison, answered the other way round",
      'User.objects.using("default").filter(pk=seen["pk"]).values_list("pk", "password", "is_active").first()' in unchanged_p
      and "return wf_password_replaced(seen, pending_pk, current) is None" in unchanged_p
      and "if plan is None:\n                return False" in unchanged_p
      and "{% include 'password-unchanged.py' %}" in unchanged_p)
others = [order(e) for e in entries if "flowstagebinding" in e and "slug, default-authentication-flow]" in e
          and "state: absent" not in e and e not in (deny_474, login_b)]
check("474: nothing else between the check and the login", bool(others) and max(others) < 99)
words_474 = " ".join(next((x for x in entries if "id: wf-password-replaced-stage\n" in x), "").split())
check("474: authentik's own words for a wrong password, whatever the reason",
      "deny_message: >- Invalid password. Please sign in again." in words_474
      and not any(w in words_474.lower() for w in ("changed", "account", "admin", "exist", "reset")))
check("474: no other flow here signs anyone in (enrolment and reset links don't)",
      not any("flowstagebinding" in e and "state: absent" not in e and "slug, default-authentication-flow]" not in e
              and any(s in e for s in ("wf-enrollment-login", "default-authentication-login", "userloginstage"))
              for e in entries))

# Second review of the controller bundle, findings 1 and 6: whoever chooses the emergency administrator's password
# (a reset link, the change-password page) needs at least 16 characters zxcvbn rates hard to guess; authentik's own
# change-password page, with authentik's 8-character rule, refuses that account.
strong = next((e for e in entries if "id: wf-emergency-password\n" in e), "")
check("the emergency password rule: at least 16 characters", "len(password) < 16" in strong)
check("and zxcvbn's score of 3 or more", '["score"] < 3' in strong)
prompt = next((e for e in entries if "id: wf-new-password-prompt" in e), "")
check("on the reset and change-password pages", "- !KeyOf wf-emergency-password" in prompt
      and any("id: wf-recovery-flow" in e for e in entries) and binding("wf-recovery-flow", "wf-new-password-prompt")
      and binding("wf-password-change-flow", "wf-new-password-prompt"))
check("authentik's own change-password page refuses it", any("policybinding" in e and "target: !KeyOf wf-default-password-change" in e
                                                           and "policy: !KeyOf wf-emergency-not-here" in e for e in entries)
      and any("id: wf-default-password-change\n" in e and "slug: default-password-change }" in e and "state: created" in e
              for e in entries))

# Workforce issue 474 review, findings 1 and 2: in authentik 2026.8.5 an ordinary error in an expression policy is
# "fails" (failure_result covers PolicyException only) and a negated binding turns that into "passes". So: no binding
# is negated, and every policy bound here (or checking a typed password) keeps its own code in one guard whose except
# answers, written out, the value that refuses on every binding it has: True on a deny stage's binding or the code
# step's (a step that must run), False on a gate (a flow, the password and login steps) or a password check. Each of
# its bindings' failure_result says the same.
check("no binding is negated", not any("policybinding" in e and "negate:" in e for e in entries))
ids = {}
for e in entries:
    m = re.search(r"\n    id: ([\w-]+)\n", "\n" + e)
    if m:
        ids[m.group(1)] = e
deny_stages = set(k for k, e in ids.items() if e.startswith("model: authentik_stages_deny.denystage"))
MUST_RUN = {"wf-code-step-binding"}
def refusing_for_target(key):
    e = ids.get(key, "")
    m = re.search(r"stage: !KeyOf ([\w-]+)", e)
    if "flowstagebinding" in e and m and m.group(1) in deny_stages:
        return True
    return key in MUST_RUN
want = {}   # policy key or name -> the refusing value
for e in entries:
    if "policybinding" in e and "state: absent" not in e:
        tm, pm = re.search(r"target: !KeyOf ([\w-]+)", e), re.search(r"policy: !KeyOf ([\w-]+)", e)
        if not (tm and pm):
            check("a binding names its target and policy by key: " + e.split("\n")[0], False)
            continue
        v = refusing_for_target(tm.group(1))
        check("%s on %s: one refusing value for all its bindings" % (pm.group(1), tm.group(1)), want.setdefault(pm.group(1), v) == v)
        fr = re.search(r"failure_result: (true|false)", e)
        check("%s on %s: failure_result says the same as its guard" % (pm.group(1), tm.group(1)),
              (fr.group(1) == "true" if fr else False) == v)
for e in entries:
    for m in re.finditer(r"- !KeyOf ([\w-]+)", e.split("validation_policies:")[1] if "validation_policies:" in e else ""):
        want.setdefault(m.group(1), False)
# authentik's own policies on the password and code steps (its default flow binds them; restated here by name).
for name in ("default-authentication-flow-password-stage", "default-authentication-flow-authenticator-validate-stage"):
    want[name] = True
CONSTANT = {"wf-no-first-run"}   # "return False" and nothing else: nothing to fail
guarded = 0
for e in entries:
    if "authentik_policies_expression.expressionpolicy" not in e or "state: absent" in e:
        continue
    key = (re.search(r"\n    id: ([\w-]+)\n", "\n" + e) or [None, None])[1]
    name = re.search(r"\n      name: ([\w-]+)\n", e).group(1)
    if key in ("wf-sign-in-status-code", "wf-sign-in-code"):
        continue   # bound nowhere (checked above and below); the status code has its own try/except, the shared code none
    if key in CONSTANT:
        check(key + ": a constant refusal", e.rstrip().endswith("expression: |\n        return False"))
        continue
    v = want.get(key, want.get(name))
    check(name + ": bound or used, with a refusing value", v is not None)
    body = e.split("expression: |\n", 1)[1]
    own = body.split("# ---- the authentik part ----\n", 1)[-1]
    lines = []
    for l in own.split("\n"):
        if l and not l.startswith("        "):
            break   # the entry's own end (a comment or the next key follows)
        lines.append(l)
    while lines and lines[-1] == "":
        lines.pop()
    check(name + ": its own code is one guard", lines[0] == "        try:"
          and all(l == "" or l.startswith("            ") for l in lines[1:-7]) and lines[-7] == "        except Exception as wf_error:"
          and sum(1 for l in lines if l.startswith("        ") and not l.startswith("         ")) == 2)
    check(name + ": whose except answers the refusing value (%s), whatever its log line does" % v,
          lines[-6:] == ["            try:",
                         '                ak_logger.warning("workforce: an error in a sign-in policy, so it refuses", policy="%s",' % name,
                         # Final review, finding 7: the kind of error only, never its text (which may quote values).
                         '                                  error=type(wf_error).__name__)',
                         "            except Exception:", "                pass", "            return %s" % v])
    guarded += 1
check("every guarded policy counted (23)", guarded == 23)
check("no guard logs an error's text (finding 7)", "str(wf_error)" not in text)

# Final review of the controller bundle, findings 1 and 5: authentik 2026.8.5 runs each policy of a binding in the
# request's own thread and sends its result (a pickled PolicyResult, which carries the binding and with it the policy's
# whole expression) down a pipe before anything reads it, so a result over 64 KiB blocks that thread for good: a hung
# sign-in, and enough of them leave authentik answering nobody. Every expression is measured here as Ansible's Jinja
# renders it (its includes put in); each must stay at 32 KiB or less, leaving the rest of the pipe for the binding, the
# messages and the log lines (about 1.5 to 3 KB measured live). authentik-lock-e2e.sh measures the pickled results.
import os
TEMPLATES = os.path.dirname(sys.argv[1])
def rendered_expression(e):
    """The expression of this entry as authentik holds it (YAML's indent removed, the includes put in)."""
    out = []
    for l in e.split("expression: |\n", 1)[1].split("\n"):
        inc = re.match(r"\{% include '([\w.-]+)' %\}$", l)
        if inc:
            out.extend(open(os.path.join(TEMPLATES, inc.group(1)), encoding="utf-8").read().rstrip("\n").split("\n"))
        elif l.startswith("{%"):
            continue
        elif l.startswith("        ") or l == "":
            out.append(l[8:])
        else:
            break
    return "\n".join(out).rstrip("\n") + "\n"
LIMIT = 32 * 1024
SHARED = "wf-sign-in-code"
sizes = {}
for e in entries:
    if "authentik_policies_expression.expressionpolicy" in e and "state: absent" not in e:
        key = (re.search(r"\n    id: ([\w-]+)\n", "\n" + e) or [None, None])[1] \
            or re.search(r"\n      name: ([\w-]+)\n", e).group(1)
        sizes[key] = len(rendered_expression(e).encode("utf-8"))
print("expression sizes (bytes, largest first):", sorted(sizes.items(), key=lambda kv: -kv[1])[:4])
for key, size in sorted(sizes.items()):
    if key != SHARED:
        check("%s: its expression is %d bytes, at most %d (the 64 KiB pipe, findings 1 and 5)" % (key, size, LIMIT), size <= LIMIT)
# The shared code is kept once, in a policy that is never bound (so never run as a policy, and never sent down a
# pipe): every policy that needs it loads it by name, inside its guard (an error there refuses like any other).
shared = ids.get(SHARED, "")
check("the shared sign-in code is kept once, in workforce-sign-in-code", "name: workforce-sign-in-code\n" in shared
      and "execution_logging: false" in shared and "{% include 'password-pause.py' %}\n{% include 'code-tries.py' %}\n" in shared
      and "# ---- the authentik part" not in shared)
check("which is bound nowhere", not any("policybinding" in e and SHARED in e for e in entries)
      and not any(SHARED in e for e in entries if "validation_policies:" in e))
check("and no other entry includes password-pause.py or code-tries.py", [k for k, e in ids.items() if k != SHARED
      and ("include 'password-pause.py'" in e or "include 'code-tries.py'" in e)] == [])
LOAD = ('''            from authentik.policies.expression.models import ExpressionPolicy as WfShared
            wf_shared = dict()
            exec(WfShared.objects.get(name="workforce-sign-in-code").expression, wf_shared)
            globals().update((k, v) for k, v in wf_shared.items() if k[:3] in ("wf_", "WF_"))
''')
loaders = sorted(k for k, e in ids.items() if LOAD in e)
check("the policies that use it load it, as the first thing inside their guard: %s" % loaders,
      loaders == sorted(["wf-password-throttled", "wf-network-tightened", "wf-password-paused", "wf-password-may-try",
                         "wf-password-right", "wf-password-not-checked-throttled", "wf-password-not-checked-network",
                         "wf-client-address-policy", "wf-sign-in-status-code", "wf-code-try", "wf-codes-paused"])
      and all(("        try:\n" + LOAD) in re.sub(r"\n            # [^\n]*", "", ids[k]) for k in loaders))

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
RESET="$REPO/bin/reset-admin.sh"
check "the operator's recovery removes every sign-in method of every class authentik has (new problem 6, issue 487)" \
  "$(grep -c 'for m in device_classes():' "$RESET")/$(grep -c 'removed\[m._meta.label\] = m.objects.filter(user=u).count()' "$RESET")" 1/1
check "and lifts its wrong-password pause by an unlock record (issue 462, contract R.7.4), not an attribute or by deleting records" \
  "$(grep -c 'record("workforce_password_unlock", u, at, wf_unlock_id=rid' "$RESET")/$(grep -c 'wf\["password_unlocked_at"\] = \|Reputation' "$RESET")" 1/0
check "and ends its sessions, held sign-ins, tokens and grants (issue 487)" "$(grep -c 'ended = end_sign_ins(u)' "$RESET")" 1
check "all of it in one transaction, under issue 462's lock on the account" \
  "$(grep -c 'with transaction.atomic():' "$RESET")/$(grep -c 'pg_advisory_xact_lock(%s, %s)", \[WF_LOCK_ACCOUNT' "$RESET")" 2/2
check "and holds password resets by email until --allow-reset-mail" \
  "$(grep -c 'wf\["recovery_mail_held"\] = {"recovery": rid' "$RESET")/$(grep -c -- '--allow-reset-mail)\|"--allow-reset-mail" \]' "$RESET")" 1/1
# Final review of the controller bundle, findings 2 and 6: the hold is enforced by the sign-in server itself (the recovery
# flow's policy refuses a link while it is set), and the script says the hold is in force only when it finds that.
BP="$REPO/ansible/roles/authentik/templates/workforce-app.yaml.j2"
check "the recovery flow's policy refuses a reset link while resets by email are held" \
  "$(awk '/name: workforce-recovery-staff-only$/{on=1} on && /if isinstance\(wf, dict\) and wf.get\("recovery_mail_held"\) is not None:/{print "yes"; exit}' "$BP")" yes
check "reset-admin.sh looks for exactly that check on the recovery flow" \
  "$(grep -c "expression__contains='wf.get(\"recovery_mail_held\") is not None')" "$RESET")" 1
check "and says the hold is in force only when it finds it" \
  "$(grep -c "^  HOLD=\"Password resets by email$" "$RESET")/$(grep -c "grep -qx 'mail hold: enforced'" "$RESET")" 2/1
# Live run and review of 497af97, finding 1: authentik keeps a policy's answer per account for up to 300 s and forgets
# it when a policy or binding changes, never an account; so after the hold is set or lifted the script drops the cached
# answers of the recovery flows' bindings, after the commit (and again while it looks for requests under way), and says
# "enforced" only when that worked. Finding 2: "held" means the same as in the policy (present and not null), and the
# lift removes whatever is there. Finding 3: the recovery flow needs every binding to pass, and the script checks that.
check "the recovery flow needs every binding to pass (finding 3)" \
  "$(awk '/id: wf-recovery-flow$/{on=1; next} on && /^  - /{exit} on && /^      policy_engine_mode: all$/{print "yes"; exit}' "$BP")" yes
check "reset-admin.sh drops authentik's cached answers of the recovery bindings, as authentik's own signal does" \
  "$(grep -c 'cache.keys(f"{CACHE_PREFIX}{b.policy_binding_uuid.hex}_\*")' "$RESET")" 1
check "after each commit and on each look for requests under way" \
  "$(grep -c 'forget_recovery_answers()' "$RESET")" 4
check "and says enforced only when that worked and the flow needs every binding to pass" \
  "$(grep -c '"enforced" if forgot and mail_hold_enforced()' "$RESET")/$(grep -c 'f.policy_engine_mode == PolicyEngineMode.MODE_ALL' "$RESET")" 1/1
check "held means present and not null everywhere (finding 2)" \
  "$(grep -c 'if not wf.get("recovery_mail_held")\|wf.get("recovery_mail_held") or' "$RESET")/$(grep -c 'def mail_held(wf):' "$RESET")" 0/1
check "the new password: on stdin only, never on disk, in the environment or on a command line (issue 487)" \
  "$(grep -c 'secrets/\|WF_NEW_PW\| -e ' "$RESET")/$(grep -c "printf 'reset\\\\n%s\\\\n%s\\\\n' \"\$NEW_PW\" \"\$(uuid)\" | run_py" "$RESET")" 0/1
# Workforce issue 462 (contract R.8): the application's service account gets no event access, and loses any it had.
INVITE="$REPO/ansible/roles/authentik/files/invite-service-account.py"
check "invite-service-account.py grants no view_event" "$(python3 -I -c 'import re,sys; t=open(sys.argv[1]).read(); m=re.search(r"for perm in \((.*?)\):\n    assign\(perm\)", t, re.S); print(int("view_event" in m.group(1)) if m else "no list")' "$INVITE")" 0
check "and revokes it (globally and on objects), then fails if anything still gives it" \
  "$(grep -c 'RoleModelPermission.objects.filter(role=r, permission=VIEW_EVENT).delete()\|RoleObjectPermission.objects.filter(role=r, permission=VIEW_EVENT).delete()\|fresh.has_perm("authentik_events.view_event")\|raise SystemExit("workforce-invites: "' "$INVITE")" 4
# Review of 497af97: a role that may change any policy or binding (globally or on one object) could change the shared
# sign-in code or unbind the hold, so the application's account must have none.
check "invite-service-account.py fails if the account may add, change or delete a policy or binding" \
  "$(grep -c 'raise SystemExit("workforce-invites: it may add, change or delete' "$INVITE")" 1
check "the status interface: object permissions on that one mapping only" \
  "$(grep -c 'role.assign_perms(\["authentik_core.view_propertymapping", "authentik_core.add_propertymapping"\], mapping)' "$INVITE")" 1
check "and the old unlock attribute is removed from every account" "$(grep -c 'wf.pop("password_unlocked_at", None)' "$INVITE")" 1
# Second review of the controller bundle, finding 4: the lock's policy reads authentik's own models, so a new authentik
# pin needs bin/tests/authentik-policies-e2e.sh run against it (reset-admin.sh's program: authentik-lock-e2e.sh, section 9).
VERIFIED="$(sed -n 's/^VERIFIED_AUTHENTIK=//p' "$HERE/authentik-policies-e2e.sh")"
check "authentik-policies-e2e.sh was run on the pinned authentik (set VERIFIED_AUTHENTIK once it passes)" \
  "$(grep -c "image: ghcr.io/goauthentik/server:${VERIFIED}@sha256:" "$REPO/compose.yaml")" 2
# Workforce issue 462: the pause relies on how the pinned authentik runs a sign-in. On a new pin, check again in its
# source, then run bin/tests/authentik-lock-e2e.sh on it and set its VERIFIED_AUTHENTIK: (1) the server (Rust,
# ak-axum, in 2026.8) takes the client's address from X-Forwarded-For only from AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS
# and hands Python exactly that address; (2) ClientIPMiddleware reads the first X-Forwarded-For entry, and
# X-authentik-remote-ip only with an internal service account's token; (3) pretend_user_exists gives an unsaved
# pending user; (4) the password stage's field is "password" (CharField, not trimmed) and its binding's policies run
# on every request to it (ReevaluateMarker, cache off); (5) a policy's write to the flow plan is saved with stage_ok;
# (6) a flow's refusing policy's message reaches the access-denied answer; (7) the events API filters by action and
# orders by -created; (8) no other place checks a password (the OAuth token endpoint takes app-password tokens only).
LOCK_VERIFIED="$(sed -n 's/^VERIFIED_AUTHENTIK=//p' "$HERE/authentik-lock-e2e.sh")"
check "authentik-lock-e2e.sh was run on the pinned authentik (issue 462; set its VERIFIED_AUTHENTIK once it passes)" \
  "$(grep -c "image: ghcr.io/goauthentik/server:${LOCK_VERIFIED}@sha256:" "$REPO/compose.yaml")" 2
check "reset-admin.sh and doctor.sh find authentik's python on its PATH, not by a fixed venv path (finding 2)" \
  "$(grep -c '/ak-root/' "$REPO/bin/reset-admin.sh" "$REPO/bin/doctor.sh" | awk -F: '{s+=$2} END {print s}')" 0
check "a typed emergency password is at least 16 characters (finding 1)" \
  "$(grep -c '"${#ADMIN_PASSWORD}" -lt 16' "$REPO/bin/install.sh")" 1
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
