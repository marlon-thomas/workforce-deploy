# Self-test for the sign-in server's wrong-password pause, connection throttle, alerts and wrong-code count (Workforce
# issue 462): the decision in ansible/roles/authentik/templates/password-pause.py and code-tries.py, with python3
# alone. The same vectors as the application's PasswordPause (password-pause-vectors.json, a copy of the private
# repo's src/test/resources/identity/ file: change both together). The authentik part (the lock, the records, real
# requests at the same moment) runs on the pinned authentik in bin/tests/authentik-lock-e2e.sh.
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TEMPLATES = os.path.join(HERE, "..", "..", "ansible", "roles", "authentik", "templates")
ns = {}
for name in ("password-pause.py", "code-tries.py"):
    src = open(os.path.join(TEMPLATES, name), encoding="utf-8").read()
    exec(compile(src, name, "exec"), ns)
g = ns.get
passed = failed = 0


def check(name, got, want):
    global passed, failed
    if got == want:
        passed += 1
    else:
        failed += 1
        print("FAIL: %s: expected %r, got %r" % (name, want, got))


T = g("wf_parse_time")

# ---- the shared vectors
vectors = json.load(open(os.path.join(HERE, "password-pause-vectors.json"), encoding="utf-8"))
check("vectors: schema", vectors.get("schema"), 1)
for address, key in vectors["keys"]:
    check("connection key of " + address, g("wf_connection_key")(address), key)
for address, key in vectors["networkKeys"]:
    check("network key of " + address, g("wf_network_key")(address), key)
for case in vectors["cases"]:
    events = [{"at": T(e["at"]), "kind": e["kind"], "try": e.get("try"), "account": e["account"],
               "conn": g("wf_connection_key")(e["conn"])} for e in case["events"]]
    markers = dict((k, T(v)) for k, v in case["markers"].items())
    d = g("wf_decide")(events, case["account"], case["conn"], markers, T(case["now"]))
    want = case["expect"]
    check("vector: " + case["name"], (d["paused"], d["throttled"], d["until"]),
          (want["paused"], want["throttled"], T(want["until"]) if want["until"] else None))

# ---- which requests are counted: exactly those the password stage checks
pr = g("wf_password_request")
check("a POST with a password", pr("POST", {"component": "ak-stage-password", "password": "x"}), True)
check("a password of spaces is checked (no trimming)", pr("POST", {"password": "  "}), True)
check("a number is checked as text", pr("POST", {"password": 12345}), True)
check("an empty password is never checked", pr("POST", {"password": ""}), False)
check("null", pr("POST", {"password": None}), False)
check("true", pr("POST", {"password": True}), False)
check("a list", pr("POST", {"password": ["x"]}), False)
check("no password", pr("POST", {"component": "ak-stage-password"}), False)
check("a page load", pr("GET", {"password": "x"}), False)
check("another method", pr("PUT", {"password": "x"}), False)
check("data that isn't a form", pr("POST", "password=x"), False)
cr = g("wf_code_request")
check("a code for this sign-in", cr("POST", {"code": "123456"}, ["email"]), True)
check("asking for an email code isn't a code try", cr("POST", {"selected_challenge": {"device_class": "email"}}, ["email"]), False)
check("an empty code", cr("POST", {"code": ""}, ["totp"]), False)
check("a code of spaces (trimmed to blank, never checked)", cr("POST", {"code": "   "}, ["totp"]), False)
check("no method that takes codes", cr("POST", {"code": "123456"}, ["webauthn"]), False)
check("a page load", cr("GET", {"code": "123456"}, ["totp"]), False)

# ---- the marker: the later of a new password and an unlock; a time far ahead is ignored
now = T("2026-11-14T12:00:00Z")
wm = g("wf_marker")
check("no marker", wm(None, {}, now), None)
check("a password change", wm("2026-11-14T10:00:00+00:00", {}, now), T("2026-11-14T10:00:00Z"))
check("an unlock after it wins", wm("2026-11-14T10:00:00Z", {"workforce": {"password_unlocked_at": "2026-11-14T11:00:00Z"}}, now),
      T("2026-11-14T11:00:00Z"))
check("a password change after the unlock wins", wm("2026-11-14T11:30:00Z", {"workforce": {"password_unlocked_at": "2026-11-14T11:00:00Z"}}, now),
      T("2026-11-14T11:30:00Z"))
