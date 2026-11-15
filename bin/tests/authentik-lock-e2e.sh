#!/usr/bin/env bash
# authentik-lock-e2e.sh — Workforce issue 462 on a live authentik at the compose.yaml pin: the blueprint rendered from
# the template and applied twice to a fresh authentik (PostgreSQL included), the gateway with its real Caddyfile
# (gateway/Caddyfile.localca, a throwaway certificate) in front, and sign-ins sent through authentik's own flow
# executor from throwaway containers placed where the test needs them:
#   front     the gateway's outside network, through the gateway: real clients, each its own connection;
#   untrusted a network outside AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS (compose.yaml's value), straight to authentik:
#             forwarded headers from there must be ignored;
#   back      the gateway's way to authentik, inside that range (only the stack's own containers are there, none of
#             which relays a browser's headers): a container there stands in for the gateway, so any address can be
#             a connection.
# What it proves (the owner's decisions on issue 462; contract 2, 3 and R of 15 November 2026; each line names the
# contract's test, R.9):
#   - the address: forged forwarded headers from outside never choose it (the gateway replaces them); straight to
#     authentik from outside the trusted range they are ignored too; a forged header naming a workplace address gets
#     the forger's own, ordinary, cap;
#   - the pair: five wrong for one name on one source, then refused before the password is checked; another source is
#     not paused; a name nobody has gets the same answers; twenty at one moment check exactly five; refused requests
#     aren't recorded and the pause ends 15 minutes after the fifth, during a continued attack too (time moved by
#     shifting the records back); every spelling counts as authentik's lookup finds it;
#   - L1 (owner's instruction B): a colleague completes a sign-in (password and code) on the same IPv4 address and the
#     same IPv6 /64 while someone attacks below the cap; at the cap they are refused, sign in at once elsewhere, and
#     sign in on the same source 15 minutes after the cap while a paced attack goes on, but not while an attacker
#     re-arms the moment it ends (review finding 10: only another connection helps then); three people's completed
#     sign-ins make a source proven, never a workplace: it holds at 10 (the owner's Q3); a confirmed office holds at 50,
#     not 49; each hold's alert names the people who completed sign-ins there (what the application needs for Q5);
#   - L2 (decision 2): five as a username and five as its email, then the source's cap of 10 for every name; an
#     unknown name and email get the same answers, byte for byte (the typed name aside), and the password step's
#     median time over seven samples is within 25% of a real name's (review of 15 November 2026, findings 1, 14);
#   - L3 (decision 1): each try a new TCP connection, cookie jar and flow, through the gateway: the 11th is refused;
#     25 different names at one moment from one source record exactly 10;
#   - L4 (decision 1, instruction C): in a large workplace /48 (a confirmed /56) one source is held at its cap and
#     nobody else is; 300
#     tries from rotating /64s tighten it: a never-seen /64 is refused with the network's words, staff on proven /64s
#     carry on, a proven /64 with five wrong is refused (a right password excuses only a confirmed source: review
#     finding 2), staff on proven /64s are never refused while the rotation is being counted (findings 4 and 15), and
#     it lifts 15 minutes after the newest try; an ordinary /48 tightens at 30, though three people completed sign-ins
#     in it (Q3);
#   - L5 (instruction D): with the application's real token, generic account updates (attributes, the password change
#     date) change neither the sign-in decision nor the status; the unlock refuses a stale time, a reused id, another
#     person's id, the emergency administrator and a service account; a voided id never applies; an unlock at T
#     doesn't lift a pause reached after T, even replayed;
#   - L6: the status interface answers the application's token only (not anonymous, not a staff token, not a
#     superuser); that token can't test, read or change anything else; no answer carries a code, a link or an email;
#   - L7 (decision 3, instruction E): no authentik_events.view_event, on a fresh install and after an upgrade from a
#     build that granted it (ab1d474's script: the grant is shown working, then revoked, objects included); the
#     application's token joining a group with it is seen by doctor.sh's program (review finding 5);
#   - L8: the status interface broken, then deleted: the sign-in decisions don't change;
#   - wrong codes have their own count, by account; the emergency administrator's password rule and its recovery;
#   - Workforce issue 474: a sign-in held between its password step and the login, while the password is replaced
#     (reset-admin.sh's program, the same password chosen again, the password disabled), is refused with authentik's
#     words for a wrong password and nobody is signed in, the emergency administrator and staff (after their code)
#     alike; one held while nothing changes signs in; with the check before the login (99) taken away, the login
#     step's own check still signs nobody in.
# Needs Docker (pulls the pinned images) and python3 with jinja2 (Ansible's). Fifteen to forty-five minutes (the blueprint's
# two applies take most of it on a busy machine). Every container and
# network it makes is removed at the end. Exit 0 = all pass.
#   ./bin/tests/authentik-lock-e2e.sh
VERIFIED_AUTHENTIK=2026.8.5
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
pin() { awk -v s="  $1:" '$0 == s {on=1} on && /image:/ {print $2; exit}' "$REPO/compose.yaml"; }
AK_IMAGE="$(pin authentik-server)"
PG_IMAGE="$(pin authentik-postgres)"
CADDY_IMAGE="$(pin gateway | sed -E 's/^\$\{GATEWAY_IMAGE:-(.*)\}$/\1/')"
P="wf-lock-e2e-$$"
WORK="$(mktemp -d)"
NETS=("$P-front" "$P-back" "$P-data" "$P-untrusted")
cleanup() {
  if [ "${E2E_KEEP:-}" = 1 ]; then echo "kept for debugging: $P-* (remove them by hand)"; return; fi
  docker rm -f "$P-pg" "$P-server" "$P-worker" "$P-gateway" "$P-a" "$P-b" "$P-c" "$P-d" "$P-e" "$P-f" "$P-g" "$P-s" \
    "$P-h" "$P-i" "$P-j" "$P-k" >/dev/null 2>&1 || true
  for n in "${NETS[@]}"; do docker network rm "$n" >/dev/null 2>&1 || true; done
  rm -rf "$WORK"
}
trap cleanup EXIT

PASS=0; FAILN=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAILN=$((FAILN+1)); printf 'FAIL: %s: expected [%s] got [%s]\n' "$1" "$3" "$2"; fi; }
has() { case "$2" in *"$3"*) PASS=$((PASS+1)) ;; *) FAILN=$((FAILN+1)); printf 'FAIL: %s: [%s] not in [%s]\n' "$1" "$3" "$2" ;; esac; }
die() { echo "authentik-lock-e2e: $*" >&2; docker logs --tail 40 "$P-server" 2>&1 | grep -v '"level": "debug"' | tail -20 >&2; exit 1; }
j() { python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(eval(sys.argv[1], {"d": d}))' "$1"; }

# ---- the blueprint, as the identity converge renders it (Ansible's Jinja), with a throwaway admin password
ADMIN_PW="e2e-$(openssl rand -hex 12)"
python3 - "$REPO/ansible/roles/authentik/templates" "$WORK/workforce-app.yaml" "$ADMIN_PW" <<'PY' || die "the blueprint didn't render (python3 with jinja2 is needed)"
import sys, jinja2
env = jinja2.Environment(loader=jinja2.FileSystemLoader(sys.argv[1]), undefined=jinja2.StrictUndefined, keep_trailing_newline=True)
open(sys.argv[2], "w").write(env.get_template("workforce-app.yaml.j2").render(
    app_hostname="app.e2e.test", auth_hostname="auth.e2e.test", oidc_client_id="e2e-client",
    oidc_client_secret="e2e-not-a-secret", ak_admin_password=sys.argv[3]))
PY
mkdir -p "$WORK/tls" "$WORK/t" "$WORK/state"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=auth.e2e.test \
  -addext "subjectAltName=DNS:auth.e2e.test,DNS:app.e2e.test,DNS:webmail.localhost,DNS:testmail.localhost" \
  -keyout "$WORK/tls/tls.key" -out "$WORK/tls/tls.crt" >/dev/null 2>&1 || die "no test certificate"
cp "$HERE/lib/flow-client.py" "$WORK/t/"
chmod -R a+rX "$WORK"; chmod a+rwx "$WORK/state"

# ---- networks and containers, as compose.yaml places them
TRUSTED="$(sed -n 's/^ *AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS: "\(.*\)"$/\1/p' "$REPO/compose.yaml" | head -n 1)"
[ -n "$TRUSTED" ] || die "compose.yaml's AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS not found"
in_range() { python3 -c 'import ipaddress,sys; n=ipaddress.ip_network(sys.argv[1]); print(any(n.subnet_of(ipaddress.ip_network(r)) for r in sys.argv[2].split(",")))' "$1" "$2"; }
docker network create "$P-front" >/dev/null || die "network"
docker network create --internal "$P-back" >/dev/null || die "network"
docker network create --internal "$P-data" >/dev/null || die "network"
# A range nobody trusts (198.18.0.0/15, set aside for tests): a client there is outside the trusted range.
for _ in 1 2 3 4 5; do
  docker network create --internal --subnet "198.18.$((RANDOM % 250 + 1)).0/24" "$P-untrusted" >/dev/null 2>&1 && break
done
docker network inspect "$P-untrusted" >/dev/null 2>&1 || die "network"
BACK_NET="$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$P-back")"
UNTRUSTED_NET="$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$P-untrusted")"
[ "$(in_range "$BACK_NET" "$TRUSTED")/$(in_range "$UNTRUSTED_NET" "$TRUSTED")" = True/False ] \
  || die "the test networks aren't where they must be ($BACK_NET inside and $UNTRUSTED_NET outside $TRUSTED)"
SECRET="e2e-secret-$(openssl rand -hex 16)"; PGPW="e2e-$(openssl rand -hex 8)"
docker run -d --name "$P-pg" --network "$P-data" --network-alias authentik-postgres \
  -e POSTGRES_USER=authentik -e POSTGRES_PASSWORD="$PGPW" -e POSTGRES_DB=authentik "$PG_IMAGE" >/dev/null || die "postgres"
AK_ENV=(-e TZ=Europe/London -e AUTHENTIK_POSTGRESQL__HOST=authentik-postgres -e AUTHENTIK_POSTGRESQL__USER=authentik
  -e AUTHENTIK_POSTGRESQL__NAME=authentik -e AUTHENTIK_POSTGRESQL__PASSWORD="$PGPW" -e AUTHENTIK_SECRET_KEY="$SECRET"
  -e AUTHENTIK_ERROR_REPORTING__ENABLED=false -e AUTHENTIK_WEB__BASE_URL=https://auth.e2e.test
  -e AUTHENTIK_REPUTATION__EXPIRY=900 -e AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS="$TRUSTED"
  -e SIGN_IN_WORKPLACE_SOURCE_LIMIT=50 -e SIGN_IN_WORKPLACE_NETWORK_LIMIT=300 -e "CLIENT_ADDRESSES_CONFIRMED=203.0.113.64/28 2001:db8:100::/56")
AK_VOL=(-v "$WORK/workforce-app.yaml:/blueprints/workforce-app.yaml:ro" -v "$REPO/authentik:/workforce:ro"
  -v "$REPO/branding:/branding:ro" -v "$REPO/branding/authentik-templates:/templates:ro")
docker create --name "$P-server" --network "$P-data" --network-alias authentik-server --user 1000:1000 \
  "${AK_ENV[@]}" "${AK_VOL[@]}" \
  --entrypoint dumb-init "$AK_IMAGE" -- sh /workforce/email-route.sh server >/dev/null || die "server"
docker network connect --alias authentik-server "$P-back" "$P-server" || die "server network"
docker network connect --alias authentik-server "$P-untrusted" "$P-server" || die "server network"
# The worker without the Workforce blueprint: it would apply it by itself at the same moment as the converge's own
# apply below, and the two wait on each other's locks for minutes. Applied here as the converge applies it.
docker create --name "$P-worker" --network "$P-data" --user 1000:1000 "${AK_ENV[@]}" "${AK_VOL[@]:2}" \
  --entrypoint dumb-init "$AK_IMAGE" -- sh /workforce/email-route.sh worker >/dev/null || die "worker"
