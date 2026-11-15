# flow-client.py — a sign-in client for bin/tests/authentik-lock-e2e.sh: authentik's flow executor driven as the
# sign-in page drives it (JSON challenges, one session per sign-in), run inside a throwaway container placed where the
# test wants the request to come from. Prints one JSON line per answer. Test-only; never on a server.
#   python flow-client.py <base> <command> [args…]       base: https://auth.e2e.test (the gateway) or http://host:9000
import json
import sys
import threading
import warnings
from urllib.parse import quote

import requests

warnings.filterwarnings("ignore")
BASE = sys.argv[1].rstrip("/")
EXTRA = {}          # headers sent with every request (forged ones, for the tests that need them)


def session():
    s = requests.Session()
    s.verify = False
    s.headers.update(EXTRA)
    s.headers["Accept"] = "application/json"
    return s


def executor(slug, query=""):
    return "%s/api/v3/flows/executor/%s/?query=%s" % (BASE, slug, quote(query, safe=""))


def outcome(r):
    try:
        j = r.json()
    except ValueError:
        return {"result": "http", "status": r.status_code, "body": r.text[:300]}
    comp = j.get("component", "")
    if comp == "ak-stage-access-denied":
        return {"result": "denied", "message": j.get("error_message") or "", "component": comp}
    errors = j.get("response_errors") or {}
    if errors:
        words = []
        for v in errors.values():
            words += [e.get("string", "") for e in v]
        return {"result": "error", "message": " | ".join(words), "component": comp}
    return {"result": "next", "component": comp, "message": j.get("error_message") or ""}


def start(name, slug="default-authentication-flow"):
    """A new sign-in up to the password step: (session, answer to the name)."""
    s = session()
    s.get(executor(slug), timeout=30)
    r = s.post(executor(slug), json={"component": "ak-stage-identification", "uid_field": name}, timeout=30)
    return s, outcome(r)


def password(s, pw, slug="default-authentication-flow"):
    return outcome(s.post(executor(slug), json={"component": "ak-stage-password", "password": pw}, timeout=30))


