#!/usr/bin/env python3
"""check-controller-compose.py - the suite as the appliance controller runs it (Workforce ADR-0032 §2).

Run by bin/ci-validate.sh on `docker compose -f compose.yaml -f compose.controller.yaml config --format json`, with
every profile on. Paths given to the Docker API resolve on the host, not in the controller, so this fails on:

- any host path (a bind mount, `./…` or absolute), and so the Docker socket;
- any file secret (`secrets:`), at the top or in a service;
- a mount of the controller's volume without a subpath, or one outside the service's own `services/<service>/…`
  (the api alone also gets the ADR-0031 mailbox), or one that isn't read-only (only the mailbox's requests are);
- a volume with driver options (the local driver's bind options are a host folder);
- a service that is still started and holds the socket (the backup container's jobs moved into the controller).

The controller's allow-list proxy enforces the same at run time; this catches it in review.

    python3 -I bin/check-controller-compose.py controller.json
"""
import json
import re
import posixpath
import sys

CONTROLLER_VOLUME = "controller"
MAILBOX = {"mailbox/requests": False, "mailbox/results": True}  # subpath -> must be read-only


TMPFS_OPTION = re.compile(r"^(uid=\d+|gid=\d+|mode=0?[0-7]{3,4}|size=\d+[kmg]?|nr_inodes=\d+[kmg]?)$")


def memory_only(opts):
    """A tmpfs, as the docreader's socket volume is: memory, never a host folder (the proxy allows the same)."""
    if set(opts) - {"type", "device", "o"} or opts.get("type") != "tmpfs" or opts.get("device") != "tmpfs":
        return False
    return all(TMPFS_OPTION.match(p) for p in str(opts.get("o", "")).split(",") if p)


def problems_in(config):
    out = []
    if config.get("secrets"):
        out.append(f"top-level secrets remain: {', '.join(sorted(config['secrets']))}")
    vols = config.get("volumes", {})
    ctl = vols.get(CONTROLLER_VOLUME)
    if not ctl or not ctl.get("external"):
        out.append("the controller's volume is not declared as external")
    for name, v in vols.items():
        if v.get("driver_opts") and not memory_only(v["driver_opts"]):
            out.append(f"volume {name} has driver options other than a tmpfs's")
        if v.get("driver") not in (None, "local"):
            out.append(f"volume {name} uses the {v.get('driver')} driver")
    for svc, s in sorted(config.get("services", {}).items()):
        if s.get("secrets"):
            out.append(f"{svc}: file secrets remain ({', '.join(x.get('source', '?') for x in s['secrets'])})")
        for m in s.get("volumes") or []:
            kind = m.get("type")
            target = m.get("target")
            if kind == "bind":
                out.append(f"{svc}: host path {m.get('source')} -> {target}")
                continue
            if kind not in ("volume", "tmpfs"):
                out.append(f"{svc}: mount type {kind} -> {target}")
                continue
            if kind == "tmpfs" or m.get("source") != CONTROLLER_VOLUME:
                sub = (m.get("volume") or {}).get("subpath")
                if sub and (sub.startswith("/") or ".." in sub.split("/")):
                    out.append(f"{svc}: subpath {sub} leaves its volume")
                continue
            sub = (m.get("volume") or {}).get("subpath") or ""
            parts = sub.split("/")
            if not sub or posixpath.normpath(sub) != sub or any(p in ("", ".", "..") for p in parts):
                out.append(f"{svc}: the controller's volume mounted without a plain subpath -> {target}")
            elif sub in MAILBOX:
                if svc != "api":
                    out.append(f"{svc}: only the api gets the mailbox ({sub})")
                elif MAILBOX[sub] and not m.get("read_only"):
                    out.append(f"{svc}: {sub} must be read-only")
            elif parts[0] != "services" or len(parts) < 3 or parts[1] != svc:
                out.append(f"{svc}: gets {sub}, which is not its own services/{svc}/ folder")
            elif not m.get("read_only"):
                out.append(f"{svc}: {sub} must be read-only")
    return out


def main(path):
    with open(path, encoding="utf-8") as f:
        config = json.load(f)
    problems = problems_in(config)
    if not config.get("services"):
        problems.append("no services: is this the resolved file?")
    for p in problems:
        print(f"FAIL {p}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
