#!/usr/bin/env python3
"""check-docreader.py - the docreader and api settings Workforce ADR-0042 depends on, checked in the resolved compose file.

Run by bin/ci-validate.sh on `docker compose config --format json`. A change that quietly gives the docreader a network,
a secret, a volume, a capability or a writable file system fails here, as does an api /tmp with no size or no init
(Workforce issues 330 and 333).

    python3 -I bin/check-docreader.py compose.json
"""
import json
import sys


def main(path):
    with open(path, encoding="utf-8") as f:
        config = json.load(f)
    services = config.get("services", {})
    problems = []

    def need(ok, what):
        if not ok:
            problems.append(what)

    d = services.get("docreader")
    api = services.get("api")
    need(d is not None, "there is no docreader service")
    need(api is not None, "there is no api service")
    if d is None or api is None:
        return report(problems)

    # The docreader: no network, nothing to read, nothing to keep, and as little power as it needs.
    need(d.get("network_mode") == "none", "docreader: network_mode must be none")
    need(not d.get("networks"), "docreader: must join no network")
    need(not d.get("ports") and not d.get("expose"), "docreader: must publish no port")
    need(d.get("read_only") is True, "docreader: read_only must be true")
    need("ALL" in (d.get("cap_drop") or []), "docreader: cap_drop must be ALL")
    need(set(d.get("cap_add") or []) <= {"SETUID", "SETGID", "KILL"},
         "docreader: cap_add may hold only SETUID, SETGID and KILL (to run each job as its own user, and stop it)")
    need("no-new-privileges:true" in (d.get("security_opt") or []), "docreader: security_opt must hold no-new-privileges:true")
    need(not d.get("secrets"), "docreader: must have no secrets")
    need(not d.get("env_file"), "docreader: must have no env_file")
    need(set((d.get("environment") or {}).keys()) <= {"TZ"}, "docreader: environment may hold only TZ")
    vols = d.get("volumes") or []
    need(len(vols) == 1 and vols[0].get("source") == "pdf_socket" and vols[0].get("target") == "/run/pdf",
         "docreader: its only volume must be pdf_socket at /run/pdf")
    need(d.get("init") is True, "docreader: init must be true")
    limits = ((d.get("deploy") or {}).get("resources") or {}).get("limits") or {}
    need(int(d.get("pids_limit") or limits.get("pids") or 0) > 0, "docreader: a process limit (pids) must be set")
    need(bool(limits.get("memory")), "docreader: a memory limit must be set")
    need(bool(limits.get("cpus")), "docreader: a cpus limit must be set")
    need(any(str(t).startswith("/tmp:") and "size=" in str(t) for t in (d.get("tmpfs") or [])),
         "docreader: /tmp must be a tmpfs with a size")
    need(d.get("image") == api.get("image"), "docreader: must run the api's own image (nothing new to sign or pin)")
    entry = d.get("entrypoint") or []
    need("com.careangelssupport.workforce.shared.pdf.worker.Supervisor" in entry, "docreader: must start the Supervisor")

    # The socket's folder: in memory, the app user's alone.
    opts = ((config.get("volumes") or {}).get("pdf_socket") or {}).get("driver_opts") or {}
    need(opts.get("type") == "tmpfs" and "mode=0700" in opts.get("o", "") and "uid=999" in opts.get("o", ""),
         "pdf_socket: must be a tmpfs volume owned by uid 999 with mode 0700")

    # The api: reaches the docreader through that folder; /tmp has a size; init reaps children.
    api_vols = api.get("volumes") or []
    need(any(v.get("source") == "pdf_socket" and v.get("target") == "/run/pdf" for v in api_vols),
         "api: must mount pdf_socket at /run/pdf")
    need(str((api.get("environment") or {}).get("WORKFORCE_DOCREADER_SOCKET", "")).startswith("/run/pdf/"),
         "api: WORKFORCE_DOCREADER_SOCKET must name the socket in /run/pdf")
    need(any(str(t).startswith("/tmp:") and "size=" in str(t) for t in (api.get("tmpfs") or [])),
         "api: /tmp must be a tmpfs with a size (issue 333)")
    need(api.get("init") is True, "api: init must be true (issue 333)")

    # Nothing else shares the socket.
    for name, s in services.items():
        if name in ("api", "docreader"):
            continue
        need(not any((v.get("source") == "pdf_socket") for v in (s.get("volumes") or [])),
             name + ": must not mount pdf_socket")
    return report(problems)


def report(problems):
    for p in problems:
        print("FAIL " + p)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
