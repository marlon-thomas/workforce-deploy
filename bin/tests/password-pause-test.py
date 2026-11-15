# Self-test for the sign-in server's wrong-password pause, connection throttle, alerts and wrong-code count (Workforce
# issue 462, contract section R of 15 November 2026): the decision in ansible/roles/authentik/templates/password-pause.py
# and code-tries.py, with python3 alone, against password-pause-vectors.json (kept here only since 15 November: the
# application asks the sign-in server instead of computing a pause). The authentik part (the lock, the records, real
# requests at the same moment, the status interface) runs on the pinned authentik in bin/tests/authentik-lock-e2e.sh.
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
check("vectors: schema", vectors.get("schema"), 2)
L = g("wf_limits")
for address, key in vectors["keys"]:
    check("connection key of " + address, g("wf_connection_key")(address), key)
for address, key in vectors["networkKeys"]:
    check("network key of " + address, g("wf_network_key")(address), key)
for case in vectors["cases"]:
    events = [{"at": T(e["at"]), "kind": e["kind"], "try": e.get("try"), "account": e["account"],
               "conn": g("wf_connection_key")(e["conn"])} for e in case["events"]]
    markers = dict((k, T(v)) for k, v in case["markers"].items())
    d = g("wf_decide")(events, case["account"], case["conn"], markers, T(case["now"]), L(case.get("config", {})))
    want = case["expect"]
    check("vector: " + case["name"], (d["paused"], d["throttled"], d["until"], d["rule"]),
          (want["paused"], want["throttled"], T(want["until"]) if want["until"] else None, want.get("rule")))

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

# ---- V5, the marker: the later of a new password and the newest unlock record; never an attribute
now = T("2026-11-14T12:00:00Z")
wm = g("wf_marker")
check("no marker", wm(None, [], now), None)
check("a password change", wm("2026-11-14T10:00:00+00:00", [], now), T("2026-11-14T10:00:00Z"))
check("an unlock record after it wins", wm("2026-11-14T10:00:00Z", ["2026-11-14T11:00:00.250000Z"], now),
      T("2026-11-14T11:00:00.25Z"))
check("a password change after the unlock wins", wm("2026-11-14T11:30:00Z", ["2026-11-14T11:00:00Z"], now),
      T("2026-11-14T11:30:00Z"))
check("the newest of several unlocks", wm(None, ["2026-11-14T09:00:00Z", "2026-11-14T11:00:00Z"], now), T("2026-11-14T11:00:00Z"))
check("one far ahead is ignored", wm(None, ["2026-11-14T13:00:00Z"], now), None)
check("an unreadable one is ignored", wm(None, ["soon", True], now), None)
check("an attribute is never a marker: password_unlocked_at set to now in attributes is ignored",
      wm(None, {"workforce": {"password_unlocked_at": "2026-11-14T12:00:00Z"}}, now), None)

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
    ev2 = ev + [{"at": base - 86400, "kind": "signed", "account": "u:%d" % k, "conn": "192.0.2.50"} for k in range(1, n + 1)]
    d = g("wf_decide")(ev2, "n:" + "e" * 32, "192.0.2.50", {}, base + 20)
    check("%d accounts with a completed sign-in there: %s" % (n, "a workplace, its cap is 50" if n == 3 else "not yet a workplace"),
          d["throttled"], n != 3)
cfg0 = L({})
check("unknown names never make a workplace", g("wf_workplace")([{"at": base, "kind": "signed", "account": "n:%d" % i,
      "conn": "192.0.2.50"} for i in range(5)], "192.0.2.50", False, cfg0, base + 1), False)

# ---- the settings (contract R.3, R.4): read from the sign-in server's environment, checked again there
import ipaddress
check("defaults", (cfg0["source"], cfg0["network"], cfg0["confirmed"], cfg0["confirmed_networks"], cfg0["warnings"]),
      (50, 300, [], [], []))
c = L({"SIGN_IN_WORKPLACE_SOURCE_LIMIT": "100", "SIGN_IN_WORKPLACE_NETWORK_LIMIT": "1000"})
check("the highest allowed", (c["source"], c["network"], c["warnings"]), (100, 1000, []))
c = L({"SIGN_IN_WORKPLACE_SOURCE_LIMIT": "19", "SIGN_IN_WORKPLACE_NETWORK_LIMIT": "1001"})
check("out of range: the defaults, named", (c["source"], c["network"], c["warnings"]),
      (50, 300, ["SIGN_IN_WORKPLACE_NETWORK_LIMIT", "SIGN_IN_WORKPLACE_SOURCE_LIMIT"]))
