#!/usr/bin/env python3
"""
bootstrap.py — one-command remote deployment for the Workforce.

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
    python3 bootstrap.py --host 10.230.4.55 --keyfile ~/.ssh/id_ed25519
                                                       # key auth (root password
                                                       # locked, e.g. fresh Incus guest)
    python3 bootstrap.py --host 203.0.113.7 --host-key-fingerprint SHA256:abc…
                                                       # verify the server's host key
                                                       # (from the provider console:
                                                       # ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub)

Host keys are never trusted blindly: with --host-key-fingerprint the presented
key must match; without it, accept-new semantics (first contact is recorded in
~/.ssh/known_hosts, a CHANGED key is refused). known_hosts is never scrubbed.

Root password is prompted with getpass when not supplied (never on the command
line — it would leak into `ps` on your machine).  When --keyfile is given,
key auth is used instead and no password is asked for.

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

import shlex

from deploylib import REF_RE, bundle_update, explain_bad_host_key, verified_ssh_client

BUNDLE_REPO = "https://github.com/marlon-thomas/workforce-deploy.git"
INSTALL_CMD = "cd /opt/workforce-deploy && ./bin/install.sh --env {env}"

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
echo "==> Fetching the deployment bundle straight to its final home…"
if [ -d /opt/workforce-deploy/.git ]; then
# Pull as the checkout's OWNER (the installer chowns the bundle to the service
# user; git refuses cross-owner pulls, and a root pull would litter root-owned
# files through the service user's working tree).
OWNER=$(stat -c '%U' /opt/workforce-deploy/.git)
if [ "$OWNER" = root ]; then
  sh -c "cd /opt/workforce-deploy && "{pull}
else
  sudo -u "$OWNER" sh -c "cd /opt/workforce-deploy && "{pull}
fi
else
  rm -rf /root/workforce-deploy
  git clone -q {branch}{repo} /opt/workforce-deploy
fi
echo "==> Bundle ready. Handing over to the installer (answer its prompts below)."
"""