check("an unlock 2 minutes ahead counts", wm(None, {"workforce": {"password_unlocked_at": "2026-11-14T12:02:00Z"}}, now),
      T("2026-11-14T12:02:00Z"))
check("one further ahead is ignored", wm(None, {"workforce": {"password_unlocked_at": "2026-11-14T13:00:00Z"}}, now), None)
check("an unreadable one is ignored", wm(None, {"workforce": {"password_unlocked_at": "soon"}}, now), None)
check("attributes not a dict", wm(None, "x", now), None)

# ---- names nobody has: a keyed digest, never the name
nk = g("wf_name_key")
ak = g("wf_account_key")
k1 = nk("server-secret", "PAT.SMITH@EXAMPLE.ORG")
check("it is a digest", bool(re.fullmatch(r"n:[0-9a-f]{32}", k1)), True)
check("keyed by the server's secret", k1 != nk("another-secret", "PAT.SMITH@EXAMPLE.ORG"), True)
# Review finding 1: the name is folded by the database exactly as authentik's lookup folds it (UPPER, in
# wf_ak_subject), never by Python here: Python's lower() joined spellings (the Kelvin sign K, U+212A, and k) that
# authentik's lookup keeps apart, so they shared a count only for a name nobody has.
check("the key takes the folded name as it is", nk("s", "KIM") != nk("s", "\u212aIM"), True)
check("a real account found by its username: its number", ak(7, "PAT", "PAT", "s"), "u:7")
check("with no typed name kept: its number", ak(7, None, "PAT", "s"), "u:7")
check("an unknown name: its name's key", ak(None, "PAT", "PAT", "s"), nk("s", "PAT"))
check("a real account found by its email: that name's key, as for a name nobody has",
      ak(7, "PAT@EXAMPLE.ORG", "PAT", "s"), nk("s", "PAT@EXAMPLE.ORG"))
check("so its email and an unknown email count alike", ak(7, "PAT@EXAMPLE.ORG", "PAT", "s"),
      ak(None, "PAT@EXAMPLE.ORG", "PAT@EXAMPLE.ORG", "s"))

# ---- refused requests are never recorded: a pause doesn't move while it is attacked
def tries(account, conn, *minutes, base="2026-11-14T10:00:00Z"):
    return [{"at": T(base) + 60 * m, "kind": "try", "try": "%s-%s-%s" % (account, conn, m), "account": account,
             "conn": conn} for m in minutes]

ev = tries("u:7", "203.0.113.5", 0, 1, 2, 3, 4)
for minute in (5, 10, 18.9):
    d = g("wf_decide")(ev, "u:7", "203.0.113.5", {}, T("2026-11-14T10:00:00Z") + 60 * minute)
    check("attacked at minute %s: paused until 10:19 still" % minute, (d["paused"], d["until"]), (True, T("2026-11-14T10:19:00Z")))
d = g("wf_decide")(ev, "u:7", "203.0.113.5", {}, T("2026-11-14T10:19:00Z"))
check("and it ends then", d["paused"], False)

# ---- alerts: spread over accounts, over connections, a throttle starting; never a decision
sp = g("wf_spread")
base = T("2026-11-14T10:00:00Z")
ev = [{"at": base + i, "kind": "try", "try": "t%d" % i, "account": "n:%032x" % i, "conn": "198.51.100.7"} for i in range(4)]
check("four accounts from one connection: no alert", [a["wf_kind"] for a in sp(ev, "n:x", "198.51.100.7", None, base + 10)], [])
ev.append({"at": base + 5, "kind": "try", "try": "t5", "account": "u:9", "conn": "198.51.100.7"})
alerts = sp(ev, "u:9", "198.51.100.7", 9, base + 10)
check("five: connection-spread", [a["wf_kind"] for a in alerts], ["connection-spread"])
check("naming only real accounts", alerts[0]["wf_user_pks"], [9])
check("with counts", (alerts[0]["wf_accounts"], alerts[0]["wf_wrong"]), (5, 5))
v6 = [{"at": base + i, "kind": "try", "try": "v%d" % i, "account": "n:%032x" % i, "conn": "2001:db8:7:%x::/64" % i} for i in range(5)]
alerts = sp(v6, "n:%032x" % 4, "2001:db8:7:4::/64", None, base + 10)
check("five names from five /64s of one /48: connection-spread for the /48",
      [(a["wf_kind"], a["wf_conn"], a["wf_connections"]) for a in alerts], [("connection-spread", "2001:db8:7::/48", 5)])
