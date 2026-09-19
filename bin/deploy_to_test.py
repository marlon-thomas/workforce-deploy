#!/usr/bin/env python3
"""
deploy_to_test.py — deploy the workforce suite to the TEST appliance,
from any operating system (Windows, macOS, Linux).

  STEP 0  host prerequisites, checked per-OS. READ-ONLY: this script never
          uses sudo. One-time privileged fixes live in
          ../host-setup/setup-host.py — invoked AUTOMATICALLY via sudo
          when it detects something it fixes, so the human is only asked for
          what genuinely cannot be scripted (re-login, browser auth);
          idempotent) — missing prerequisites are pointed there.
  STEP 1  boot the bare Ubuntu appliance      (vagrant up + snapshot)
  STEP 2  verify the guest has internet       (HTTPS probe; gentle recovery)
  STEP 3  install the suite inside it         (bootstrap.py --vagrant --env test,
          interactive: GitHub PAT, email, admin password, backup target)
  STEP 4  Tailscale + DuckDNS                 (VM joins your tailnet, records
          point at it — browse from any tailnet device)
  STEP 5  converge to the pinned version      (deploylib.converge + verify —
          the SAME shared code deploy_to_prod.py runs; box moves to
          environments/test.env:APP_VERSION via update.sh)

Usage:
  python3 deploy_to_test.py                 # full journey
  python3 deploy_to_test.py --check-only    # STEP 0 only
  python3 deploy_to_test.py --fresh         # destroy + rebuild the VM first
  python3 deploy_to_test.py --skip-to N     # resume at step N (runs N..5)

Everything the VM runs comes from the deployment bundle (cloned fresh from
origin by bootstrap.py) — nothing is ever hand-edited in the VM.
"""

import argparse
import getpass
import os
import platform
import re
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import deploylib                                    # noqa: E402
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

# Privileged fixes the script CAN run itself via sudo (the sudo prompt lands
# on the user's TTY). "The deploy script never runs as root" is about its own
# privileges — it must not offload known, idempotent, one-command fixes to the
# human. Genuinely human-only items (re-login for group membership, browser
# auth at the DNS/tailscale providers, the service-user password) stay in
# MISSING + pause_for_manual.
PRIV_TASKS = []
SETUP_HOST = os.path.normpath(
    os.path.join(HERE, "..", "host-setup", "setup-host.py"))


