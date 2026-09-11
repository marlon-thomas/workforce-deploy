#!/usr/bin/env python3
"""
deploy_to_test.py — deploy the workforce suite to the TEST appliance,
from any operating system (Windows, macOS, Linux).

  STEP 0  host prerequisites, checked per-OS. READ-ONLY: this script never
          uses sudo. One-time privileged fixes live in
          ../host-setup/setup-host.py (sudo python3 setup-host.py,
          idempotent) — missing prerequisites are pointed there.
  STEP 1  boot the bare Ubuntu appliance      (vagrant up + snapshot)
  STEP 2  verify the guest has internet       (HTTPS probe; gentle recovery)
  STEP 3  install the suite inside it         (bootstrap.py --vagrant --env test,
          interactive: GitHub PAT, email, admin password, backup target)
  STEP 4  Tailscale + DuckDNS                 (VM joins your tailnet, records
          point at it — browse from any tailnet device)

Usage:
  python3 deploy_to_test.py                 # full journey
  python3 deploy_to_test.py --check-only    # STEP 0 only
  python3 deploy_to_test.py --fresh         # destroy + rebuild the VM first
  python3 deploy_to_test.py --skip-to N     # resume at step N (runs N..4)

Everything the VM runs comes from the deployment bundle (cloned fresh from
origin by bootstrap.py) — nothing is ever hand-edited in the VM.
"""

import argparse
import getpass
import os
import platform
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ENV_DIR = os.path.normpath(os.path.join(HERE, "..", "environments"))
BOOTSTRAP = os.path.join(HERE, "bootstrap.py")

DUCKDNS_API = "https://www.duckdns.org/update"   # the DuckDNS service endpoint

# Hostnames derive from the test environment file (single source of truth —
# the same values the installer uses). Token path is a host-side convention,
# overridable via the DUCKDNS_TOKEN_FILE environment variable.
DUCKDNS_TOKEN_FILE = os.environ.get("DUCKDNS_TOKEN_FILE") or os.path.expanduser(
    os.path.join("~", ".config", "workforce-dev", "duckdns.env"))


def _load_test_env():
    env = {}
    path = os.path.join(ENV_DIR, "test.env")
    if os.path.isfile(path):
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, val = line.partition("=")
                env[key.strip()] = val.strip()
    return env


TEST_ENV = _load_test_env()
BASE_DOMAIN = TEST_ENV.get("BASE_DOMAIN")
APP_HOSTNAME = (f"{TEST_ENV['WF_SUBDOMAIN']}.{BASE_DOMAIN}"
                if BASE_DOMAIN and TEST_ENV.get("WF_SUBDOMAIN") else None)
AUTH_HOSTNAME = (f"{TEST_ENV['AUTH_SUBDOMAIN']}.{BASE_DOMAIN}"
                 if BASE_DOMAIN and TEST_ENV.get("AUTH_SUBDOMAIN") else None)


def duckdns_name(hostname):
    if hostname and BASE_DOMAIN and hostname.endswith("." + BASE_DOMAIN):
        return hostname[:-(len(BASE_DOMAIN) + 1)]
    return hostname


def require_hostnames():
    if not (APP_HOSTNAME and AUTH_HOSTNAME):
        fail(f"hostnames could not be derived from {ENV_DIR}/test.env "
             "(needs BASE_DOMAIN, WF_SUBDOMAIN, AUTH_SUBDOMAIN).")


OS = platform.system()          # Windows | Darwin | Linux
DISTRO = ""
if OS == "Linux":
    try:
        with open("/etc/os-release") as f:
            DISTRO = "fedora" if "fedora" in f.read().lower() else "other"
    except OSError:
        DISTRO = "other"

MISSING = []


def say(msg=""):
    print(msg, flush=True)


def ok(msg):
    print(f"  [OK]   {msg}", flush=True)


def warn(msg):
    print(f"  [WARN] {msg}", flush=True)


def note(msg):
    print(f"  [..]   {msg}", flush=True)


