#!/usr/bin/env python3
"""
deploy_to_test.py — deploy the workforce suite to the TEST appliance: the
Incus system container `workforce-test` (project `appliance`) on the devbox.

Incus is the ONLY supported test platform. The devbox is a VPS without
/dev/kvm, so Vagrant/libvirt VMs cannot run there; the appliance is an Incus
*container* (handover note 2026-10-11 §6, ADR-0014 topology note).

  STEP 0  host prerequisites (read-only checks; the only sudo it may run is
          the one-time trust import of the private test CA)
  STEP 1  the appliance exists and is running   (--fresh: restore snapshot
          'clean' first — the installed, verified baseline)
  STEP 2  the guest has outbound internet       (HTTPS probe; host NAT check)
  STEP 3  Tailscale + DuckDNS                   (guest on the tailnet, both
          test names pointing at its tailnet IP — before any install, because
          the installer's OIDC discovery goes through the public hostname)
  STEP 4  install the suite if it is not there  (bootstrap.py --host <guest>
          over SSH: host key pinned from the guest itself via incus, this
          host's key authorised for root; interactive prompts on first install)
  STEP 5  converge to environments/test.env:APP_VERSION + verify
          (deploylib.converge — the SAME code deploy_to_prod.py runs; only the
          transport differs: `incus exec … sudo -u workforce_app_sa -H bash -lc`)

Usage (on the devbox, from a clone of this repo):
  python3 bin/deploy_to_test.py                 # full journey (idempotent)
  python3 bin/deploy_to_test.py --check-only    # STEP 0 only
  python3 bin/deploy_to_test.py --skip-to 5     # just converge + verify
  python3 bin/deploy_to_test.py --fresh         # reset to snapshot 'clean', then converge
  python3 bin/deploy_to_test.py --snapshot      # after a verified run: re-take 'clean'

Incus access: as a member of `incus-admin`, or via passwordless `sudo incus`
(detected automatically). Creating the container itself (project, storage
pool, profile, network, host NAT) is a one-time manual step — RUNBOOK.md
"Test appliance (Incus)".

Everything the guest runs comes from the deployment bundle (cloned from
origin by bootstrap.py) — nothing is ever hand-edited in the guest.
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
import time
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import deploylib                                    # noqa: E402
ENV_DIR = os.path.normpath(os.path.join(HERE, "..", "environments"))
BOOTSTRAP = os.path.join(HERE, "bootstrap.py")

DUCKDNS_API = "https://www.duckdns.org/update"   # the DuckDNS service endpoint

# Host-side token file (outside the repo), overridable via the environment.
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

# The appliance (environments/test.env; defaults = the devbox as built 2026-10-11).
INSTANCE = TEST_ENV.get("INCUS_INSTANCE", "workforce-test")
PROJECT = TEST_ENV.get("INCUS_PROJECT", "appliance")
SNAPSHOT = TEST_ENV.get("INCUS_SNAPSHOT", "clean")
TS_HOSTNAME = TEST_ENV.get("TAILSCALE_HOSTNAME", INSTANCE)
SSH_KEY = os.path.expanduser(TEST_ENV.get("GUEST_SSH_KEY", "~/.ssh/id_ed25519"))
SERVICE_USER = "workforce_app_sa"
WORKDIR = deploylib.WORKDIR

# `incus` or `sudo -n incus` — decided in STEP 0 (see incus_access()).
INCUS = ["incus"]


def duckdns_name(hostname):
    if hostname and BASE_DOMAIN and hostname.endswith("." + BASE_DOMAIN):
        return hostname[:-(len(BASE_DOMAIN) + 1)]
    return hostname


def require_hostnames():
    if not (APP_HOSTNAME and AUTH_HOSTNAME):
        fail(f"hostnames could not be derived from {ENV_DIR}/test.env "
             "(needs BASE_DOMAIN, WF_SUBDOMAIN, AUTH_SUBDOMAIN).")


OS = platform.system()
DISTRO = ""
if OS == "Linux":
    try:
        with open("/etc/os-release") as f:
            DISTRO = "fedora" if "fedora" in f.read().lower() else "other"
    except OSError:
        DISTRO = "other"

MISSING = []

# Privileged fixes the script runs itself via sudo (prompt on this TTY) —
# today only the one-time import of the private test CA into the trust store.
PRIV_TASKS = []


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



# ============================================================ incus transport

def incus(*args):
    """Run an incus command against the appliance's project, capturing output."""
    return sh_out(INCUS + list(args) + ["--project", PROJECT])


