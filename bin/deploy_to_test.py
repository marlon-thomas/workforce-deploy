#!/usr/bin/env python3
"""
deploy_to_test.py — deploy the workforce suite to the TEST appliance,
from any operating system (Windows, macOS, Linux).

One command that does the whole journey:

  STEP 0  host prerequisites, checked per-OS (vagrant, hypervisor, plugins,
          paramiko; Fedora-specific libxcrypt-compat + libvirt group)
  STEP 1  boot the bare Ubuntu appliance      (vagrant up + snapshot)
  STEP 2  install the suite inside it         (bootstrap.py --vagrant --env test,
          interactive: email, admin password, backup target, GitHub PAT)
  STEP 3  put the VM on your Tailscale network (tailscale up + tailnet IP)
  STEP 4  point the DuckDNS records at the VM  (works from the token file or a
          one-time prompt — no curl needed, this runs on Windows too)

When it finishes, browse from any device on your tailnet, at the hostnames
derived from deploy/environments/test.env (APP_HOSTNAME / AUTH_HOSTNAME):
the app, and the authentik sign-in (user: admin).

Usage:
  python3 deploy_to_test.py                 # full journey
  python3 deploy_to_test.py --check-only    # STEP 0 only: report and exit
  python3 deploy_to_test.py --fresh         # destroy + rebuild the VM first
  python3 deploy_to_test.py --skip-to 3     # resume at tailscale/DuckDNS steps

The script only orchestrates — it never edits the VM by hand. Everything the
VM runs comes from the deployment bundle, exactly like production.
"""

import argparse
import getpass
import os
import platform
import shutil
import socket
import subprocess
import sys
import time
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ENV_DIR = os.path.normpath(os.path.join(HERE, "..", "environments"))
BOOTSTRAP = os.path.join(HERE, "bootstrap.py")

# Hostnames and the token path are NOT hardcoded — they derive from the
# test environment file (single source of truth, same values the installer
# uses). Hostnames: APP_HOSTNAME = WF_SUBDOMAIN.BASE_DOMAIN, etc.
# Token file: host-side convention, overridable via the DUCKDNS_TOKEN_FILE
# environment variable.
DUCKDNS_API = "https://www.duckdns.org/update"   # the DuckDNS service endpoint


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

# Names for the DuckDNS update API = hostnames minus the duckdns.org suffix.
def _duckdns_name(hostname):
    if hostname and BASE_DOMAIN and hostname.endswith("." + BASE_DOMAIN):
        return hostname[:-(len(BASE_DOMAIN) + 1)]
    return hostname


DUCKDNS_NAMES = ",".join(n for n in (_duckdns_name(APP_HOSTNAME),
                                     _duckdns_name(AUTH_HOSTNAME)) if n)
DUCKDNS_TOKEN_FILE = os.environ.get("DUCKDNS_TOKEN_FILE") or os.path.expanduser(
    os.path.join("~", ".config", "workforce-dev", "duckdns.env"))


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


def run(cmd, cwd=None, check=True, capture=False):
    """Run a command, streaming output (bootstrap's interactive prompts need
    the real terminal). Returns CompletedProcess."""
    printable = " ".join(str(c) for c in cmd[:8])
    note(f"$ {printable}{' …' if len(cmd) > 8 else ''}")
    try:
        r = subprocess.run(cmd, cwd=cwd, check=False,
                           capture_output=capture, text=capture)
        if check and r.returncode != 0:
            fail(f"command failed (exit {r.returncode}): {printable}")
        return r
    except FileNotFoundError:
        fail(f"command not found: {cmd[0]}")


def have(cmd):
    return shutil.which(cmd) is not None


def pause_for_manual(instructions):
    """Print privileged commands the user must run themselves, wait for them
    to do it, then return so the checks can re-run (step0 re-invokes itself,
    max 3 rounds). This script never asks for a password."""
    print()
    warn("ACTION NEEDED — run these in a terminal, then come back here:")
    for line in instructions:
        print(f"    {line}")
    try:
        input("\n  Press Enter when done… ")
    except EOFError:
        fail("no interactive terminal available — fix the items above and re-run.")