def fail(msg):
    print(f"\n  [FAIL] {msg}\n", flush=True)
    sys.exit(1)


def sh(cmd, cwd=None, check=True):
    """Run a command, streaming output to the terminal (interactive prompts
    stay interactive)."""
    printable = " ".join(str(c) for c in cmd[:8])
    note(f"$ {printable}{' …' if len(cmd) > 8 else ''}")
    try:
        r = subprocess.run(cmd, cwd=cwd, check=False)
        if check and r.returncode != 0:
            fail(f"command failed (exit {r.returncode}): {printable}")
        return r
    except FileNotFoundError:
        fail(f"command not found: {cmd[0]}")


def sh_out(cmd, cwd=None, check=False):
    """Run a command CAPTURING output (for probes and value extraction).
    This is deliberately a separate function from sh() — the original
    single helper with an optional capture flag caused the probe bug where
    output printed to the terminal but stdout was None."""
    try:
        return subprocess.run(cmd, cwd=cwd, check=False,
                              capture_output=True, text=True)
    except FileNotFoundError:
        fail(f"command not found: {cmd[0]}")


def have(cmd):
    return shutil.which(cmd) is not None


def pause_for_manual(instructions):
    print()
    warn("ACTION NEEDED — run these in a terminal, then come back here:")
    for line in instructions:
        print(f"    {line}")
    try:
        input("\n  Press Enter when done… ")
    except EOFError:
        fail("no interactive terminal available — fix the items above and re-run.")


# ============================================================ STEP 0