def guest(cmd, as_service_user=False):
    """Run a shell command inside the guest (as root, or as the service user
    through a login shell — the same identity the installer and update.sh use).
    Returns (returncode, combined output)."""
    # sudo -u, not -i: -i re-parses the command through the target's shell, so $vars
    # meant for an inner `sh -c '…'` (deploylib.GUARDED_PULL) were expanded one layer
    # early — the guard became a no-op and `exit $rc` always exited 0.
    inner = (["sudo", "-n", "-u", SERVICE_USER, "-H", "bash", "-lc", cmd]
             if as_service_user else ["bash", "-lc", cmd])
    r = sh_out(INCUS + ["exec", INSTANCE, "--project", PROJECT, "--"] + inner)
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def incus_access():
    """Pick the incus invocation that can see the appliance's project: plain
    `incus` for incus-admin members, else passwordless `sudo -n incus`. A
    member of the restricted `incus` group only sees its own per-user project,
    which is why plain `incus list --project appliance` can look empty."""
    global INCUS
    for prefix in (["incus"], ["sudo", "-n", "incus"]):
        r = sh_out(prefix + ["project", "show", PROJECT])
        if r.returncode == 0:
            INCUS = prefix
            return True
    return False


def instance_state():
    """'RUNNING' | 'STOPPED' | … | None when the instance does not exist."""
    r = incus("list", INSTANCE, "-c", "ns", "--format", "csv")
    for line in (r.stdout or "").splitlines():
        name, _, state = line.partition(",")
        if name == INSTANCE:
            return state.strip()
    return None


def snapshot_exists():
    r = incus("snapshot", "list", INSTANCE, "--format", "csv", "-c", "n")
    return SNAPSHOT in [l.strip() for l in (r.stdout or "").splitlines()]


def guest_eth0_ip():
    rc, out = guest("ip -4 -o addr show dev eth0 | awk '{print $4}' | cut -d/ -f1")
    ip = out.strip().splitlines()[-1].strip() if out.strip() else ""
    return ip if rc == 0 and re.match(r"^\d+\.\d+\.\d+\.\d+$", ip) else None



# ============================================================ STEP 0

def step0(attempts=0, check_only=False):
    say("\n───────── STEP 0: host prerequisites ─────────")
    MISSING.clear()
    PRIV_TASKS.clear()

    if OS != "Linux":
        fail("the TEST appliance runs in Incus on the devbox — run this script "
             "there (it is Linux-only).")

    if not have("incus"):
        MISSING.append("incus CLI — the devbox runs Incus (zabbly repo); this "
                       "host is not the appliance host")
    elif incus_access():
        how = "incus-admin" if INCUS == ["incus"] else "passwordless sudo"
        ok(f"incus can manage project '{PROJECT}' (via {how})")
        state = instance_state()
        if state is None:
            MISSING.append(f"Incus instance '{INSTANCE}' not found in project "
                           f"'{PROJECT}' — create it once by hand (RUNBOOK.md, "
                           "'Test appliance (Incus)'); this script never creates "
                           "or destroys the container")
        else:
            ok(f"appliance '{INSTANCE}' exists ({state})")
    else:
        user = os.environ.get("USER") or os.environ.get("LOGNAME", "")
        MISSING.append(
            f"no admin access to Incus project '{PROJECT}' — either  sudo usermod "
            f"-aG incus-admin {user}  (then log out & back in) or allow "
            "passwordless sudo for incus")

    for tool in ("ssh-keygen", "curl"):
        if not have(tool):
            MISSING.append(f"{tool} — install it (apt-get install openssh-client curl)")
    if not os.path.isfile(SSH_KEY) or not os.path.isfile(SSH_KEY + ".pub"):
        MISSING.append(f"SSH key pair {SSH_KEY}(.pub) — bootstrap.py authenticates "
                       "to the guest's root with it (GUEST_SSH_KEY in test.env)")
    else:
        ok(f"SSH key for the guest: {SSH_KEY}")

    # paramiko (bootstrap.py talks SSH through it)
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
    if PRIV_TASKS and check_only:
        # --check-only never changes anything: report, don't run.
        for t in PRIV_TASKS:
            MISSING.append(t["whys"][0] + " — a full run does this via sudo:  "
                           + " &&  ".join(" ".join(map(str, c)) for c in t["cmds"]))
        PRIV_TASKS.clear()
    if check_only:
        if MISSING:
            warn("would need attention before a deploy:")
            for m in MISSING:
                print(f"    - {m}")
        else:
            say("  All prerequisites satisfied.")
        return
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
            return step0(attempts + 1, check_only)

    if MISSING:
        if attempts >= 2:
            fail("prerequisites still missing after 3 rounds — fix manually "
                 "and re-run.")
        pause_for_manual(MISSING)
        return step0(attempts + 1, check_only)

    say("  All prerequisites satisfied.")


