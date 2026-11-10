#!/usr/bin/env python3
"""check-hardening.py — images pinned by digest, and each service's least privilege (Workforce ADR-0032 §5, issue 53).

Usage: check-hardening.py <resolved.json>...
  Each file is `docker compose config --format json` for compose.yaml (with one overlay or none, every profile on).
  bin/ci-validate.sh runs it. It also reads, in this repo, the literal image references in bin/ and ansible/ and the
  gateway's Dockerfile, and the three copies of the stock gateway image. Prints a FAIL line for each problem; exit 1.

Every service in compose.yaml has:
  - an image pinned by digest (name:tag@sha256:...), except the suite image, which moves with APP_VERSION;
  - a user, and not root, unless ROOT below says why;
  - a read-only root file system, unless WRITABLE below says why;
  - cap_drop ALL, and no cap_add beyond what CAPS below allows it, each with its reason in compose.yaml;
  - no-new-privileges; never privileged, never the host's network, process or IPC namespace;
  - the docker socket only if it is the backup service.
A change that needs more says so here, where review sees it.
"""

import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, ".."))

# Started as root, and why (compose.yaml says the same beside each).
ROOT = {
    "api": "the image's entrypoint copies the secrets for the app user, then becomes it before java starts",
    "worker": "as api",
    "migrate": "as api",
    "docreader": "setpriv makes the supervisor the app user at once (Workforce ADR-0042)",
    "backup": "it holds the docker socket, which belongs to the container's root",
    "volume-owners": "it gives volumes to their services' users, then ends",
}
# A writable root file system, and why.
WRITABLE = {
    "init": "backups and restores stage the whole evidence bucket in its /tmp, on disk",
    "backup": "it installs its tools with apk at every start",
    "webmail": "the image copies Roundcube into its web root at every start",
}
# The only capabilities a service may add back.
CAPS = {
    "gateway": {"NET_BIND_SERVICE"},
    "mail": {"NET_BIND_SERVICE"},
    "api": {"CHOWN", "DAC_READ_SEARCH", "FOWNER", "SETUID", "SETGID"},
    "worker": {"CHOWN", "DAC_READ_SEARCH", "FOWNER", "SETUID", "SETGID"},
    "migrate": {"CHOWN", "DAC_READ_SEARCH", "FOWNER", "SETUID", "SETGID"},
    "docreader": {"SETUID", "SETGID", "KILL"},
    "volume-owners": {"CHOWN", "DAC_READ_SEARCH"},
    "backup": {"CHOWN", "DAC_OVERRIDE", "FOWNER", "SETGID"},
}
SOCKET_ALLOWED = {"backup"}

# Our own images, which move with each release rather than by a pin here: the suite (APP_VERSION) and the DNS-01
# gateway build (TLS_MODE=dns01). ADR-0032's signed release manifest is what pins their digests.
OWN_MOVING = ("ghcr.io/marlon-thomas/workforce-suite", "ghcr.io/marlon-thomas/workforce-deploy-gateway")

PINNED = re.compile(r"@sha256:[0-9a-f]{64}$")
IMAGE_SHAPE = re.compile(r"^[a-z0-9][a-z0-9._/:@-]*$")
problems = []


def fail(where, why):
    problems.append(f"FAIL {where}: {why}")


def norm_cap(c):
    c = str(c).upper()
    return c[4:] if c.startswith("CAP_") else c