def step0(attempts=0):
    say("\n───────── STEP 0: host prerequisites ─────────")
    MISSING.clear()

    # Fedora: libxcrypt-compat BEFORE anything vagrant — Vagrant's embedded
    # Ruby won't even start without it.
    if OS == "Linux" and DISTRO == "fedora":
        r = subprocess.run(["rpm", "-q", "libxcrypt-compat"],
                           capture_output=True, check=False)
        if r.returncode == 0:
            ok("libxcrypt-compat (Fedora)")
        else:
            MISSING.append("libxcrypt-compat missing — run once:  "
                           "sudo python3 deploy/host-setup/setup-host.py")

    # vagrant: present AND runnable
    vagrant_ok = False
    if have("vagrant"):
        v = sh_out(["vagrant", "--version"])
        if v.returncode != 0:
            tail = (v.stderr or v.stdout or "").strip().splitlines()
            MISSING.append("vagrant does not run: "
                           + (tail[-1] if tail else f"exit {v.returncode}"))
        else:
            ok(f"vagrant runs ({(v.stdout or '').strip() or 'version probe ok'})")
            vagrant_ok = True
    else:
        for p in (os.path.expanduser(os.path.join("~", ".local", "bin")),
                  os.path.join(os.environ.get("LOCALAPPDATA", ""),
                               "Programs", "workforce-bin")):
            if p and os.path.isfile(os.path.join(
                    p, "vagrant.exe" if OS == "Windows" else "vagrant")):
                os.environ["PATH"] = p + os.pathsep + os.environ["PATH"]
                break
        if have("vagrant"):
            ok("vagrant (found in a user bin dir)")
            vagrant_ok = True
        else:
            MISSING.append("vagrant — install from "
                           "https://developer.hashicorp.com/vagrant/install")

    # hypervisor / provider
    if OS == "Linux":
        if not have("virsh"):
            pkg = ("sudo dnf install -y @virtualization"
                   if DISTRO == "fedora" else
                   "sudo apt-get install -y qemu-kvm libvirt-daemon-system "
                   "libvirt-clients")
            MISSING.append(f"libvirt/KVM — run:  {pkg}")
        elif subprocess.run(["systemctl", "is-active", "--quiet", "libvirtd"],
                            check=False).returncode != 0:
            MISSING.append("libvirtd is not running — run once:  "
                           "sudo python3 deploy/host-setup/setup-host.py")
        if have("virsh"):
            r = sh_out(["virsh", "-c", "qemu:///system", "list", "--all"])
            if r.returncode == 0:
                ok("libvirt access (group membership effective)")
            else:
                user = os.environ.get("USER") or os.environ.get("LOGNAME", "")
                MISSING.append(
                    f"libvirt group access — run:  sudo usermod -aG libvirt {user}"
                    "   …then LOG OUT & BACK IN")
            # default NAT network active
            ni = sh_out(["virsh", "-c", "qemu:///system", "net-info", "default"])
            net_active = any(
                ln.strip().startswith("Active:")
                and ln.split(":", 1)[1].strip().lower() == "yes"
                for ln in (ni.stdout or "").splitlines())
            if net_active:
                ok("libvirt default network (NAT)")
            else:
                MISSING.append("libvirt default network is inactive — run "
                               "once:  sudo python3 "
                               "deploy/host-setup/setup-host.py")
            # firewalld forwards virbr0
            if have("firewall-cmd"):
                az = sh_out(["firewall-cmd", "--get-active-zones"])
                if "virbr0" in (az.stdout or ""):
                    ok("firewalld forwards virbr0 (guest internet)")
                else:
                    MISSING.append("firewalld is not forwarding virbr0 — "
                                   "run once:  sudo python3 "
                                   "deploy/host-setup/setup-host.py")
    else:
        if have("VBoxManage") or have("virtualbox"):
            ok("VirtualBox")
        else:
            hint = ("Enable Hyper-V, or install VirtualBox from "
                    "https://www.virtualbox.org/wiki/Downloads"
                    if OS == "Windows" else
                    "brew install --cask virtualbox")
            MISSING.append(f"a hypervisor — {hint}")

    # vagrant-libvirt plugin (Linux only; needs a working vagrant)
    if OS == "Linux" and vagrant_ok:
        r = sh_out(["vagrant", "plugin", "list"])
        if "vagrant-libvirt" in (r.stdout or ""):
            ok("vagrant-libvirt plugin")
        else:
            note("installing the vagrant-libvirt plugin (user-local, no sudo)…")
            sh(["vagrant", "plugin", "install", "vagrant-libvirt"])
            ok("vagrant-libvirt plugin (installed just now)")

        # docker↔libvirt coexistence: persistent DOCKER-USER accepts via a
        # systemd drop-in (docker's FORWARD DROP policy swallows guest
        # traffic otherwise; the drop-in re-applies on every docker start).
        if have("docker") and have("virsh"):
            dropin = ("/etc/systemd/system/docker.service.d/"
                      "workforce-libvirt-forward.conf")
            if os.path.exists(dropin):
                ok("docker↔libvirt forwarding fix (persistent)")
            else:
                MISSING.append("docker↔libvirt forwarding fix not installed "
                               "(docker's FORWARD DROP swallows guest "
                               "traffic) — run once:  sudo python3 "
                               "deploy/host-setup/setup-host.py")

    # paramiko
    try:
        import paramiko  # noqa: F401
        ok("paramiko (python SSH)")
    except ImportError:
        note("installing paramiko…")
        sh([sys.executable, "-m", "pip", "install", "--user", "paramiko"])
        try:
            import paramiko  # noqa: F401
            ok("paramiko (installed just now)")
        except ImportError:
            MISSING.append(f"paramiko — run:  {sys.executable} "
                           "-m pip install --user paramiko")

    if MISSING:
        if attempts >= 2:
            fail("prerequisites still missing after 3 rounds — fix manually "
                 "and re-run.")
        pause_for_manual(MISSING)
        return step0(attempts + 1)

    say("  All prerequisites satisfied.")


# ============================================================ STEP 1

def vm_created():
    r = sh_out(["vagrant", "status"], cwd=ENV_DIR)
    return "not created" not in (r.stdout or "")


def snapshot_exists():
    r = sh_out(["vagrant", "snapshot", "list"], cwd=ENV_DIR)
    return "clean" in (r.stdout or "")