def sudo_run(cmd):
    """Run a privileged command with sudo prompting in the user's own
    terminal (inherited TTY) — the user types the password to sudo directly;
    this script never sees or captures it. Returns True only on success.
    Non-interactive contexts (piped stdin) simply fail and fall back to the
    manual-instructions path."""
    if not sys.stdin.isatty():
        return False
    try:
        return subprocess.run(cmd, check=False).returncode == 0
    except FileNotFoundError:
        return False


# ============================================================ STEP 0

def step0(attempts=0):
    say("\n───────── STEP 0: host prerequisites ─────────")
    MISSING.clear()

    # --- Fedora: libxcrypt-compat BEFORE anything vagrant -------------------
    # Vagrant ships an embedded Ruby that won't even start without it, so
    # every `vagrant` invocation below depends on this being in place.
    if OS == "Linux" and DISTRO == "fedora":
        r = subprocess.run(["rpm", "-q", "libxcrypt-compat"],
                           capture_output=True, check=False)
        if r.returncode == 0:
            ok("libxcrypt-compat (Fedora)")
        else:
            note("installing libxcrypt-compat (sudo may ask for your password)…")
            if sudo_run(["sudo", "dnf", "install", "-y", "-q",
                         "libxcrypt-compat"]):
                ok("libxcrypt-compat (Fedora, installed just now)")
            else:
                MISSING.append("libxcrypt-compat — run:  "
                               "sudo dnf install -y libxcrypt-compat")

    # --- vagrant ----------------------------------------------------------
    if have("vagrant"):
        ok("vagrant")
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
        else:
            MISSING.append("vagrant — install from https://developer.hashicorp.com/vagrant/install")

    # Sanity probe: the binary exists AND runs (catches embedded-Ruby breakage
    # that mere presence checks miss).
    vagrant_ok = False
    if have("vagrant"):
        v = subprocess.run(["vagrant", "--version"], capture_output=True,
                           text=True, check=False)
        if v.returncode != 0:
            tail = (v.stderr or v.stdout or "").strip().splitlines()
            MISSING.append("vagrant does not run: "
                           + (tail[-1] if tail else f"exit {v.returncode}"))
        else:
            ok(f"vagrant runs ({(v.stdout or '').strip() or 'version probe ok'})")
            vagrant_ok = True
    else:
        MISSING.append("vagrant — install from https://developer.hashicorp.com/vagrant/install")

    # --- hypervisor / provider (per OS) ------------------------------------
    if OS == "Linux":
        if not have("virsh"):
            pkg = ("sudo dnf install -y @virtualization"
                   if DISTRO == "fedora" else
                   "sudo apt-get install -y qemu-kvm libvirt-daemon-system libvirt-clients")
            MISSING.append(f"libvirt/KVM — run:  {pkg}")
        elif subprocess.run(["systemctl", "is-active", "--quiet", "libvirtd"],
                            check=False).returncode != 0:
            if sudo_run(["sudo", "systemctl", "enable", "--now", "libvirtd"]):
                ok("libvirtd (started)")
            else:
                MISSING.append("libvirtd is not running — run:  "
                               "sudo systemctl enable --now libvirtd")

        # Group access to the system libvirt daemon (the real test: can we talk to it?)
        if have("virsh"):
            r = subprocess.run(["virsh", "-c", "qemu:///system", "list", "--all"],
                               capture_output=True, text=True, check=False)
            if r.returncode == 0:
                ok("libvirt access (group membership effective)")
            else:
                user = os.environ.get("USER") or os.environ.get("LOGNAME", "")
                MISSING.append(
                    f"libvirt group access — run:  sudo usermod -aG libvirt {user}"
                    "   …then LOG OUT & BACK IN (group changes need a new session)")

        # Guest outbound internet: the default NAT network must be active and
        # the host firewall must forward virbr0 (Fedora firewalld hands virbr0
        # to the 'libvirt' zone; if that assignment is missing, guests resolve
        # DNS but every outbound connection times out).
        if have("virsh"):
            ni = subprocess.run(["virsh", "-c", "qemu:///system", "net-info",
                                 "default"], capture_output=True, text=True,
                                check=False)
            # parse robustly — virsh pads the value column variably, so a
            # literal "Active:      yes" match never fits (the false-negative
            # that made a running network look inactive).
            net_active = any(
                ln.strip().startswith("Active:")
                and ln.split(":", 1)[1].strip().lower() == "yes"
                for ln in (ni.stdout or "").splitlines())
            if not net_active:
                if sudo_run(["sudo", "virsh", "-c", "qemu:///system",
                             "net-start", "default"]):
                    ok("libvirt default network (started)")
                else:
                    MISSING.append("libvirt default network is inactive — run:  "
                                   "sudo virsh net-start default")
            else:
                ok("libvirt default network (NAT)")
            if have("firewall-cmd"):
                az = subprocess.run(["firewall-cmd", "--get-active-zones"],
                                    capture_output=True, text=True, check=False)
                zones = az.stdout or ""
                if "virbr0" in zones:
                    ok("firewalld forwards virbr0 (guest internet)")
                elif "libvirt" in zones and "virbr0" not in zones:
                    # libvirt zone active but interface not assigned
                    if not sudo_run(["sudo", "firewall-cmd", "--zone=libvirt",
                                     "--add-interface=virbr0"]):
                        MISSING.append(
                            "firewalld is not forwarding virbr0 — run:\n"
                            "      sudo firewall-cmd --zone=libvirt --add-interface=virbr0\n"
                            "      sudo firewall-cmd --zone=libvirt --add-service=dhcp --add-service=dns --add-service=ssh --add-service=tftp\n"
                            "      sudo firewall-cmd --zone=libvirt --add-forward")
                else:
                    warn("firewalld zones do not mention virbr0 yet — if the VM "
                         "cannot reach the internet after boot, run:\n"
                         "      sudo firewall-cmd --zone=libvirt --add-interface=virbr0")
    else:
        # Windows / macOS: VirtualBox (or Hyper-V) — GUI install, can't automate.
        if have("VBoxManage") or have("virtualbox"):
            ok("VirtualBox")
        else:
            hint = ("Enable Hyper-V, or install VirtualBox from "
                    "https://www.virtualbox.org/wiki/Downloads"
                    if OS == "Windows" else
                    "brew install --cask virtualbox")
            MISSING.append(f"a hypervisor — {hint}")

    # --- vagrant-libvirt plugin (Linux only; needs a working vagrant) ------
    if OS == "Linux" and vagrant_ok:
        r = run(["vagrant", "plugin", "list"], capture=True, check=False)
        if "vagrant-libvirt" in (r.stdout or ""):
            ok("vagrant-libvirt plugin")
        else:
            note("installing the vagrant-libvirt plugin (user-local, no sudo)…")
            run(["vagrant", "plugin", "install", "vagrant-libvirt"])
            ok("vagrant-libvirt plugin (installed just now)")

    # --- paramiko (bootstrap.py) --------------------------------------------
    try:
        import paramiko  # noqa: F401
        ok("paramiko (python SSH)")
    except ImportError:
        note("installing paramiko…")
        run([sys.executable, "-m", "pip", "install", "--user", "paramiko"])
        try:
            import paramiko  # noqa: F401
            ok("paramiko (installed just now)")
        except ImportError:
            MISSING.append(f"paramiko — run:  {sys.executable} -m pip install --user paramiko")

    if MISSING:
        if attempts >= 2:
            fail("prerequisites still missing after 3 rounds — fix manually and re-run.")
        pause_for_manual(MISSING)
        return step0(attempts + 1)

    say("  All prerequisites satisfied.")