def priv(why, cmds):
    """Register an idempotent privileged fix (deduped by first command)."""
    key = " ".join(map(str, cmds[0]))
    for t in PRIV_TASKS:
        if t["key"] == key:
            if why not in t["whys"]:
                t["whys"].append(why)
            return
    PRIV_TASKS.append({"key": key, "whys": [why], "cmds": cmds})


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
    PRIV_TASKS.clear()

    # Fedora: libxcrypt-compat BEFORE anything vagrant — Vagrant's embedded
    # Ruby won't even start without it.
    if OS == "Linux" and DISTRO == "fedora":
        r = subprocess.run(["rpm", "-q", "libxcrypt-compat"],
                           capture_output=True, check=False)
        if r.returncode == 0:
            ok("libxcrypt-compat (Fedora)")
        else:
            priv("libxcrypt-compat missing (Vagrant's Ruby needs it)",
                 [["sudo", "python3", SETUP_HOST]])

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
                            check=False).returncode != 0 and \
                subprocess.run(["systemctl", "is-active", "--quiet", "virtqemud"],
                               check=False).returncode != 0:
            # Fedora 40+ runs the modular daemons: virtqemud is active while
            # libvirtd stays inactive/socket-activated — accept either.
            priv("libvirt daemons not running (libvirtd and virtqemud "
                 "both inactive)", [["sudo", "python3", SETUP_HOST]])
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
                priv("libvirt default network inactive",
                     [["sudo", "python3", SETUP_HOST]])
            # firewalld forwards virbr0
            if have("firewall-cmd"):
                az = sh_out(["firewall-cmd", "--get-active-zones"])
                if "virbr0" in (az.stdout or ""):
                    ok("firewalld forwards virbr0 (guest internet)")
                else:
                    priv("firewalld not forwarding virbr0",
                     [["sudo", "python3", SETUP_HOST]])
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
                priv("docker↔libvirt forwarding drop-in missing "
                     "(docker's FORWARD DROP swallows guest traffic)",
                     [["sudo", "python3", SETUP_HOST]])

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

    # TLS material for the test environment's mode (the env file decides; we
    # just honour it). certs mode: a workstation private CA must exist AND be
    # trusted here. Fully idempotent — "already done" states are detected and
    # skipped; only the one-time sudo trust import is ever escalated.
    tenv = _load_test_env()
    if tenv.get("TLS_MODE") == "certs":
        if not have("openssl"):
            MISSING.append("openssl — needed for the private test CA "
                           "(dnf/apt install openssl)")
        else:
            ca_dir = os.path.expanduser(
                tenv.get("TLS_CA_DIR", "~/.config/workforce-dev/testca"))
            want_hosts = {f"{tenv.get('WF_SUBDOMAIN')}.{tenv.get('BASE_DOMAIN')}",
                          f"{tenv.get('AUTH_SUBDOMAIN')}.{tenv.get('BASE_DOMAIN')}"}
            leaf = os.path.join(ca_dir, "tls.crt")

            def _san_hosts():
                """DNS names on the leaf's SAN (set), or None when unreadable."""
                r = sh_out(["openssl", "x509", "-in", leaf, "-noout",
                            "-ext", "subjectAltName"])
                if r.returncode != 0:
                    return None
                return set(re.findall(r"DNS:([^,\s]+)", r.stdout or ""))

            def _ready():
                return all(os.path.isfile(os.path.join(ca_dir, n))
                           for n in ("tls.crt", "tls.key", "ca.crt")) \
                    and _san_hosts() == want_hosts

            if _ready():
                ok(f"test CA leaf matches this environment's hostnames ({ca_dir})")
            else:
                note("private test CA missing or stale for these hostnames — "
                     "generating (root reused if it already exists)…")
                try:
                    sh(["bash", os.path.join(HERE, "gen-test-ca.sh"), "test"])
                except SystemExit:
                    pass
                ok("test CA + leaf generated") if _ready() else MISSING.append(
                    "gen-test-ca.sh failed — run manually:  "
                    "bash deploy/bin/gen-test-ca.sh test")

            if _ready():
                # Is the root ACTUALLY trusted on this machine? The definitive
                # check verifies the leaf against the system default store
                # (distro-agnostic; 'OK' only after a real import).
                v = sh_out(["openssl", "verify", leaf])
                if v.returncode == 0:
                    ok("test root CA trusted by this machine (system store)")
                else:
                    anchor = ("/etc/pki/ca-trust/source/anchors/care-angels-testca.crt"
                              if DISTRO == "fedora" else
                              "/usr/local/share/ca-certificates/care-angels-testca.crt")
                    refresh = ("update-ca-trust" if DISTRO == "fedora"
                               else "update-ca-certificates")
                    priv("import the test root CA into this machine's "
                         "trust store",
                         [["sudo", "cp", os.path.join(ca_dir, "ca.crt"), anchor],
                          ["sudo", refresh]])

    # Privileged fixes we CAN take ourselves: run them via sudo now (the
    # password prompt lands on this TTY) and re-probe, instead of pushing a
    # "run this in another terminal" errand on the human. If sudo fails or
    # there is no TTY, the item degrades to the manual list.
    if PRIV_TASKS:
        if attempts >= 2:
            for t in PRIV_TASKS:
                MISSING.append(t["whys"][0] + " — manual:  "
                               + " &&  ".join(" ".join(c) for c in t["cmds"]))
            PRIV_TASKS.clear()
        else:
            say("Privileged host fixes available — running them now via "
                "sudo (a password prompt may appear):")
            for t in PRIV_TASKS:
                for w in t["whys"]:
                    print(f"    - {w}")
            failed = []
            for t in PRIV_TASKS:
                for c in t["cmds"]:
                    try:
                        rc = subprocess.run(c).returncode
                    except Exception:
                        rc = 127
                    if rc != 0:
                        failed.append((t, c))
                        break
            PRIV_TASKS.clear()
            for t, c in failed:
                MISSING.append(t["whys"][0] + " — auto-fix failed; run:  "
                               + " ".join(map(str, c)))
            return step0(attempts + 1)

    if MISSING:
        if attempts >= 2:
            fail("prerequisites still missing after 3 rounds — fix manually "
                 "and re-run.")
        pause_for_manual(MISSING)
        return step0(attempts + 1)

    say("  All prerequisites satisfied.")