def step1(fresh):
    say("\n───────── STEP 1: boot the appliance ─────────")
    if fresh and vm_created():
        note("destroying the existing VM (--fresh)…")
        sh(["vagrant", "destroy", "-f"], cwd=ENV_DIR)
    sh(["vagrant", "up"], cwd=ENV_DIR)
    if not snapshot_exists():
        sh(["vagrant", "snapshot", "save", "clean"], cwd=ENV_DIR)
        ok("snapshot 'clean' saved — future resets: "
           "vagrant snapshot restore clean")
    else:
        ok("snapshot 'clean' exists")
    say("  Appliance is up.")


# ============================================================ STEP 2

PROBE_CMD = ("curl -4 -m 8 -sI https://github.com | head -1")


def guest_internet_ok():
    """HTTPS deliberately: some networks blackhole plain-HTTP to Ubuntu
    mirrors while everything else works — an HTTP probe would measure the
    ISP, not the VM (observed in the field)."""
    r = sh_out(["vagrant", "ssh", "-c", PROBE_CMD], cwd=ENV_DIR)
    out = r.stdout or ""
    return any(code in out for code in ("200", "301", "302")), out


def step2():
    say("\n───────── STEP 2: verify guest internet ─────────")
    for attempt in range(3):
        good, out = guest_internet_ok()
        if good:
            ok(f"VM has outbound internet ({out.strip().splitlines()[-1] if out.strip() else 'probe'})")
            return
        if attempt == 0:
            # Is ssh itself alive? Stale vagrant↔libvirt state after an
            # out-of-band VM restart makes vagrant ssh return nothing.
            r = sh_out(["vagrant", "ssh", "-c", "echo ok"], cwd=ENV_DIR)
            if "ok" not in (r.stdout or ""):
                warn("vagrant cannot reach the VM (stale state) — cycling "
                     "the VM through vagrant…")
                sh(["vagrant", "halt", "--force"], cwd=ENV_DIR, check=False)
                sh(["vagrant", "up"], cwd=ENV_DIR, check=False)
                time.sleep(3)
            else:
                warn("guest lease may be stale — renewing gently…")
                sh(["vagrant", "ssh", "-c",
                    "sudo dhclient -r eth0 2>/dev/null; sudo dhclient eth0; "
                    "sleep 2"], cwd=ENV_DIR, check=False)
                time.sleep(3)
        elif attempt == 1:
            warn("still no internet — full vagrant-managed VM cycle…")
            sh(["vagrant", "halt", "--force"], cwd=ENV_DIR, check=False)
            sh(["vagrant", "up"], cwd=ENV_DIR, check=False)
            time.sleep(3)
        else:
            diag = sh_out(["vagrant", "ssh", "-c",
                           "ip -4 addr show eth0 | grep inet; "
                           + PROBE_CMD + "; echo curl_exit=$?"],
                          cwd=ENV_DIR)
            guest = (diag.stdout or "(unreachable)").strip()
            host_probe = sh_out(["curl", "-4", "-m", "8", "-sI",
                                 "https://github.com"])
            fail("the VM has no outbound internet. Guest state:\n    "
                 + guest.replace("\n", "\n    ")
                 + "\n  Host probe on the same URL: "
                 + ((host_probe.stdout or "").strip().splitlines()[-1]
                    if (host_probe.stdout or "").strip() else "failed")
                 + "\n  If the host fails too, it is the network, not the VM.")


# ============================================================ STEP 3

def step3():
    say("\n───────── STEP 3: install the suite (interactive) ─────────")
    say("  The installer will ask, here in this terminal:")
    say("    - GitHub username + token with read:packages (private images)")
    say("    - email for certificate notices")
    say("    - admin password (the sign-in account)")
    say("    - backup directory")
    say("  The DuckDNS token is copied in automatically if present at:")
    say(f"    {DUCKDNS_TOKEN_FILE}")
    cmd = [sys.executable, BOOTSTRAP, "--vagrant", "--env", "test"]
    sh(cmd)


# ============================================================ STEP 4