ev = tries("u:3", "203.0.113.1", 0) + tries("u:3", "203.0.113.2", 1) + tries("u:3", "203.0.113.3", 2)
alerts = sp(ev, "u:3", "203.0.113.3", 3, base + 200)
check("one account from three connections in an hour: account-spread", [a["wf_kind"] for a in alerts], ["account-spread"])
check("about that account", (alerts[0]["wf_user_pk"], alerts[0]["wf_connections"]), (3, 3))
# A person typed under their username and their email: one account for alerts (the records' wf_user_pk).
ev = tries("u:3", "203.0.113.1", 0) + tries("n:e3", "203.0.113.2", 1)
for e in ev:
    e["pk"] = 3
ev += [dict(x, pk=3) for x in tries("n:e3", "203.0.113.3", 2)]
check("one person tried under two names from three connections: account-spread",
      [a["wf_kind"] for a in sp(ev, "n:e3", "203.0.113.3", 3, base + 200)], ["account-spread"])
check("but each name keeps its own pause", (g("wf_decide")(tries("u:3", "203.0.113.1", 0, 1, 2) + tries("n:e3", "203.0.113.1", 3, 4),
      "u:3", "203.0.113.1", {}, base + 300)["paused"]), False)
check("an unknown name never raises an account alert", sp(tries("n:aa", "203.0.113.1", 0) + tries("n:aa", "203.0.113.2", 1)
      + tries("n:aa", "203.0.113.3", 2), "n:aa", "203.0.113.3", None, base + 200, {}), [])
ev = []
for h in range(20):
    ev += tries("u:4", "203.0.113.%d" % (h % 2 + 1), 70 * h)
check("twenty wrong for one account in a day: account-spread", [a["wf_kind"] for a in sp(ev, "u:4", "203.0.113.1", 4, base + 70 * 19 * 60 + 1)],
      ["account-spread"])
before = [{"at": base + i, "kind": "try", "try": "s%d" % i, "account": "n:%032x" % i, "conn": "192.0.2.9"} for i in range(9)]
after = before + [{"at": base + 9, "kind": "try", "try": "s9", "account": "n:%032x" % 9, "conn": "192.0.2.9"}]
kinds = [a["wf_kind"] for a in sp(after, "n:%032x" % 9, "192.0.2.9", None, base + 10, before=before)]
check("the tenth stranger: throttled (and a spread)", sorted(kinds), ["connection-spread", "throttled"])
more = after + [{"at": base + 11, "kind": "try", "try": "s11", "account": "n:%032x" % 11, "conn": "192.0.2.9"}]
check("the throttle is announced once, when it starts",
      [a["wf_kind"] for a in sp(more, "n:%032x" % 11, "192.0.2.9", None, base + 12, before=after) if a["wf_kind"] == "throttled"], [])
check("alert keys", (g("wf_alert_key")({"wf_kind": "account-spread", "wf_user_pk": 4}),
                     g("wf_alert_key")({"wf_kind": "throttled", "wf_conn": "192.0.2.9"})), (("wf_user_pk", 4), ("wf_conn", "192.0.2.9")))

# ---- a workplace /48 is still bounded (review finding 3): the pause counts by /64, so it bounds nothing there
def rights(accounts, prefix, when="2026-11-11T09:00:00Z"):
    out = []
    for i, a in enumerate(accounts):
        out += [{"at": T(when), "kind": k, "try": "ok-" + a, "account": a, "conn": "%s:%x::/64" % (prefix, 0xa0 + i)}
                for k in ("try", "right")]
    return out
office = rights(["u:20", "u:21", "u:22"], "2001:db8:9")
spray = lambda n: [{"at": base + i, "kind": "try", "try": "w%d" % i, "account": "u:7",
                    "conn": "2001:db8:9:%x::/64" % (i + 1)} for i in range(n)]
