#!/usr/bin/env bash
# authentik-brand-e2e.sh — Workforce issue 502 on a live authentik at the compose.yaml pin: which brand is the default
# after the Workforce blueprint (rendered from the template) is applied, in each way an install can be found.
#   A  authentik's own default-brand.yaml applied first (its worker's first start): ours updates that brand, which
#      stays the default, with Workforce's title and the recovery flow;
#   B  the brand there but not the default, and no brand the default (an install from before this fix): made the
#      default;
#   C  ours applied first (no brand yet): created and made the default; default-brand.yaml applied after it then adds
#      nothing;
#   D  an organisation's own brand made the default by hand: the blueprint still applies (authentik refuses a second
#      default brand, which would fail the whole blueprint), that brand stays the default and ours is left as it is;
#   each apply applies again (an update applies it every time).
# Needs Docker (pulls the pinned images) and python3 with jinja2 (Ansible's). Five to twenty minutes. Every container and
# network it makes is removed at the end. Exit 0 = all pass.
#   ./bin/tests/authentik-brand-e2e.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
pin() { awk -v s="  $1:" '$0 == s {on=1} on && /image:/ {print $2; exit}' "$REPO/compose.yaml"; }
AK_IMAGE="$(pin authentik-server)"
PG_IMAGE="$(pin authentik-postgres)"
P="wf-brand-e2e-$$"
WORK="$(mktemp -d)"
cleanup() {
  if [ "${E2E_KEEP:-}" = 1 ]; then echo "kept for debugging: $P-* (remove them by hand)"; return; fi
  docker rm -f -v "$P-pg" "$P-server" "$P-worker" >/dev/null 2>&1 || true
  docker network rm "$P-data" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

PASS=0; FAILN=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAILN=$((FAILN+1)); printf 'FAIL: %s: expected [%s] got [%s]\n' "$1" "$3" "$2"; fi; }
die() { echo "authentik-brand-e2e: $*" >&2; docker logs --tail 40 "$P-server" 2>&1 | grep -v '"level": "debug"' | tail -20 >&2; exit 1; }

# ---- the blueprint, as the identity converge renders it (Ansible's Jinja), with a throwaway admin password
ADMIN_PW="e2e-$(openssl rand -hex 12)"
python3 - "$REPO/ansible/roles/authentik/templates" "$WORK/workforce-app.yaml" "$ADMIN_PW" <<'PY' || die "the blueprint didn't render (python3 with jinja2 is needed)"
import sys, jinja2
env = jinja2.Environment(loader=jinja2.FileSystemLoader(sys.argv[1]), undefined=jinja2.StrictUndefined, keep_trailing_newline=True)
open(sys.argv[2], "w").write(env.get_template("workforce-app.yaml.j2").render(
    app_hostname="app.e2e.test", auth_hostname="auth.e2e.test", oidc_client_id="e2e-client",
    oidc_client_secret="e2e-not-a-secret", ak_admin_password=sys.argv[3]))
PY
chmod -R a+rX "$WORK"

docker network create --internal "$P-data" >/dev/null || die "network"
SECRET="e2e-secret-$(openssl rand -hex 16)"; PGPW="e2e-$(openssl rand -hex 8)"
docker run -d --name "$P-pg" --network "$P-data" --network-alias authentik-postgres \
  -e POSTGRES_USER=authentik -e POSTGRES_PASSWORD="$PGPW" -e POSTGRES_DB=authentik "$PG_IMAGE" >/dev/null || die "postgres"
