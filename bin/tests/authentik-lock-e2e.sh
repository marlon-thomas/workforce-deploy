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
# What it proves (the owner's decision on issue 462, and contract 2 and 3):
#   - the address: forged forwarded headers from outside never choose it (the gateway replaces them); straight to
#     authentik from outside the trusted range they are ignored too;
#   - wrong passwords pause one account on one connection: five, then refused before the password is checked; another
#     connection is not paused; a name nobody has gets the same answers; twenty at one moment check exactly five;
#     refused requests aren't recorded and the pause ends 15 minutes after the fifth, during a continued attack too
#     (time moved by shifting the records back); the throttle holds strangers on a connection, not people known
#     there; alerts are written; an unlock (the application's attribute, written through the API by its own service
#     account) and ./bin/reset-admin.sh lift a pause; the service account may read the records and nothing more new;
#   - (review of 14 November 2026) every spelling of a name counts as authentik's lookup finds it, real or unknown
#     alike, a real account's email counts apart like any name, and the password step shows names as typed; tries
#     from many /64s of one /48 at one moment are counted one at a time against its thirty (25, then eight at once:
#     exactly 30 recorded; 33 without the /48's lock);
#   - wrong codes have their own count, by account, and don't touch passwords;
#   - the emergency administrator's password rule (wf-emergency-password) fires in the real reset-link flow and the
#     account-menu change flow, and authentik's own change-password page refuses that account.
# Needs Docker (pulls the pinned images) and python3 with jinja2 (Ansible's). Five to thirty minutes (the blueprint's
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
  docker rm -f "$P-pg" "$P-server" "$P-worker" "$P-gateway" "$P-a" "$P-b" "$P-c" "$P-d" "$P-e" "$P-f" "$P-g" "$P-s" >/dev/null 2>&1 || true
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
mkdir -p "$WORK/tls" "$WORK/t"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=auth.e2e.test \
  -addext "subjectAltName=DNS:auth.e2e.test,DNS:app.e2e.test,DNS:webmail.localhost,DNS:testmail.localhost" \
  -keyout "$WORK/tls/tls.key" -out "$WORK/tls/tls.crt" >/dev/null 2>&1 || die "no test certificate"
cp "$HERE/lib/flow-client.py" "$WORK/t/"
chmod -R a+rX "$WORK"

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
  -e AUTHENTIK_REPUTATION__EXPIRY=900 -e AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS="$TRUSTED")
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
  docker run -d --name "$P-$name" --network "$net" "$@" -v "$WORK/t:/t:ro" --entrypoint sleep "$AK_IMAGE" 3600 >/dev/null \
    || die "client $name"
}
for c in a b c e f g; do client "$c" "$P-front" --add-host "auth.e2e.test:$GW"; done
client d "$P-untrusted"
client s "$P-back"
A="$(ip_on "$P-a" "$P-front")"; B="$(ip_on "$P-b" "$P-front")"; C="$(ip_on "$P-c" "$P-front")"; E="$(ip_on "$P-e" "$P-front")"
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

# ---- people: two staff (codes by email set up), one with an authenticator app; the application's service account
TOTP_KEY="$(openssl rand -hex 20)"; printf '%s' "$TOTP_KEY" > "$WORK/t/totp.key"; chmod a+r "$WORK/t/totp.key"
PW_PAT="pat-$(openssl rand -hex 8)"; PW_SAM="sam-$(openssl rand -hex 8)"; PW_KIM="kim-$(openssl rand -hex 8)"
akshell "
from authentik.core.models import User
from authentik.stages.authenticator_totp.models import TOTPDevice
for name, pw in (('pat', '$PW_PAT'), ('sam', '$PW_SAM'), ('kim', '$PW_KIM')):
    u, _ = User.objects.update_or_create(username=name, defaults={'email': name + '@example.org', 'type': 'internal',
        'attributes': {'workforce': {'codes': name + '@example.org'}}})
    u.set_password(pw); u.save()
TOTPDevice.objects.update_or_create(user=User.objects.get(username='pat'), name='app',
    defaults={'key': '$TOTP_KEY', 'confirmed': True, 'digits': 6, 'step': 30})
print('people ready')" >/dev/null
TOKEN="$(openssl rand -hex 24)"
printf '%s' "$TOKEN" | docker exec -i "$P-server" ak shell -c "$(cat "$REPO/ansible/roles/authentik/files/invite-service-account.py")" \
  2>/dev/null | grep -q 'workforce-invites converged' || die "the service account wasn't made"
PAT_PK="$(sql "select id from authentik_core_user where username = 'pat'")"
SAM_PK="$(sql "select id from authentik_core_user where username = 'sam'")"
KIM_PK="$(sql "select id from authentik_core_user where username = 'kim'")"
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

