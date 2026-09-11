#!/usr/bin/env python3
"""
setup-host.py — ONE-TIME, idempotent privileged setup for a workforce
development host. Run with sudo explicitly:

    sudo python3 setup-host.py

Everything here needs root, so it lives here — deploy_to_test.py itself
NEVER uses sudo and can be run repeatedly, unprivileged and idempotent.

Safe to re-run: every step checks first and skips work already done.

What it ensures (Linux; Fedora and Debian/Ubuntu paths):
  1. libxcrypt-compat (Fedora — Vagrant's embedded Ruby needs it)
  2. libvirtd enabled + running
  3. libvirt 'default' NAT network active
  4. firewalld forwards virbr0 (guest internet)
  5. docker↔libvirt coexistence (DOCKER-USER accepts via a systemd drop-in
     re-applied on every docker start)
  6. the invoking user in the libvirt and docker groups

On Windows/macOS nothing here applies — the script prints what to install
manually (VirtualBox/Hyper-V) and exits.
"""

import grp
import os
import pwd
import shutil
import subprocess
import sys

FEDORA = False
DEBIAN = False
try:
    with open("/etc/os-release") as f:
        rel = f.read().lower()
    FEDORA = "fedora" in rel
    DEBIAN = ("debian" in rel) or ("ubuntu" in rel)
except OSError:
    pass

DONE = []
SKIPPED = []


def sh(cmd, check=False):
    return subprocess.run(cmd, check=check, capture_output=True, text=True)


def done(msg):
    DONE.append(msg)
    print(f"  [DONE]   {msg}")


def skipped(msg):
    SKIPPED.append(msg)
    print(f"  [SKIP]   {msg}")


def note(msg):
    print(f"  [..]     {msg}")


def apt(pkg):
    return sh(["apt-get", "install", "-y", "-q", pkg])


def dnf(pkg):
    return sh(["dnf", "install", "-y", "-q", pkg])


def in_group(user, group):
    try:
        return group in [g.gr_name for g in grp.getgrall()
                         if user in g.gr_mem] or \
            group == grp.getgrgid(pwd.getpwnam(user).pw_gid).gr_name
    except KeyError:
        return False


def ensure_libxcrypt():
    if not FEDORA:
        return
    if sh(["rpm", "-q", "libxcrypt-compat"]).returncode == 0:
        skipped("libxcrypt-compat already installed")
        return
    note("installing libxcrypt-compat…")
    dnf("libxcrypt-compat")
    done("libxcrypt-compat installed (Fedora)")


def ensure_libvirtd():
    if not shutil.which("virsh"):
        note("installing libvirt…")
        if FEDORA:
            sh(["dnf", "group", "install", "-y", "virtualization"])
        elif DEBIAN:
            for p in ("qemu-kvm", "libvirt-daemon-system",
                      "libvirt-clients", "dnsmasq"):
                apt(p)
        else:
            return
        done("libvirt installed")
    if sh(["systemctl", "is-active", "--quiet", "libvirtd"]).returncode != 0:
        sh(["systemctl", "enable", "--now", "libvirtd"])
        done("libvirtd enabled + started")
    else:
        skipped("libvirtd already running")


def ensure_default_net():
    ni = sh(["virsh", "-c", "qemu:///system", "net-info", "default"])
    active = any(ln.strip().startswith("Active:")
                 and ln.split(":", 1)[1].strip().lower() == "yes"
                 for ln in (ni.stdout or "").splitlines())
    if active:
        skipped("libvirt default network already active")
        return
    sh(["virsh", "-c", "qemu:///system", "net-start", "default"])
    done("libvirt default network started")


def ensure_firewalld_forwarding():
    if not shutil.which("firewall-cmd"):
        skipped("firewalld not present")
        return
    az = sh(["firewall-cmd", "--get-active-zones"]).stdout or ""
    if "virbr0" in az:
        skipped("firewalld already forwards virbr0")
        return
    sh(["firewall-cmd", "--zone=libvirt", "--add-interface=virbr0"])
    sh(["firewall-cmd", "--zone=libvirt", "--add-forward"])
    done("firewalld forwards virbr0")


def ensure_docker_libvirt_fix():
    if not (shutil.which("docker") and shutil.which("virsh")):
        skipped("docker↔libvirt coexistence not needed (no docker)")
        return
    dropin = "/etc/systemd/system/docker.service.d/workforce-libvirt-forward.conf"
    helper = "/usr/local/lib/workforce-libvirt-forward.sh"
    helper_body = """#!/bin/bash
set -u
command -v iptables >/dev/null 2>&1 || exit 0
iptables -L DOCKER-USER >/dev/null 2>&1 || exit 0
for bridge in /sys/class/net/virbr*; do
    [ -e "$bridge" ] || continue
    b="$(basename "$bridge")"
    for dir in "-i" "-o"; do
        if ! iptables -C DOCKER-USER $dir "$b" -j ACCEPT 2>/dev/null; then
            iptables -I DOCKER-USER 1 $dir "$b" -j ACCEPT
        fi
    done
done
"""
    dropin_body = ("[Service]\n"
                   "ExecStartPost=/usr/local/lib/"
                   "workforce-libvirt-forward.sh\n")
    if os.path.exists(dropin) and os.path.exists(helper):
        skipped("docker↔libvirt forwarding fix already installed")
    else:
        os.makedirs("/usr/local/lib", exist_ok=True)
        with open(helper, "w") as f:
            f.write(helper_body)
        os.chmod(helper, 0o755)
        os.makedirs(os.path.dirname(dropin), exist_ok=True)
        with open(dropin, "w") as f:
            f.write(dropin_body)
        sh(["systemctl", "daemon-reload"])
        done("docker↔libvirt forwarding fix installed (persistent)")
    # apply the rules right now, not just on next docker restart
    r = sh([helper])
    if r.returncode == 0:
        skipped("DOCKER-USER accepts present")
    else:
        done("DOCKER-USER accepts applied")


def ensure_groups():
    user = os.environ.get("SUDO_USER")
    if not user or user == "root":
        skipped("group membership: invoked without SUDO_USER — add your "
                "user to 'libvirt' and 'docker' groups manually")
        return
    for group in ("libvirt", "docker"):
        if in_group(user, group):
            skipped(f"{user} already in '{group}'")
            continue
        if shutil.which("docker") or group == "libvirt":
            sh(["usermod", "-aG", group, user])
            done(f"{user} added to '{group}' (re-login to take effect)")


def main():
    if os.geteuid() != 0:
        sys.exit("Run me with sudo:  sudo python3 setup-host.py")
    if not (FEDORA or DEBIAN):
        print("Non-Linux host: install VirtualBox (or enable Hyper-V) and "
              "Vagrant manually, then run deploy_to_test.py — it needs no "
              "sudo.")
        return
    print("═══════════════════════════════════════════════════════")
    print("  Workforce dev host setup (privileged, idempotent)")
    print("═══════════════════════════════════════════════════════")
    ensure_libxcrypt()
    ensure_libvirtd()
    ensure_default_net()
    ensure_firewalld_forwarding()
    ensure_docker_libvirt_fix()
    ensure_groups()
    print(f"\n  {len(DONE)} changed, {len(SKIPPED)} already correct. "
          "deploy_to_test.py now runs fully without sudo.")


if __name__ == "__main__":
    main()