# ============================================================ STEP 1

def step1(fresh):
    say("\n───────── STEP 1: the appliance ─────────")
    state = instance_state()
    if state is None:
        fail(f"instance '{INSTANCE}' is gone from project '{PROJECT}' — recreate "
             "it per RUNBOOK.md 'Test appliance (Incus)', then re-run.")
    if fresh:
        if not snapshot_exists():
            fail(f"--fresh needs snapshot '{SNAPSHOT}', which does not exist yet "
                 "— run once without --fresh, then --snapshot.")
        note(f"restoring snapshot '{SNAPSHOT}' (the installed, verified baseline)…")
        # No tailscale logout first: the snapshot holds the node's own state,
        # so the restored guest comes back as the same tailnet device.
        r = incus("snapshot", "restore", INSTANCE, SNAPSHOT)
        if r.returncode != 0:
            fail("snapshot restore failed: " + (r.stderr or r.stdout or "").strip())
        ok(f"restored '{SNAPSHOT}'")
        state = instance_state()
    if state != "RUNNING":
        note(f"starting '{INSTANCE}' (was {state})…")
        r = incus("start", INSTANCE)
        if r.returncode != 0:
            fail("could not start the appliance: " + (r.stderr or r.stdout or "").strip())
    for _ in range(30):
        rc, _out = guest("true")
        if rc == 0:
            break
        time.sleep(2)
    else:
        fail("the appliance is running but `incus exec` does not answer.")
    ok(f"'{INSTANCE}' is running" + (" (snapshot "
       f"'{SNAPSHOT}' available for --fresh)" if snapshot_exists() else ""))


# ============================================================ STEP 2

PROBE_CMD = "curl -4 -m 8 -sI https://github.com | head -1"


def guest_internet_ok():
    """HTTPS deliberately: some networks blackhole plain-HTTP to Ubuntu
    mirrors while everything else works."""
    rc, out = guest(PROBE_CMD)
    return any(code in out for code in ("200", "301", "302")), out


def step2():
    say("\n───────── STEP 2: verify guest internet ─────────")
    good, out = guest_internet_ok()
    if good:
        ok(f"guest has outbound internet ({out.strip().splitlines()[-1] if out.strip() else 'probe'})")
        return
    host = sh_out(["curl", "-4", "-m", "8", "-sI", "https://github.com"])
    if not (host.stdout or "").upper().lstrip().startswith("HTTP"):
        fail("the devbox itself has no outbound internet — fix that first.")
    # Known devbox gotcha: guest egress depends on the persisted host NAT for
    # the Incus bridge (incus-nat.service: MASQUERADE + FORWARD accepts that
    # ufw's FORWARD drop would otherwise swallow).
    nat = sh_out(["systemctl", "is-active", "incus-nat.service"])
    if (nat.stdout or "").strip() != "active":
        warn("incus-nat.service is not active — restarting it (sudo)…")
        sh(["sudo", "systemctl", "restart", "incus-nat.service"], check=False)
        time.sleep(3)
        good, out = guest_internet_ok()
        if good:
            ok("guest internet restored by restarting incus-nat.service")
            return
    _rc, diag = guest("ip -4 -o addr show dev eth0; ip route; cat /etc/resolv.conf; "
                      + PROBE_CMD + "; echo curl_exit=$?")
    fail("the guest has no outbound internet although the host does. Guest state:\n    "
         + diag.strip().replace("\n", "\n    ")
         + "\n  Check: systemctl status incus-nat.service; sudo nft list ruleset | "
           "grep -A3 10.230.4; guest DNS must be 1.1.1.1/8.8.8.8 (RUNBOOK.md).")


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
    """Put the guest on the tailnet and point DuckDNS at it BEFORE any install:
    the playbook's OIDC discovery check resolves the public hostname, which
    must already reach this guest."""
    say("\n───────── STEP 3: Tailscale + DuckDNS ─────────")
    require_hostnames()
    rc, out = guest("tailscale ip -4 2>/dev/null")
    ip = out.strip().splitlines()[0].strip() if rc == 0 and out.strip() else ""
    if ip.startswith("100."):
        ok(f"guest already on the tailnet: {ip}")
    else:
        rc, _ = guest("command -v tailscale")
        if rc != 0:
            note("installing Tailscale inside the guest (one-time)…")
            rc, out = guest("curl -fsSL https://tailscale.com/install.sh | sh")
            if rc != 0:
                fail("Tailscale install failed in the guest:\n" + out[-800:])
        join = f"tailscale up --hostname={shlex.quote(TS_HOSTNAME)}"
        if getattr(main, "ts_auth_key", None):
            join += f" --auth-key={shlex.quote(main.ts_auth_key)}"
            note("joining the tailnet with the provided auth key…")
        else:
            say("  A login URL will appear — open it in a browser and approve the device.")
        # Interactive: stream it (the login URL must reach the operator).
        sh(INCUS + ["exec", INSTANCE, "--project", PROJECT, "--", "bash", "-lc", join],
           check=False)
        rc, out = guest("tailscale ip -4")
        ip = out.strip().splitlines()[0].strip() if rc == 0 and out.strip() else ""
        if not ip.startswith("100."):
            fail(f"could not read the guest's tailnet IP (got: {ip!r}).")
        ok(f"guest tailnet IP: {ip}")

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
             "Check the token, then re-run with --skip-to 3.")
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
                 f"DNS caching — retry shortly or:  echo '{ip} {host}' | sudo tee -a /etc/hosts")


