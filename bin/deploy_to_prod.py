#!/usr/bin/env python3
"""
deploy_to_prod.py — deploy the workforce suite to the PRODUCTION appliance.

Sibling of deploy_to_test.py. The environment-specific parts of a deploy
live in each script; the version-change path and the post-deploy check are
the SHARED functions in deploylib.py, so test and prod cannot drift:

    STEP 0  reachability + local prerequisites (read-only)
    STEP 1  ensure the bundle is installed on the box
            (already there -> nothing happens; fresh -> hand over to
             bootstrap.py --env prod, the same installer the test path uses)
    STEP 2  human gate: type the target version to confirm a prod change
    STEP 3  converge: deploylib.converge() -> update.sh <prod pin> (backup,
            pull image, migrate, health check, auto-rollback)
    STEP 4  verify: https://<app>/api/v1/build-meta reports the pinned version

The prod version is environments/prod.env:APP_VERSION — bumping it is the
deliberate, committed human decision; this script never edits it.

Usage:
  python3 deploy_to_prod.py                # full journey
  python3 deploy_to_prod.py --check-only   # STEP 0 only
  python3 deploy_to_prod.py --host 203.0.113.10
"""

import argparse
import getpass
import os
import re
import socket
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
sys.path.insert(0, HERE)

import deploylib                                   # noqa: E402
from deploylib import converge, verify_buildmeta   # noqa: E402

try:
    import paramiko
except ImportError:
    sys.exit("paramiko is required:  python3 -m pip install --user paramiko")

INVENTORY = os.path.join(ROOT, "ansible", "inventories", "prod", "hosts.yml")
PROD_ENV = os.path.join(ROOT, "environments", "prod.env")
BOOTSTRAP = os.path.join(HERE, "bootstrap.py")
WORKDIR = deploylib.WORKDIR


def say(msg):
    print(msg, flush=True)


def ok(msg):
    print(f"  [OK]   {msg}", flush=True)


def warn(msg):
    print(f"  [WARN] {msg}", flush=True)


def fail(msg):
    print(f"\n  [FAIL] {msg}\n", flush=True)
    sys.exit(1)


def parse_inventory():
    """Flat regex over hosts.yml (no yaml dependency): what this script needs
    is one host with a handful of keys."""
    if not os.path.isfile(INVENTORY):
        fail(f"prod inventory not found: {INVENTORY}")
    text = open(INVENTORY, encoding="utf-8").read()

    def grab(key):
        m = re.search(rf"{key}:\s*(\S+)", text)
        return m.group(1) if m else None

    host = grab("ansible_host")
    if not host:
        fail("no ansible_host in the prod inventory — pass --host")
    return {"host": host,
            "app": grab("app_hostname"),
            "service_user": grab("service_user") or "workforce_app_sa"}


# ---------------------------------------------------------------- transport

class SSH:
    """Paramiko session that echoes remote output while capturing it, so
    deploylib.run() gets (rc, out) for BOTH live viewing and parsing."""

    def __init__(self, host, user, password=None, port=22):
        self.client = paramiko.SSHClient()
        self.client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        self.client.connect(host, port=port, username=user,
                            password=password, timeout=15,
                            look_for_keys=True, allow_agent=True)

    def run(self, cmd):
        chan = self.client.get_transport().open_session()
        chan.get_pty()
        chan.exec_command(cmd)
        buf = b""
        while True:
            while chan.recv_ready():
                data = chan.recv(4096)
                buf += data
                sys.stdout.write(data.decode(errors="replace"))
                sys.stdout.flush()
            if chan.exit_status_ready() and not chan.recv_ready():
                break
            time.sleep(0.05)
        return chan.recv_exit_status(), buf.decode(errors="replace")

    def close(self):
        self.client.close()


def ssh_or_prompt(host, user):
    """Key auth if it works (agent/default keys), else ask for the password.
    Returns an SSH handle, or None when the box cannot be reached as `user`."""
    try:
        return SSH(host, user)
    except paramiko.AuthenticationException:
        pw = getpass.getpass(f"  password for {user}@{host}: ")
        try:
            return SSH(host, user, password=pw)
        except paramiko.AuthenticationException:
            return None
    except Exception as exc:                       # noqa: BLE001 — unreachable etc.
        warn(f"cannot reach {user}@{host}: {exc}")
        return None