# ============================================================ bundle pull

def git_repo_root():
    """Walk up from this script looking for a git repository root."""
    root = HERE
    for _ in range(4):
        if os.path.isdir(os.path.join(root, ".git")):
            return root
        parent = os.path.dirname(root)
        if parent == root:
            return None
        root = parent
    return None


def pull_bundle():
    """Pull the latest bundle BEFORE deploying, and return the origin URL.

    The VM clones the bundle from GitHub fresh on every run (bootstrap.py),
    so the deployed code is always origin HEAD. This step keeps the LOCAL
    copy the same story: if this script lives inside a bundle checkout
    (bin/ + environments/ at the repo root), fast-forward it first and pass
    its origin to bootstrap, so everything comes from one place. Running
    from the development source repo is detected and left alone — the VM
    must get the public bundle, not the private source.
    """
    root = git_repo_root()
    if not root or not have("git"):
        return None
    is_bundle = os.path.isfile(os.path.join(root, "environments", "test.env"))
    if not is_bundle:
        return None
    r = subprocess.run(["git", "-C", root, "remote", "get-url", "origin"],
                       capture_output=True, text=True, check=False)
    origin = (r.stdout or "").strip()
    note("self-update: pulling the latest deployment bundle…")
    p = subprocess.run(["git", "-C", root, "pull", "--ff-only"], check=False)
    if p.returncode != 0:
        warn("bundle could not fast-forward (offline or diverged) — "
             "continuing with the local copy; the VM still clones origin HEAD.")
    if origin.startswith("https://"):
        return origin
    warn("origin is not an https URL — the VM will clone the public bundle.")
    return None