c = L({"SIGN_IN_WORKPLACE_SOURCE_LIMIT": "100", "SIGN_IN_WORKPLACE_NETWORK_LIMIT": "100"})
check("a source limit not below the network's: both defaults (one source could tighten a /48 alone)",
      (c["source"], c["network"], len(c["warnings"])), (50, 300, 2))
c = L({"SIGN_IN_WORKPLACE_SOURCE_LIMIT": " 60 ", "SIGN_IN_WORKPLACE_NETWORK_LIMIT": "-5"})
check("spaces are trimmed; a negative isn't a number", (c["source"], c["network"]), (60, 300))
c = L({"CLIENT_ADDRESSES_CONFIRMED": "203.0.113.7, 2001:db8:1:2::/64 198.51.100.0/24,[2001:db8:9::5],::ffff:192.0.2.9,nonsense,0.0.0.0/0,::/0,10.0.0.0/7"})
check("confirmed addresses, keys and ranges as sources; nonsense named; the whole internet raises no limit",
      ([str(n) for n in c["confirmed"]], c["confirmed_networks"], c["readiness_only"], c["warnings"]),
      (["203.0.113.7/32", "2001:db8:1:2::/64", "198.51.100.0/24", "2001:db8:9::5/128", "192.0.2.9/32"], [], 3,
       ["CLIENT_ADDRESSES_CONFIRMED"]))
wc = g("wf_confirmed")
wpl = g("wf_workplace")
check("an address in a confirmed range is confirmed", wc("198.51.100.77", c["confirmed"]), True)
check("one outside isn't", wc("198.51.101.1", c["confirmed"]), False)
check("a /64 holding a confirmed address is", wc("2001:db8:9::/64", c["confirmed"]), True)
# Review of 15 November 2026, findings 3 and 17: an entry raises a limit only where it is no wider than what it makes a
# workplace. A confirmed address or /64 never makes its whole /48 a workplace network; an entry from a /48 to a /63
# makes its /48 one and nothing more; wider ones (and IPv4 wider than a /24) are for the readiness check only.
check("a confirmed address doesn't make its /48 a workplace network", wpl([], "2001:db8:9::/48", True, c, base), False)
c = L({"CLIENT_ADDRESSES_CONFIRMED": "2001:db8:a::/48 2001:db8:b:100::/56,2001:db8::/32 198.51.0.0/16 10.0.0.0/8 198.51.7.0/24"})
check("a /48 and a /56 confirm networks; a /32 and IPv4 wider than a /24 confirm the readiness check only",
      ([str(n) for n in c["confirmed"]], [str(n) for n in c["confirmed_networks"]], c["readiness_only"], c["warnings"]),
      (["198.51.7.0/24"], ["2001:db8:a::/48", "2001:db8:b:100::/56"], 3, []))
check("a confirmed /48 is a workplace network", wpl([], "2001:db8:a::/48", True, c, base), True)
check("and so is the /48 holding a confirmed /56", wpl([], "2001:db8:b::/48", True, c, base), True)
check("but none of their /64s is a workplace source", [wpl([], k, False, c, base) for k in ("2001:db8:a:1::/64", "2001:db8:b:100::/64")],
      [False, False])
check("nor proven", g("wf_proven")([], "2001:db8:a:1::/64", c, base), False)
check("an address in a confirmed /16 is no workplace source", wpl([], "198.51.8.1", False, c, base), False)
check("one in a confirmed /24 is", wpl([], "198.51.7.200", False, c, base), True)
check("an IPv4 range never confirms an IPv6 source", wc("::ffff:0:0/96", c["confirmed"]), False)
check("nothing that isn't an address", wc("nonsense", c["confirmed"]), False)

# ---- alerts when a hold begins (contract R.3, R.6.6): which kind, and the affected accounts
before = [{"at": base + i, "kind": "try", "try": "o%d" % i, "account": "n:%032x" % i, "conn": "203.0.113.70"} for i in range(49)]
office_cfg = L({"CLIENT_ADDRESSES_CONFIRMED": "203.0.113.64/28"})
signed = [{"at": base - 3600, "kind": "signed", "account": "u:%d" % k, "conn": "203.0.113.70"} for k in (31, 32)]
after = signed + before + [{"at": base + 49, "kind": "try", "try": "o49", "account": "n:%032x" % 49, "conn": "203.0.113.70"}]
al = [a for a in sp(after, "n:%032x" % 49, "203.0.113.70", None, base + 50, before=signed + before, cfg=office_cfg)
      if a["wf_kind"] != "connection-spread"]
