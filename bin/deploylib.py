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

# `git pull --ff-only` of the bundle, safe across the commit that took
# secrets/initial-admin-password out of git tracking: on a box where the
# installer wrote the real password into the (then tracked) file, a plain pull
# aborts ("local changes would be overwritten"); where it did not, the pull
# deletes it. Park the file, reset it to the tracked bytes, pull, put it back.
# No-op once the box's checkout no longer tracks the file. Shell, run inside
# the checkout as its owner; no braces (it is .format()-ed into bootstrap.py).
GUARDED_PULL = (
    'f=secrets/initial-admin-password; k=secrets/.initial-admin-password.keep; '
    'if git ls-files --error-unmatch "$f" >/dev/null 2>&1 && [ -f "$f" ]; then '
    'cp -p "$f" "$k" && git checkout -q -- "$f"; fi; '
    'git pull -q --ff-only; rc=$?; '
    'if [ -f "$k" ]; then mv -f "$k" "$f"; fi; exit $rc'
)


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
    ok_rc, out = run(f"cd {WORKDIR} && sh -c '{GUARDED_PULL}' && ./bin/update.sh {target}")
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


# ---------------------------------------------------------------- SSH host keys

def host_key_sha256(key):
    """OpenSSH-style fingerprint of a paramiko PKey: 'SHA256:<b64, no padding>'."""
    import base64
    import hashlib
    digest = hashlib.sha256(key.asbytes()).digest()
    return "SHA256:" + base64.b64encode(digest).decode().rstrip("=")


def verified_ssh_client(fingerprint=None, known_hosts=None):
    """A paramiko SSHClient that never trusts a host key blindly and never
    rewrites known_hosts (the old flow scrubbed it and used AutoAddPolicy:
    any MITM on first OR later contact was accepted silently).

    fingerprint given ('SHA256:...', as printed by `ssh-keygen -lf` on the
    server's /etc/ssh/ssh_host_ed25519_key.pub): the presented key must match
    it — checked BEFORE authentication, so no password is ever sent to an
    impostor. Authoritative over known_hosts (the re-provisioned-server case).

    No fingerprint: OpenSSH `StrictHostKeyChecking=accept-new` semantics —
    a host with no known_hosts entry is accepted on first contact and appended
    (one line, file never rewritten); a host whose key DIFFERS from its entry
    is refused (paramiko BadHostKeyException) with the remediation to run.

    known_hosts: path to use instead of ~/.ssh/known_hosts. '/dev/null' means
    ephemeral trust for this session only (nothing recorded). No current caller
    uses it: the Incus test path pins the guest's key via --host-key-fingerprint.
    """
    import paramiko

    path = os.path.expanduser(known_hosts or "~/.ssh/known_hosts")
    ephemeral = path == os.devnull
    want = None
    if fingerprint:
        want = fingerprint.strip()
        if not want.startswith("SHA256:"):
            want = "SHA256:" + want
        want = want.rstrip("=")

    class _Policy(paramiko.MissingHostKeyPolicy):
        def missing_host_key(self, client, hostname, key):
            got = host_key_sha256(key)
            if want is not None and got != want:
                raise paramiko.SSHException(
                    f"host key for {hostname} is {got}, but --host-key-fingerprint "
                    f"says {want} — refusing to connect (possible MITM, or the "
                    "wrong fingerprint was supplied)")
            if want is None and not ephemeral and client.get_host_keys().lookup(hostname):
                # Known host, different key TYPE than recorded: not a first
                # contact — accept-new must not turn it into one.
                raise paramiko.SSHException(
                    f"{hostname} presented a {key.get_name()} key ({got}) but "
                    f"{path} records only other key types for it — refusing. "
                    "Verify out of band and pass --host-key-fingerprint.")
            if ephemeral:
                print(f"Host key {hostname}: {key.get_name()} {got} (session-only trust)")
                return
            print(f"Host key {hostname}: {key.get_name()} {got} "
                  f"({'verified' if want else 'first contact — accepted and recorded'})")
            if want is not None and os.path.isfile(path):
                try:
                    stale = paramiko.HostKeys(path).lookup(hostname)
                except Exception:              # noqa: BLE001 — unreadable file: just don't record
                    stale = True
                if stale:
                    print(f"NOTE: {path} has an older entry for {hostname}; it was "
                          "NOT changed. Once you are sure, remove it yourself: "
                          f"ssh-keygen -R '{hostname}'")
                    return
            try:
                os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
                with open(path, "a", encoding="utf-8") as fh:
                    fh.write(f"{hostname} {key.get_name()} {key.get_base64()}\n")
            except OSError as exc:
                print(f"WARN: could not record the host key in {path}: {exc}")

    client = paramiko.SSHClient()
    if want is None and not ephemeral and os.path.isfile(path):
        # Known keys are enforced; a mismatch raises BadHostKeyException
        # before authentication. (With a fingerprint the arg is the authority,
        # so stale entries are not consulted — and never deleted.)
        client.load_host_keys(path)
    client.set_missing_host_key_policy(_Policy())
    return client


def explain_bad_host_key(exc, host, port=22):
    """Exit message for a host-key mismatch: what happened, what to do."""
    import paramiko
    if isinstance(exc, paramiko.BadHostKeyException):
        name = host if port == 22 else f"[{host}]:{port}"
        fail(f"HOST KEY MISMATCH for {name}: known_hosts has "
             f"{host_key_sha256(exc.expected_key)}, the server presented "
             f"{host_key_sha256(exc.key)}.\n"
             "  If the server was deliberately re-provisioned, confirm the new key "
             "out of band (provider console: ssh-keygen -lf "
             "/etc/ssh/ssh_host_ed25519_key.pub) and either pass "
             "--host-key-fingerprint SHA256:... or remove the stale entry yourself:\n"
             f"    ssh-keygen -R '{name}'\n"
             "  Otherwise STOP: something may be intercepting the connection.")
    raise exc