# ============================================================ STEP 4 (installer)

def installed():
    rc, _ = guest(f"test -f {WORKDIR}/.env")
    return rc == 0


def authorise_host_key():
    """Make sure this host's public key may log in as root in the guest (the
    guest's root password is locked). incus exec is the trusted channel."""
    with open(SSH_KEY + ".pub") as f:
        pub = f.read().strip()
    rc, _ = guest("install -d -m 700 /root/.ssh && touch /root/.ssh/authorized_keys && "
                  "chmod 600 /root/.ssh/authorized_keys && grep -qxF "
                  + shlex.quote(pub) + " /root/.ssh/authorized_keys || echo "
                  + shlex.quote(pub) + " >> /root/.ssh/authorized_keys")
    if rc != 0:
        fail("could not authorise this host's SSH key for root in the guest.")


def guest_host_key_fingerprint():
    """The guest's ED25519 host-key fingerprint, read through incus — so
    bootstrap.py can PIN it instead of trusting first contact over the network."""
    rc, out = guest("ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub")
    m = re.search(r"(SHA256:\S+)", out)
    if rc != 0 or not m:
        fail("could not read the guest's SSH host key (is openssh-server installed?).")
    return m.group(1)


def step4(reinstall):
    say("\n───────── STEP 4: install the suite ─────────")
    if installed() and not reinstall:
        ok(f"suite already installed in the guest ({WORKDIR}/.env present) — "
           "version changes happen in STEP 5")
        return
    ip = guest_eth0_ip()
    if not ip:
        fail("could not read the guest's eth0 address.")
    authorise_host_key()
    fp = guest_host_key_fingerprint()
    ok(f"guest {ip}, host key pinned {fp}")
    say("  First install: the installer asks for the service-user password, a")
    say("  GitHub PAT (read:packages), admin password and backup target, here in")
    say("  this terminal. The test-CA leaf is shipped automatically.")
    cmd = [sys.executable, BOOTSTRAP, "--host", ip, "--user", "root",
           "--keyfile", SSH_KEY, "--host-key-fingerprint", fp, "--env", "test"]
    try:
        sh(cmd)
    except KeyboardInterrupt:
        restore_terminal()
        say("\n  (interrupted — the installer is resumable; rerun this "
            "script with --skip-to 4 --reinstall)")
        raise SystemExit(130)
    finally:
        restore_terminal()


# ============================================================ STEP 5 (version)