# ============================================================ teardown

def tailscale_leave():
    """Unregister this VM's tailnet node before it dies (best-effort).
    Without this every reprovision leaves an offline orphan in the tailnet,
    and Tailscale's name-dedup then registers the next node as
    workforce-test-2, -3, … instead of the stable hostname the Vagrantfile
    pins. A powered-off VM can't speak for itself — logged as a note."""
    if not vm_created():
        return
    r = sh_out(["vagrant", "ssh", "-c", "sudo tailscale logout"], cwd=ENV_DIR)
    if r.returncode == 0:
        ok("VM logged out of the tailnet — no orphaned node left behind")
    else:
        note("tailscale logout skipped (VM powered off, or tailscale absent) "
             "— clean any stale workforce-test-* device in the tailnet admin")


def teardown():
    """Destroy the appliance. Everything inside it (deployment, database,
    certs, /opt state) dies with it, and the node unregisters itself from
    the tailnet first. External state that survives is cosmetic and
    re-pointed automatically on the next deploy."""
    say("\n───────── TEARDOWN ─────────")
    if vm_created():
        tailscale_leave()
        sh(["vagrant", "destroy", "-f"], cwd=ENV_DIR)
        ok("VM destroyed — deployment, data, certs and snapshot all gone")
    else:
        note("no VM exists — nothing to destroy")
    say("  Remaining external state (cosmetic):")
    say("    - DuckDNS records still aimed at the old tailnet IP")
    say("  Re-pointed automatically by the next deploy (STEP 3).")


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
        tailscale_leave()
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


def _probe_host_out():
    h = sh_out(["curl", "-4", "-m", "8", "-sI", "https://github.com"])
    return (h.stdout or "").upper().lstrip().startswith("HTTP")


def heal_host_network():
    """Host-side self-recovery for the known firewalld/docker/libvirt race over
    the iptables-nft FORWARD chain (observed 2026-09-19: host fine, guest fine,
    zero transit — the policy-drop chain quietly lost the zone/libvirt jumps
    after a network recreation). Ladder runs lightest-first and stops at the
    first success. The docker step restarts host containers; it is ordered last
    and only matters when the deploy cannot proceed without forwarding anyway.
    Requires passwordless sudo; otherwise prints the exact manual commands."""
    if not _probe_host_out():
        warn("host itself has no outbound internet — nothing to self-heal here; "
             "check the host connection first.")
        return False
    if sh_out(["sudo", "-n", "true"]).returncode != 0:
        note("no passwordless sudo on the host — cannot self-heal automatically. Manual ladder:")
        note("  sudo firewall-cmd --reload                                # 1")
        note("  sudo systemctl restart firewalld                          # 2")
        note("  sudo systemctl restart docker                             # 3 (bounces host containers)")
        note("  sudo virsh net-destroy vagrant-libvirt && sudo virsh net-start vagrant-libvirt  # 4 + vagrant reload")
        return False
    if sh_out(["cat", "/proc/sys/net/ipv4/ip_forward"]).stdout.strip() != "1":
        say("  re-enabling IPv4 forwarding…")
        sh(["sudo", "-n", "sysctl", "-w", "net.ipv4.ip_forward=1"], check=False)
    ladder = [
        ("reload firewall rules",
         [["sudo", "-n", "firewall-cmd", "--reload"]], False),
        ("restart firewalld (FORWARD hooks rebuild)",
         [["sudo", "-n", "systemctl", "restart", "firewalld"]], False),
        ("restart docker after firewalld (correct chain order; host containers bounce)",
         [["sudo", "-n", "systemctl", "restart", "docker"]], False),
        ("recreate the libvirt network + reload the VM",
         [["sudo", "-n", "virsh", "net-destroy", "vagrant-libvirt"],
          ["sudo", "-n", "virsh", "net-start", "vagrant-libvirt"]], True),
    ]
    for label, cmds, reload_vm in ladder:
        say("  self-heal: " + label + "…")
        for c in cmds:
            sh(c, check=False)
        if reload_vm:
            sh(["vagrant", "reload"], cwd=ENV_DIR, check=False)
        time.sleep(4)
        good, _ = guest_internet_ok()
        if good:
            ok("network self-healed at step: " + label)
            return True
    return False


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
            # third failure: stop poking the guest (its lease/route/vagrant state
            # already had two tries) and heal the HOST transit layer instead.
            if heal_host_network():
                return

    diag = sh_out(["vagrant", "ssh", "-c",
                   "ip -4 addr show eth0 | grep inet; "
                   + PROBE_CMD + "; echo curl_exit=$?"],
                  cwd=ENV_DIR)
    guest = (diag.stdout or "(unreachable)").strip()
    host_line = sh_out(["curl", "-4", "-m", "8", "-sI", "https://github.com"])
    fail("the VM has no outbound internet, and the host self-heal ladder did not "
         "restore it. Guest state:\n    "
         + guest.replace("\n", "\n    ")
         + "\n  Host probe on the same URL: "
         + ((host_line.stdout or "").strip().splitlines()[-1]
            if (host_line.stdout or "").strip() else "failed")
         + "\n  If the host probe failed, it is the host's own connection. "
           "Otherwise attach this output plus `sudo nft list chain ip filter FORWARD` "
           "when reporting.")