# ---- 6. an unlock in Workforce: the attribute, written through the API by the application's own service account
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
r="$(fc d "$IN" api GET "/api/v3/core/users/$PAT_PK/" "$TOKEN" | j 'd["status"]')"
check "the service account reads the account" "$r" 200
r="$(fc d "$IN" api PATCH "/api/v3/core/users/$PAT_PK/" "$TOKEN" "{\"attributes\": {\"workforce\": {\"codes\": \"pat@example.org\", \"password_unlocked_at\": \"$NOW_ISO\"}}}" | j 'd["status"]')"
check "and writes the unlock (change_user, already held)" "$r" 200
r="$(fc a "$OUT" signin pat "$PW_PAT" | result)"
check "after the unlock, pat signs in from A again" "$r" "next:ak-stage-authenticator-validate:"
r="$(fc d "$IN" api GET "/api/v3/events/events/?action=custom_workforce_password_try&ordering=-created&page_size=500&page=1" "$TOKEN")"
check "the service account reads the records (view_event)" "$(printf '%s' "$r" | j 'd["status"]')" 200
check "filtered by action, newest first" "$(printf '%s' "$r" | j 'len(d["body"]["results"]) > 0 and all(x["action"] == "custom_workforce_password_try" for x in d["body"]["results"]) and d["body"]["results"][0]["created"] >= d["body"]["results"][-1]["created"]')" True
check "with the context the application reads" "$(printf '%s' "$r" | j 'sorted(d["body"]["results"][0]["context"].keys())[:4]')" "['wf_account', 'wf_conn', 'wf_try', 'wf_user_pk']"
r="$(fc d "$IN" api GET "/api/v3/core/users/$PAT_PK/" "$TOKEN" | j '"password_change_date" in d["body"]')"
check "the account's password change date is in the API's answer" "$r" True
r="$(fc d "$IN" api DELETE "/api/v3/events/events/$(sql "select event_uuid from authentik_events_event where action = 'custom_workforce_password_try' limit 1")/" "$TOKEN" | j 'd["status"]')"
check "but may not delete them" "$r" 403

# ---- 6b. the application's reads: one person's records by ?username= (authentik's events filter), and wf_fwd
r="$(fc d "$IN" api GET "/api/v3/events/events/?action=custom_workforce_password_try&username=pat&ordering=-created&page_size=500&page=1" "$TOKEN")"
check "?username=pat: pat's tries only" "$(printf '%s' "$r" | j 'sorted(set(x["context"]["wf_account"] for x in d["body"]["results"]))')" "['u:$PAT_PK']"
check "all of them" "$(printf '%s' "$r" | j 'len(d["body"]["results"])')" "$(sql "select count(*) from authentik_events_event where action = 'custom_workforce_password_try' and context->>'wf_account' = 'u:$PAT_PK'")"
fwd() { sql "select context->>'wf_fwd' from authentik_events_event where action = 'custom_workforce_password_right' and context->>'wf_account' = 'u:$PAT_PK' order by created desc limit 1"; }
check "a right password straight from a client: not forwarded" "$(fwd)" false
fc a "$OUT" signin --headers '{"X-Forwarded-For": "198.51.100.50"}' pat "$PW_PAT" >/dev/null
check "the same with a forwarding header from a peer nobody named: wf_fwd" "$(fwd)" true