# ============================================================ STEP 1

def vm_created():
    r = run(["vagrant", "status"], cwd=ENV_DIR, capture=True, check=False)
    return "not created" not in (r.stdout or "")


def snapshot_exists():
    r = run(["vagrant", "snapshot", "list"], cwd=ENV_DIR, capture=True, check=False)
    return "clean" in (r.stdout or "")


def step1(fresh):
    say("\n───────── STEP 1: boot the appliance ─────────")
    if fresh and vm_created():
        note("destroying the existing VM (--fresh)…")
        run(["vagrant", "destroy", "-f"], cwd=ENV_DIR)
    run(["vagrant", "up"], cwd=ENV_DIR)
    # Fail fast on guest internet problems with actionable output, instead
    # of a confusing apt failure deep inside the installer.
    r = run(["vagrant", "ssh", "-c",
             "curl -4 -m 8 -sI http://archive.ubuntu.com | head -1"],
            cwd=ENV_DIR, check=False)
    if "200" not in (r.stdout or "") and "301" not in (r.stdout or "")             and "302" not in (r.stdout or ""):
        fail("the VM has no outbound internet (DNS may resolve but TCP is "
             "blocked). On Fedora, fix the forwarding then re-run:\n"
             "    sudo firewall-cmd --zone=libvirt --add-interface=virbr0\n"
             "    sudo firewall-cmd --zone=libvirt --add-forward\n"
             "  …or restart the libvirt network so it re-registers:\n"
             "    sudo virsh net-destroy default && sudo virsh net-start default")
    ok("VM has outbound internet")
    if not snapshot_exists():
        run(["vagrant", "snapshot", "save", "clean"], cwd=ENV_DIR)
        ok("snapshot 'clean' saved — future resets: vagrant snapshot restore clean")
    else:
        ok("snapshot 'clean' exists")
    say("  Appliance is up.")


# ============================================================ STEP 2

def step2():
    say("\n───────── STEP 2: install the suite (interactive) ─────────")
    say("  The installer will ask, here in this terminal:")
    say("    - GitHub username + token with read:packages (private images)")
    say("    - email for certificate notices")
    say("    - admin password (the sign-in account)")
    say("    - backup directory")
    say("  The DuckDNS token is copied in automatically if present at:")
    say(f"    {DUCKDNS_TOKEN_FILE}")
    cmd = [sys.executable, BOOTSTRAP, "--vagrant", "--env", "test"]
    if getattr(main, "bundle_repo", None):
        cmd += ["--repo", main.bundle_repo]
    run(cmd)


# ============================================================ STEP 3

def step3():
    say("\n───────── STEP 3: put the VM on your tailnet ─────────")
    say("  A login URL will appear — open it in a browser and approve the device.")
    run(["vagrant", "ssh", "-c", "sudo tailscale up"], cwd=ENV_DIR, check=False)
    r = run(["vagrant", "ssh", "-c", "tailscale ip -4"], cwd=ENV_DIR,
            capture=True)
    ip = (r.stdout or "").strip().splitlines()[-1].strip() if r.stdout else ""
    if not ip or not ip.startswith("100."):
        fail(f"could not read the VM's tailnet IP (got: {ip!r}). Run "
             "vagrant ssh -c 'tailscale ip -4' manually.")
    ok(f"VM tailnet IP: {ip}")
    return ip