# ---------------------------------------------------------------- steps

def step0(inv, target):
    say("\n───────── STEP 0: prerequisites ─────────")
    if not os.path.isfile(PROD_ENV):
        fail(f"{PROD_ENV} missing — the prod pin must exist before deploying")
    if not target:
        fail("environments/prod.env has no APP_VERSION — pin a version first")
    ok(f"prod pin: {target}")
    try:
        with socket.create_connection((inv["host"], 22), timeout=8):
            ok(f"ssh reachable at {inv['host']}:22")
    except OSError as exc:
        fail(f"{inv['host']}:22 unreachable ({exc})")


def step1_ensure_installed(inv):
    say("\n───────── STEP 1: bundle present on the box? ─────────")
    ssh = ssh_or_prompt(inv["host"], inv["service_user"])
    if ssh:
        rc, _ = ssh.run(f"test -f {WORKDIR}/.env && test -d {WORKDIR}/.git")
        if rc == 0:
            ok(f"{WORKDIR} installed — resuming day-2 path")
            return ssh
        ssh.close()
    warn("production box has no installed deployment — running the "
         "first-time installer (bootstrap.py --env prod). It will ask for "
         "the root password and, on a fresh box, installer questions.")
    input("  Press Enter to start the installer (Ctrl+C to abort)… ")
    rc = subprocess.run([sys.executable, BOOTSTRAP,
                         "--host", inv["host"], "--env", "prod"]).returncode
    if rc != 0:
        fail("bootstrap.py failed — fix its complaint and re-run this script")
    ssh = ssh_or_prompt(inv["host"], inv["service_user"])
    if not ssh:
        fail("post-install: cannot log in as the service user — check the "
             "account, then re-run")
    ok("installer finished; box reachable as service user")
    return ssh


def step2_gate(current, target):
    say("\n───────── STEP 2: CONFIRM PRODUCTION CHANGE ─────────")
    say(f"  production is about to move {current} -> {target}")
    typed = input("  type the target version to proceed (anything else aborts): ").strip()
    if typed != target:
        say("  Aborted — nothing was changed.")
        raise SystemExit(0)
    ok("confirmed")


def step3_converge(ssh, target):
    say("\n───────── STEP 3: converge to the pinned version ─────────")
    return converge(ssh.run, target)


def step4_verify(inv, target):
    say("\n───────── STEP 4: verify the live application ─────────")
    app = inv["app"] or deploylib.app_hostname(
        deploylib.read_env_file(PROD_ENV))
    verify_buildmeta(f"https://{app}/api/v1/build-meta", target)


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", help="override the inventory address")
    ap.add_argument("--check-only", action="store_true", help="STEP 0 only")
    args = ap.parse_args()

    inv = parse_inventory()
    if args.host:
        inv["host"] = args.host
    target = deploylib.read_env_file(PROD_ENV).get("APP_VERSION")

    say("═══════════════════════════════════════════════════════")
    say(f"  Workforce Suite → PRODUCTION ({inv['host']})")
    say("═══════════════════════════════════════════════════════")

    step0(inv, target)
    if args.check_only:
        say("\nCheck complete — nothing was run.")
        return

    ssh = step1_ensure_installed(inv)
    try:
        current = deploylib.box_version(ssh.run)
        if not current:
            fail(f"no APP_VERSION readable in {WORKDIR}/.env on the box")
        if current == target:
            ok(f"box already on the pinned version {target} — "
               "STEP 2/3 skipped, STEP 4 still verifies")
        else:
            step2_gate(current, target)
            step3_converge(ssh, target)
        step4_verify(inv, target)
    finally:
        ssh.close()

    say("\n═══════════════════════════════════════════════════════")
    say(f"  PRODUCTION is on {target}.")
    say("═══════════════════════════════════════════════════════")


if __name__ == "__main__":
    main()