def check_service(label, name, svc, suite_image):
    where = f"{label} service {name}"
    image = svc.get("image") or ""
    if not PINNED.search(image) and image != suite_image:
        fail(where, f"image {image or '(none)'} is not pinned by digest (name:tag@sha256:...)")
    user = str(svc.get("user") or "")
    uid = user.split(":")[0]
    if not user:
        fail(where, "no user: set one, so a change of the image's default can't make it root")
    elif uid in ("0", "root") and name not in ROOT:
        fail(where, f"runs as root ({user}); give it a user of its own, or say why in ROOT")
    if not svc.get("read_only") and name not in WRITABLE:
        fail(where, "root file system not read-only; add sized tmpfs folders, or say why in WRITABLE")
    drop = {norm_cap(c) for c in svc.get("cap_drop") or []}
    if "ALL" not in drop:
        fail(where, "cap_drop is not [ALL]")
    extra = {norm_cap(c) for c in svc.get("cap_add") or []} - CAPS.get(name, set())
    if extra:
        fail(where, f"adds capabilities {sorted(extra)} that CAPS doesn't allow it")
    opts = [str(o).replace("=", ":") for o in svc.get("security_opt") or []]
    if not any(o in ("no-new-privileges", "no-new-privileges:true") for o in opts):
        fail(where, "no no-new-privileges:true in security_opt")
    if svc.get("privileged"):
        fail(where, "privileged")
    for key in ("network_mode", "pid", "ipc"):
        if str(svc.get(key) or "") == "host":
            fail(where, f"{key}: host")
    for vol in svc.get("volumes") or []:
        target = vol.get("target", "") if isinstance(vol, dict) else str(vol)
        if target.endswith("docker.sock") and name not in SOCKET_ALLOWED:
            fail(where, "mounts the docker socket")


def check_resolved(path):
    with open(path, encoding="utf-8") as f:
        services = json.load(f).get("services", {})
    label = os.path.basename(path)
    suite_image = (services.get("api") or {}).get("image")
    for name, svc in sorted(services.items()):
        check_service(label, name, svc, suite_image)


def repo_files():
    for sub in ("bin", "bin/lib"):
        for f in sorted(os.listdir(os.path.join(REPO, sub))):
            if f.endswith((".sh", ".py")) and f not in ("ci-validate.sh", "check-hardening.py"):
                yield os.path.join(sub, f)
    for root, _dirs, files in os.walk(os.path.join(REPO, "ansible")):
        for f in sorted(files):
            if f.endswith((".j2", ".yml", ".yaml")):
                yield os.path.relpath(os.path.join(root, f), REPO)
    yield "gateway/Dockerfile"


LITERALS = [
    re.compile(r"^\s*(?:-\s*)?image:\s*['\"]?([^\s'\"#]+)"),           # YAML, and YAML written by a script
    re.compile(r"\b[A-Z][A-Z0-9_]*IMAGE[A-Z0-9_]*=['\"]?([^\s'\"]+)"),  # shell: SOME_IMAGE="..."
    re.compile(r"gateway_image\s*\|\s*default\('([^']+)'"),            # env.j2
    re.compile(r"^FROM\s+(\S+)"),                                      # Dockerfile
]


def check_literals():
    for rel in repo_files():
        path = os.path.join(REPO, rel)
        if not os.path.isfile(path):
            continue
        with open(path, encoding="utf-8") as f:
            for n, line in enumerate(f, 1):
                for pat in LITERALS:
                    m = pat.search(line)
                    if not m:
                        continue
                    ref = m.group(1)
                    # Not an image name (a sed pattern, a variable), one of ours, or a placeholder on the .invalid
                    # domain that nothing pulls (RFC 2606).
                    if (not IMAGE_SHAPE.match(ref) or ref.startswith(OWN_MOVING)
                            or ref.split("/", 1)[0].endswith(".invalid")):
                        continue
                    if not PINNED.search(ref):
                        fail(f"{rel}:{n}", f"image {ref} is not pinned by digest")


def check_stock_gateway():
    def grab(rel, pat):
        with open(os.path.join(REPO, rel), encoding="utf-8") as f:
            m = re.search(pat, f.read())
        return m.group(1) if m else None
    copies = {
        "compose.yaml": grab("compose.yaml", r"\$\{GATEWAY_IMAGE:-([^}]+)\}"),
        "bin/lib/common.sh": grab("bin/lib/common.sh", r'GATEWAY_STOCK_IMAGE="([^"]+)"'),
        "ansible/roles/workforce/templates/env.j2": grab("ansible/roles/workforce/templates/env.j2",
                                                         r"gateway_image\s*\|\s*default\('([^']+)'"),
    }
    if None in copies.values() or len(set(copies.values())) != 1:
        fail("stock gateway image", "compose.yaml, bin/lib/common.sh and env.j2 must name the same pinned image: "
             + ", ".join(f"{k}={v}" for k, v in copies.items()))


def main(argv):
    if not argv:
        sys.exit(__doc__)
    for path in argv:
        check_resolved(path)
    check_literals()
    check_stock_gateway()
    for p in problems:
        print(p)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