docker start "$P-server" "$P-worker" >/dev/null || die "start"
docker create --name "$P-gateway" --network "$P-front" --network-alias gateway -e APP_HOSTNAME=app.e2e.test -e AUTH_HOSTNAME=auth.e2e.test \
  -e GATEWAY_TRUSTED_PROXIES=192.0.2.255/32 -v "$REPO/gateway:/etc/caddy/gateway:ro" -v "$WORK/tls:/etc/caddy/tls:ro" \
  "$CADDY_IMAGE" caddy run --config /etc/caddy/gateway/Caddyfile.localca --adapter caddyfile >/dev/null || die "gateway"
docker network connect "$P-back" "$P-gateway" || die "gateway network"
docker start "$P-gateway" >/dev/null || die "gateway start"
ip_on() { docker inspect -f "{{(index .NetworkSettings.Networks \"$2\").IPAddress}}" "$1"; }
GW="$(ip_on "$P-gateway" "$P-front")"
client() { # client <name> <network> [--add-host …]
  local name="$1" net="$2"; shift 2
  docker run -d --name "$P-$name" --network "$net" "$@" -v "$WORK/t:/t:ro" -v "$WORK/state:/state" --entrypoint sleep "$AK_IMAGE" 7200 >/dev/null \
    || die "client $name"
}
for c in a b c e f g h i j k; do client "$c" "$P-front" --add-host "auth.e2e.test:$GW"; done
client d "$P-untrusted"
client s "$P-back"
A="$(ip_on "$P-a" "$P-front")"; B="$(ip_on "$P-b" "$P-front")"; C="$(ip_on "$P-c" "$P-front")"; E="$(ip_on "$P-e" "$P-front")"
H="$(ip_on "$P-h" "$P-front")"; I="$(ip_on "$P-i" "$P-front")"; J="$(ip_on "$P-j" "$P-front")"
D="$(ip_on "$P-d" "$P-untrusted")"
# OUT: through the gateway. IN: straight to authentik (from d, outside the trusted range; from s, inside it).
OUT=https://auth.e2e.test; IN=http://authentik-server:9000
fc() { local who="$1" base="$2"; shift 2; docker exec "$P-$who" python /t/flow-client.py "$base" "$@"; }
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

echo "$(date +%T) authentik is ready; applying the blueprint"
# ---- the blueprint, applied as the identity converge applies it, then again (it must apply again, not only once).
# First authentik's own default flows, which the worker applies on its first start.
for _ in $(seq 1 60); do
  [ "$(sql "select count(*) from authentik_flows_flow where slug in ('default-authentication-flow', 'default-invalidation-flow', 'default-password-change', 'default-user-settings-flow', 'default-authenticator-totp-setup')")" = 5 ] \
    && [ "$(sql "select count(*) from authentik_blueprints_blueprintinstance where status <> 'successful' and enabled")" = 0 ] && break
  sleep 5
done
applied=no
T0=$(date +%s)
for _ in $(seq 1 40); do
  out="$(docker exec -w / "$P-server" python /manage.py apply_blueprint /blueprints/workforce-app.yaml 2>&1)" && \
    case "$out" in *"Blueprint invalid"*) : ;; *) applied=yes; break ;; esac
  sleep 10
done
check "the blueprint applies on a fresh authentik" "$applied" yes
echo "     applied in $(( $(date +%s) - T0 )) s"
[ "$applied" = yes ] || { printf '%s\n' "$out" | grep -iv debug | tail -15; die "the blueprint didn't apply"; }
echo "$(date +%T) applied; again"
out="$(docker exec -w / "$P-server" python /manage.py apply_blueprint /blueprints/workforce-app.yaml 2>&1)"; rc=$?
echo "$(date +%T) applied again"
case "$out" in *"Blueprint invalid"*) rc=9 ;; esac
check "and again" "$rc" 0
check "the old by-account lock is gone" "$(sql "select count(*) from authentik_policies_expression_expressionpolicy p join authentik_policies_policy b on b.policy_uuid = p.policy_ptr_id where b.name = 'workforce-too-many-tries-by-account'")" 0

# ---- people: three staff with an authenticator app (codes by email set up too), and others; the application's service account
TOTP_KEY="$(openssl rand -hex 20)"; printf '%s' "$TOTP_KEY" > "$WORK/t/totp.key"
TOTP_SAM="$(openssl rand -hex 20)"; printf '%s' "$TOTP_SAM" > "$WORK/t/totp-sam.key"
TOTP_KIM="$(openssl rand -hex 20)"; printf '%s' "$TOTP_KIM" > "$WORK/t/totp-kim.key"
chmod a+r "$WORK"/t/totp*.key
PW_PAT="pat-$(openssl rand -hex 8)"; PW_SAM="sam-$(openssl rand -hex 8)"; PW_KIM="kim-$(openssl rand -hex 8)"; PW_LEE="lee-$(openssl rand -hex 8)"
akshell "
from authentik.core.models import User
from authentik.stages.authenticator_totp.models import TOTPDevice
for name, pw in (('pat', '$PW_PAT'), ('sam', '$PW_SAM'), ('kim', '$PW_KIM'), ('lee', '$PW_LEE')):
    u, _ = User.objects.update_or_create(username=name, defaults={'email': name + '@example.org', 'type': 'internal',
        'name': 'Kim Example' if name == 'kim' else '', 'attributes': {'workforce': {'codes': name + '@example.org'}}})
    u.set_password(pw); u.save()
for name, key in (('pat', '$TOTP_KEY'), ('sam', '$TOTP_SAM'), ('kim', '$TOTP_KIM')):
    TOTPDevice.objects.update_or_create(user=User.objects.get(username=name), name='app',
        defaults={'key': key, 'confirmed': True, 'digits': 6, 'step': 30})
print('people ready')" >/dev/null
TOKEN="$(openssl rand -hex 24)"
converge_sa() { printf '%s' "$TOKEN" | docker exec -i "$P-server" ak shell -c "$1" 2>&1 | grep -v '^{' | tail -3; }
NEW_SA="$(cat "$REPO/ansible/roles/authentik/files/invite-service-account.py")"
converge_sa "$NEW_SA" | grep -q 'workforce-invites converged' || { converge_sa "$NEW_SA"; die "the service account wasn't made"; }
check "the service account's script runs again (idempotent)" "$(converge_sa "$NEW_SA" | grep -c 'workforce-invites converged')" 1
PAT_PK="$(sql "select id from authentik_core_user where username = 'pat'")"
SAM_PK="$(sql "select id from authentik_core_user where username = 'sam'")"
KIM_PK="$(sql "select id from authentik_core_user where username = 'kim'")"
LEE_PK="$(sql "select id from authentik_core_user where username = 'lee'")"
SVC_PK="$(sql "select id from authentik_core_user where username = 'workforce-invites'")"
NETWORK="Too many wrong passwords from this network. Wait 15 minutes, or use another connection"
tries() { sql "select count(*) from authentik_events_event where action = 'custom_workforce_password_try' and context->>'wf_account' = '$1' and context->>'wf_conn' = '$2'"; }
result() { j 'd["result"] + ":" + d.get("component","") + ":" + d.get("message","")'; }
PAUSED="Too many wrong passwords for this name, from this connection"
THROTTLED="Too many wrong passwords from this connection. Wait 15 minutes, or use another connection"

# ---- 1. the address: never chosen by a forwarded header
FORGED='{"X-Forwarded-For": "198.51.100.11, 198.51.100.12", "X-Real-IP": "198.51.100.13", "Forwarded": "for=198.51.100.14", "X-authentik-remote-ip": "198.51.100.15", "True-Client-IP": "198.51.100.16", "X-Client-IP": "198.51.100.17", "CF-Connecting-IP": "198.51.100.18"}'
check "through the gateway: the client's own address" "$(fc a "$OUT" address | j 'd["message"]')" "workforce-client-address=$A"
check "forged headers through the gateway: still its own" "$(fc a "$OUT" address --headers "$FORGED" | j 'd["message"]')" "workforce-client-address=$A"
check "forged headers straight to authentik from outside the trusted range: its own" \
  "$(fc d "$IN" address --headers "$FORGED" | j 'd["message"]')" "workforce-client-address=$D"
check "inside the trusted range (the gateway's, and only the stack's own containers): X-Forwarded-For is taken" \
  "$(fc s "$IN" address --headers '{"X-Forwarded-For": "198.51.100.21"}' | j 'd["message"]')" "workforce-client-address=198.51.100.21"
check "there, only its first entry (the gateway sends one)" \
  "$(fc s "$IN" address --headers '{"X-Forwarded-For": "198.51.100.22, 198.51.100.23"}' | j 'd["message"]')" "workforce-client-address=198.51.100.22"
check "and X-authentik-remote-ip never (no outpost token)" \
  "$(fc s "$IN" address --headers '{"X-authentik-remote-ip": "198.51.100.24"}' | j 'd["message"]')" "workforce-client-address=$(ip_on "$P-s" "$P-back")"
# The readiness probe exactly as doctor.sh, install.sh and update.sh run it (bin/lib/client-address.sh): a one-off of
# the pinned curl image on the gateway's outside network, forged headers, through the gateway.
PROBE_OUT="$(cd "$WORK" && CA_PROBE_NETWORK="$P-front" CA_COMPOSE_FILE="$REPO/compose.yaml" AUTH_HOSTNAME=auth.e2e.test \
  CLIENT_ADDRESS_FILE="$WORK/status/client-address.json" bash -c '. "$1/bin/lib/common.sh"; . "$1/bin/lib/client-address.sh"; client_address_probe' _ "$REPO")"
check "the readiness probe through the real gateway: OK" "$?:$PROBE_OUT" "0:the sign-in server sees each client's own address (forged headers ignored)"
check "its record" "$(j 'str(d["ok"]) + " " + str(d["forgedIgnored"]) + " " + str(d["seen"] == d["probeAddress"])' < "$WORK/status/client-address.json")" "True True True"
check "the probe signs nobody in and records nothing" "$(sql "select count(*) from authentik_events_event where action like 'custom_workforce_%'")" 0

# ---- 2. five wrong passwords pause one account on one connection, whatever the headers say
for i in 1 2 3 4 5; do
  r="$(fc a "$OUT" signin --headers "{\"X-Forwarded-For\": \"$B\"}" pat "wrong-$i" | result)"
  check "pat from A, wrong password $i: checked and wrong" "${r%%:*}" error
done
check "five tries recorded for (pat, A), none for B" "$(tries "u:$PAT_PK" "$A")/$(tries "u:$PAT_PK" "$B")" "5/0"
r="$(fc a "$OUT" signin pat "$PW_PAT" | result)"
has "pat from A, sixth (even the right password): refused at once" "$r" "denied:ak-stage-access-denied:$PAUSED"
check "refused: not recorded" "$(tries "u:$PAT_PK" "$A")" 5
r="$(fc b "$OUT" signin pat "$PW_PAT" | result)"
check "pat from B at once: the password is right, on to the code" "$r" "next:ak-stage-authenticator-validate:"
r="$(fc b "$OUT" signin sam wrong-1 | result)"
check "someone else on A's paused account's other connection: unaffected" "${r%%:*}" error
r="$(fc a "$OUT" signin sam "$PW_SAM" | result)"
has "another person on connection A: not paused (on to the code step)" "$r" "next:ak-stage-authenticator-"
check "the refusal is recorded, once a minute at most" "$(sql "select string_agg(context->>'wf_why', ',') from authentik_events_event where action = 'custom_workforce_password_refused' and context->>'wf_conn' = '$A'")" paused

check "a real account's tries carry it as the event's user" "$(sql "select distinct \"user\"->>'username' from authentik_events_event where action = 'custom_workforce_password_try' and context->>'wf_account' = 'u:$PAT_PK'")" pat

# ---- 3. a name nobody has: the same answers, the same pause
for i in 1 2 3 4 5; do
  r="$(fc c "$OUT" signin nobody-here "wrong-$i" | result)"
  check "unknown name from C, wrong $i: the same answer as a real one" "${r%%:*}:$(printf '%s' "$r" | cut -d: -f2)" "error:ak-stage-password"