# ============================================================ STEP 4 (installer)

def step4():
    say("\n───────── STEP 4: install the suite (interactive) ─────────")
    say("  First run: the installer asks for a GitHub PAT (read:packages),")
    say("  email, admin password and backup directory, here in this terminal.")
    say("  An existing deployment resumes with no prompts at all.")
    say("  Out-of-band files are copied in automatically per the env file")
    say(f"  (DuckDNS token at {DUCKDNS_TOKEN_FILE}, test CA leaf at")
    say("   ~/.config/workforce-dev/testca) — the installer consumes both.")
    cmd = [sys.executable, BOOTSTRAP, "--vagrant", "--env", "test"]
    try:
        sh(cmd)
    except KeyboardInterrupt:
        restore_terminal()
        say("\n  (interrupted — the installer is resumable; rerun this "
            "script to continue)")
        raise SystemExit(130)
    finally:
        restore_terminal()


# ============================================================ STEP 5 (version)

def step5_version():
    """Shared converge+verify: identical code path to deploy_to_prod's.
    Only the transport differs — here a vagrant ssh as the service user."""
    say("\n───────── STEP 5: converge to pinned version + verify ─────────")
    target = TEST_ENV.get("APP_VERSION")
    if not target:
        fail("environments/test.env has no APP_VERSION pin")

    def run(cmd):
        full = ["vagrant", "ssh", "-c",
                "sudo -n -iu workforce_app_sa bash -lc " + shlex.quote(cmd)]
        r = sh_out(full, cwd=ENV_DIR)
        out = (r.stdout or "") + (r.stderr or "")
        if r.returncode != 0:
            say(out)                       # show what went wrong, not just rc
        return r.returncode, out

    current = deploylib.box_version(run)
    if not current:
        fail("cannot read APP_VERSION from /opt/workforce-deploy/.env on the VM "
             "(install failed?)")
    if current == target:
        ok(f"VM already on the pinned version {target}")
    else:
        deploylib.converge(run, target)
    ca = os.path.expanduser(
        TEST_ENV.get("TLS_CA_DIR", "~/.config/workforce-dev/testca") + "/ca.crt")
    require_hostnames()
    deploylib.verify_buildmeta(f"https://{APP_HOSTNAME}/api/v1/build-meta",
                               target, cafile=ca, insecure=True)
    # #15: the installer's one-time password banner scrolled away long ago;
    # reprint the recoverable record HERE, at the moment the operator is
    # reading this terminal. Only exists for installs that auto-generated it.
    r = sh_out(["vagrant", "ssh", "-c",
                "sudo -n cat /opt/workforce-deploy/secrets/initial-admin-password 2>/dev/null || true"],
               cwd=ENV_DIR)
    initial = (r.stdout or "").strip()
    # Guard against a corrupt record printing as the "password" (observed once:
    # 2-byte literal \n). Short/escaped content is treated as absent.
    if initial and len(initial) >= 8 and "\\" not in initial and initial != "\\n":
        warn("initial admin password (auto-generated at install): " + initial)
        say("  (on the box: /opt/workforce-deploy/secrets/initial-admin-password —"
            " move it to your password manager, then delete the file)")


