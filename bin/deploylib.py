#!/usr/bin/env python3
"""
deploylib.py — shared deploy core for the operator scripts.

deploy_to_test.py and deploy_to_prod.py own everything environment-specific
(transport, VM lifecycle, tailnet/DNS, TLS trust). The version-change path
and post-deploy verification live HERE so test and prod execute literally
the same steps and cannot drift:

    converge(run, target)        — drive a box to a pinned version
                                   (bundle git pull + update.sh when behind)
    verify_buildmeta(url, want)  — ask the running application what version
                                   it believes it is

`run` is a callable: run(cmd) -> (exit_code, combined_output), executed as
whichever service user owns /opt/workforce-deploy on the target box.
"""

import json
import os
import re
import ssl
import sys
import time
import urllib.request

WORKDIR = "/opt/workforce-deploy"


def say(msg):
    print(msg, flush=True)


def ok(msg):
    print(f"  [OK]   {msg}", flush=True)


def warn(msg):
    print(f"  [WARN] {msg}", flush=True)


def fail(msg):
    print(f"\n  [FAIL] {msg}\n", flush=True)
    sys.exit(1)


def read_env_file(path):
    """Parse an environments/<name>.env KEY=VALUE file."""
    kv = {}
    if os.path.isfile(path):
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, _, v = line.partition("=")
                    kv[k.strip()] = v.strip()
    return kv


def app_hostname(kv):
    """APP url pieces, tolerating both key spellings the env files use
    (test.env says WF_SUBDOMAIN, prod.env says APP_SUBDOMAIN)."""
    sub = kv.get("APP_SUBDOMAIN") or kv.get("WF_SUBDOMAIN")
    base = kv.get("BASE_DOMAIN")
    if not (sub and base):
        fail(f"cannot derive app hostname from env file "
             f"(need APP_SUBDOMAIN|WF_SUBDOMAIN + BASE_DOMAIN, got {sorted(kv)})")
    return f"{sub}.{base}"


def box_version(run):
    """APP_VERSION the box's own .env currently pins (empty if unreadable)."""
    rc, out = run(f"grep -m1 '^APP_VERSION=' {WORKDIR}/.env 2>/dev/null || true")
    m = re.search(r"=(\S+)", out or "")
    return m.group(1) if m else ""


def converge(run, target):
    """Bring the box to `target` using its bundle checkout. Idempotent:
    already-there is a no-op; anything else goes through update.sh (which
    backs up first and auto-rolls-back on a red health check)."""
    current = box_version(run)
    if not current:
        fail(f"cannot read APP_VERSION from {WORKDIR}/.env on the box — "
             "is the suite installed there? (run bootstrap.py / deploy_to_test.py first)")
    say(f"  bundle pins {target}; box runs {current}")
    if current == target:
        ok("box already on the pinned version — nothing to deploy")
        return current
    ok_rc, out = run(f"cd {WORKDIR} && git pull --ff-only && ./bin/update.sh {target}")
    if ok_rc != 0:
        fail(f"update.sh {target} exited {ok_rc}. update.sh rolls itself back on "
             "failure — check its output above, then run ./bin/doctor.sh on the box.")
    after = box_version(run)
    if after != target:
        fail(f"update ran but the box still reports {after!r}, not {target!r} — "
             "investigate with ./bin/doctor.sh before trusting this deploy")
    ok(f"box updated {current} -> {target}")
    return target


def verify_buildmeta(url, want, cafile=None, insecure=False, attempts=6, delay=10):
    """Poll the running app's /api/v1/build-meta until it reports `want`
    (or give up honestly). Returns the reported version string."""
    ctx = ssl.create_default_context()
    if cafile and os.path.isfile(cafile):
        ctx.load_verify_locations(cafile)
    elif insecure:
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    meta = None
    for i in range(attempts):
        try:
            with urllib.request.urlopen(url, timeout=10, context=ctx) as resp:
                meta = json.loads(resp.read().decode())
            break
        except Exception as exc:            # noqa: BLE001 — any HTTP/TLS issue retries
            if i == attempts - 1:
                fail(f"build-meta never became reachable at {url} ({exc}) — "
                     "the app may be down; run doctor.sh on the box")
            say(f"  [..]   build-meta not answering yet ({exc.__class__.__name__}) — "
                f"retry in {delay}s")
            time.sleep(delay)
    got = (meta or {}).get("version", "?")
    if got == want:
        ok(f"live app confirms version {got} ({url})")
    else:
        warn(f"live app reports {got!r}, deploy expected {want!r} — "
             "check the update actually replaced the running containers")
    return got
