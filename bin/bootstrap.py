#!/usr/bin/env python3
"""
bootstrap.py — one-command remote deployment for the Care Angels Workforce Suite.

Run this from ANYWHERE (your laptop, another server) with the target's root
credentials; it connects over SSH and drives the entire first deployment:

    1. installs host prerequisites (git, curl) on the fresh server
    2. clones the public deployment bundle (workforce-deploy)
    3. runs install.sh INTERACTIVELY — you answer its prompts live through this
       terminal (service-user password, GitHub token, the four questions)

Usage:
    python3 bootstrap.py --host 203.0.113.7
    python3 bootstrap.py --host 203.0.113.7 --user root --port 22
    python3 bootstrap.py --host vmi.example.com          # password prompted securely

Root password is prompted with getpass when not supplied (never on the command
line — it would leak into `ps` on your machine).

Requires: python3 + paramiko  (pip install paramiko)
"""

import argparse
import getpass
import os
import sys
import time

try:
    import paramiko
except ImportError:
    sys.exit("paramiko is required:  pip install paramiko")

BUNDLE_REPO = "https://github.com/marlon-thomas/workforce-deploy.git"
INSTALL_CMD = "cd /root/workforce-deploy && ./bin/install.sh --env {env}"

# Vagrant mode: the bundle lands in /home/vagrant (not /root), and sudo is NOPASSWD.
VAGRANT_PREP = r"""
set -e
echo "==> Installing host prerequisites (git, curl, tailscale)…"
# Some networks blackhole plain-HTTP to Ubuntu mirrors; apt over https
# works everywhere that has DNS + 443 (observed on a filtered home network).
sudo sed -i 's|http://archive.ubuntu.com|https://archive.ubuntu.com|g; \
             s|http://security.ubuntu.com|https://security.ubuntu.com|g; \
             s|http://us.archive.ubuntu.com|https://us.archive.ubuntu.com|g' \
    /etc/apt/sources.list /etc/apt/sources.list.d/*.sources 2>/dev/null || true
sudo apt-get update -qq >/dev/null
sudo apt-get install -y -qq git curl ca-certificates >/dev/null
if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1 || \
    echo "WARN: tailscale install failed — install it manually inside the VM."
fi
sudo systemctl enable --now tailscaled >/dev/null 2>&1 || true
echo "==> Fetching the deployment bundle…"
rm -rf /home/vagrant/workforce-deploy
git clone -q {repo} /home/vagrant/workforce-deploy
sudo chown -R vagrant:vagrant /home/vagrant/workforce-deploy
echo "==> Bundle ready. Handing over to the installer (answer its prompts below)."
"""

PREP = r"""
set -e
export DEBIAN_FRONTEND=noninteractive
echo "==> Installing host prerequisites (git, curl)…"

# Fresh Ubuntu boxes run unattended-upgrades in the background; it holds the dpkg
# lock for minutes. Wait politely instead of failing (process 1596 lesson).
for i in $(seq 1 60); do
  if ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
     && ! pgrep -x apt-get >/dev/null \
     && ! pgrep -x dpkg >/dev/null; then
    break
  fi
  if [ "$i" = 1 ]; then
    echo "    (waiting for apt/dpkg to become available — unattended-upgrades runs"
    echo "     automatically on fresh Ubuntu; this usually takes a minute or two)"
  fi
  sleep 10
done
sed -i 's|http://archive.ubuntu.com|https://archive.ubuntu.com|g; \
        s|http://security.ubuntu.com|https://security.ubuntu.com|g; \
        s|http://us.archive.ubuntu.com|https://us.archive.ubuntu.com|g' \
    /etc/apt/sources.list /etc/apt/sources.list.d/*.sources 2>/dev/null || true
apt-get update -qq >/dev/null
apt-get install -y -qq git curl ca-certificates >/dev/null
echo "==> Fetching the deployment bundle…"
rm -rf /root/workforce-deploy
git clone -q {repo} /root/workforce-deploy
echo "==> Bundle ready. Handing over to the installer (answer its prompts below)."
"""


