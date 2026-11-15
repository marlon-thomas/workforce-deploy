#!/usr/bin/env bash
# Self-test for bin/check-controller-compose.py (Workforce ADR-0032 §2): each way a Compose file could reach the
# host, or give a service the wrong folder of the controller's volume, must fail it; the shape the controller
# uses must pass. Hermetic: resolved files written here, as `docker compose config --format json` gives them.
#   ./bin/tests/controller-compose-test.sh      exit 0 = all pass
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
exec python3 -I - "$HERE/../check-controller-compose.py" <<'PY'
import copy
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("check", sys.argv[1])
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)

own = lambda target, sub, ro=True: {"type": "volume", "source": "controller", "target": target, "read_only": ro, "volume": {"subpath": sub}}
GOOD = {
    "name": "workforce-deploy",
    "services": {
        "api": {"volumes": [
            {"type": "volume", "source": "app_data", "target": "/app/data"},
            own("/run/secrets", "services/api/secrets"),
            own("/run/workforce-actions/requests", "mailbox/requests", ro=False),
            own("/run/workforce-actions/results", "mailbox/results"),
            own("/run/workforce-status", "status/health"),
        ]},
        "postgres": {"volumes": [{"type": "volume", "source": "pg_data", "target": "/var/lib/postgresql/data"}, own("/run/secrets", "services/postgres/secrets")]},
        "gateway": {"volumes": [{"type": "volume", "source": "caddy_data", "target": "/data", "volume": {"nocopy": True}}]},
    },
    "volumes": {
        "controller": {"name": "workforce-controller", "external": True},
        "app_data": {"name": "workforce-deploy_app_data"},
        "pg_data": {"name": "workforce-deploy_pg_data"},
        "caddy_data": {"name": "workforce-deploy_caddy_data"},
        "pdf_socket": {"name": "workforce-deploy_pdf_socket", "driver": "local", "driver_opts": {"type": "tmpfs", "device": "tmpfs", "o": "uid=999,gid=999,mode=0700,size=1m"}},
    },
}
BASE = {"name": "workforce-deploy", "services": {"gateway": GOOD["services"]["gateway"]}, "volumes": {"caddy_data": {"name": "workforce-deploy_caddy_data"}}}

passed = failed = 0


def expect(label, mutate, want):
    global passed, failed
    c = copy.deepcopy(GOOD)
    mutate(c)
    found = check.problems_in(c, BASE)
    if want is None:
        ok = not found
    else:
        ok = any(want in p for p in found)
    if ok:
        passed += 1
    else:
        failed += 1
        print(f"FAIL: {label}: expected {'nothing' if want is None else repr(want)}, got {found}")


def alias(c):
    c["volumes"]["ctl2"] = {"name": "workforce-controller", "external": True}
    c["services"]["api"]["volumes"].append({"type": "volume", "source": "ctl2", "target": "/x"})


def alias_sub(c):
    c["volumes"]["ctl2"] = {"name": "workforce-controller", "external": True}
    c["services"]["postgres"]["volumes"].append({"type": "volume", "source": "ctl2", "target": "/x", "read_only": True, "volume": {"subpath": "private"}})


expect("the shape the controller uses", lambda c: None, None)
expect("the controller's volume under another key, whole and writable", alias, "the controller's volume mounted without a plain subpath")
expect("the controller's volume under another key, at another folder", alias_sub, "not its own services/postgres/")
expect("a host device", lambda c: c["services"]["api"].update(devices=[{"source": "/dev/sda", "target": "/dev/sda", "permissions": "rwm"}]), "host devices")
expect("a config from a file", lambda c: (c.update(configs={"c1": {"file": "/etc/passwd"}}), c["services"]["api"].update(configs=[{"source": "c1"}])), "comes from a file")
expect("volumes_from", lambda c: c["services"]["api"].update(volumes_from=["container:portainer"]), "volumes_from")
expect("a host bind", lambda c: c["services"]["api"]["volumes"].append({"type": "bind", "source": "/opt/workforce-deploy/secrets", "target": "/x"}), "host path")
expect("the Docker socket", lambda c: c["services"]["postgres"]["volumes"].append({"type": "bind", "source": "/var/run/docker.sock", "target": "/var/run/docker.sock"}), "host path /var/run/docker.sock")
expect("a writable subpath", lambda c: c["services"]["postgres"]["volumes"].append(own("/y", "services/postgres/secrets", ro=False)), "must be read-only")
expect("another service's folder", lambda c: c["services"]["postgres"]["volumes"].append(own("/z", "services/api/secrets")), "not its own services/postgres/")
expect("the mailbox for another service", lambda c: c["services"]["postgres"]["volumes"].append(own("/z", "mailbox/requests", ro=False)), "only the api gets the mailbox")
expect("the health watch's status for another service", lambda c: c["services"]["postgres"]["volumes"].append(own("/z", "status/health")), "only the api gets the health watch's status")
expect("the health watch's status made writable", lambda c: c["services"]["api"]["volumes"].append(own("/y", "status/health", ro=False)), "status/health must be read-only")
expect("the backup's status for anyone", lambda c: c["services"]["api"]["volumes"].append(own("/y", "status/backup")), "not its own services/api/")
expect("the alerts for anyone", lambda c: c["services"]["api"]["volumes"].append(own("/y", "alerts")), "not its own services/api/")
expect("results made writable", lambda c: c["services"]["api"]["volumes"].__setitem__(3, own("/run/workforce-actions/results", "mailbox/results", ro=False)), "mailbox/results must be read-only")
expect("a subpath out of its volume", lambda c: c["services"]["postgres"]["volumes"].append(own("/z", "services/postgres/../api")), "without a plain subpath")
expect("a file secret", lambda c: c["services"]["api"].update(secrets=[{"source": "db_password"}]), "file secrets remain")
expect("a top-level secret", lambda c: c.update(secrets={"db_password": {"file": "/x"}}), "top-level secrets remain")
expect("bind options on a volume", lambda c: c["volumes"]["pg_data"].update(driver="local", driver_opts={"type": "none", "o": "bind", "device": "/etc"}), "driver options other than a tmpfs's")
expect("bind hidden in a tmpfs's options", lambda c: c["volumes"]["pdf_socket"]["driver_opts"].update(o="size=1m,bind"), "driver options other than a tmpfs's")
expect("nocopy lost", lambda c: c["services"]["gateway"]["volumes"][0].pop("volume"), "has lost nocopy")
expect("a service publishing the controller's page (issue 488)",
       lambda c: c["services"]["api"].update(ports=[{"mode": "ingress", "host_ip": "127.0.0.1", "target": 8443, "published": "8443", "protocol": "tcp"}]),
       "publishes 8443")
expect("the controller's volume not external", lambda c: c["volumes"]["controller"].pop("external"), "not declared as external")

print(f"controller-compose self-test: {passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
PY
