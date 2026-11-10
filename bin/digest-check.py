#!/usr/bin/env python3
"""digest-check.py — is every image this repo pins by digest still there, and still those bytes? (ADR-0015)

Run daily by .github/workflows/digest-check.yml, and by hand (it needs the network, nothing else):
  python3 -I bin/digest-check.py

For every name[:tag]@sha256:<digest> in compose.yaml, compose.dev.yaml, the scripts in bin/, the Ansible templates and
gateway/Dockerfile (a pin's tag may also sit in a "# tag: X" comment on its line):

  FAIL  the registry no longer serves that digest, or serves other bytes for it: a fresh install would fail to pull
        it (the incident ADR-0015 records), or the pin was mistyped.
  FAIL  one of our own images (ghcr.io/marlon-thomas/...) whose tag now names other bytes: rebuilt by
        build-thirdparty.yml without the pin moving with it, or someone else pushed.
  MOVED a third-party tag that now names a newer build. Not a failure: appliances keep the bytes they were tested
        with. A newer build may carry security fixes, so look, then repin deliberately in a reviewed change.
        Expected daily for clamav/clamav, whose builds carry that day's signatures.
"""

import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, ".."))
OWN = "ghcr.io/marlon-thomas/"
ACCEPT = ", ".join([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
])
REF = re.compile(r"((?:[a-z0-9][a-z0-9.-]*(?::[0-9]+)?/)?[a-z0-9][a-z0-9._/-]*)(?::(\w[\w.-]*))?@sha256:([0-9a-f]{64})")
TAG_COMMENT = re.compile(r"#\s*tag:\s*([\w][\w.:-]*)")


def files():
    for rel in ("compose.yaml", "compose.dev.yaml", "compose.smoke.yaml", "gateway/Dockerfile"):
        yield rel
    for sub in ("bin", "bin/lib"):
        for f in sorted(os.listdir(os.path.join(REPO, sub))):
            if f.endswith((".sh", ".py")) and f != "digest-check.py":
                yield os.path.join(sub, f)
    for root, _dirs, names in os.walk(os.path.join(REPO, "ansible")):
        for f in sorted(names):
            if f.endswith((".j2", ".yml", ".yaml")):
                yield os.path.relpath(os.path.join(root, f), REPO)


def pins():
    found = {}
    for rel in files():
        path = os.path.join(REPO, rel)
        if not os.path.isfile(path):
            continue
        with open(path, encoding="utf-8") as f:
            for n, line in enumerate(f, 1):
                for m in REF.finditer(line):
                    name, tag, digest = m.groups()
                    if not tag:
                        c = TAG_COMMENT.search(line)
                        tag = c.group(1) if c else None
                    found.setdefault((name, tag, digest), []).append(f"{rel}:{n}")
    return found


def split(name):
    first = name.split("/", 1)[0]
    if "/" in name and ("." in first or ":" in first or first == "localhost"):
        registry, repo = first, name.split("/", 1)[1]
    else:
        registry, repo = "docker.io", name
    if registry == "docker.io":
        if "/" not in repo:
            repo = "library/" + repo
        return "registry-1.docker.io", repo, (
            f"https://auth.docker.io/token?service=registry.docker.io&scope=repository:{repo}:pull")
    if registry == "ghcr.io":
        return "ghcr.io", repo, f"https://ghcr.io/token?scope=repository:{repo}:pull"
    return registry, repo, None


def token(url):
    if not url:
        return None
    with urllib.request.urlopen(url, timeout=30) as r:
        body = json.load(r)
    return body.get("token") or body.get("access_token")


def fetch(host, repo, ref, bearer, method):
    headers = {"Accept": ACCEPT}
    if bearer:
        headers["Authorization"] = f"Bearer {bearer}"
    req = urllib.request.Request(f"https://{host}/v2/{repo}/manifests/{ref}", headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read(), r.headers.get("Docker-Content-Digest", "")


def main():
    found = pins()
    if not found:
        sys.exit("XX no image pinned by digest found: has the pins' shape changed? Update bin/digest-check.py.")
    failed, moved, rows = [], [], []
    for (name, tag, digest), where in sorted(found.items()):
        label = f"{name}:{tag or '(no tag)'}"
        host, repo, token_url = split(name)
        try:
            bearer = token(token_url)
            body, _ = fetch(host, repo, f"sha256:{digest}", bearer, "GET")
        except (urllib.error.URLError, OSError, ValueError) as e:
            failed.append(f"{label}: sha256:{digest[:16]}… can't be fetched ({e}) — pinned at {', '.join(where)}")
            rows.append((label, digest, "NOT SERVED"))
            continue
        if hashlib.sha256(body).hexdigest() != digest:
            failed.append(f"{label}: the registry serves other bytes for sha256:{digest[:16]}… — pinned at {where[0]}")
            rows.append((label, digest, "OTHER BYTES"))
            continue
        status = "OK"
        if tag:
            try:
                _, now = fetch(host, repo, tag, bearer, "HEAD")
            except (urllib.error.URLError, OSError) as e:
                moved.append(f"{label}: the tag isn't served any more ({e}); the pinned bytes still are")
                now = ""
                status = "NO TAG"
            if now and now != f"sha256:{digest}":
                if name.startswith(OWN):
                    failed.append(f"{label} now names {now[:23]}…, compose pins sha256:{digest[:16]}…: "
                                  "repin deliberately, or stop and find out who pushed")
                    status = "DRIFT"
                else:
                    moved.append(f"{label}: a newer build is out ({now[:23]}…); the pin keeps sha256:{digest[:16]}…")
                    status = "MOVED"
        rows.append((label, digest, status))
        print(f"{status:5} {label} sha256:{digest[:16]}…")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as f:
            f.write("## Image pins\n\n| image | pinned | registry |\n|---|---|---|\n")
            for label, digest, status in rows:
                f.write(f"| `{label}` | `sha256:{digest[:12]}…` | {status} |\n")
    for m in moved:
        print(f"::warning::{m}" if summary else f"MOVED {m}")
    for m in failed:
        print(f"::error::{m}" if summary else f"FAIL  {m}")
    if failed:
        sys.exit(f"XX {len(failed)} pin(s) failed — see above.")
    print(f"All {len(rows)} pins are served as pinned ({len(moved)} with a newer build out).")


if __name__ == "__main__":
    main()
