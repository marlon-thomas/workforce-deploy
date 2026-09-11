#!/bin/bash
# workforce-libvirt-forward.sh — let libvirt guest traffic through docker's
# FORWARD chain. Docker sets the FORWARD policy to DROP and whitelists only
# its own bridges, which silently swallows libvirt VM traffic (guests reach
# the host but not the internet). DOCKER-USER is docker's designated hook
# for user rules: anything accepted there passes before docker's rules.
#
# Idempotent and dynamic: covers every virbr* bridge present, skips rules
# that already exist, and is safe to re-run (it is re-run automatically on
# every docker start via the systemd drop-in that installed it).
#
# Installed by deploy_to_test.py (STEP 0) on hosts that run docker + libvirt.
set -u
command -v iptables >/dev/null 2>&1 || exit 0
iptables -L DOCKER-USER >/dev/null 2>&1 || exit 0   # docker not running yet

for bridge in /sys/class/net/virbr*; do
    [ -e "$bridge" ] || continue                    # no virbr* bridges
    b="$(basename "$bridge")"
    for dir in "-i" "-o"; do
        if ! iptables -C DOCKER-USER $dir "$b" -j ACCEPT 2>/dev/null; then
            iptables -I DOCKER-USER 1 $dir "$b" -j ACCEPT
        fi
    done
done