# ============================================================ STEP 4

def read_duckdns_token():
    if os.path.isfile(DUCKDNS_TOKEN_FILE):
        with open(DUCKDNS_TOKEN_FILE) as f:
            for line in f:
                if line.startswith("DUCKDNS_TOKEN="):
                    return line.split("=", 1)[1].strip()
    say(f"  No token file at {DUCKDNS_TOKEN_FILE}")
    return getpass.getpass("  DuckDNS token (input hidden): ").strip()


def step4(ip):
    say("\n───────── STEP 4: point DuckDNS at the VM ─────────")
    token = read_duckdns_token()
    qs = urllib.parse.urlencode({
        "domains": DUCKDNS_NAMES, "token": token, "ip": ip, "verbose": "true"})
    url = f"{DUCKDNS_API}?{qs}"
    say("  Updating DuckDNS (both hostnames → the tailnet IP)…")
    try:
        with urllib.request.urlopen(url, timeout=30) as resp:
            body = resp.read().decode().strip()
    except Exception as exc:
        fail(f"DuckDNS update failed: {exc}")
    if not body.upper().startswith("OK"):
        fail(f"DuckDNS rejected the update (response: {body[:200]!r}). "
             "Check the token, then re-run with --skip-to 4.")
    ok("DuckDNS updated.")

    # Confirm the public DNS actually answers with the tailnet IP now.
    require_hostnames()
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
                 "DNS caching — retry in a minute or add a hosts entry:")
            hosts_hint()


def hosts_hint():
    require_hostnames()
    if OS == "Windows":
        say(f"    (admin) Add-Content $env:SystemRoot\\System32\\drivers\\etc\\hosts "
            f'"<ip> {APP_HOSTNAME}"')
        say(f"    (admin) Add-Content $env:SystemRoot\\System32\\drivers\\etc\\hosts "
            f'"<ip> {AUTH_HOSTNAME}"')
    else:
        say(f"    (sudo)  echo '<ip> {APP_HOSTNAME}' >> /etc/hosts")
        say(f"    (sudo)  echo '<ip> {AUTH_HOSTNAME}' >> /etc/hosts")



# ============================================================ main

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--fresh", action="store_true",
                    help="destroy the existing VM and rebuild from scratch")
    ap.add_argument("--check-only", action="store_true",
                    help="run STEP 0 (prerequisite report) and exit")
    ap.add_argument("--skip-to", type=int, default=1, choices=[1, 2, 3, 4],
                    help="resume at a step (e.g. --skip-to 3 after an install)")
    args = ap.parse_args()

    say("═══════════════════════════════════════════════════════")
    say("  Workforce Suite → TEST environment (any OS)")
    say("═══════════════════════════════════════════════════════")

    step0()
    if args.check_only:
        say("\nCheck complete — nothing was run.")
        return
    main.bundle_repo = pull_bundle()
    if not os.path.isdir(ENV_DIR):
        fail(f"environments directory not found: {ENV_DIR}")

    if args.skip_to <= 1:
        step1(args.fresh)
    if args.skip_to <= 2:
        step2()
    if args.skip_to <= 3:
        ip = step3()
        step4(ip)
    else:
        r = run(["vagrant", "ssh", "-c", "tailscale ip -4"], cwd=ENV_DIR,
                capture=True, check=False)
        ip = (r.stdout or "").strip().splitlines()[-1].strip()
        step4(ip)

    say("\n═══════════════════════════════════════════════════════")
    say("  TEST environment deployed.")
    require_hostnames()
    say(f"    App:     https://{APP_HOSTNAME}")
    say(f"    Sign-in: https://{AUTH_HOSTNAME}   (user: admin)")
    say("  Reachable from any device on your tailnet.")
    say("  Reset anytime:  vagrant snapshot restore clean && vagrant up")
    say("═══════════════════════════════════════════════════════")


if __name__ == "__main__":
    main()