def step5_version():
    """Shared converge+verify: identical code path to deploy_to_prod's.
    Only the transport differs — incus exec as the service user."""
    say("\n───────── STEP 5: converge to pinned version + verify ─────────")
    target = TEST_ENV.get("APP_VERSION")
    if not target:
        fail("environments/test.env has no APP_VERSION pin")

    def run(cmd):
        rc, out = guest(cmd, as_service_user=True)
        if rc != 0:
            say(out)                       # show what went wrong, not just rc
        return rc, out

    current = deploylib.box_version(run)
    if not current:
        fail(f"cannot read APP_VERSION from {WORKDIR}/.env in the guest "
             "(install failed?)")
    if current == target:
        ok(f"appliance already on the pinned version {target}")
    else:
        deploylib.converge(run, target)
    ca = os.path.expanduser(
        TEST_ENV.get("TLS_CA_DIR", "~/.config/workforce-dev/testca") + "/ca.crt")
    require_hostnames()
    deploylib.verify_buildmeta(f"https://{APP_HOSTNAME}/api/v1/build-meta",
                               target, cafile=ca, insecure=True)
    # #15: reprint the one-time admin password record while the operator is
    # reading this terminal (only exists for installs that auto-generated it).
    _rc, initial = guest(f"cat {WORKDIR}/secrets/initial-admin-password 2>/dev/null || true")
    initial = initial.strip()
    if initial and len(initial) >= 8 and "\\" not in initial:
        warn("initial admin password (auto-generated at install): " + initial)
        say(f"  (in the guest: {WORKDIR}/secrets/initial-admin-password —"
            " move it to your password manager, then delete the file)")


def take_snapshot():
    """(Re)take the baseline snapshot --fresh restores. Only after a verified run."""
    if snapshot_exists():
        r = incus("snapshot", "delete", INSTANCE, SNAPSHOT)
        if r.returncode != 0:
            fail("could not replace the old snapshot: " + (r.stderr or "").strip())
    r = incus("snapshot", "create", INSTANCE, SNAPSHOT)
    if r.returncode != 0:
        fail("snapshot failed: " + (r.stderr or r.stdout or "").strip())
    ok(f"snapshot '{SNAPSHOT}' taken — `--fresh` now resets to this state")


# ============================================================ main

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--fresh", action="store_true",
                    help=f"restore snapshot '{SNAPSHOT}' first, then run the journey")
    ap.add_argument("--check-only", action="store_true",
                    help="run STEP 0 (prerequisite report) and exit")
    ap.add_argument("--skip-to", type=int, default=0, choices=[0, 1, 2, 3, 4, 5],
                    help="resume at step N (runs that step and everything after): "
                         "0 prereqs, 1 appliance, 2 guest-internet, "
                         "3 Tailscale+DuckDNS, 4 install, 5 version converge")
    ap.add_argument("--reinstall", action="store_true",
                    help="STEP 4 runs bootstrap.py even when the suite is installed "
                         "(the installer resumes/re-converges)")
    ap.add_argument("--snapshot", action="store_true",
                    help=f"after a successful verify, (re)take snapshot '{SNAPSHOT}'")
    ap.add_argument("--tailscale-auth-key",
                    help="join the tailnet unattended (else a login URL is shown)")
    args = ap.parse_args()

    say("═══════════════════════════════════════════════════════")
    say(f"  Workforce Suite → TEST appliance (Incus: {PROJECT}/{INSTANCE})")
    say("═══════════════════════════════════════════════════════")

    main.ts_auth_key = args.tailscale_auth_key
    step0(check_only=args.check_only)   # always: it also decides how incus is invoked
    if args.check_only:
        say("\nCheck complete — nothing was changed.")
        return

    if args.skip_to <= 1:
        step1(args.fresh)
    if args.skip_to <= 2:
        step2()
    if args.skip_to <= 3:
        step3_tailnet()
    if args.skip_to <= 4:
        step4(args.reinstall)
    if args.skip_to <= 5:
        step5_version()
    if args.snapshot:
        take_snapshot()

    require_hostnames()
    say("\n═══════════════════════════════════════════════════════")
    say("  TEST appliance deployed.")
    say(f"    App:     https://{APP_HOSTNAME}")
    say(f"    Sign-in: https://{AUTH_HOSTNAME}   (user: admin)")
    say("  Reachable from any device on your tailnet (test-CA root installed).")
    say(f"  Reset to the baseline:  deploy_to_test.py --fresh   (snapshot '{SNAPSHOT}')")
    say("═══════════════════════════════════════════════════════")


if __name__ == "__main__":
    main()
