#!/usr/bin/env python3
"""check-controller-compose.py - the suite as the appliance controller runs it (Workforce ADR-0032 §2).

Run by bin/ci-validate.sh on `docker compose -f compose.yaml -f compose.controller.yaml config --format json`, with
every profile the controller can switch on, and on compose.yaml alone resolved the same way. Paths given to the
Docker API resolve on the host, not in the controller, so this fails on:

- any host path: a bind mount (so the Docker socket), a host device, a config from a file, a volume with driver
  options other than a tmpfs's (the local driver's bind options are a host folder), or volumes_from;
- any file secret (`secrets:`), at the top or in a service;
- a mount of the controller's volume, by whatever key the file gives it (the volume is known by the name Docker
  knows it by), without a plain subpath, or outside the service's own `services/<service>/…` (the api alone also
  gets the ADR-0031 mailbox and the health watch's status/health), or not read-only (only the mailbox's requests are written);
- a volume mount without `nocopy` where compose.yaml has it: Docker's copy-up would hand the volume back to root
  and undo volume-owners.

The controller's allow-list proxy enforces the same at run time; this catches it in review.

    python3 -I bin/check-controller-compose.py controller.json compose.json
"""
import json
import posixpath
import re
import sys

CONTROLLER_KEY = "controller"
MAILBOX = {"mailbox/requests": False, "mailbox/results": True}  # subpath -> must be read-only
# What the health watch last found: the health job's folder, outside services/ (Workforce PR 438), for the api only.
STATUS = {"status/health": True}  # subpath -> must be read-only
TMPFS_OPTION = re.compile(r"^(uid=\d+|gid=\d+|mode=0?[0-7]{3,4}|size=\d+[kmg]?|nr_inodes=\d+[kmg]?)$")


def memory_only(opts):
    """A tmpfs, as the docreader's socket volume is: memory, never a host folder (the proxy allows the same)."""
    if set(opts) - {"type", "device", "o"} or opts.get("type") != "tmpfs" or opts.get("device") != "tmpfs":
        return False
    return all(TMPFS_OPTION.match(p) for p in str(opts.get("o", "")).split(",") if p)


def volume_name(config, key):
    v = (config.get("volumes") or {}).get(key) or {}
    return v.get("name") or f"{config.get('name', '')}_{key}"


def nocopy_mounts(config):
    """(service, volume name, target) for every volume mount that has nocopy."""
    out = set()
    for svc, s in (config.get("services") or {}).items():
        for m in s.get("volumes") or []:
            if m.get("type") == "volume" and m.get("source") and (m.get("volume") or {}).get("nocopy"):
                out.add((svc, volume_name(config, m["source"]), m.get("target")))
    return out


def problems_in(config, base=None):
    out = []
    vols = config.get("volumes") or {}
    declared = vols.get(CONTROLLER_KEY)
    if not declared or not declared.get("external") or not declared.get("name"):
        out.append("the controller's volume is not declared as external, with its name")
        return out
    controller = declared["name"]
    if config.get("secrets"):
        out.append(f"top-level secrets remain: {', '.join(sorted(config['secrets']))}")
    for name, c in (config.get("configs") or {}).items():
        out.append(f"config {name} comes from {'a file' if c.get('file') else 'outside the controller'}")
    for key, v in vols.items():
        if v.get("driver_opts") and not memory_only(v["driver_opts"]):
            out.append(f"volume {key} has driver options other than a tmpfs's")
        if v.get("driver") not in (None, "local"):
            out.append(f"volume {key} uses the {v.get('driver')} driver")
    for svc, s in sorted((config.get("services") or {}).items()):
        if s.get("secrets"):
            out.append(f"{svc}: file secrets remain ({', '.join(x.get('source', '?') for x in s['secrets'])})")
        if s.get("configs"):
            out.append(f"{svc}: configs ({', '.join(x.get('source', '?') for x in s['configs'])})")
        if s.get("devices"):
            out.append(f"{svc}: host devices ({', '.join(str(d.get('source', d)) if isinstance(d, dict) else str(d) for d in s['devices'])})")
        if s.get("volumes_from"):
            out.append(f"{svc}: volumes_from {', '.join(s['volumes_from'])}")
        for m in s.get("volumes") or []:
            kind = m.get("type")
            target = m.get("target")
            if kind == "bind":
                out.append(f"{svc}: host path {m.get('source')} -> {target}")
                continue
            if kind not in ("volume", "tmpfs"):
                out.append(f"{svc}: mount type {kind} -> {target}")
                continue
            sub = (m.get("volume") or {}).get("subpath") or ""
            if kind == "tmpfs" or not m.get("source") or volume_name(config, m["source"]) != controller:
                if sub and (sub.startswith("/") or ".." in sub.split("/")):
                    out.append(f"{svc}: subpath {sub} leaves its volume")
                continue
            parts = sub.split("/")
            if not sub or posixpath.normpath(sub) != sub or any(p in ("", ".", "..") for p in parts):
                out.append(f"{svc}: the controller's volume mounted without a plain subpath -> {target}")
            elif sub in MAILBOX or sub in STATUS:
                if svc != "api":
                    what = "the mailbox" if sub in MAILBOX else "the health watch's status"
                    out.append(f"{svc}: only the api gets {what} ({sub})")
                elif {**MAILBOX, **STATUS}[sub] and not m.get("read_only"):
                    out.append(f"{svc}: {sub} must be read-only")
            elif parts[0] != "services" or len(parts) < 3 or parts[1] != svc:
                out.append(f"{svc}: gets {sub}, which is not its own services/{svc}/ folder")
            elif not m.get("read_only"):
                out.append(f"{svc}: {sub} must be read-only")
    # Workforce issue 453: the sign-in server's one-shot set-up runs authentik's own code against its database, so it
    # must be the very image authentik-server runs (a different version could migrate or misread that database).
    services = config.get("services") or {}
    if "identity-setup" in services:
        if services["identity-setup"].get("image") != (services.get("authentik-server") or {}).get("image"):
            out.append("identity-setup: its image is not authentik-server's")
        if "controller-identity" not in (services["identity-setup"].get("profiles") or []):
            out.append("identity-setup: it must have its own profile, so `up` never starts it")
    if base is not None:
        have = nocopy_mounts(config)
        services = config.get("services") or {}
        for svc, name, target in sorted(nocopy_mounts(base)):
            if svc in services and (svc, name, target) not in have:
                out.append(f"{svc}: {name} -> {target} has lost nocopy (compose.yaml has it)")
    return out


def main(path, base_path=None):
    with open(path, encoding="utf-8") as f:
        config = json.load(f)
    base = None
    if base_path:
        with open(base_path, encoding="utf-8") as f:
            base = json.load(f)
    problems = problems_in(config, base)
    if not config.get("services"):
        problems.append("no services: is this the resolved file?")
    for p in problems:
        print(f"FAIL {p}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:3]))
