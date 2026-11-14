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
            if c == "@totp":
                c = totp(open("/t/totp.key").read().strip())
            out.append(dict(outcome(s.post(executor("default-authentication-flow"), json={
                "component": "ak-stage-authenticator-validate", "code": c}, timeout=30)), step="code"))
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
    import hashlib
    import hmac
    import struct
    import time
    counter = int(time.time()) // step
    mac = hmac.new(bytes.fromhex(hexkey), struct.pack(">Q", counter), hashlib.sha1).digest()
    o = mac[-1] & 15
    return str((struct.unpack(">I", mac[o:o + 4])[0] & 0x7FFFFFFF) % 10 ** digits).zfill(digits)


main()