check("the 50th at a workplace source: workplace-throttled, naming the people who sign in there",
      [(a["wf_kind"], a["wf_workplace"], a["wf_affected_pks"], a["wf_wrong"]) for a in al], [("workplace-throttled", True, [31, 32], 50)])
check("no alert before it", [a["wf_kind"] for a in sp(signed + before, "n:%032x" % 48, "203.0.113.70", None, base + 49,
      before=signed + before[:-1], cfg=office_cfg) if a["wf_kind"] != "connection-spread"], [])
v6 = [{"at": base + i, "kind": "try", "try": "z%d" % i, "account": "n:%032x" % i, "conn": "2001:db8:7:%x::/64" % (i + 1)} for i in range(29)]
proven6 = [{"at": base - 3600, "kind": "signed", "account": "u:51", "conn": "2001:db8:7:a0::/64"}]
last = {"at": base + 29, "kind": "try", "try": "z29", "account": "n:%032x" % 29, "conn": "2001:db8:7:ff::/64"}
al = [a for a in sp(proven6 + v6 + [last], "n:%032x" % 29, "2001:db8:7:ff::/64", None, base + 30, before=proven6 + v6)
      if a["wf_kind"] == "network-tightened"]
check("the 30th wrong in an ordinary /48: network-tightened for the /48, naming who signs in there",
      [(a["wf_conn"], a["wf_workplace"], a["wf_affected_pks"], a["wf_wrong"], a["wf_connections"]) for a in al],
      [("2001:db8:7::/48", False, [51], 30, 30)])
check("every alert has the same keys", sorted(al[0].keys()), sorted(["wf_kind", "wf_conn", "wf_user_pk", "wf_user_pks", "wf_accounts",
      "wf_connections", "wf_wrong", "wf_window", "wf_workplace", "wf_affected_pks"]))

# ---- V6, the status interface's answers (contract R.7): the pair rule over every name tied to the person
st = g("wf_status")
pt = lambda account, conn, minutes, pk=7: [{"at": base + 60 * m, "kind": "try", "try": "%s%s%d" % (account, conn, m), "account": account,
                                           "conn": conn, "pk": pk} for m in minutes]
check("five under the username from one source: paused there", st(pt("u:7", "203.0.113.1", range(5)), 7, None, base + 300),
      {"paused": True, "pausedSources": 1, "until": base + 240 + 900})
check("five under the email from another: two sources, the latest end",
      st(pt("u:7", "203.0.113.1", range(5)) + pt("n:" + "e" * 32, "203.0.113.2", range(2, 7)), 7, None, base + 400),
      {"paused": True, "pausedSources": 2, "until": base + 360 + 900})
check("three and three: not paused", st(pt("u:7", "203.0.113.1", range(3)) + pt("n:" + "e" * 32, "203.0.113.1", range(3, 6)), 7, None, base + 400),
      {"paused": False, "pausedSources": 0, "until": None})
check("someone else's tries never count", st(pt("u:8", "203.0.113.1", range(5), pk=8), 7, None, base + 300)["paused"], False)
check("after the marker: lifted", st(pt("u:7", "203.0.113.1", range(5)), 7, base + 250, base + 300)["paused"], False)
check("an old marker: a later pause stands", st(pt("u:7", "203.0.113.1", range(5, 10)), 7, base + 250, base + 600)["paused"], True)

# ---- the unlock: authorisation is the caller's (authentik part); here replay, staleness and acknowledgement (R.7.4)
ud = g("wf_unlock_decide")
us = g("wf_unlock_status_decide")
uid = "0b6f1d2a-3c4d-4e5f-8a9b-0c1d2e3f4a5b"
iso_now = "2026-11-14T10:00:00Z"
check("a fresh id, the time right: apply", ud([], False, uid, 7, iso_now, base), ("apply", None))
check("119 seconds off: still", ud([], False, uid, 7, "2026-11-14T10:01:59Z", base)[0], "apply")
check("121 seconds off: stale", ud([], False, uid, 7, "2026-11-14T09:57:59Z", base)[1]["why"], "stale")
check("no time: stale", ud([], False, uid, 7, None, base)[1]["why"], "stale")
check("not a random UUID: invalid", [ud([], False, x, 7, iso_now, base)[1]["why"] for x in
      ("", None, uid.upper(), "0b6f1d2a-3c4d-1e5f-8a9b-0c1d2e3f4a5b", uid + "0")], ["invalid"] * 5)