done
r="$(fc c "$OUT" signin nobody-here wrong-6 | result)"
has "unknown name, sixth: the same refusal" "$r" "denied:ak-stage-access-denied:$PAUSED"
check "an unknown name's tries carry no user" "$(sql "select distinct \"user\"::text from authentik_events_event where action = 'custom_workforce_password_try' and context->>'wf_account' like 'n:%'")" "{}"
check "the typed name is never stored" "$(sql "select count(*) from authentik_events_event where action like 'custom_workforce_%' and (context::text like '%nobody-here%' or \"user\"::text like '%nobody-here%')")" 0
# ---- 3b. review finding 1: every spelling of a name counts as authentik's lookup finds it, for real names and unknown
# ones alike, and a real account's other name (its email) counts apart like any name. A container inside the trusted
# range stands in for the gateway (section 1), so each pair below has a connection of its own.
akshell "
from authentik.core.models import User
u, _ = User.objects.update_or_create(username='kit', defaults={'email': 'kit.work@example.org', 'type': 'internal'})
u.set_password('$PW_KIM'); u.save()
print('kit ready')" >/dev/null
KIT_PK="$(sql "select id from authentik_core_user where username = 'kit'")"
via() { local at="$1"; shift; fc s "$IN" signin --headers "{\"X-Forwarded-For\": \"$at\"}" "$@" | result; }
pause_then() { # pause_then <connection> <name> <then typed> → the answer to <then typed> after five wrong for <name>
  local i; for i in 1 2 3 4 5; do via "$1" "$2" "wrong-$i" >/dev/null; done
  via "$1" "$3" wrong-6
}
KELVIN=$'\u212a'; LONG_S=$'\u017f'
REAL="$(pause_then 192.0.2.101 kit "${KELVIN}it")"; UNKNOWN="$(pause_then 192.0.2.102 kate "${KELVIN}ate")"
check "Kelvin sign after five for a real name: the same answer as for an unknown name" "$REAL" "$UNKNOWN"
check "(which is: checked, not paused; authentik's lookup doesn't match it)" "${REAL%%:*}" error
REAL="$(pause_then 192.0.2.103 sam "${LONG_S}am")"; UNKNOWN="$(pause_then 192.0.2.104 sue "${LONG_S}ue")"
check "long s after five for a real name: the same answer as for an unknown name" "$REAL" "$UNKNOWN"
REAL="$(pause_then 192.0.2.105 KIT kit)"; UNKNOWN="$(pause_then 192.0.2.106 KATE kate)"
has "another case after five: paused for a real name" "$REAL" "denied:ak-stage-access-denied:$PAUSED"
check "and the same for an unknown name" "$UNKNOWN" "$REAL"
REAL="$(pause_then 192.0.2.107 kit kit.work@example.org)"; UNKNOWN="$(pause_then 192.0.2.108 kate kate.work@example.org)"
check "a real account's email after five for its username: the same answer as for an unknown name's" "$REAL" "$UNKNOWN"
check "(which is: checked, not paused)" "${REAL%%:*}" error
check "its email's tries still carry the person" "$(sql "select count(*) from authentik_events_event where action = 'custom_workforce_password_try' and context->>'wf_account' like 'n:%' and (context->>'wf_user_pk')::int = $KIT_PK and \"user\"->>'username' = 'kit'")" 1
check "the password step shows the name as typed, for a real name" "$(fc s "$IN" shown KIT | j 'd["pending_user"]')" KIT
check "and for an unknown one" "$(fc s "$IN" shown KATE | j 'd["pending_user"]')" KATE
check "no typed name is stored" "$(sql "select count(*) from authentik_events_event where action like 'custom_workforce_%' and (context::text ~* 'kate|kit.work' or \"user\"::text ~* 'kate|kit.work')")" 0

r="$(fc c "$OUT" raw pat '{"component": "ak-stage-password", "password": ""}' | result)"
check "an empty password isn't checked, and isn't counted" "$(tries "u:$PAT_PK" "$C")" 0

# ---- 4. twenty at the same moment: exactly five checked
fc b "$OUT" burst 20 kim wrong-burst > "$WORK/burst.json"
check "twenty at once for (kim, B): exactly five recorded" "$(tries "u:$KIM_PK" "$B")" 5
check "and fifteen refused, with the pause's words, the password unchecked" \
  "$(PAUSED="$PAUSED" j 'sum(1 for x in d if x and x["result"] == "denied" and x["message"].startswith(__import__("os").environ["PAUSED"]))' < "$WORK/burst.json")" 15
# The five checked are wrong; authentik's own password step may also end the fifth's sign-in ("Invalid password": it
# gives up on a sign-in once the name's reputation fell by five meanwhile). Nobody gets further.
check "none of the twenty gets past the password" "$(j 'sum(1 for x in d if not x or x["result"] == "next")' < "$WORK/burst.json")" 0

# ---- 5. a continued attack: refusals aren't recorded, and the pause still ends 15 minutes after the fifth
# age_records <account> <connection> <interval>: the pair's records moved back so that its newest try was that long ago.
# (kim's password was set when the test began, which is its marker: moved back too, so that the tries still count.)
sql "update authentik_core_user set password_change_date = now() - interval '2 hours' where username = 'kim'" >/dev/null
age_records() { sql "update authentik_events_event set created = created - ((interval '$3') - (now() - (select max(created) from authentik_events_event where action = 'custom_workforce_password_try' and context->>'wf_account' = '$1' and context->>'wf_conn' = '$2'))), expires = expires - interval '$3' where action like 'custom_workforce_password_%' and context->>'wf_account' = '$1' and context->>'wf_conn' = '$2'" >/dev/null; }
for i in 1 2 3; do fc b "$OUT" signin kim "again-$i" >/dev/null; done
check "while paused, nothing more is recorded" "$(tries "u:$KIM_PK" "$B")" 5
age_records "u:$KIM_PK" "$B" "14 minutes 50 seconds"
r="$(fc b "$OUT" signin kim "$PW_KIM" | result)"
has "ten seconds before the end: still paused" "$r" "$PAUSED"
age_records "u:$KIM_PK" "$B" "15 minutes 1 second"
r="$(fc b "$OUT" signin kim "$PW_KIM" | result)"
has "15 minutes after the fifth, despite the attack: the right password goes on" "$r" "next:ak-stage-authenticator-"
for i in 1 2 3 4 5; do fc b "$OUT" signin kim "later-$i" >/dev/null; done
r="$(fc b "$OUT" signin kim "$PW_KIM" | result)"
has "five more wrong: paused again" "$r" "$PAUSED"

# ---- helpers for the sections below
SPK=7ccaf87d-46bb-5dcd-9b0c-7f0df9db4045     # the status interface's fixed id (invite-service-account.py)
ADMIN_PK="$(sql "select id from authentik_core_user where username = 'admin'")"
DONE="next:xak-flow-redirect:"
xff() { printf '{"X-Forwarded-For": "%s"}' "$1"; }
nowiso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
uuid4() { python3 -c 'import uuid; print(uuid.uuid4())'; }
# st <user pk or null> <context json> [token]: the status interface's answer, as the application gets it (a JSON
# object with "v": 1; {"http": <status>, "successful": …} when there is none it could read)
st() {
  fc d "$IN" api POST "/api/v3/propertymappings/all/$SPK/test/" "${3:-$TOKEN}" "{\"user\": $1, \"context\": $2}" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read()); b = d.get("body")
if d.get("status") == 200 and isinstance(b, dict) and b.get("successful"):
    print(json.dumps(json.loads(b["result"]), sort_keys=True))
else:
    print(json.dumps({"http": d.get("status"), "successful": b.get("successful") if isinstance(b, dict) else None}))'
}
# complete <client> <base> <headers or ""> <name> <password> <key file>: a whole sign-in, password and code (the
# authenticator app's next unused code); prints the last answer
complete() {
  local who="$1" base="$2" hdr="$3"; shift 3
  if [ -n "$hdr" ]; then fc "$who" "$base" code --headers "$hdr" "$1" "$2" "@totp:$3"; else fc "$who" "$base" code "$1" "$2" "@totp:$3"; fi \
    | j 'd[-1]["result"] + ":" + d[-1]["component"] + ":" + d[-1].get("message", "")'
}
# trycount <source key>: its wrong tries recorded (every try not marked right)
trycount() { sql "select count(*) from authentik_events_event t where t.action = 'custom_workforce_password_try' and t.context->>'wf_conn' = '$1' and not exists (select 1 from authentik_events_event r where r.action = 'custom_workforce_password_right' and r.context->>'wf_try' = t.context->>'wf_try')"; }
# age_source <source key> <interval>: the source's records moved back so that its newest try was that long ago
age_source() { sql "update authentik_events_event set created = created - ((interval '$2') - (now() - (select max(created) from authentik_events_event where action = 'custom_workforce_password_try' and context->>'wf_conn' = '$1'))), expires = expires - interval '$2' where action like 'custom_workforce_password_%' and context->>'wf_conn' = '$1'" >/dev/null; }
# age_net <IPv6 /48> <interval>: the same for every record in a /48 (by address)
age_net() { sql "update authentik_events_event set created = created - ((interval '$2') - (now() - (select max(created) from authentik_events_event where action = 'custom_workforce_password_try' and client_ip <<= '$1'))), expires = expires - interval '$2' where action like 'custom_workforce_password_%' and client_ip <<= '$1'" >/dev/null; }
count_words() { WORDS="$2" j 'sum(1 for x in d if x and x.get("result") == "denied" and x.get("message", "").startswith(__import__("os").environ["WORDS"]))' < "$1"; }
count_checked() { j 'sum(1 for x in d if x and x.get("result") == "error")' < "$1"; }

# ---- 6. the sign-in status interface (contract R.7) and the unlock; L7 on a fresh install; L5; L6
# An email as authentik records every one it sends (email_sent, its whole body), with a code and a reset link in it.
EV="$(akshell "
from authentik.core.models import User
from authentik.events.models import Event, EventAction
u = User.objects.get(username='lee')
e = Event.new(EventAction.EMAIL_SENT, message='Email to lee@example.org sent', subject='Your sign-in code',
    body='Your code is E2E-CODE-724913. Reset: https://auth.e2e.test/if/flow/workforce-recovery/?flow_token=E2E-LINK-0000',
    from_email='workforce@example.org', to_email=['lee@example.org'])
e.user = {'pk': u.pk, 'username': u.username}
e.save()
print('EV', e.pk)" | sed -n 's/^EV //p')"
check "L7 fresh install: the application's token gets no events (403)" "$(fc d "$IN" api GET "/api/v3/events/events/?page_size=5" "$TOKEN" | j 'd["status"]')" 403
check "L7 fresh install: nor an email_sent event by its id" "$(fc d "$IN" api GET "/api/v3/events/events/$EV/" "$TOKEN" | j 'd["status"] in (403, 404)')" True
check "L7 fresh install: the account has no view_event, globally or on any object" "$(akshell "
from authentik.core.models import User
from guardian.models import RoleObjectPermission
u = User.objects.get(username='workforce-invites')
print('PERM', u.has_perm('authentik_events.view_event'), RoleObjectPermission.objects.filter(role__in=u.all_roles(), permission__codename='view_event').count())" | sed -n 's/^PERM //p')" "False 0"