def read_duckdns_token():
    if os.path.isfile(DUCKDNS_TOKEN_FILE):
        with open(DUCKDNS_TOKEN_FILE) as f:
            for line in f:
                if line.startswith("DUCKDNS_TOKEN="):
                    return line.split("=", 1)[1].strip()
    say(f"  No token file at {DUCKDNS_TOKEN_FILE}")
    return getpass.getpass("  DuckDNS token (input hidden): ").strip()


def step4():
    say("\n───────── STEP 4: Tailscale + DuckDNS ─────────")
    require_hostnames()
    say("  A login URL will appear — open it in a browser and approve "
        "the device.")
    sh(["vagrant", "ssh", "-c", "sudo tailscale up"], cwd=ENV_DIR, check=False)
    r = sh_out(["vagrant", "ssh", "-c", "tailscale ip -4"], cwd=ENV_DIR)
    ip = (r.stdout or "").strip().splitlines()[-1].strip() if r.stdout else ""
    if not ip.startswith("100."):
        fail(f"could not read the VM's tailnet IP (got: {ip!r}). Run "
             "vagrant ssh -c 'tailscale ip -4' manually.")
    ok(f"VM tailnet IP: {ip}")

    token = read_duckdns_token()
    qs = urllib.parse.urlencode({
        "domains": ",".join(n for n in (duckdns_name(APP_HOSTNAME),
                                        duckdns_name(AUTH_HOSTNAME)) if n),
        "token": token, "ip": ip, "verbose": "true"})
    try:
        with urllib.request.urlopen(f"{DUCKDNS_API}?{qs}", timeout=30) as resp:
            body = resp.read().decode().strip()
    except Exception as exc:
        fail(f"DuckDNS update failed: {exc}")
    if not body.upper().startswith("OK"):
        fail(f"DuckDNS rejected the update (response: {body[:200]!r}). "
             "Check the token, then re-run with --skip-to 4.")
    ok("DuckDNS records updated.")

    for host in (APP_HOSTNAME, AUTH_HOSTNAME):
        resolved = ""
        for _ in range(6):
            try:
                resolved = socket.gethostbyname(host)
                if resolved == ip:
                    break
            except socket.gaierror:
                pass
            time.sleep(5)
        if resolved == ip:
            ok(f"{host} → {resolved}")
        else:
            warn(f"{host} → {resolved or 'unresolved'} (expected {ip}); "
                 "DNS caching — retry shortly or add a hosts entry:")
            if OS == "Windows":
                say(f"    (admin) Add-Content $env:SystemRoot\\System32"
                    f"\\drivers\\etc\\hosts '\"<ip> {host}\"'")
            else:
                say(f"    (sudo)  echo '<ip> {host}' >> /etc/hosts")


# ============================================================ main

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--fresh", action="store_true",
                    help="destroy the existing VM and rebuild from scratch")
    ap.add_argument("--check-only", action="store_true",
                    help="run STEP 0 (prerequisite report) and exit")
    ap.add_argument("--skip-to", type=int, default=0, choices=[0, 1, 2, 3, 4],
                    help="resume at a step (runs that step and everything after)")
    args = ap.parse_args()

    say("═══════════════════════════════════════════════════════")
    say("  Workforce Suite → TEST environment (any OS)")
    say("═══════════════════════════════════════════════════════")

    step0()
    if args.check_only:
        say("\nCheck complete — nothing was run.")
        return
    if not os.path.isdir(ENV_DIR):
        fail(f"environments directory not found: {ENV_DIR}")

    if args.skip_to <= 1:
        step1(args.fresh)
    if args.skip_to <= 2:
        step2()
    if args.skip_to <= 3:
        step3()
    if args.skip_to <= 4:
        step4()

    require_hostnames()
    say("\n═══════════════════════════════════════════════════════")
    say("  TEST environment deployed.")
    say(f"    App:     https://{APP_HOSTNAME}")
    say(f"    Sign-in: https://{AUTH_HOSTNAME}   (user: admin)")
    say("  Reachable from any device on your tailnet.")
    say("  Reset anytime:  vagrant snapshot restore clean && vagrant up")
    say("═══════════════════════════════════════════════════════")


if __name__ == "__main__":
    main()