first = ud([(base - 30, 7, True)], False, uid, 7, "2026-11-14T08:00:00Z", base)
check("the same id for the same person again: the first answer and time, nothing new, however late",
      (first[0], first[1]["applied"], first[1]["at"], first[1]["wasPaused"]), ("answer", True, "2026-11-14T09:59:30.000000Z", True))
check("the same id for another person: reused", ud([(base - 30, 7, True)], False, uid, 8, iso_now, base)[1], {"v": 1, "op": "unlock", "applied": False, "why": "reused"})
check("a voided id: reused, never applied", ud([], True, uid, 7, iso_now, base)[1]["why"], "reused")
check("asked about before it was applied: void it", us([], False, uid, 7)[0], "void")
check("then: voided", us([], True, uid, 7)[1]["voided"], True)
check("applied: its server time", us([(base, 7, False)], False, uid, 7)[1], {"v": 1, "op": "unlock-status", "applied": True, "id": uid,
      "at": "2026-11-14T10:00:00.000000Z"})
check("another person's id: reused", us([(base, 8, False)], False, uid, 7)[1]["why"], "reused")

# ---- the alerts' answer: counts, keys and numbers, nothing else
ao = g("wf_alert_out")
out = ao("e4b9c1d2-0000-4000-8000-000000000001", base, {"wf_kind": "network-tightened", "wf_conn": "2001:db8:7::/48",
         "wf_user_pk": None, "wf_user_pks": [3, "x", True], "wf_accounts": 4, "wf_connections": 30, "wf_wrong": 30,
         "wf_window": 900, "wf_workplace": False, "wf_affected_pks": [51], "secret": "never"})
check("an alert's answer", out, {"id": "e4b9c1d2-0000-4000-8000-000000000001", "at": "2026-11-14T10:00:00.000000Z",
      "kind": "network-tightened", "scope": "network", "source": "2001:db8:7::/48", "workplace": False, "accounts": 4,
      "sources": 30, "wrong": 30, "window": 900, "userPks": [3], "affectedPks": [51]})
check("account-spread is about an account", ao("x", base, {"wf_kind": "account-spread"})["scope"], "account")
check("a /48's connection-spread is about a network", ao("x", base, {"wf_kind": "connection-spread", "wf_conn": "2001:db8::/48"})["scope"], "network")
ac = g("wf_alert_cursor")
check("a cursor", ac("2026-11-14T10:00:00.000001Z|e4b9c1d2-0000-4000-8000-000000000001"),
      (base + 0.000001, "e4b9c1d2-0000-4000-8000-000000000001"))
check("no cursor", [ac(x) for x in (None, "", "x|y", "2026-11-14T10:00:00Z|' or 1=1")], [None] * 4)

# ---- a completed sign-in counts only for an active internal account whose password was checked (R.2)
class Plan:
    def __init__(self, ctx):
        self.context = ctx
class Person:
    def __init__(self, active=True, kind="internal"):
        self.is_active, self.type = active, kind
si = g("wf_signs_in")
check("staff, password checked: counts", si(Person(), Plan({"user_backend": "x"})), True)
check("no password checked: doesn't", si(Person(), Plan({})), False)
check("a service account doesn't", si(Person(kind="service_account"), Plan({"user_backend": "x"})), False)
check("an inactive one doesn't", si(Person(active=False), Plan({"user_backend": "x"})), False)
check("nobody doesn't", si(None, Plan({"user_backend": "x"})), False)

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
               "workforce-client-address", "workforce-code-try", "workforce-codes-paused", "workforce-network-tightened",
               "workforce-password-not-checked-network", "workforce-sign-in-status-code"):
    m = re.search(r"name: " + policy + r"\n(      execution_logging: false\n)?      expression: \|\n\{% filter indent\(8, true\) %\}\n\{% include 'password-pause.py' %\}", bp)
    check(policy + " includes the decision", bool(m), True)

print("password pause self-test: %d passed, %d failed" % (passed, failed))
sys.exit(1 if failed else 0)