def read_env_file(env_name):
    """Parse deploy/environments/<env>.env (KEY=VALUE lines). The env FILE is
    the single source of truth for what out-of-band material a deployment
    needs — bootstrap.py itself never branches on test-vs-prod."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "..", "environments", env_name + ".env")
    kv = {}
    if os.path.isfile(path):
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    kv[k.strip()] = v.strip()
    return kv


def ship_env_files(client, env_name, remote_home):
    """Copy host-side secret material into the target VM per the env file's
    declarations (sftp cannot reach /opt before the service user exists, and
    these files must never enter the PUBLIC git bundle):
      TLS_MODE=dns01  -> DuckDNS token file (installer also prompts as fallback)
      TLS_MODE=certs  -> private-CA leaf (tls.crt/tls.key/ca.crt) into
                         <home>/tls-upload/, which install.sh's root phase
                         moves into secrets/tls (prod declares neither → no-op).
    """
    kv = read_env_file(env_name)
    sftp = client.open_sftp()
    try:
        if kv.get("TLS_MODE", "http01") == "dns01":
            tok = os.path.expanduser("~/.config/workforce-dev/duckdns.env")
            if os.path.isfile(tok):
                sftp.put(tok, f"{remote_home}/duckdns.env")
                # 644: the DNS-01 branch reads it as the SERVICE user
                # (workforce_app_sa), not root — 0600 is unreadable
                # to it and the installer falls back to prompting.
                run_quiet(client, f"chmod 644 {remote_home}/duckdns.env")
                print("DuckDNS token file copied into the VM.")
        if kv.get("TLS_MODE") == "certs":
            ca_dir = os.path.expanduser(
                kv.get("TLS_CA_DIR", "~/.config/workforce-dev/testca"))
            names = ("tls.crt", "tls.key", "ca.crt")
            have = [n for n in names if os.path.isfile(os.path.join(ca_dir, n))]
            if have == list(names):
                run_quiet(client, f"mkdir -p {remote_home}/tls-upload")
                for n in names:
                    sftp.put(os.path.join(ca_dir, n), f"{remote_home}/tls-upload/{n}")
                print("Test-CA leaf shipped to tls-upload/ "
                      "(installer moves it into secrets/tls).")
            else:
                print(f"WARN: TLS_MODE=certs but no leaf in {ca_dir} — run "
                      f"'./bin/gen-test-ca.sh {env_name}' on the workstation; "
                      "the installer will fail with the same guidance.")
    finally:
        sftp.close()


def connect(host, port, user, password, keyfile=None, fingerprint=None,
            known_hosts=None):
    client = verified_ssh_client(fingerprint=fingerprint, known_hosts=known_hosts)
    print(f"Connecting to {user}@{host}:{port} …")
    try:
        client.connect(host, port=port, username=user, password=password,
                       key_filename=keyfile,
                       look_for_keys=False, allow_agent=False, timeout=20)
    except paramiko.BadHostKeyException as exc:
        explain_bad_host_key(exc, host, port)
    except paramiko.SSHException as exc:
        sys.exit(f"XX {exc}")
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

    # Raw-mode keyboard forwarding needs a real local TTY. Without one
    # (CI, agents, nohup) fall back to a pure output pump: the remote PTY
    # still renders the installer live, but nothing can be typed — a run
    # that needs prompt answers must happen from a real terminal. A
    # resumed install (.env present) never prompts and works here.
    interactive = sys.stdin.isatty()
    old_attrs = None
    if interactive:
        import tty
        import termios
        try:
            old_attrs = termios.tcgetattr(sys.stdin)
            tty.setraw(sys.stdin.fileno())
        except Exception:
            interactive, old_attrs = False, None
    if not interactive:
        print("(no local TTY: forwarding installer output only — if it "
              "prompts for input it will block; resumed installs do not)")
    try:
        while True:
            r, _, _ = select.select([chan] + ([sys.stdin] if interactive else []),
                                    [], [], 0.05)
            if chan in r:
                try:
                    data = chan.recv(4096)
                except Exception:
                    break
                if not data:
                    break
                sys.stdout.write(data.decode(errors="replace"))
                sys.stdout.flush()
            if interactive and sys.stdin in r:
                data = sys.stdin.read(1)
                if not data:
                    break
                chan.send(data)
            if chan.exit_status_ready() and not chan.recv_ready():
                break
    except KeyboardInterrupt:
        print("\n(bootstrap interrupted — the remote installer may still be running)")
    finally:
        if old_attrs is not None:
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
    ap.add_argument("--host", required=True, help="server IP or hostname "
                    "(the TEST appliance: deploy_to_test.py passes the Incus "
                    "guest's eth0 address)")
    ap.add_argument("--port", type=int, default=22)
    ap.add_argument("--user", default="root")
    ap.add_argument("--password", help="root password (prompted if omitted, "
                    "skipped entirely when --keyfile is given)")
    ap.add_argument("--keyfile", help="private key for SSH auth instead of a "
                    "password (e.g. the Incus test guest, whose root account has "
                    "no password)")
    ap.add_argument("--host-key-fingerprint", metavar="SHA256:…",
                    help="expected server host-key fingerprint (as printed by "
                         "'ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub' on the "
                         "server's console); verified before any credential is sent. "
                         "Without it: accept-new (first contact recorded in "
                         "~/.ssh/known_hosts, a changed key refused)")
    ap.add_argument("--env", default="prod", choices=["test", "prod"],
                    help="deployment environment (test = Ubuntu appliance, prod = live VPS)")
    ap.add_argument("--repo", default=BUNDLE_REPO,
                    help="deployment bundle repo to clone inside the target "
                         "(default: the public bundle; deploy_to_test passes "
                         "the origin of the bundle it runs from)")
    ap.add_argument("--ref", metavar="TAG",
                    help="deployment bundle release tag to install from (deploy_to_prod "
                         "passes environments/prod.env DEPLOY_REF); default: main")
    ap.add_argument("--smoke", action="store_true",
                    help="no-TLS smoke install (OIDC-less, HTTP)")
    args = ap.parse_args()

    if args.keyfile:
        # '~' and relative paths are a human convenience; paramiko wants absolute.
        args.keyfile = os.path.abspath(os.path.expanduser(args.keyfile))
        if not os.path.isfile(args.keyfile):
            sys.exit(f"error: key file not found: {args.keyfile}")

    if args.keyfile:
        # Key auth (--keyfile): no password needed or wanted.
        password = args.password
    else:
        password = args.password
        while not password:
            # mandatory: empty input = accidental Enter — retry, not quit
            password = getpass.getpass(
                f"Password for {args.user}@{args.host} "
                "(Enter to retry, Ctrl+C to exit): ")

    client = connect(args.host, args.port, args.user, password,
                     keyfile=getattr(args, "keyfile", None),
                     fingerprint=args.host_key_fingerprint,
                     known_hosts=None)
    try:
        prep_cmd = PREP
        install_cmd = INSTALL_CMD.format(env=args.env)
        # repo chosen via --repo (or the public bundle default), formatted
        # into the prep templates at use-site
        if args.ref and not REF_RE.fullmatch(args.ref):
            sys.exit(f"error: --ref {args.ref!r} is not a plain tag name")
        branch = f"--branch {args.ref} " if args.ref else ""
        rc = run_quiet(client, prep_cmd.format(repo=args.repo, branch=branch,
                                               pull=shlex.quote(bundle_update(args.ref))))
        if rc != 0:
            sys.exit(f"Host preparation failed (exit {rc}).")
        ship_env_files(client, args.env, "/root")
        print("")
        print("=" * 72)
        print(" Interactive installer starting. Answer its prompts here:")
        print("   - service-user password (typed twice)")
        print("   - GitHub username + read:packages token")
        print("   - the four deployment questions")
        print("=" * 72)
        print("")
        interactive_shell(client, install_cmd + (" --smoke" if args.smoke else ""))
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