r="$(st "$PAT_PK" '{"wf_op": "status"}')"
check "status: pat, paused on A since section 2, on one source" "$(printf '%s' "$r" | j 'str(d.get("known")) + " " + str(d.get("paused")) + " " + str(d.get("pausedSources"))')" "True True 1"
check "with when it ends and when it was checked" "$(printf '%s' "$r" | j 'd["until"] > d["checkedAt"]')" True
U1="$(uuid4)"
r="$(st "$PAT_PK" "{\"wf_op\": \"unlock\", \"wf_unlock_id\": \"$U1\", \"wf_requested_at\": \"$(nowiso)\"}")"
check "unlock pat: applied, acknowledged with the server's time, and it was paused" "$(printf '%s' "$r" | j 'str(d.get("applied")) + " " + str(d.get("wasPaused")) + " " + str(d.get("id") == "'"$U1"'")')" "True True True"
U1_AT="$(printf '%s' "$r" | j 'd["at"]')"
check "recorded by the sign-in server, by its own clock" "$(sql "select count(*) from authentik_events_event where action = 'custom_workforce_password_unlock' and context->>'wf_unlock_id' = '$U1' and (context->>'wf_user_pk')::int = $PAT_PK and context->>'wf_at' = '$U1_AT'")" 1
check "after the unlock, pat signs in from A again" "$(fc a "$OUT" signin pat "$PW_PAT" | result)" "next:ak-stage-authenticator-validate:"
check "status: not paused, the unlock named" "$(st "$PAT_PK" '{"wf_op": "status"}' | j 'str(d["paused"]) + " " + d["lastUnlock"]["id"]')" "False $U1"
check "unlock-status of it: applied, at the same time" "$(st "$PAT_PK" "{\"wf_op\": \"unlock-status\", \"wf_unlock_id\": \"$U1\"}" | j 'str(d["applied"]) + " " + d["at"]')" "True $U1_AT"
fwd() { sql "select context->>'wf_fwd' from authentik_events_event where action = 'custom_workforce_password_right' and context->>'wf_account' = 'u:$PAT_PK' order by created desc limit 1"; }
check "a right password straight from a client: not forwarded" "$(fwd)" false
fc a "$OUT" signin --headers '{"X-Forwarded-For": "198.51.100.50"}' pat "$PW_PAT" >/dev/null
check "the same with a forwarding header from a peer nobody named: wf_fwd" "$(fwd)" true

# L5: lee is paused on one source; the application's real token then tries every generic way to change it.
LEE_SRC=192.0.2.150
for i in 1 2 3 4 5; do via "$LEE_SRC" lee "wrong-$i" >/dev/null; done
has "L5: lee paused on one source" "$(via "$LEE_SRC" lee "$PW_LEE")" "$PAUSED"
BEFORE="$(st "$LEE_PK" '{"wf_op": "status"}' | j 'str(d["paused"]) + " " + str(d["pausedSources"]) + " " + str(d["until"])')"
check "L5: status: paused" "${BEFORE%% *}" True
PCD="$(sql "select password_change_date from authentik_core_user where id = $LEE_PK")"
NOWI="$(nowiso)"
n=0
for body in "{\"attributes\": {\"workforce\": {\"codes\": \"lee@example.org\", \"password_unlocked_at\": \"$NOWI\"}}}" \
            "{\"attributes\": {\"workforce\": {\"codes\": \"lee@example.org\", \"pause\": {\"paused\": false, \"until\": null}, \"password_unlocked\": true}}}" \
            '{"attributes": {"workforce": {}}}' '{"attributes": {}}' "{\"password_change_date\": \"$NOWI\"}" \
            "{\"attributes\": {\"workforce\": {\"codes\": \"lee@example.org\"}}, \"password_change_date\": \"$NOWI\", \"last_login\": \"$NOWI\"}"; do
  n=$((n+1))
  code="$(fc d "$IN" api PATCH "/api/v3/core/users/$LEE_PK/" "$TOKEN" "$body" | j 'd["status"]')"
  check "L5 update $n with the application's token: authentik takes it" "$code" 200
  has "L5 update $n: lee is still refused at the sign-in page" "$(via "$LEE_SRC" lee "$PW_LEE")" "$PAUSED"
  check "L5 update $n: the status is unchanged" "$(st "$LEE_PK" '{"wf_op": "status"}' | j 'str(d["paused"]) + " " + str(d["pausedSources"]) + " " + str(d["until"])')" "$BEFORE"
done
check "L5: the password change date can't be written through the API" "$(sql "select password_change_date from authentik_core_user where id = $LEE_PK")" "$PCD"
check "L5: nor can a record be made (POST events)" "$(fc d "$IN" api POST /api/v3/events/events/ "$TOKEN" '{"action": "custom_workforce_password_unlock", "app": "workforce", "context": {"wf_user_pk": 1}}' | j 'd["status"] in (403, 405)')" True
STALE="$(date -u -d '-3 minutes' +%Y-%m-%dT%H:%M:%SZ)"
check "L5: an unlock asked for 3 minutes ago: stale" "$(st "$LEE_PK" "{\"wf_op\": \"unlock\", \"wf_unlock_id\": \"$(uuid4)\", \"wf_requested_at\": \"$STALE\"}" | j 'd["applied"], d["why"]')" "(False, 'stale')"
check "L5: pat's unlock id used for lee: reused" "$(st "$LEE_PK" "{\"wf_op\": \"unlock\", \"wf_unlock_id\": \"$U1\", \"wf_requested_at\": \"$(nowiso)\"}" | j 'd["applied"], d["why"]')" "(False, 'reused')"
check "L5: the emergency administrator: refused" "$(st "$ADMIN_PK" "{\"wf_op\": \"unlock\", \"wf_unlock_id\": \"$(uuid4)\", \"wf_requested_at\": \"$(nowiso)\"}" | j 'd["applied"], d["why"]')" "(False, 'account')"
check "L5: a service account: refused" "$(st "$SVC_PK" "{\"wf_op\": \"unlock\", \"wf_unlock_id\": \"$(uuid4)\", \"wf_requested_at\": \"$(nowiso)\"}" | j 'd["applied"], d["why"]')" "(False, 'account')"
check "L5: an id that isn't a fresh random one: refused" "$(st "$LEE_PK" "{\"wf_op\": \"unlock\", \"wf_unlock_id\": \"1\", \"wf_requested_at\": \"$(nowiso)\"}" | j 'd["applied"], d["why"]')" "(False, 'invalid')"
V="$(uuid4)"
check "L5: asking about an id before it was applied voids it" "$(st "$LEE_PK" "{\"wf_op\": \"unlock-status\", \"wf_unlock_id\": \"$V\"}" | j 'd["applied"], d["voided"]')" "(False, True)"
check "L5: so a delayed unlock with it never applies" "$(st "$LEE_PK" "{\"wf_op\": \"unlock\", \"wf_unlock_id\": \"$V\", \"wf_requested_at\": \"$(nowiso)\"}" | j 'd["applied"], d["why"]')" "(False, 'reused')"
has "L5: after all that, lee is still refused" "$(via "$LEE_SRC" lee "$PW_LEE")" "$PAUSED"
U2="$(uuid4)"
r="$(st "$LEE_PK" "{\"wf_op\": \"unlock\", \"wf_unlock_id\": \"$U2\", \"wf_requested_at\": \"$(nowiso)\"}")"
check "L5: a real unlock: applied" "$(printf '%s' "$r" | j 'd["applied"], d["wasPaused"]')" "(True, True)"
U2_AT="$(printf '%s' "$r" | j 'd["at"]')"
check "L5: lee's right password goes on" "$(via "$LEE_SRC" lee "$PW_LEE" | cut -d: -f1)" next
# (The five before the unlock are moved out of the source's 15 minutes, so the five below reach lee's own pause, not
# the source's cap of ten.)
age_source "$LEE_SRC" "16 minutes"
for i in 1 2 3 4 5; do via "$LEE_SRC" lee "again-$i" >/dev/null; done
has "L5: five wrong after the unlock: paused again (an unlock at T doesn't lift a pause reached after T)" "$(via "$LEE_SRC" lee "$PW_LEE")" "$PAUSED"
r="$(st "$LEE_PK" "{\"wf_op\": \"unlock\", \"wf_unlock_id\": \"$U2\", \"wf_requested_at\": \"$(nowiso)\"}")"
check "L5: the old unlock replayed: its first answer and time, nothing new" "$(printf '%s' "$r" | j 'd["applied"], d.get("repeated"), d["at"]')" "(True, True, '$U2_AT')"
has "L5: and lee is still refused" "$(via "$LEE_SRC" lee "$PW_LEE")" "$PAUSED"
check "L5: and the status still says paused" "$(st "$LEE_PK" '{"wf_op": "status"}' | j 'd["paused"]')" True
check "L5: one unlock recorded for lee (the replay added none)" "$(sql "select count(*) from authentik_events_event where action = 'custom_workforce_password_unlock' and (context->>'wf_user_pk')::int = $LEE_PK")" 1

# L6: who may ask, and what the application's token can do besides
SAM_TOKEN="$(openssl rand -hex 24)"; ROOT_TOKEN="$(openssl rand -hex 24)"
akshell "
from authentik.core.models import Group, Token, User
sam = User.objects.get(username='sam')
Token.objects.update_or_create(identifier='e2e-sam', defaults={'user': sam, 'intent': 'api', 'expiring': False, 'key': '$SAM_TOKEN'})
root, _ = User.objects.update_or_create(username='e2e-root', defaults={'type': 'internal', 'name': 'e2e root'})
Group.objects.filter(is_superuser=True).first().users.add(root)
Token.objects.update_or_create(identifier='e2e-root', defaults={'user': root, 'intent': 'api', 'expiring': False, 'key': '$ROOT_TOKEN'})
print('tokens ready')" >/dev/null
check "L6: anonymous: nothing" "$(st "$LEE_PK" '{"wf_op": "status"}' not-a-token | j 'd.get("http") in (401, 403)')" True
check "L6: a member of staff's own token: nothing" "$(st "$LEE_PK" '{"wf_op": "status"}' "$SAM_TOKEN" | j 'd.get("http")')" 403
check "L6: a superuser's token: no status (the interface answers the application only)" "$(st "$LEE_PK" '{"wf_op": "status"}' "$ROOT_TOKEN" | j 'd.get("known"), d.get("why"), "paused" in d')" "(False, 'caller', False)"
OTHER_PM="$(sql "select pm_uuid from authentik_core_propertymapping where pm_uuid <> '$SPK' limit 1")"
check "L6: the application's token can't test another mapping" "$(fc d "$IN" api POST "/api/v3/propertymappings/all/$OTHER_PM/test/" "$TOKEN" '{"context": {}}' | j 'd["status"] != 200')" True
TRY_POLICY="$(sql "select policy_uuid from authentik_policies_policy where name = 'workforce-password-try'")"
check "L6: nor test a policy" "$(fc d "$IN" api POST "/api/v3/policies/all/$TRY_POLICY/test/" "$TOKEN" "{\"user\": $LEE_PK}" | j 'd["status"] != 200')" True
check "L6: nor list policies" "$(fc d "$IN" api GET /api/v3/policies/all/ "$TOKEN" | j 'd["status"]')" 403
check "L6: nor change the interface" "$(fc d "$IN" api PATCH "/api/v3/propertymappings/all/$SPK/" "$TOKEN" '{"expression": "return 1"}' | j 'd["status"] >= 400')" True
check "L6: nor delete it" "$(fc d "$IN" api DELETE "/api/v3/propertymappings/all/$SPK/" "$TOKEN" | j 'd["status"]')" 403
LINK="$(fc d "$IN" api POST "/api/v3/core/users/$LEE_PK/recovery/" "$TOKEN" '{}' | j 'd["body"]["link"]')"
LINK_TOKEN="${LINK##*flow_token=}"
ANSWERS="$(st "$LEE_PK" '{"wf_op": "status"}'; st "$LEE_PK" "{\"wf_op\": \"unlock-status\", \"wf_unlock_id\": \"$U2\"}"; st "$SVC_PK" '{"wf_op": "alerts"}')"
check "L6: after a code email and a reset link, no answer carries the code, the link, the email or its address" \
  "$(printf '%s' "$ANSWERS" | grep -c -e E2E-CODE -e E2E-LINK -e "${LINK_TOKEN:-no-link}" -e 'lee@example.org' -e 'Your code')" 0