def main():
    cmd, args = sys.argv[2], sys.argv[3:]
    if args and args[0] == "--headers":
        EXTRA.update(json.loads(args[1]))
        args = args[2:]
    if cmd == "signin":                       # signin <name> <password> → the answer to the password
        name, pw = args
        s, first = start(name)
        if first["component"] != "ak-stage-password":
            print(json.dumps(dict(first, step="name")))
            return
        print(json.dumps(dict(password(s, pw), step="password")))
    elif cmd == "raw":                        # raw <name> <json body for the password step>: what the stage counts
        name, body = args
        s, first = start(name)
        if first["component"] != "ak-stage-password":
            print(json.dumps(dict(first, step="name")))
            return
        r = s.post(executor("default-authentication-flow"), json=json.loads(body), timeout=30)
        print(json.dumps(dict(outcome(r), step="password")))
    elif cmd == "burst":                      # burst <n> <name> <password>: n sign-ins, n passwords at one moment
        n, name, pw = int(args[0]), args[1], args[2]
        ready = []
        for _ in range(n):
            s, first = start(name)
            ready.append((s, first))
        answers = [None] * n
        gate = threading.Barrier(n)

        def fire(i):
            s, first = ready[i]
            if first["component"] != "ak-stage-password":
                answers[i] = dict(first, step="name")
                return
            gate.wait()
            answers[i] = password(s, pw)

        threads = [threading.Thread(target=fire, args=(i,)) for i in range(n)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        print(json.dumps(answers))
    elif cmd == "many":                       # many <n> <name pattern> <password> [<XFF pattern> [per] [first]]: n
        # sign-ins one after another, each a new session (TCP connection, cookie jar, flow); answers to the passwords
        n, pattern, pw = int(args[0]), args[1], args[2]
        xff = args[3] if len(args) > 3 else None
        per = int(args[4]) if len(args) > 4 else 1          # [per]: that many sign-ins from each address in turn
        first_at = int(args[5]) if len(args) > 5 else 0     # [first]: the first address's number
        out = []
        for i in range(n):
            s = session()
            if xff:
                s.headers["X-Forwarded-For"] = xff % (first_at + i // per) if "%" in xff else xff
            s.get(executor("default-authentication-flow"), timeout=30)
            r = s.post(executor("default-authentication-flow"), json={"component": "ak-stage-identification",
                                                                    "uid_field": pattern % i if "%" in pattern else pattern}, timeout=30)
            first = outcome(r)
            if first["component"] != "ak-stage-password":
                out.append(dict(first, step="name"))
                continue
            out.append(password(s, pw))
            s.close()
        print(json.dumps(out))
    elif cmd == "burstnames":                 # burstnames <n> <name pattern with %d> <password>: n sign-ins, each a
        # different name, their passwords at one moment
        n, pattern, pw = int(args[0]), args[1], args[2]
        ready = []
        for i in range(n):
            s, first = start(pattern % i)
            ready.append((s, first))
        answers = [None] * n
        gate = threading.Barrier(n)

        def fire_named(i):
            s, first = ready[i]
            if first["component"] != "ak-stage-password":
                answers[i] = dict(first, step="name")
                gate.wait()
                return
            gate.wait()
            answers[i] = password(s, pw)

        threads = [threading.Thread(target=fire_named, args=(i,)) for i in range(n)]
        for t_ in threads:
            t_.start()
        for t_ in threads:
            t_.join()
        print(json.dumps(answers))
    elif cmd == "trace":                      # trace <name> <password>: every answer in full, the name, the timings
        import time
        name, pw = args
        s = session()
        steps = []
        t0 = time.monotonic()
        r = s.get(executor("default-authentication-flow"), timeout=30)
        steps.append({"status": r.status_code, "body": r.text, "seconds": time.monotonic() - t0})
        t0 = time.monotonic()
        r = s.post(executor("default-authentication-flow"), json={"component": "ak-stage-identification", "uid_field": name}, timeout=30)
        steps.append({"status": r.status_code, "body": r.text, "seconds": time.monotonic() - t0})
        t0 = time.monotonic()
        r = s.post(executor("default-authentication-flow"), json={"component": "ak-stage-password", "password": pw}, timeout=30)
        steps.append({"status": r.status_code, "body": r.text, "seconds": time.monotonic() - t0})
        print(json.dumps(steps))
    elif cmd == "shown":                      # shown <name>: the name the password step shows for it
        s = session()
        s.get(executor("default-authentication-flow"), timeout=30)
        r = s.post(executor("default-authentication-flow"), json={"component": "ak-stage-identification",
                                                                    "uid_field": args[0]}, timeout=30)
        j = r.json()
        print(json.dumps({"component": j.get("component", ""), "pending_user": j.get("pending_user")}))
    elif cmd == "spray":                      # spray <first> <n> <prefix> <password>: names each from its own /64
        # of one /48 (X-Forwarded-For: <prefix>:<i>::1): <first> one after another, then <n> at one moment.
        first_n, n, prefix, pw = int(args[0]), int(args[1]), args[2], args[3]
        for i in range(first_n):
            s = session()
            s.headers["X-Forwarded-For"] = "%s:%x::1" % (prefix, 0x1000 + i)
            s.get(executor("default-authentication-flow"), timeout=30)
            s.post(executor("default-authentication-flow"), json={"component": "ak-stage-identification",
                                                                    "uid_field": "spray-first-%d" % i}, timeout=30)
            password(s, pw)
        ready = []
        for i in range(n):
            s = session()
            s.headers["X-Forwarded-For"] = "%s:%x::1" % (prefix, i + 1)
            s.get(executor("default-authentication-flow"), timeout=30)
            r = s.post(executor("default-authentication-flow"), json={"component": "ak-stage-identification",
                                                                        "uid_field": "spray-%d" % i}, timeout=30)
            ready.append((s, outcome(r)))
        answers = [None] * n
        gate = threading.Barrier(n)

        def fire(i):
            s, first = ready[i]
            if first["component"] != "ak-stage-password":
                answers[i] = dict(first, step="name")
                return
            gate.wait()
            answers[i] = password(s, pw)

        threads = [threading.Thread(target=fire, args=(i,)) for i in range(n)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        print(json.dumps(answers))
    elif cmd == "code":                       # code <name> <password> <code>…: the code step, codes in turn
        name, pw, codes = args[0], args[1], args[2:]
        s, first = start(name)
        r = password(s, pw)
        out = [dict(r, step="password")]
        for c in codes:
            if c.startswith("@wait"):             # @wait<seconds>: let authentik's own wait after wrong codes pass
                import time
                time.sleep(int(c[5:]))
                continue
            if c.startswith("@totp"):             # @totp or @totp:<key file>: the next code of that key never used yet
                c = totp(open("/t/" + (c[6:] or "totp.key")).read().strip())
            out.append(dict(outcome(s.post(executor("default-authentication-flow"), json={
                "component": "ak-stage-authenticator-validate", "code": c}, timeout=30)), step="code"))
        print(json.dumps(out))
    elif cmd == "hold":                       # hold <name> <password> <mark> [<key file>]: a sign-in held after
        # its password step (Workforce issue 474). The password's answer (a redirect to the next step) isn't followed;
        # /state/<mark>.held is written, and the client waits (at most 120 s) for /state/<mark>.go, then goes on: the
        # next step, the code step with the key's next code when a key is given, and then who this session is signed
        # in as (the API's own answer: 200 and the username, or 403 when nobody is).
        import os
        import time
        name, pw, mark = args[0], args[1], args[2]
        key = args[3] if len(args) > 3 else None
        s, first = start(name)
        out = [dict(first, step="name")]
        r = s.post(executor("default-authentication-flow"), json={"component": "ak-stage-password", "password": pw},
                   timeout=30, allow_redirects=False)
        out.append({"step": "password", "status": r.status_code})     # 302: accepted, on to the next step
        open("/state/%s.held" % mark, "w").write("held")
        deadline = time.time() + 120
        while not os.path.exists("/state/%s.go" % mark) and time.time() < deadline:
            time.sleep(0.2)
        nxt = dict(outcome(s.get(executor("default-authentication-flow"), timeout=30)), step="after")
        out.append(nxt)
        if key and nxt.get("component") == "ak-stage-authenticator-validate":
            out.append(dict(outcome(s.post(executor("default-authentication-flow"), json={
                "component": "ak-stage-authenticator-validate", "code": totp(open("/t/" + key).read().strip())},
                timeout=30)), step="code"))
        me = s.get(BASE + "/api/v3/core/users/me/", timeout=30)
        who = None
        if me.status_code == 200:
            try:
                who = (me.json().get("user") or {}).get("username")
            except ValueError:
                who = None
        out.append({"step": "me", "status": me.status_code, "username": who})
        print(json.dumps(out))
    elif cmd == "address":                    # address: what the sign-in server sees as this client's address
        r = session().get(executor("workforce-client-address"), timeout=30)
        print(json.dumps(outcome(r)))
    elif cmd == "recovery":                   # recovery <flow_token> <password>…: a reset link, passwords in turn
        token, pws = args[0], args[1:]
        s = session()
        out = [outcome(s.get(executor("workforce-recovery", "flow_token=" + token), timeout=30))]
        for pw in pws:
            out.append(outcome(s.post(executor("workforce-recovery", "flow_token=" + token), json={
                "component": "ak-stage-prompt", "password": pw, "password_repeat": pw}, timeout=30)))
        print(json.dumps(out))
    elif cmd == "change":                     # change <name> <password> <flow> <new password>…: signed in, a flow
        name, pw, slug, pws = args[0], args[1], args[2], args[3:]
        s, first = start(name)
        signed = password(s, pw)
        out = [dict(signed, step="sign-in")]
        out.append(dict(outcome(s.get(executor(slug), timeout=30)), step="open"))
        # Signed in, the API checks CSRF as for the browser: the flow's page sets the cookie, sent back as the header,
        # with the page as the Referer.
        page = "%s/if/flow/%s/" % (BASE, slug)
        s.get(page, timeout=30, headers={"Accept": "text/html"})
        s.headers["Referer"] = page
        s.headers["X-authentik-CSRF"] = s.cookies.get("authentik_csrf") or ""
        for new in pws:
            out.append(dict(outcome(s.post(executor(slug), json={
                "component": "ak-stage-prompt", "password": new, "password_repeat": new}, timeout=30)), step="new"))
        print(json.dumps(out))
    elif cmd == "api":                        # api <method> <path> <token> [json]: the API as a service account
        method, path, token = args[0], args[1], args[2]
        body = json.loads(args[3]) if len(args) > 3 else None
        r = session().request(method, BASE + path, json=body, timeout=30, headers={"Authorization": "Bearer " + token})
        print(json.dumps({"status": r.status_code, "body": r.json() if r.content and "json" in r.headers.get(
            "content-type", "") else r.text[:300]}))
    else:
        sys.exit("unknown command " + cmd)


def totp(hexkey, step=30, digits=6):
    """The key's code for a time step no sign-in has used yet (authentik never takes the same step twice): the steps
    used are kept in /state (shared by every client container), so a second sign-in waits for the next step."""
    import hashlib
    import hmac
    import os
    import struct
    import time
    mark = "/state/totp-" + hashlib.sha256(hexkey.encode()).hexdigest()[:16]
    last = int(open(mark).read()) if os.path.exists(mark) else -1
    while int(time.time()) // step <= last:
        time.sleep(1)
    counter = int(time.time()) // step
    if os.path.isdir("/state"):
        open(mark, "w").write(str(counter))
    mac = hmac.new(bytes.fromhex(hexkey), struct.pack(">Q", counter), hashlib.sha1).digest()
    o = mac[-1] & 15
    return str((struct.unpack(">I", mac[o:o + 4])[0] & 0x7FFFFFFF) % 10 ** digits).zfill(digits)


main()