# ============================================================ STEP 3 (tailnet+DNS)

def restore_terminal():
    """bootstrap drives the local terminal in raw mode for the remote PTY
    session. If it dies mid-session (interrupt, connection drop), the
    terminal can stay raw — no echo, broken newlines — which feels like
    the script 'didn't return control'. Restore unconditionally."""
    if OS != "Windows":
        subprocess.run(["stty", "sane"], check=False)
        print()


def read_duckdns_token():
    if os.path.isfile(DUCKDNS_TOKEN_FILE):
        with open(DUCKDNS_TOKEN_FILE) as f:
            for line in f:
                if line.startswith("DUCKDNS_TOKEN="):
                    return line.split("=", 1)[1].strip()
    say(f"  No token file at {DUCKDNS_TOKEN_FILE}")
    return getpass.getpass("  DuckDNS token (input hidden): ").strip()


def step3_tailnet():
    """Join the tailnet and point DuckDNS at THIS VM BEFORE the installer:
    the playbook's discovery check resolves the public hostname, which must
    reach THIS VM (the historical fresh-deploy chicken-and-egg)."""
    say("\n───────── STEP 3: Tailscale + DuckDNS (before install) ─────────")
    require_hostnames()
    say("  A login URL will appear — open it in a browser and approve "
        "the device.")
    # Fresh VMs don't have tailscale yet: bootstrap installs it (STEP 4),
    # but the join now happens first. Install on demand, idempotently.
    r = sh_out(["vagrant", "ssh", "-c", "command -v tailscale"], cwd=ENV_DIR)
    if r.returncode != 0 or not (r.stdout or "").strip():
        note("installing Tailscale inside the VM (one-time)…")
        sh(["vagrant", "ssh", "-c",
            "curl -fsSL https://tailscale.com/install.sh | sudo sh"],
           cwd=ENV_DIR)
    join_cmd = "sudo tailscale up"
    if getattr(main, "ts_auth_key", None):
        join_cmd += f" --auth-key={main.ts_auth_key}"
        note("joining the tailnet with the provided auth key…")
    sh(["vagrant", "ssh", "-c", join_cmd], cwd=ENV_DIR, check=False)
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
                    help="tear down the VM and redeploy from scratch "
                         "(full journey)")
    ap.add_argument("--teardown", action="store_true",
                    help="destroy the VM and stop (no redeploy)")
    ap.add_argument("--check-only", action="store_true",
                    help="run STEP 0 (prerequisite report) and exit")
    ap.add_argument("--skip-to", type=int, default=0, choices=[0, 1, 2, 3, 4, 5],
                    help="resume at step N (runs that step and everything "
                         "after): 0 prereqs, 1 VM, 2 guest-internet, "
                         "3 Tailscale+DuckDNS, 4 install, 5 version converge")
    ap.add_argument("--tailscale-auth-key",
                    help="join the tailnet unattended (else the login URL "
                         "is shown for browser approval)")
    args = ap.parse_args()

    say("═══════════════════════════════════════════════════════")
    say("  Workforce Suite → TEST environment (any OS)")
    say("═══════════════════════════════════════════════════════")

    main.ts_auth_key = args.tailscale_auth_key
    if args.teardown:
        teardown()
        return
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
        step3_tailnet()
    if args.skip_to <= 4:
        step4()
    if args.skip_to <= 5:
        step5_version()

    require_hostnames()
    say("\n═══════════════════════════════════════════════════════")
    say("  TEST environment deployed.")
    say(f"    App:     https://{APP_HOSTNAME}")
    say(f"    Sign-in: https://{AUTH_HOSTNAME}   (user: admin)")
    say("  Reachable from any device on your tailnet.")
    say("  Reset anytime:   vagrant snapshot restore clean && vagrant up")
    say("  Full tear-down + redeploy:  deploy_to_test.py --fresh")
    say("═══════════════════════════════════════════════════════")


if __name__ == "__main__":
    main()