AK_ENV=(-e TZ=Europe/London -e AUTHENTIK_POSTGRESQL__HOST=authentik-postgres -e AUTHENTIK_POSTGRESQL__USER=authentik
  -e AUTHENTIK_POSTGRESQL__NAME=authentik -e AUTHENTIK_POSTGRESQL__PASSWORD="$PGPW" -e AUTHENTIK_SECRET_KEY="$SECRET"
  -e AUTHENTIK_ERROR_REPORTING__ENABLED=false -e AUTHENTIK_WEB__BASE_URL=https://auth.e2e.test)
AK_VOL=(-v "$WORK/workforce-app.yaml:/blueprints/workforce-app.yaml:ro" -v "$REPO/authentik:/workforce:ro"
  -v "$REPO/branding:/branding:ro" -v "$REPO/branding/authentik-templates:/templates:ro")
docker create --name "$P-server" --network "$P-data" --user 1000:1000 "${AK_ENV[@]}" "${AK_VOL[@]}" \
  --entrypoint dumb-init "$AK_IMAGE" -- sh /workforce/email-route.sh server >/dev/null || die "server"
# The worker without the Workforce blueprint (its own discovery would apply it at the same moment as ours below); it
# applies authentik's own blueprints, default-brand.yaml among them, on its first start: case A.
docker create --name "$P-worker" --network "$P-data" --user 1000:1000 "${AK_ENV[@]}" "${AK_VOL[@]:2}" \
  --entrypoint dumb-init "$AK_IMAGE" -- sh /workforce/email-route.sh worker >/dev/null || die "worker"
docker start "$P-server" "$P-worker" >/dev/null || die "start"
sql() { docker exec "$P-pg" psql -U authentik -d authentik -tAc "$1"; }
akshell() { docker exec -i "$P-server" ak shell -c "$1" 2>/dev/null | grep -v '^{' ; }

echo "waiting for authentik (first start runs its migrations)…"
for _ in $(seq 1 90); do
  docker exec "$P-server" python -c 'import urllib.request; urllib.request.urlopen("http://localhost:9000/-/health/ready/", timeout=3)' \
    >/dev/null 2>&1 && break
  sleep 5
done
docker exec "$P-server" python -c 'import urllib.request; urllib.request.urlopen("http://localhost:9000/-/health/ready/", timeout=3)' \
  >/dev/null 2>&1 || die "authentik never became ready"
for _ in $(seq 1 60); do
  [ "$(sql "select count(*) from authentik_flows_flow where slug in ('default-authentication-flow', 'default-invalidation-flow', 'default-password-change', 'default-user-settings-flow', 'default-authenticator-totp-setup')")" = 5 ] \
    && [ "$(sql "select count(*) from authentik_blueprints_blueprintinstance where status <> 'successful' and enabled")" = 0 ] \
    && [ "$(sql "select count(*) from authentik_brands_brand")" = 1 ] && break
  sleep 5
done
# The worker is stopped now: from here on only this script applies blueprints, one at a time.
docker stop "$P-worker" >/dev/null || die "worker stop"

apply() { # apply <file>: 0 when it applied; the same retries as the identity converge (authentik still settling)
  local out
  for _ in $(seq 1 30); do
    out="$(docker exec -w / "$P-server" python /manage.py apply_blueprint "$1" 2>&1)" && \
      case "$out" in *"Blueprint invalid"*) : ;; *) return 0 ;; esac
    sleep 5
  done
  printf '%s\n' "$out" | grep -iv debug | grep -iE "invalid|error|default" | tail -8 >&2
  return 1
}
# Every brand, one line each: domain default title has-recovery-flow (sorted by domain).
brands() { sql "select domain || ' ' || \"default\" || ' ' || coalesce(branding_title, '-') || ' ' || (flow_recovery_id is not null)
                from authentik_brands_brand order by domain" | tr '\n' ';'; }
OURS="authentik-default true Workforce true;"

echo "$(date +%T) A: authentik's own default brand first"
check "A: authentik made its default brand" "$(sql "select count(*) from authentik_brands_brand where domain = 'authentik-default' and \"default\"")" 1
apply /blueprints/workforce-app.yaml; check "A: the blueprint applies" $? 0
check "A: one brand, the default, Workforce's, with the recovery flow" "$(brands)" "$OURS"
apply /blueprints/workforce-app.yaml; check "A: and applies again" $? 0
check "A: unchanged" "$(brands)" "$OURS"

echo "$(date +%T) B: the brand there, no brand the default"
sql "update authentik_brands_brand set \"default\" = false" >/dev/null
apply /blueprints/workforce-app.yaml; check "B: the blueprint applies" $? 0
check "B: made the default" "$(brands)" "$OURS"

echo "$(date +%T) C: ours first, then default-brand.yaml"
akshell "from authentik.brands.models import Brand; Brand.objects.all().delete()" >/dev/null
check "C: no brand" "$(sql "select count(*) from authentik_brands_brand")" 0
apply /blueprints/workforce-app.yaml; check "C: the blueprint applies" $? 0
check "C: created as the default" "$(brands)" "$OURS"
apply /blueprints/default/default-brand.yaml; check "C: default-brand.yaml applies after it" $? 0
check "C: and adds nothing" "$(brands)" "$OURS"
apply /blueprints/workforce-app.yaml; check "C: ours applies again" $? 0
check "C: unchanged" "$(brands)" "$OURS"

echo "$(date +%T) D: an organisation's own brand is the default"
sql "update authentik_brands_brand set \"default\" = false" >/dev/null
akshell "from authentik.brands.models import Brand; Brand.objects.create(domain='org.e2e.test', default=True, branding_title='Org')" >/dev/null
check "D: the organisation's brand is the default" "$(sql "select domain from authentik_brands_brand where \"default\"")" org.e2e.test
apply /blueprints/workforce-app.yaml; check "D: the blueprint still applies" $? 0
check "D: the organisation's brand stays the default; ours is left as it is" "$(brands)" "authentik-default false Workforce true;org.e2e.test true Org false;"
apply /blueprints/workforce-app.yaml; check "D: and applies again" $? 0
check "D: unchanged" "$(brands)" "authentik-default false Workforce true;org.e2e.test true Org false;"

echo "authentik-brand-e2e: ${PASS} passed, ${FAILN} failed"
[ "$FAILN" = 0 ]