# ---- 7. the throttle (fix round): ten wrong from one connection hold every name there alike, unless it is a workplace
fc e "$OUT" signin pat "$PW_PAT" >/dev/null     # pat: the right password from E once (no exemption by name any more)
for i in 1 2 3 4 5 6 7 8 9 10; do fc e "$OUT" signin "stranger-$i" wrong >/dev/null; done
has "E: ten wrong for ten names: sam is throttled, with the throttle's words" "$(fc e "$OUT" signin sam "$PW_SAM" | result)" "$THROTTLED"
has "pat, who signed in from E before: the same answer" "$(fc e "$OUT" signin pat "$PW_PAT" | result)" "$THROTTLED"
has "a name nobody has: the same answer" "$(fc e "$OUT" signin nobody-else "$PW_PAT" | result)" "$THROTTLED"
r="$(fc d "$IN" api PATCH "/api/v3/core/users/$PAT_PK/" "$TOKEN" "{\"attributes\": {\"workforce\": {\"codes\": \"pat@example.org\", \"password_unlocked_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}}" | j 'd["status"]')"
has "an unlock doesn't lift a throttle" "$(fc e "$OUT" signin pat "$PW_PAT" | result)" "$THROTTLED"
check "pat from A meanwhile: not held" "$(fc a "$OUT" signin pat "$PW_PAT" | result)" "next:ak-stage-authenticator-validate:"
has "a throttle alert" "$(sql "select context->>'wf_kind' from authentik_events_event where action = 'custom_workforce_password_alert' and context->>'wf_conn' = '$E'")" throttled
has "and a spread alert for the connection" "$(sql "select context->>'wf_kind' from authentik_events_event where action = 'custom_workforce_password_alert' and context->>'wf_conn' = '$E'")" connection-spread
check "each at most once an hour" "$(sql "select count(*) from authentik_events_event where action = 'custom_workforce_password_alert' and context->>'wf_conn' = '$E' group by context->>'wf_kind' order by 1 desc limit 1")" 1
# A workplace: three real accounts typed the right password there. A container inside the trusted range stands in for
# the gateway here (authentik takes X-Forwarded-For from it, as section 1 shows), so any address can be a connection.
OFFICE='{"X-Forwarded-For": "203.0.113.77"}'
for who in "pat $PW_PAT" "sam $PW_SAM" "kim $PW_KIM"; do set -- $who; fc s "$IN" signin --headers "$OFFICE" "$1" "$2" >/dev/null; done
for i in 1 2 3 4 5 6 7 8 9 10 11; do fc s "$IN" signin --headers "$OFFICE" "visitor-$i" wrong >/dev/null; done
r="$(fc s "$IN" signin --headers "$OFFICE" visitor-12 wrong | result)"
check "a workplace (3 staff signed in there): eleven wrong for other names, still no throttle" "${r%%:*}" error
has "and staff sign in there" "$(fc s "$IN" signin --headers "$OFFICE" kim "$PW_KIM" | result)" "next:ak-stage-authenticator-"
# IPv6: thirty wrong from thirty /64s of one /48 throttle the /48 (authentik keeps addresses as inet; <<= finds them).
for i in $(seq 1 30); do fc s "$IN" signin --headers "{\"X-Forwarded-For\": \"2001:db8:5:$i::1\"}" "v6-$i" wrong >/dev/null; done
has "a 31st /64 of that /48: throttled" "$(fc s "$IN" signin --headers '{"X-Forwarded-For": "2001:db8:5:ff::1"}' kim "$PW_KIM" | result)" "$THROTTLED"
has "another /48: not" "$(fc s "$IN" signin --headers '{"X-Forwarded-For": "2001:db8:6::1"}' kim "$PW_KIM" | result)" "next:ak-stage-authenticator-"
has "a spread alert for the /48" "$(sql "select context->>'wf_conn' from authentik_events_event where action = 'custom_workforce_password_alert' and context->>'wf_kind' = 'connection-spread'")" "2001:db8:5::/48"
# Review finding 4: another /48 has 25 wrong from as many /64s, then eight more /64s try at one moment. The /48's lock
# counts them one at a time, so exactly five more are checked (thirty in all) and three get the throttle's words.
# (Without it, each could read the count before the others had written theirs. Few at once: each recorded try holds
# the lock for its whole transaction, and a wait past lock_timeout refuses the password unchecked, which is safe but
# isn't what this measures.)
fc s "$IN" spray 25 8 2001:db8:7 wrong > "$WORK/spray.json"
check "25, then eight at once from one /48's /64s: exactly thirty recorded" "$(sql "select count(*) from authentik_events_event where action = 'custom_workforce_password_try' and client_ip <<= '2001:db8:7::/48'")" 30
check "and three held, with the throttle's words" \
  "$(THROTTLED="$THROTTLED" j 'sum(1 for x in d if x and x["result"] == "denied" and x["message"].startswith(__import__("os").environ["THROTTLED"]))' < "$WORK/spray.json")" 3
j '[(x or {}).get("result", "") + ":" + (x or {}).get("message", "")[:40] for x in d]' < "$WORK/spray.json"

# ---- 7b. doctor.sh's "where sign-ins came from" (contract 2.3 b): its program, word for word, in the live authentik
CA_PROGRAM="$(bash -c '. "$1/bin/lib/client-address.sh"; printf "%s" "$CLIENT_ADDRESS_AK"' _ "$REPO")"
CA_LIVE="$(docker exec -i "$P-server" ak shell -c "$CA_PROGRAM" 2>/dev/null | grep -E '^WF(CONN|SIGNINS|INSUM|FWD|ALERTS) ')"
check "its summaries first (review finding 9)" "$(printf '%s\n' "$CA_LIVE" | head -n 4 | cut -d' ' -f1 | paste -sd' ' -)" "WFSIGNINS WFINSUM WFFWD WFALERTS"
has "doctor.sh's program: sign-ins from A, by connection key" "$CA_LIVE" "WFCONN $A in "
has "the IPv6 tries by /64" "$CA_LIVE" "WFCONN 2001:db8:5:1::/64 try "
has "the forwarded sign-in counted" "$CA_LIVE" "WFFWD 1 $A"
check "the alerts counted" "$(printf '%s\n' "$CA_LIVE" | grep -c '^WFALERTS [1-9][0-9]* [0-9]* [1-9]')" 1
check "no name in it" "$(printf '%s\n' "$CA_LIVE" | grep -c -E 'pat|sam|kim|nobody|stranger|visitor')" 0

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
ADMIN_PK="$(sql "select id from authentik_core_user where username = 'admin'")"
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
check "reset-admin.sh: the marker is written" "$(sql "select attributes->'workforce'->>'password_unlocked_at' is not null from authentik_core_user where username = 'admin'")" t
check "reset-admin.sh: nobody else's" "$(sql "select count(*) from authentik_core_user where attributes->'workforce' ? 'password_unlocked_at' and username not in ('admin', 'pat')")" 0
check "after reset-admin.sh, admin signs in from F" "$(fc f "$OUT" signin admin "$RESET_PW" | j 'd["result"]')" next

echo "authentik lock on the pinned authentik ($AK_IMAGE): ${PASS} passed, ${FAILN} failed"
[ "$FAILN" -eq 0 ]