dec = g("wf_decide")
check("a workplace /48: 299 wrong from as many /64s, not held", dec(office + spray(299), "u:7", "2001:db8:9:ffff::1", {}, base + 400)["throttled"], False)
check("the 300th holds it", dec(office + spray(300), "u:7", "2001:db8:9:ffff::1", {}, base + 400)["throttled"], True)
check("until 15 minutes after the 300th", dec(office + spray(300), "u:7", "2001:db8:9:ffff::1", {}, base + 400)["until"], base + 299 + 900)
check("a /48 that isn't a workplace: after 30, as before", dec(spray(30), "u:7", "2001:db8:9:ffff::1", {}, base + 400)["throttled"], True)
check("a workplace connection itself is still never throttled", dec(rights(["u:20", "u:21", "u:22"], "2001:db8:9")[:2]
      + [dict(e, conn="2001:db8:9:a0::/64") for e in rights(["u:21", "u:22"], "2001:db8:9")]
      + [{"at": base + i, "kind": "try", "try": "x%d" % i, "account": "n:%032x" % i, "conn": "2001:db8:9:a0::/64"} for i in range(29)],
      "u:7", "2001:db8:9:a0::5", {}, base + 400)["throttled"], False)

# ---- the throttle never depends on the name: a real account, a known one and an unknown name get the same answer
ev = [{"at": base + i, "kind": "try", "try": "w%d" % i, "account": "n:%032x" % i, "conn": "192.0.2.50"} for i in range(10)]
ev += [{"at": base - 86400, "kind": "right", "try": "r1", "account": "u:1", "conn": "192.0.2.50"},
       {"at": base - 86400, "kind": "try", "try": "r1", "account": "u:1", "conn": "192.0.2.50"}]
answers = set()
for who, marker in (("u:1", None), ("u:2", base - 60), ("n:" + "e" * 32, None)):
    d = g("wf_decide")(ev, who, "192.0.2.50", {who: marker} if marker else {}, base + 20)
    answers.add((d["paused"], d["throttled"], d["until"]))
check("throttled: the same answer for a known account, one just unlocked and an unknown name", answers,
      set([(False, True, base + 9 + 900)]))
for n in (2, 3):
    ev2 = ev + [{"at": base - 86400, "kind": "right", "try": "x%d" % n, "account": "u:%d" % n, "conn": "192.0.2.50"}]
    if n == 3:
        ev2 += [{"at": base - 86400, "kind": "right", "try": "x2", "account": "u:2", "conn": "192.0.2.50"}]
    d = g("wf_decide")(ev2, "n:" + "e" * 32, "192.0.2.50", {}, base + 20)
    check("%d real accounts with a right password there: %s" % (n, "a workplace, never throttled" if n == 3 else "not yet a workplace"),
          d["throttled"], n != 3)
check("unknown names never make a workplace", g("wf_workplace")([{"at": base, "kind": "right", "try": "a", "account": "n:%d" % i,
      "conn": "192.0.2.50"} for i in range(5)], "192.0.2.50", False, base + 1), False)

# ---- wrong codes: their own count, by account
cp = g("wf_codes_paused")
codes = [(base + 60 * i, "c%d" % i) for i in range(5)]
check("five wrong codes: paused until 15 minutes after the fifth", cp(codes, set(), base + 300), base + 240 + 900)
check("four are not", cp(codes[:4], set(), base + 300), None)
check("a right one doesn't count", cp(codes, {"c2"}, base + 300), None)
check("over after 15 minutes", cp(codes, set(), base + 240 + 900), None)

# ---- the files are Jinja includes: nothing that Jinja would read as its own
for name in ("password-pause.py", "code-tries.py"):
    src = open(os.path.join(TEMPLATES, name), encoding="utf-8").read()
    check(name + " has no Jinja delimiters", re.findall(r"\{\{|\}\}|\{%|%\}|\{#|#\}", src), [])
bp = open(os.path.join(TEMPLATES, "workforce-app.yaml.j2"), encoding="utf-8").read()
for policy in ("workforce-password-paused", "workforce-password-try", "workforce-password-right",
               "workforce-client-address", "workforce-code-try", "workforce-codes-paused"):
    m = re.search(r"name: " + policy + r"\n      expression: \|\n\{% filter indent\(8, true\) %\}\n\{% include 'password-pause.py' %\}", bp)
    check(policy + " includes the decision", bool(m), True)

print("password pause self-test: %d passed, %d failed" % (passed, failed))
sys.exit(1 if failed else 0)