def scrub_known_hosts(host):
    """Remove any stale entries for the host (both its name and resolved IPs) from
    the local known_hosts files — a re-provisioned server (new host key) would
    otherwise trip client-side strict host key checking on some setups."""
    import socket
    import glob
    import subprocess
    names = {host}
    try:
        infos = socket.getaddrinfo(host, None)
        for info in infos:
            names.add(info[4][0])
    except OSError:
        pass
    removed_any = False
    for kh in glob.glob(os.path.expanduser("~/.ssh/known_hosts*")):
        for name in names:
            result = subprocess.run(
                ["ssh-keygen", "-R", name, "-f", kh],
                capture_output=True)
            # ssh-keygen -R exits 0 even when nothing was removed; detect via output
            if b"Found" not in result.stderr and result.returncode == 0 and result.stdout:
                pass
            removed_any = True  # ssh-keygen -R rewrites the file idempotently
    if removed_any:
        print(f"Cleared known_hosts entries for: {', '.join(sorted(names))}")


def connect(host, port, user, password, keyfile=None):
    scrub_known_hosts(host)
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    print(f"Connecting to {user}@{host}:{port} …")
    client.connect(host, port=port, username=user, password=password,
                   key_filename=keyfile,
                   look_for_keys=False, allow_agent=False, timeout=20)
    print("Connected.")
    return client


def run_quiet(client, cmd):
    """Run a command, stream output, return exit code."""
    transport = client.get_transport()
    chan = transport.open_session()
    chan.get_pty()
    chan.exec_command(cmd)
    buf = b""
    while True:
        if chan.recv_ready():
            buf += chan.recv(4096)
            while buf:
                line, nl, rest = buf.partition(b"\n")
                if nl:
                    print(line.decode(errors="replace"))
                    buf = rest
                else:
                    break
        if chan.exit_status_ready() and not chan.recv_ready():
            break
        time.sleep(0.1)
    while chan.recv_ready():
        print(chan.recv(4096).decode(errors="replace"), end="")
    return chan.recv_exit_status()


def interactive_shell(client, cmd):
    """Open an interactive PTY running cmd; the local terminal drives it live."""
    transport = client.get_transport()
    chan = transport.open_session()
    chan.get_pty(term="xterm", width=terminal_width(), height=40)
    chan.invoke_shell() if not cmd else chan.exec_command(cmd)
    import select
    import tty
    import termios

    old_attrs = termios.tcgetattr(sys.stdin)
    tty.setraw(sys.stdin.fileno())
    try:
        while True:
            r, _, _ = select.select([chan, sys.stdin], [], [], 0.05)
            if chan in r:
                try:
                    data = chan.recv(4096)
                except Exception:
                    break
                if not data:
                    break
                sys.stdout.write(data.decode(errors="replace"))
                sys.stdout.flush()
            if sys.stdin in r:
                data = sys.stdin.read(1)
                if not data:
                    break
                chan.send(data)
            if chan.exit_status_ready() and not chan.recv_ready():
                break
    except KeyboardInterrupt:
        print("\n(bootstrap interrupted — the remote installer may still be running)")
    finally:
        termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old_attrs)
    # Propagate the remote exit status — a silent installer failure must
    # never look like success (the banner below is printed by the caller).
    try:
        rc = chan.recv_exit_status()
    except Exception:
        rc = -1
    if rc != 0:
        sys.exit(f"\nXX remote installer FAILED (exit {rc}) — see its output "
                 "above; fix and re-run (the installer resumes safely).")
    return rc