check "L6: (a link was made)" "$([ "${#LINK_TOKEN}" -gt 20 ] && echo yes)" yes

# ---- 7. the source's cap: ten wrong from one source hold every name there alike, and an unlock doesn't lift it
fc e "$OUT" signin pat "$PW_PAT" >/dev/null     # pat: the right password from E once (no exemption by name)
for i in 1 2 3 4 5 6 7 8 9 10; do fc e "$OUT" signin "stranger-$i" wrong >/dev/null; done
has "E: ten wrong for ten names: sam is held, with the source's words" "$(fc e "$OUT" signin sam "$PW_SAM" | result)" "$THROTTLED"
has "pat, who signed in from E before: the same answer" "$(fc e "$OUT" signin pat "$PW_PAT" | result)" "$THROTTLED"
has "a name nobody has: the same answer" "$(fc e "$OUT" signin nobody-else "$PW_PAT" | result)" "$THROTTLED"
check "an unlock of pat" "$(st "$PAT_PK" "{\"wf_op\": \"unlock\", \"wf_unlock_id\": \"$(uuid4)\", \"wf_requested_at\": \"$(nowiso)\"}" | j 'd["applied"]')" True
has "doesn't lift a source's hold" "$(fc e "$OUT" signin pat "$PW_PAT" | result)" "$THROTTLED"
check "pat from A meanwhile: not held" "$(fc a "$OUT" signin pat "$PW_PAT" | result)" "next:ak-stage-authenticator-validate:"
has "a throttle alert" "$(sql "select context->>'wf_kind' from authentik_events_event where action = 'custom_workforce_password_alert' and context->>'wf_conn' = '$E'")" throttled
has "and a spread alert for the source" "$(sql "select context->>'wf_kind' from authentik_events_event where action = 'custom_workforce_password_alert' and context->>'wf_conn' = '$E'")" connection-spread
check "each at most once an hour" "$(sql "select count(*) from authentik_events_event where action = 'custom_workforce_password_alert' and context->>'wf_conn' = '$E' group by context->>'wf_kind' order by 1 desc limit 1")" 1
# IPv6: thirty wrong from thirty /64s of one /48 tighten it (authentik keeps addresses as inet; <<= finds them).
for i in $(seq 1 30); do fc s "$IN" signin --headers "{\"X-Forwarded-For\": \"2001:db8:5:$i::1\"}" "v6-$i" wrong >/dev/null; done
has "a 31st /64 of that /48, never seen: refused with the network's words" "$(fc s "$IN" signin --headers '{"X-Forwarded-For": "2001:db8:5:ff::1"}' kim "$PW_KIM" | result)" "$NETWORK"
has "another /48: not" "$(fc s "$IN" signin --headers '{"X-Forwarded-For": "2001:db8:6::1"}' kim "$PW_KIM" | result)" "next:ak-stage-authenticator-"
has "a spread alert for the /48" "$(sql "select context->>'wf_conn' from authentik_events_event where action = 'custom_workforce_password_alert' and context->>'wf_kind' = 'connection-spread'")" "2001:db8:5::/48"
check "and a network-tightened alert, once" "$(sql "select count(*) from authentik_events_event where action = 'custom_workforce_password_alert' and context->>'wf_kind' = 'network-tightened' and context->>'wf_conn' = '2001:db8:5::/48'")" 1
# Review finding 4: another /48 has 25 wrong from as many /64s, then eight more /64s try at one moment. The /48's lock
# counts them one at a time, so exactly five more are checked (thirty in all) and three (never-seen /64s of a
# tightened /48) get the network's words.
fc s "$IN" spray 25 8 2001:db8:7 wrong > "$WORK/spray.json"
check "25, then eight at once from one /48's /64s: exactly thirty recorded" "$(sql "select count(*) from authentik_events_event where action = 'custom_workforce_password_try' and client_ip <<= '2001:db8:7::/48'")" 30
check "and three refused, with the network's words" "$(count_words "$WORK/spray.json" "$NETWORK")" 3

# ---- 8. wrong codes: their own count, by account; passwords aren't touched
# authentik's own code step also slows down after wrong codes (django-otp: 16 s after the fifth), so the right code is
# typed once that has passed: the code step accepts it, and the check after it (31) still refuses.
fc a "$OUT" code pat "$PW_PAT" 000000 000001 000002 000003 000004 @wait34 @totp > "$WORK/codes.json"
check "five wrong codes, then the right one: refused after the code" "$(j 'd[-1]["result"] + ":" + d[-1]["message"][:28]' < "$WORK/codes.json")" "denied:That code was wrong too many"
check "five code tries recorded" "$(sql "select count(*) from authentik_events_event where action = 'custom_workforce_code_try' and (context->>'wf_user_pk')::int = $PAT_PK")" 5
r="$(fc b "$OUT" signin pat "$PW_PAT" | result)"
check "pat's password still goes on (to the code step, whose wait still holds)" "${r%%:*}" denied
has "with the codes' words, not the passwords'" "$r" "That code was wrong too many times"

# A right code is marked right, so it never counts towards the wait: with the wrong ones 16 minutes old, pat signs in
# with a code (a new one: authentik never takes the same code twice) and nothing is left counted against it.
sql "update authentik_events_event set created = created - interval '16 minutes' where action like 'custom_workforce_code_%' and (context->>'wf_user_pk')::int = $PAT_PK" >/dev/null
fc a "$OUT" code pat "$PW_PAT" @wait31 @totp > "$WORK/code-ok.json"
check "after the wait, the right code signs pat in" "$(j 'd[-1]["result"] + ":" + d[-1]["component"]' < "$WORK/code-ok.json")" "next:xak-flow-redirect"
check "and only that code is marked right (the flow plan keeps the try; the one typed while paused counts nowhere)" "$(sql "select count(*) from authentik_events_event where action = 'custom_workforce_code_right' and (context->>'wf_user_pk')::int = $PAT_PK")" 1

# ---- 9. the emergency administrator: its password rule in the real flows; reset-admin.sh lifts its pause
LINK="$(fc d "$IN" api POST "/api/v3/core/users/$ADMIN_PK/recovery/" "$TOKEN" '{}' | j 'd["body"]["link"]')"
FT="${LINK##*flow_token=}"
fc a "$OUT" recovery "$FT" "Kestrel12!" passwordpassword "violet tractor ocean pebble lantern" > "$WORK/rec.json"
check "reset link: the new-password page opens" "$(j 'd[0]["component"]' < "$WORK/rec.json")" ak-stage-prompt
has "reset link: 10 characters refused for admin" "$(j 'd[1]["message"]' < "$WORK/rec.json")" "needs at least 16 characters"
has "reset link: 16 easy ones refused" "$(j 'd[2]["message"]' < "$WORK/rec.json")" "too easy to guess"
check "reset link: five unrelated words accepted" "$(j 'd[3]["result"]' < "$WORK/rec.json")" next
NEW_ADMIN="violet tractor ocean pebble lantern"
fc b "$OUT" change admin "$NEW_ADMIN" workforce-password-change "Kestrel12!" > "$WORK/chg.json"
check "admin signs in with it (no code)" "$(j 'd[0]["result"]' < "$WORK/chg.json")" next
has "account menu: 10 characters refused for admin" "$(j 'd[2]["message"]' < "$WORK/chg.json")" "needs at least 16 characters"
fc b "$OUT" change admin "$NEW_ADMIN" default-password-change > "$WORK/def.json"
has "authentik's own change-password page refuses admin" "$(j 'd[1]["message"]' < "$WORK/def.json")" "Workforce's account menu"
# Fresh connections F and G (A, B and C carry the earlier tests' wrong tries, which count towards a throttle).
for i in 1 2 3 4 5; do fc f "$OUT" signin admin "wrong-$i" >/dev/null; done
has "admin paused on F" "$(fc f "$OUT" signin admin "$NEW_ADMIN" | result)" "$PAUSED"
check "admin from G: not paused" "$(fc g "$OUT" signin admin "$NEW_ADMIN" | j 'd["result"]')" next
# reset-admin.sh's program, exactly as the script passes it to the container (the real database this time).
python3 - "$REPO/bin/reset-admin.sh" "$WORK/reset.sh-c" <<'PY' || die "reset-admin.sh's program not found"
import re, sys
m = re.search(r"authentik-server sh -c \\\n  '(.*?)' 2>&1 \| tail -1\)\"", open(sys.argv[1], encoding="utf-8").read(), re.S)
if not m:
    sys.exit(1)
open(sys.argv[2], "w").write(m.group(1))
PY
RESET_PW="reset-$(openssl rand -hex 12)"
r="$(docker exec -e WF_NEW_PW="$RESET_PW" "$P-server" sh -c "$(cat "$WORK/reset.sh-c")" 2>&1 | tail -1)"
check "reset-admin.sh: OK" "$r" OK
check "reset-admin.sh: an unlock record is written for admin (contract R.7.4), by the server's clock" "$(sql "select count(*) from authentik_events_event where action = 'custom_workforce_password_unlock' and (context->>'wf_user_pk')::int = $ADMIN_PK and context->>'wf_at' like '20%Z'")" 1
check "reset-admin.sh: no account carries the old unlock attribute" "$(sql "select count(*) from authentik_core_user where attributes->'workforce' ? 'password_unlocked_at'")" 0
check "after reset-admin.sh, admin signs in from F" "$(fc f "$OUT" signin admin "$RESET_PW" | j 'd["result"]')" next


# ---- 10. L2 (the owner's decision 2): a username and its email counted apart, inside the source's cap of 10
# answers <source> <name> <n>: n wrong passwords for one name, one answer a line
answers() { local i; for i in $(seq 1 "$3"); do via "$1" "$2" "wrong-$i"; done; }
REAL="$(answers 192.0.2.160 kit 5; via 192.0.2.160 kit wrong-6; answers 192.0.2.160 kit.work@example.org 5; via 192.0.2.160 kit.work@example.org wrong-6; via 192.0.2.160 sam "$PW_SAM")"
UNKNOWN="$(answers 192.0.2.161 kate 5; via 192.0.2.161 kate wrong-6; answers 192.0.2.161 kate.work@example.org 5; via 192.0.2.161 kate.work@example.org wrong-6; via 192.0.2.161 sam "$PW_SAM")"
check "L2: five as the username, all checked; the sixth: that name paused" "$(printf '%s\n' "$REAL" | sed -n '1,6p' | cut -d: -f1 | paste -sd' ' -)" "error error error error error denied"
has "L2: (with the pause's words)" "$(printf '%s\n' "$REAL" | sed -n 6p)" "$PAUSED"
check "L2: five as its email, all checked (the email counts apart)" "$(printf '%s\n' "$REAL" | sed -n '7,11p' | cut -d: -f1 | paste -sd' ' -)" "error error error error error"
has "L2: then the source holds at 10, for every name" "$(printf '%s\n' "$REAL" | sed -n 12p)" "$THROTTLED"
has "L2: a colleague's right password there too" "$(printf '%s\n' "$REAL" | sed -n 13p)" "$THROTTLED"
check "L2: ten recorded: five under each name" "$(trycount 192.0.2.160) $(sql "select count(distinct context->>'wf_account') from authentik_events_event where action = 'custom_workforce_password_try' and context->>'wf_conn' = '192.0.2.160'")" "10 2"
check "L2: an unknown username and email get exactly the same answers, step by step" "$UNKNOWN" "$REAL"
# Byte for byte (the typed name aside), and how long each took: an unknown username and email beside real ones.
# norm <trace> <typed name>: the answers with the typed name replaced, and the avatar too when it is exactly the one
# authentik draws from the typed name (its initials and its colour, from an MD5 of the name), never from the account
# (a real account's display name, Kim Example, would draw "KE" in another colour and so tell that it exists).
norm() { NAME="$2" python3 -c '
import base64, hashlib, json, os, re, sys
d = json.loads(sys.stdin.read()); n = os.environ["NAME"]
c = int(hashlib.md5(n.lower().encode()).hexdigest(), 16) % 0xFFFFFF
colour = "#%02x%02x%02x" % tuple(min(max((c >> s) & 0xFF, 55), 200) for s in (16, 8, 0))
out = []
for x in d:
    body = json.loads(x["body"])
    av = body.get("pending_user_avatar")
    if isinstance(av, str) and av.startswith("data:image/svg+xml;base64,"):
        svg = base64.b64decode(av.split(",", 1)[1]).decode()
        if re.search(r"fill=\"" + colour + r"\"", svg) and re.search(r">" + re.escape(n.split()[0][:2].upper()) + r"</text>", svg):
            body["pending_user_avatar"] = "<AVATAR OF NAME>"
    out.append([x["status"], json.dumps(body, sort_keys=True).replace(n, "<NAME>")])
print(json.dumps(out))' <<< "$1"; }
secs() { j 'round(d[2]["seconds"], 3)' <<< "$1"; }
T_REAL="$(fc s "$IN" trace --headers "$(xff 192.0.2.162)" kim wrong-x)"; T_UNK="$(fc s "$IN" trace --headers "$(xff 192.0.2.163)" kimx wrong-x)"
check "L2: an unknown username's answers are a real one's, byte for byte (the typed name, and the avatar drawn from it, aside)" "$(norm "$T_UNK" kimx)" "$(norm "$T_REAL" kim)"
has "L2: (the avatar is drawn from the typed name, not the account)" "$(norm "$T_REAL" kim)" "<AVATAR OF NAME>"
M_REAL="$(fc s "$IN" trace --headers "$(xff 192.0.2.164)" kim@example.org wrong-x)"; M_UNK="$(fc s "$IN" trace --headers "$(xff 192.0.2.165)" kix@example.org wrong-x)"
check "L2: an unknown email's are a real email's" "$(norm "$M_UNK" kix@example.org)" "$(norm "$M_REAL" kim@example.org)"
# The time of the password step (review of 15 November 2026, findings 1 and 14): seven samples of each, interleaved,
# each from a new source (so no pause or cap is reached), compared by their medians. One more password hash for
# unknown names (authentik's TokenBackend did that until it was taken off the stage) made them about 1.6 times
# slower; a factor of 3 let that through. Now each pair of medians must be within 25% of each other.
: > "$WORK/l2-times"
for n in 1 2 3 4 5 6 7; do
  k=0
  for name in kim kimx kim@example.org kix@example.org; do
    printf '%s %s\n' "$k" "$(secs "$(fc s "$IN" trace --headers "$(xff "192.0.2.$((196 + 4 * n + k))")" "$name" wrong-t)")" >> "$WORK/l2-times"
    k=$((k + 1))
  done
done
L2_MEDIANS="$(python3 -c '
import statistics, sys
t = {}
for line in open(sys.argv[1]):
    k, s = line.split()
    t.setdefault(int(k), []).append(float(s))
print(" ".join("%.3f" % statistics.median(t[k]) for k in range(4)))' "$WORK/l2-times")"
echo "     L2 password step, median of 7 (real name, unknown name, real email, unknown email), seconds: $L2_MEDIANS"
check "L2: an unknown name and email take as long as real ones (medians within 25%, all under 10 s)" \
  "$(python3 -c 'import sys; r, u, re_, ue = (float(x) for x in sys.argv[1:]); print(max(r, u, re_, ue) < 10 and max(r, u) <= 1.25 * min(r, u) and max(re_, ue) <= 1.25 * min(re_, ue))' $L2_MEDIANS)" True

# ---- 11. L3 (decision 1): what "connection" means; forged headers can't claim a workplace; requests at one moment
fc h "$OUT" many 10 "l3-%d" wrong > "$WORK/l3.json"
check "L3: through the gateway, ten tries, each a new TCP connection, cookie jar and flow: all checked" "$(count_checked "$WORK/l3.json")" 10
check "L3: every one recorded under H's own address" "$(trycount "$H")" 10
has "L3: the 11th (a new connection again, a real name, its right password): held, with the source's words" "$(fc h "$OUT" signin kim "$PW_KIM" | result)" "$THROTTLED"
check "L3: and not recorded" "$(trycount "$H")" 10
fc i "$OUT" many 10 "forged-%d" wrong 203.0.113.70 > "$WORK/forged.json"
check "a forged X-Forwarded-For naming a confirmed workplace address: the tries are the forger's own" "$(trycount "$I")/$(trycount 203.0.113.70)" "10/0"
has "and held at the ordinary cap of 10, not the workplace's 50" "$(fc i "$OUT" signin --headers '{"X-Forwarded-For": "203.0.113.70"}' kim "$PW_KIM" | result)" "$THROTTLED"
fc s "$IN" burstnames --headers "$(xff 192.0.2.170)" 25 "sim-%d" wrong > "$WORK/sim.json"
check "L3: 25 names at one moment from one source: exactly 10 recorded" "$(trycount 192.0.2.170)" 10
check "L3: 10 checked, 15 refused, none further" "$(count_checked "$WORK/sim.json") $(j 'sum(1 for x in d if x and x["result"] == "denied")' < "$WORK/sim.json") $(j 'sum(1 for x in d if not x or x["result"] == "next")' < "$WORK/sim.json")" "10 15 0"

# ---- 12. L1 (the owner's instruction B): a colleague behind the same address while someone there attacks
fc j "$OUT" many 9 "l1-%d" wrong >/dev/null
check "L1: nine wrong from J (through the gateway, any names)" "$(trycount "$J")" 9
check "L1: below the cap, a colleague on the same address completes a sign-in (password and code)" "$(complete j "$OUT" "" pat "$PW_PAT" totp.key)" "$DONE"
fc j "$OUT" signin l1-x wrong >/dev/null
check "L1: the tenth counted" "$(trycount "$J")" 10
has "L1: at the cap the colleague is refused, with the source's words" "$(fc j "$OUT" signin pat "$PW_PAT" | result)" "$THROTTLED"
check "L1: and signs in at once from another connection" "$(complete k "$OUT" "" pat "$PW_PAT" totp.key)" "$DONE"
fc j "$OUT" many 5 "l1-more-%d" wrong >/dev/null
check "L1: the attack goes on: refused, so never counted" "$(trycount "$J")" 10
age_source "$J" "14 minutes 50 seconds"
has "L1: 14 min 50 s after the try that reached the cap: still refused" "$(fc j "$OUT" signin pat "$PW_PAT" | result)" "$THROTTLED"
fc j "$OUT" many 3 "l1-late-%d" wrong >/dev/null
age_source "$J" "15 minutes 1 second"
check "L1: 15 min 1 s after it, the attack still going: the colleague completes a sign-in from J" "$(complete j "$OUT" "" pat "$PW_PAT" totp.key)" "$DONE"
# Review of 15 November 2026, finding 10: that attacker was paced. One that sends again the moment the hold ends
# re-holds the source within a second, so a colleague there gets in only by winning that race; the way out is another
# connection (contract R.5: the maximum disruption lasts as long as the attack).
fc j "$OUT" many 10 "l1-rearm-%d" wrong > "$WORK/rearm.json"
check "L1: an attacker re-arming the moment it ends: ten counted again at once" "$(count_checked "$WORK/rearm.json")" 10
has "L1: and the colleague is refused there again straight away" "$(fc j "$OUT" signin pat "$PW_PAT" | result)" "$THROTTLED"
check "L1: while another connection still signs in" "$(complete k "$OUT" "" pat "$PW_PAT" totp.key)" "$DONE"
echo "     L1 measured on one IPv4 address: no wait below the cap; at the cap refused until 15 minutes after the try that reached it (refused at 14 min 50 s, in at 15 min 1 s against a paced attacker); refused requests never moved it; an attacker re-arming at expiry re-held it at once, and the colleague got in only from another connection"
# The same on one IPv6 /64 (two addresses of it), and another /64 of the same /48 at once.
fc s "$IN" many 9 "l1v6-%d" wrong 2001:db8:a1:1::10 >/dev/null
check "L1 /64: below the cap, a colleague on another address of the /64 completes a sign-in" "$(complete s "$IN" "$(xff 2001:db8:a1:1::20)" sam "$PW_SAM" totp-sam.key)" "$DONE"
via 2001:db8:a1:1::10 l1v6-x wrong >/dev/null
has "L1 /64: at the cap, refused" "$(via 2001:db8:a1:1::20 sam "$PW_SAM")" "$THROTTLED"
check "L1 /64: another /64 of the same /48: at once" "$(complete s "$IN" "$(xff 2001:db8:a1:2::20)" sam "$PW_SAM" totp-sam.key)" "$DONE"
fc s "$IN" many 3 "l1v6-more-%d" wrong 2001:db8:a1:1::10 >/dev/null
check "L1 /64: refused, not counted" "$(trycount 2001:db8:a1:1::/64)" 10
age_source 2001:db8:a1:1::/64 "15 minutes 1 second"
check "L1 /64: 15 minutes after the cap: in" "$(complete s "$IN" "$(xff 2001:db8:a1:1::20)" sam "$PW_SAM" totp-sam.key)" "$DONE"
# The owner's Q3: three people's completed sign-ins make a source proven, never a workplace: it holds at 10.
WP=198.51.100.200
for who in "pat $PW_PAT totp.key" "sam $PW_SAM totp-sam.key" "kim $PW_KIM totp-kim.key"; do
  set -- $who
  check "L1 Q3: $1 completes a sign-in at a source nobody confirmed" "$(complete s "$IN" "$(xff $WP)" "$1" "$2" "$3")" "$DONE"
done
check "L1 Q3: three people's completed sign-ins recorded there" "$(sql "select count(distinct context->>'wf_user_pk') from authentik_events_event where action = 'custom_workforce_signed_in' and context->>'wf_conn' = '$WP'")" 3
fc s "$IN" many 10 "wp-%d" wrong "$WP" > "$WORK/wp.json"
check "L1 Q3: ten wrong there, every one checked" "$(count_checked "$WORK/wp.json")" 10
has "L1 Q3: no workplace: the 10th holds it, with the source's words" "$(via "$WP" kim "$PW_KIM")" "$THROTTLED"
check "L1 Q3/Q5: its alert is throttled (no workplace) and names the people who completed sign-ins there" \
  "$(sql "select context->>'wf_workplace' || ' ' || (select string_agg(x::text, ',' order by x::int) from jsonb_array_elements_text(context->'wf_affected_pks') x) from authentik_events_event where action = 'custom_workforce_password_alert' and context->>'wf_kind' = 'throttled' and context->>'wf_conn' = '$WP'")" \
  "false $(printf '%s\n' "$PAT_PK" "$SAM_PK" "$KIM_PK" | sort -n | paste -sd, -)"
check "L1 Q3: and no workplace-throttled alert for it" "$(sql "select count(*) from authentik_events_event where action = 'custom_workforce_password_alert' and context->>'wf_kind' = 'workplace-throttled' and context->>'wf_conn' = '$WP'")" 0
# A confirmed office (CLIENT_ADDRESSES_CONFIRMED, 203.0.113.64/28): its cap is 50, not 10 and not none.
CO=203.0.113.70
for who in "pat $PW_PAT totp.key" "sam $PW_SAM totp-sam.key" "kim $PW_KIM totp-kim.key"; do
  set -- $who
  check "L1 confirmed office: $1 completes a sign-in there" "$(complete s "$IN" "$(xff $CO)" "$1" "$2" "$3")" "$DONE"
done
fc s "$IN" many 49 "office-%d" wrong "$CO" > "$WORK/co.json"
check "L1 confirmed office: 49 wrong, every one checked" "$(count_checked "$WORK/co.json")" 49
has "L1 confirmed office: staff still sign in there" "$(via "$CO" kim "$PW_KIM")" "next:ak-stage-authenticator-"
via "$CO" office-50 wrong >/dev/null
has "L1 confirmed office: the 50th holds it, with the source's words" "$(via "$CO" kim "$PW_KIM")" "$THROTTLED"
check "L1 confirmed office: alert workplace-throttled, naming the people who sign in there" \
  "$(sql "select context->>'wf_workplace' || ' ' || (select string_agg(x::text, ',' order by x::int) from jsonb_array_elements_text(context->'wf_affected_pks') x) from authentik_events_event where action = 'custom_workforce_password_alert' and context->>'wf_kind' = 'workplace-throttled' and context->>'wf_conn' = '$CO'")" \
  "true $(printf '%s\n' "$PAT_PK" "$SAM_PK" "$KIM_PK" | sort -n | paste -sd, -)"

# ---- 13. L4 (decision 1, instruction C): a large workplace /48, one malicious source, then rotating /64s. The /48 is a
# workplace network only through the operator's confirmed /56 (2001:db8:100::/56; the owner's Q3), whose /64s are
# neither workplace nor proven sources for that: staff's /64s are proven by their own completed sign-ins.
W=2001:db8:100
for who in "pat $PW_PAT totp.key 1" "sam $PW_SAM totp-sam.key 2" "kim $PW_KIM totp-kim.key 3"; do
  set -- $who
  check "L4: $1 completes a sign-in on /64 $4 of the workplace /48" "$(complete s "$IN" "$(xff "$W:$4::5")" "$1" "$2" "$3")" "$DONE"
done
fc s "$IN" many 12 "l4m-%d" wrong "$W:66::1" > "$WORK/l4m.json"
check "L4: one malicious source in it: ten checked, then held" "$(count_checked "$WORK/l4m.json") $(count_words "$WORK/l4m.json" "$THROTTLED")" "10 2"
check "L4: staff on another /64 complete sign-ins meanwhile" "$(complete s "$IN" "$(xff "$W:2::5")" sam "$PW_SAM" totp-sam.key)" "$DONE"
has "L4: a quiet /64 nobody has used: the right password goes on" "$(via "$W:77::1" kim "$PW_KIM")" "next:ak-stage-authenticator-"
check "L4: one source can't tighten the /48" "$(sql "select count(*) from authentik_events_event where action = 'custom_workforce_password_alert' and context->>'wf_kind' = 'network-tightened' and context->>'wf_conn' = '$W::/48'")" 0
# Rotating /64s: 290 more, ten from each of 29 /64s: each is held at its own 10, and the /48's 300th tightens it.
# Four clients at once (each /64 in one of them), so that all 290 fall within 15 minutes on a busy machine.
# Meanwhile (review of 15 November 2026, findings 4 and 15) staff on two proven /64s of the same /48 keep typing their
# right passwords: none may be refused because the attack's tries are being counted (a lock wait of 5 s, or a slow
# read, fails closed with the pause's words).
fc s "$IN" many 80 "l4r0-%d" wrong "$W:%x::1" 10 512 > "$WORK/l4r0.json" &
fc s "$IN" many 70 "l4r1-%d" wrong "$W:%x::1" 10 520 > "$WORK/l4r1.json" &
fc s "$IN" many 70 "l4r2-%d" wrong "$W:%x::1" 10 527 > "$WORK/l4r2.json" &
fc s "$IN" many 70 "l4r3-%d" wrong "$W:%x::1" 10 534 > "$WORK/l4r3.json" &
( for n in 1 2 3 4 5 6; do
    t0=$(date +%s.%N); r="$(via "$W:2::5" sam "$PW_SAM")"; printf '%s %s\n' "${r%%:*}:$(printf '%s' "$r" | cut -d: -f2)" "$(awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN {printf "%.2f", b - a}')"
    t0=$(date +%s.%N); r="$(via "$W:3::5" kim "$PW_KIM")"; printf '%s %s\n' "${r%%:*}:$(printf '%s' "$r" | cut -d: -f2)" "$(awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN {printf "%.2f", b - a}')"
  done > "$WORK/l4staff" ) &
wait
check "L4 load: twelve right passwords on proven /64s while 290 wrong ones were counted in the /48: none refused" \
  "$(grep -c '^next:ak-stage-authenticator-' "$WORK/l4staff")/$(wc -l < "$WORK/l4staff")" "12/12"
echo "     L4 load: staff password steps during the flood, slowest $(sort -k2 -n "$WORK/l4staff" | tail -n 1 | cut -d' ' -f2) s; answers: $(cut -d' ' -f1 "$WORK/l4staff" | sort | uniq -c | paste -sd' ' -)"
check "L4: 290 from 29 rotating /64s, all checked (each /64 holds only at its own 10)" \
  "$(( $(count_checked "$WORK/l4r0.json") + $(count_checked "$WORK/l4r1.json") + $(count_checked "$WORK/l4r2.json") + $(count_checked "$WORK/l4r3.json") ))" 290
check "L4: the /48's 300th tightens it (a workplace network): one alert" "$(sql "select count(*) || ' ' || min(context->>'wf_workplace') from authentik_events_event where action = 'custom_workforce_password_alert' and context->>'wf_kind' = 'network-tightened' and context->>'wf_conn' = '$W::/48'")" "1 true"
check "L4 Q5: and it names the people who completed sign-ins in the /48" \
  "$(sql "select (select string_agg(x::text, ',' order by x::int) from jsonb_array_elements_text(context->'wf_affected_pks') x) from authentik_events_event where action = 'custom_workforce_password_alert' and context->>'wf_kind' = 'network-tightened' and context->>'wf_conn' = '$W::/48'")" \
  "$(printf '%s\n' "$PAT_PK" "$SAM_PK" "$KIM_PK" | sort -n | paste -sd, -)"
has "L4: a /64 never seen before: refused, with the network's words" "$(via "$W:88::1" kim "$PW_KIM")" "$NETWORK"
check "L4: staff on a proven /64 carry on (a whole sign-in)" "$(complete s "$IN" "$(xff "$W:3::5")" kim "$PW_KIM" totp-kim.key)" "$DONE"
# Abusive: a proven /64 (pat signed in there; that right password moved back 20 minutes) with five wrong and no right.
sql "update authentik_events_event set created = created - interval '20 minutes' where action = 'custom_workforce_password_right' and context->>'wf_conn' in ('$W:1::/64', '$W:3::/64')" >/dev/null
fc s "$IN" many 5 "l4a-%d" wrong "$W:1::9" > "$WORK/l4a.json"
check "L4: a proven /64's five wrong in the tightened /48: checked (it isn't abusive until then)" "$(count_checked "$WORK/l4a.json")" 5
has "L4: then it is: refused, with the network's words" "$(via "$W:1::5" pat "$PW_PAT")" "$NETWORK"
fc s "$IN" many 4 "l4b-%d" wrong "$W:3::9" >/dev/null
has "L4: another proven /64 with four: carries on" "$(via "$W:3::5" kim "$PW_KIM")" "next:ak-stage-authenticator-"
# Review of 15 November 2026, finding 2: a right password no longer excuses a source nobody confirmed. Someone with an
# account who proves a /64 and types their own right password still gets no more than four wrong there.
has "L4 insider: sam's right password from a proven /64" "$(via "$W:2::5" sam "$PW_SAM")" "next:ak-stage-authenticator-"
fc s "$IN" many 5 "l4i-%d" wrong "$W:2::9" > "$WORK/l4i.json"
check "L4 insider: then five wrong there, checked" "$(count_checked "$WORK/l4i.json")" 5
has "L4 insider: and refused, with the network's words, the right password notwithstanding" "$(via "$W:2::5" sam "$PW_SAM")" "$NETWORK"
age_net "$W::/48" "14 minutes 50 seconds"
has "L4: 14 min 50 s after the newest counted try: still tightened" "$(via "$W:88::1" kim "$PW_KIM")" "$NETWORK"
age_net "$W::/48" "15 minutes 1 second"
has "L4: 15 minutes after it: lifted" "$(via "$W:88::1" kim "$PW_KIM")" "next:ak-stage-authenticator-"
# An ordinary /48: three people complete sign-ins on three of its /64s, which makes them proven and the /48 no
# workplace network (the owner's Q3); thirty from rotating /64s tighten it.
O=2001:db8:200
for who in "kim $PW_KIM totp-kim.key 1" "pat $PW_PAT totp.key 2" "sam $PW_SAM totp-sam.key 3"; do
  set -- $who
  check "L4 ordinary /48: $1 completes a sign-in on /64 $4" "$(complete s "$IN" "$(xff "$O:$4::5")" "$1" "$2" "$3")" "$DONE"
done
fc s "$IN" many 30 "l4o-%d" wrong "$O:%x::1" 1 16 > "$WORK/l4o.json"
check "L4 ordinary /48: thirty from thirty /64s, all checked" "$(count_checked "$WORK/l4o.json")" 30
check "L4 Q3: three people's completed sign-ins made no workplace network: tightened at 30" "$(sql "select count(*) || ' ' || min(context->>'wf_workplace') from authentik_events_event where action = 'custom_workforce_password_alert' and context->>'wf_kind' = 'network-tightened' and context->>'wf_conn' = '$O::/48'")" "1 false"
has "L4 ordinary /48: a never-seen /64 is refused, with the network's words" "$(via "$O:ff::1" kim "$PW_KIM")" "$NETWORK"
has "L4 ordinary /48: the proven, quiet /64 carries on" "$(via "$O:1::5" kim "$PW_KIM")" "next:ak-stage-authenticator-"
age_net "$O::/48" "15 minutes 1 second"
has "L4 ordinary /48: 15 minutes after the newest counted try: lifted" "$(via "$O:ff::1" kim "$PW_KIM")" "next:ak-stage-authenticator-"

# ---- 14. the alerts, as the application reads them (contract R.7.2 "alerts"), and doctor.sh's counts (contract 2.3 b)
r="$(st "$SVC_PK" '{"wf_op": "alerts", "wf_limit": 200}')"
for kind in connection-spread throttled workplace-throttled network-tightened; do
  has "alerts: $kind among them" "$(printf '%s' "$r" | j 'sorted(set(a["kind"] for a in d["alerts"]))')" "'$kind'"
done
check "alerts: the workplace's names the people who sign in there" "$(printf '%s' "$r" | j '[sorted(a["affectedPks"]) for a in d["alerts"] if a["kind"] == "workplace-throttled"][0]')" "$(python3 -c 'import sys; print(sorted(int(x) for x in sys.argv[1:]))' "$PAT_PK" "$SAM_PK" "$KIM_PK")"
check "alerts: no typed name in them" "$(printf '%s' "$r" | grep -c -E 'stranger|visitor|kate|l4m-|wp-|office-|nobody')" 0
check "alerts Q5: a throttled source where people completed sign-ins names them, and is no workplace (Q3)" \
  "$(printf '%s' "$r" | j '[(a["workplace"], sorted(a["affectedPks"])) for a in d["alerts"] if a["kind"] == "throttled" and a["source"] == "'"$WP"'"][0]')" \
  "(False, $(python3 -c 'import sys; print(sorted(int(x) for x in sys.argv[1:]))' "$PAT_PK" "$SAM_PK" "$KIM_PK"))"
check "alerts Q5: one where nobody did names nobody" "$(printf '%s' "$r" | j '[a["affectedPks"] for a in d["alerts"] if a["kind"] == "throttled" and a["source"] == "'"$H"'"][0]')" "[]"
FIRST="$(st "$SVC_PK" '{"wf_op": "alerts", "wf_limit": 1}')"
NEXT="$(printf '%s' "$FIRST" | j 'd["next"]')"
check "alerts: one at a time, the cursor moves on" "$(st "$SVC_PK" "{\"wf_op\": \"alerts\", \"wf_limit\": 1, \"wf_after\": \"$NEXT\"}" | j 'd["alerts"][0]["id"]')" "$(printf '%s' "$r" | j 'd["alerts"][1]["id"]')"
CA_PROGRAM="$(bash -c '. "$1/bin/lib/client-address.sh"; printf "%s" "$CLIENT_ADDRESS_AK"' _ "$REPO")"
CA_LIVE="$(docker exec -i "$P-server" ak shell -c "$CA_PROGRAM" 2>/dev/null | grep -E '^WF(CONN|SIGNINS|INSUM|FWD|ALERTS|CRED) ')"
check "doctor.sh's program: Workforce's account has no event access and no other group" "$(printf '%s\n' "$CA_LIVE" | grep '^WFCRED ')" "WFCRED ok"
check "doctor.sh's program: its summaries first (review finding 9)" "$(printf '%s\n' "$CA_LIVE" | head -n 4 | cut -d' ' -f1 | paste -sd' ' -)" "WFSIGNINS WFINSUM WFFWD WFALERTS"
has "doctor.sh's program: sign-ins from A, by connection key" "$CA_LIVE" "WFCONN $A in "
has "the IPv6 tries by /64" "$CA_LIVE" "WFCONN 2001:db8:5:1::/64 try "
has "the forwarded sign-in counted" "$CA_LIVE" "WFFWD 1 $A"
check "the alerts counted, workplace and network ones too" "$(printf '%s\n' "$CA_LIVE" | grep -c '^WFALERTS [1-9][0-9]* [0-9]* [1-9][0-9]* [1-9][0-9]* [1-9][0-9]*$')" 1
check "no name in it" "$(printf '%s\n' "$CA_LIVE" | grep -c -E 'pat|sam|kim|nobody|stranger|visitor')" 0

# ---- 15. L7 on an upgraded install: a build that granted view_event (ab1d474's script), then this one
OLD_SA="$(git -C "$REPO" show ab1d474:ansible/roles/authentik/files/invite-service-account.py 2>/dev/null)"
if [ -z "$OLD_SA" ]; then
  echo "     (ab1d474 isn't in this checkout: its grant is made directly instead)"
  OLD_SA='from authentik.rbac.models import Role
Role.objects.get(name="workforce-invites").assign_perms("authentik_events.view_event")
print("workforce-invites converged")'
fi
check "L7 upgrade: the earlier build's script runs" "$(converge_sa "$OLD_SA" | grep -c 'workforce-invites converged')" 1
r="$(fc d "$IN" api GET "/api/v3/events/events/$EV/" "$TOKEN")"
check "L7 upgrade: with it, the token reads an email_sent event, its body and code included (the exposure)" "$(printf '%s' "$r" | j 'd["status"]')/$(printf '%s' "$r" | grep -c E2E-CODE)" "200/1"
akshell "
from authentik.events.models import Event
from authentik.rbac.models import Role
Role.objects.get(name='workforce-invites').assign_perms('authentik_events.view_event', Event.objects.get(pk='$EV'))
print('object grant made')" >/dev/null
check "L7 upgrade: this build's script runs" "$(converge_sa "$NEW_SA" | grep -c 'workforce-invites converged')" 1
check "L7 upgrade: that event is refused now" "$(fc d "$IN" api GET "/api/v3/events/events/$EV/" "$TOKEN" | j 'd["status"] in (403, 404)')" True
check "L7 upgrade: and the list" "$(fc d "$IN" api GET "/api/v3/events/events/?page_size=5" "$TOKEN" | j 'd["status"]')" 403
check "L7 upgrade: no view_event left, globally or on any object" "$(akshell "
from authentik.core.models import User
from guardian.models import RoleObjectPermission
u = User.objects.get(username='workforce-invites')
print('PERM', u.has_perm('authentik_events.view_event'), RoleObjectPermission.objects.filter(role__in=u.all_roles(), permission__codename='view_event').count())" | sed -n 's/^PERM //p')" "False 0"
check "L7 upgrade: the status interface still answers" "$(st "$LEE_PK" '{"wf_op": "status"}' | j 'd["known"]')" True
# Review of 15 November 2026, finding 5: the application's token holds change_user, and authentik 2026.8.5 refuses
# only superuser groups, so the token may add itself to a group an operator made later with view_event. Whatever
# authentik answers, doctor.sh's "sign-in server account" row (the WFCRED line) must see the result on its next run.
LEAK_IDS="$(akshell "
from authentik.core.models import Group
from authentik.rbac.models import Role
r, _ = Role.objects.get_or_create(name='e2e-leak'); r.assign_perms('authentik_events.view_event')
g, _ = Group.objects.get_or_create(name='e2e-leak'); g.roles.add(r)
print('IDS', g.pk, Group.objects.get(name='workforce-invites').pk)" | sed -n 's/^IDS //p')"
read -r LEAK_GROUP OWN_GROUP <<< "$LEAK_IDS"
code="$(fc d "$IN" api PATCH "/api/v3/core/users/$SVC_PK/" "$TOKEN" "{\"groups\": [\"$OWN_GROUP\", \"$LEAK_GROUP\"]}" | j 'd["status"]')"
echo "     L5 groups: the application's token adding itself to a group with view_event: HTTP $code"
CRED="$(docker exec -i "$P-server" ak shell -c "$CA_PROGRAM" 2>/dev/null | sed -n 's/^WFCRED //p')"
if [ "$code" = 200 ]; then
  check "L5 groups: authentik took it, and doctor.sh's program names it at once" "$CRED" "view_event,groups"
else
  check "L5 groups: refused, and doctor.sh's program still finds nothing" "$CRED" ok
fi
check "L7: the script fails, rather than carrying on, when another role still gives view_event" "$(akshell "
from authentik.core.models import Group, User
from authentik.rbac.models import Role
r, _ = Role.objects.get_or_create(name='e2e-leak'); r.assign_perms('authentik_events.view_event')
g, _ = Group.objects.get_or_create(name='e2e-leak'); g.roles.add(r); g.users.add(User.objects.get(username='workforce-invites'))
print('leak made')" >/dev/null; converge_sa "$NEW_SA" | grep -c 'may read every authentik event')" 1
akshell "
from authentik.core.models import Group
from authentik.rbac.models import Role
Group.objects.filter(name='e2e-leak').delete(); Role.objects.filter(name='e2e-leak').delete()
print('leak removed')" >/dev/null
check "L7: and passes once it is gone" "$(converge_sa "$NEW_SA" | grep -c 'workforce-invites converged')" 1
check "L7: and doctor.sh's program finds nothing again" "$(docker exec -i "$P-server" ak shell -c "$CA_PROGRAM" 2>/dev/null | sed -n 's/^WFCRED //p')" ok

# ---- 16. L8: the status interface broken, then deleted: the sign-in decisions don't change
SAM_SRC=192.0.2.190
for i in 1 2 3 4 5; do via "$SAM_SRC" sam "wrong-$i" >/dev/null; done
has "L8: sam paused on one source" "$(via "$SAM_SRC" sam "$PW_SAM")" "$PAUSED"
akshell "
from authentik.core.models import PropertyMapping
PropertyMapping.objects.filter(pk='$SPK').update(expression='raise ValueError(\"broken\")')
print('broken')" >/dev/null
check "L8: broken: the application gets no answer it could take for 'not paused'" "$(st "$SAM_PK" '{"wf_op": "status"}' | j 'd.get("paused"), d.get("successful")')" "(None, False)"
has "L8: a paused pair is still refused" "$(via "$SAM_SRC" sam "$PW_SAM")" "$PAUSED"
has "L8: a right password elsewhere still goes on" "$(via 192.0.2.191 sam "$PW_SAM")" "next:ak-stage-authenticator-"
akshell "
from authentik.core.models import PropertyMapping
from authentik.policies.expression.models import ExpressionPolicy
PropertyMapping.objects.filter(pk='$SPK').delete(); ExpressionPolicy.objects.filter(name='workforce-sign-in-status-code').delete()
print('deleted')" >/dev/null
check "L8: deleted: no answer" "$(st "$SAM_PK" '{"wf_op": "status"}' | j 'd.get("http")')" 404
has "L8: a paused pair is still refused" "$(via "$SAM_SRC" sam "$PW_SAM")" "$PAUSED"
has "L8: a right password elsewhere still goes on" "$(via 192.0.2.192 sam "$PW_SAM")" "next:ak-stage-authenticator-"
check "L8: and this build's script refuses to carry on without the status code" "$(converge_sa "$NEW_SA" | grep -c 'sign-in status code (workforce-sign-in-status-code) is missing')" 1

# ---- 17. Workforce issue 474: a sign-in held between its password step and the login can't outlive a password change.
# flow-client.py's hold sends the password, doesn't follow its answer, and waits for a go-ahead before going on, so the
# password is replaced while the sign-in is past the password step and short of the login. Each from a fresh source.
REPLACED="Invalid password. Please sign in again."
HELD_PID=""
hold() { # hold <mark> <source> <name> <password> [<key file>]: started in the background, waits until it is held
  local mark="$1" at="$2"; shift 2
  fc s "$IN" hold --headers "$(xff "$at")" "$1" "$2" "$mark" ${3:+"$3"} > "$WORK/$mark.json" &
  HELD_PID=$!
  for _ in $(seq 1 300); do [ -f "$WORK/state/$mark.held" ] && return 0; sleep 0.2; done
  die "the held sign-in $mark never reached its hold"
}
release() { touch "$WORK/state/$1.go"; wait "$HELD_PID"; }
# held_end <mark>: the password step's answer, the last step's result and words, and who the session is signed in as
held_end() { j '"%s|%s|%s|%s:%s" % (d[1]["status"], d[-2]["result"], d[-2].get("message", ""), d[-1]["status"], d[-1]["username"])' < "$WORK/$1.json"; }
admin_set() { # admin_set <new password>: reset-admin.sh's program, exactly as the script passes it to the container
  docker exec -e WF_NEW_PW="$1" "$P-server" sh -c "$(cat "$WORK/reset.sh-c")" 2>&1 | tail -1
}
hold h474a 192.0.2.201 admin "$RESET_PW"
release h474a
check "474: held, nothing changed: admin signs in" "$(held_end h474a)" "302|next||200:admin"
hold h474b 192.0.2.202 admin "$RESET_PW"
ADMIN_474="reset-$(openssl rand -hex 12)"
check "474: held, then reset-admin.sh sets a new password" "$(admin_set "$ADMIN_474")" OK
release h474b
check "474: the held sign-in is refused, with a wrong password's words, and nobody is signed in" "$(held_end h474b)" \
  "302|denied|$REPLACED|403:None"
check "474: the new password signs admin in" "$(fc s "$IN" signin --headers "$(xff 192.0.2.202)" admin "$ADMIN_474" | j 'd["result"] + ":" + d["component"]')" \
  "next:xak-flow-redirect"
# Staff, held before the code step: the same password chosen again (a new salt) is a change too.
hold h474c 192.0.2.203 pat "$PW_PAT" totp.key
akshell "
from authentik.core.models import User
u = User.objects.get(username='pat'); u.set_password('$PW_PAT'); u.save()
print('same password again')" >/dev/null
release h474c
check "474: pat, held, the same password set again: refused after the code, nobody signed in" "$(j '[x.get("step") for x in d]' < "$WORK/h474c.json")/$(held_end h474c)" \
  "['name', 'password', 'after', 'code', 'me']/302|denied|$REPLACED|403:None"
check "474: and pat signs in with it afresh" "$(complete s "$IN" "$(xff 192.0.2.203)" pat "$PW_PAT" totp.key)" "$DONE"
# The password disabled meanwhile (authentik's "no usable password").
hold h474d 192.0.2.204 admin "$ADMIN_474"
akshell "
from authentik.core.models import User
u = User.objects.get(username='admin'); u.set_unusable_password(); u.save()
print('disabled')" >/dev/null
release h474d
check "474: admin, held, its password disabled: refused, nobody signed in" "$(held_end h474d)" "302|denied|$REPLACED|403:None"
ADMIN_474="reset-$(openssl rand -hex 12)"
check "474: reset-admin.sh gives it a password again" "$(admin_set "$ADMIN_474")" OK
# The login step's own check (100): with the check at 99 bound to a policy that never refuses, a held sign-in whose
# password changed still signs nobody in (the login step is skipped), then 99 is put back.
swap474() { akshell "
from authentik.flows.models import FlowStageBinding
from authentik.policies.models import PolicyBinding
from authentik.policies.expression.models import ExpressionPolicy
b = FlowStageBinding.objects.get(target__slug='default-authentication-flow', order=99)
pb = PolicyBinding.objects.get(target=b, policy__name='$1')
pb.policy = ExpressionPolicy.objects.get(name='$2'); pb.save()
print('SWAPPED')" | grep -c '^SWAPPED$'; }
check "474: 99 set aside" "$(swap474 workforce-password-replaced workforce-no-first-run-page)" 1
hold h474e 192.0.2.205 admin "$ADMIN_474"
ADMIN_474B="reset-$(openssl rand -hex 12)"
check "474: held, then a new password" "$(admin_set "$ADMIN_474B")" OK
release h474e
check "474: 99 aside, the login step's own check: nobody signed in" "$(j 'd[-1]["status"]' < "$WORK/h474e.json")" 403
check "474: 99 put back" "$(swap474 workforce-no-first-run-page workforce-password-replaced)" 1
check "474: and admin signs in with its new password" "$(fc s "$IN" signin --headers "$(xff 192.0.2.205)" admin "$ADMIN_474B" | j 'd["result"] + ":" + d["component"]')" \
  "next:xak-flow-redirect"

echo "authentik lock on the pinned authentik ($AK_IMAGE): ${PASS} passed, ${FAILN} failed"
[ "$FAILN" -eq 0 ]