def terminal_width():
    try:
        import shutil
        return shutil.get_terminal_size().columns
    except Exception:
        return 100


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", help="server IP or hostname "
                    "(not needed with --vagrant: resolved from "
                    "'vagrant ssh-config')")
    ap.add_argument("--port", type=int, default=22)
    ap.add_argument("--user", default="root")
    ap.add_argument("--password", help="root password (prompted if omitted)")
    ap.add_argument("--env", default="prod", choices=["test", "prod"],
                    help="deployment environment (test = Ubuntu appliance, prod = live VPS)")
    ap.add_argument("--vagrant", action="store_true",
                    help="target the TEST Vagrant VM (uses 'vagrant ssh-config' for "
                         "host/port/key; run from deploy/environments after 'vagrant up')")
    ap.add_argument("--repo", default=BUNDLE_REPO,
                    help="deployment bundle repo to clone inside the target "
                         "(default: the public bundle; deploy_to_test passes "
                         "the origin of the bundle it runs from)")
    ap.add_argument("--smoke", action="store_true",
                    help="no-TLS smoke install inside the VM (OIDC-less, HTTP) — "
                         "the only mode that works without router port-forwarding")
    args = ap.parse_args()

    if args.vagrant:
        import subprocess
        # Work regardless of caller's cwd: 'vagrant ssh-config' needs the
        # Vagrantfile directory (deploy/environments, sibling of this script).
        env_dir = os.path.normpath(os.path.join(
            os.path.dirname(os.path.abspath(__file__)), "..", "environments"))
        cfg = subprocess.run(["vagrant", "ssh-config"], capture_output=True,
                             text=True, check=True,
                             cwd=env_dir if os.path.isdir(env_dir) else None).stdout
        params = {}
        for line in cfg.splitlines():
            if " " in line:
                k, _, v = line.strip().partition(" ")
                params[k.lstrip(" ")] = v.strip(" \"'")
        args.host = params.get("HostName", "127.0.0.1")
        args.port = int(params.get("Port", 2222))
        args.user = params.get("User", "vagrant")
        kf = params.get("IdentityFile")
        if kf:
            # Windows vagrant emits backslash paths — paramiko accepts either,
            # but normalise and expand for safety.
            kf = os.path.expanduser(kf.replace("\\", "/"))
        args.keyfile = kf
        print(f"Vagrant VM: {args.host}:{args.port} (user {args.user}, key auth)")

    if args.keyfile:
        # Vagrant mode: key auth — no password needed or wanted.
        password = args.password
    else:
        if not args.host:
            sys.exit("error: --host is required (unless --vagrant)")
        password = args.password or getpass.getpass(
            f"Password for {args.user}@{args.host}: ")

    client = connect(args.host, args.port, args.user, password,
                     keyfile=getattr(args, "keyfile", None))
    try:
        prep_cmd = PREP
        install_cmd = INSTALL_CMD.format(env=args.env)
        # repo chosen via --repo (or the public bundle default), formatted
        # into the prep templates at use-site
        if args.vagrant:
            rc = run_quiet(client, VAGRANT_PREP.format(repo=args.repo))
            if rc != 0:
                sys.exit(f"Host preparation failed (exit {rc}).")
            # Drop the host's DuckDNS token file into the VM so the installer
            # can pick it up for DNS-01 certificate issuance (silent if absent;
            # the installer will prompt instead).
            tok = os.path.expanduser("~/.config/workforce-dev/duckdns.env")
            if os.path.isfile(tok):
                sftp = client.open_sftp()
                try:
                    sftp.put(tok, "/home/vagrant/duckdns.env")
                    run_quiet(client, "chmod 600 /home/vagrant/duckdns.env")
                    print("DuckDNS token file copied into the VM.")
                except Exception as exc:
                    print(f"WARN: could not copy DuckDNS token ({exc}); "
                          "the installer will prompt for it.")
                finally:
                    sftp.close()
            install_cmd = ("cd /home/vagrant/workforce-deploy && "
                           "sudo -E bash ./bin/install.sh --env " + args.env
                           + (" --smoke" if args.smoke else ""))
            interactive_shell(client, install_cmd)
            print("")
            print("=" * 72)
            print(" Installer finished. Final step — put the VM on your tailnet:")
            print("   vagrant ssh -c \"sudo tailscale up\"     (follow the login URL)")
            print("   vagrant ssh -c \"tailscale ip -4\"       (the VM's tailnet IP)")
            print(" Then point the DuckDNS records at that IP:")
            print("   curl 'https://www.duckdns.org/update?domains=workforce-test,workforce-test-auth&token=<TOKEN>&ip=<TAILNET-IP>'")
            print("")
            print(" Browse (from any tailnet device):")
            print("   https://workforce-test.duckdns.org        (app)")
            print("   https://workforce-test-auth.duckdns.org   (sign-in, user: admin)")
            print("=" * 72)
            client.close()
            return
        rc = run_quiet(client, prep_cmd.format(repo=args.repo))
        if rc != 0:
            sys.exit(f"Host preparation failed (exit {rc}).")
        print("")
        print("=" * 72)
        print(" Interactive installer starting. Answer its prompts here:")
        print("   - service-user password (typed twice)")
        print("   - GitHub username + read:packages token")
        print("   - the four deployment questions")
        print("=" * 72)
        print("")
        interactive_shell(client, INSTALL_CMD.format(env=args.env))
        print("")
        print("=" * 72)
        print(" Installer finished.")
        print(f" Next: open https://workforce.<your-domain> and sign in at")
        print(f" https://auth.<your-domain> (user: admin).")
        print(" Day-2 operations run on the server as workforce_app_sa:")
        print("   cd /opt/workforce-deploy && ./bin/doctor.sh")
        print("=" * 72)
    finally:
        client.close()


if __name__ == "__main__":
    main()
