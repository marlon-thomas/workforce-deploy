#!/usr/bin/env bash
# Self-test for bin/lib/client-address.sh (Workforce issue 462, contract 2.3): GATEWAY_TRUSTED_PROXIES' check, the
# probe's record (written and read), and doctor.sh's judgement of where sign-ins came from (this server's own
# networks, concentration with CLIENT_ADDRESSES_CONFIRMED, forwarding from a peer nobody named). Hermetic: bash, a
# stand-in for docker. ./bin/tests/client-address-test.sh      exit 0 = all pass
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS=0; FAILN=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAILN=$((FAILN+1)); printf 'FAIL: %s: expected [%s] got [%s]\n' "$1" "$3" "$2"; fi; }
# docker: the stack's networks, and the probe's answer (FAKE_ANSWER).
mkdir -p "$WORK/bin"
cat > "$WORK/bin/docker" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "network ls") echo n1; echo n2 ;;
  "network inspect") case "$*" in *n1*) echo 172.18.0.0/16 ;; *) echo 172.19.0.0/16 ;; esac ;;
  "run --rm") printf '%s\n' "$*" > "$DOCKER_RUN_LOG"; printf '%s' "$FAKE_ANSWER" ;;
esac
SH
chmod +x "$WORK/bin/docker"
export PATH="$WORK/bin:$PATH"
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"
# shellcheck source=../lib/client-address.sh
. "$HERE/../lib/client-address.sh"
cd "$WORK" || exit 1

# ---- GATEWAY_TRUSTED_PROXIES
ok() { [ -z "$(gateway_proxies_problem "$1")" ] && echo ok || echo refused; }
check "empty: fine" "$(ok "")" ok
check "a proxy's address" "$(ok "203.0.113.10")" ok
check "two, by spaces" "$(ok "203.0.113.10/32 198.51.100.0/24")" ok
check "an IPv6 proxy" "$(ok "2001:db8::10/128")" ok
check "commas: refused (Caddy reads spaces)" "$(ok "203.0.113.10,203.0.113.11")" refused
check "everyone" "$(ok "0.0.0.0/0")" refused
check "loopback" "$(ok "127.0.0.1")" refused
check "the rootless network" "$(ok "10.0.2.2")" refused
check "one of this stack's networks" "$(ok "172.18.0.5/32")" refused
check "a range around them" "$(ok "172.16.0.0/12")" refused
check "far too wide" "$(ok "10.0.0.0/7")" refused
check "not an address" "$(ok "proxy.example.org")" refused
check "IPv6 link-local" "$(ok "fe80::1")" refused

# ---- the probe's record
AUTH_HOSTNAME=auth.example.org
export CA_COMPOSE_FILE="$HERE/../../compose.yaml" DOCKER_RUN_LOG="$WORK/docker-run.log"
FAKE_ANSWER=$'{"component":"ak-stage-access-denied","error_message":"workforce-client-address=172.18.0.9"}\n172.18.0.9\n200' \
  client_address_probe >/dev/null; rc=$?
check "the probe's own address seen: OK" "$rc" 0
RUN_ARGS="$(cat "$DOCKER_RUN_LOG")"
check "from the gateway's outside network (front), with the pinned curl image" \
  "$(printf '%s' "$RUN_ARGS" | grep -c -- "--network n1 .* $(client_address_curl_image) -sk")" 1
check "through the gateway, to the address check, with every forged header" \
  "$(printf '%s' "$RUN_ARGS" | grep -c -- "--connect-to auth.example.org:443:gateway:443 .*X-Forwarded-For: 198.51.100.11, 198.51.100.12.*CF-Connecting-IP: 198.51.100.18 https://auth.example.org/api/v3/flows/executor/workforce-client-address/")" 1
client_address_read; check "and read back" "$CA_OK $CA_SEEN $CA_PROBE" "true 172.18.0.9 172.18.0.9"
check "with the stack's networks" "$CA_NETWORKS_KNOWN $(printf '%s' "$CA_NETWORKS" | paste -sd' ' -)" "yes 172.18.0.0/16 172.19.0.0/16"
FAKE_ANSWER=$'{"error_message":"workforce-client-address=198.51.100.11"}\n172.18.0.9\n200' client_address_probe >/dev/null; rc=$?
client_address_read
check "a forged address: FAIL" "$rc $CA_OK" "1 false"
check "saying so" "$(printf '%s' "$CA_WHY" | grep -c 'forged header chose')" 1
FAKE_ANSWER=$'{"error_message":"workforce-client-address=172.18.0.1"}\n172.18.0.9\n200' client_address_probe >/dev/null; rc=$?
check "the gateway's own address: FAIL" "$rc" 1
FAKE_ANSWER=$'\n\n000' client_address_probe >/dev/null; rc=$?
check "no answer: FAIL" "$rc" 1
printf '{"schema":1,"checkedAt":"2026-11-14T10:00:00Z","probeAddress":"172.18.0.9","seen":"172.18.0.9","forgedIgnored":true,"ok":true,"why":null,"networks":null}\n' > status/client-address.json
client_address_read; check "the controller's record with networks null: read as unknown" "$CA_NETWORKS_KNOWN" no
printf 'nonsense' > status/client-address.json
client_address_read; check "an unreadable record" "$?" 2
rm -f status/client-address.json
client_address_read; check "no record" "$?" 1

# ---- an older .env has neither setting: doctor.sh runs with set -u
check "CLIENT_ADDRESSES_CONFIRMED unset: nothing confirmed, no error" \
  "$(unset CLIENT_ADDRESSES_CONFIRMED; set -u; client_address_confirmed 203.0.113.7 && echo yes || echo no)" no
check "doctor.sh reads GATEWAY_TRUSTED_PROXIES with a default" \
  "$(grep -c 'GATEWAY_TRUSTED_PROXIES:-}' "$HERE/../doctor.sh")" 1

# ---- where sign-ins came from
judge() { # judge <WF lines> → "<state>: <detail>"
  CA_STATE=ok; CA_DETAIL=""; CA_CONFIRMED_NOTE=""
  OWN_SET=(10.0.2.0/24 127.0.0.0/8 172.18.0.0/16)
  client_address_signins "$1"
  printf '%s: %s' "$CA_STATE" "$CA_DETAIL"
}
CLIENT_ADDRESSES_CONFIRMED=""
SPREAD=$'WFCONN 203.0.113.1 in 2 3\nWFCONN 198.51.100.2 in 2 2\nWFCONN 192.0.2.3 in 1 1\nWFCONN 203.0.113.9 in 1 1\nWFSIGNINS 5 3\nWFFWD 0 -\nWFALERTS 0 0 0'
check "people from several addresses: OK" "$(judge "$SPREAD")" "ok: "
r="$(judge $'WFCONN 172.18.0.1 in 4 3\nWFSIGNINS 4 3\nWFFWD 0 -')"
check "sign-ins from this server's own network: FAIL" "${r%%:*}" fail
check "naming it" "$(printf '%s' "$r" | grep -c '172.18.0.1, this server')" 1
check "a wrong password from it counts too" "$(judge $'WFCONN 203.0.113.1 in 1 1\nWFCONN 10.0.2.2 try 1 1\nWFSIGNINS 1 1\nWFFWD 0 -' | cut -d: -f1)" fail
ONE=$'WFCONN 203.0.113.7 in 5 4\nWFSIGNINS 5 4\nWFFWD 0 -'
r="$(judge "$ONE")"
check "everyone from one public address: WARN (not ready in the app)" "${r%%:*}" warn
check "asking to confirm it or name it" "$(printf '%s' "$r" | grep -c 'CLIENT_ADDRESSES_CONFIRMED.*GATEWAY_TRUSTED_PROXIES')" 1
CLIENT_ADDRESSES_CONFIRMED="203.0.113.7"
check "confirmed as the office: OK" "$(judge "$ONE")" "ok: "
check "and said so" "$CA_CONFIRMED_NOTE" ""   # judge runs in a subshell; the note is checked below
CA_STATE=ok; CA_CONFIRMED_NOTE=""; OWN_SET=(127.0.0.0/8); client_address_signins "$ONE"
check "the OK row names the confirmed office" "$CA_CONFIRMED_NOTE" "most sign-ins come from 203.0.113.7, confirmed as your offices' own connections"
CLIENT_ADDRESSES_CONFIRMED=""
TWO=$'WFCONN 203.0.113.7 in 4 4\nWFCONN 203.0.113.8 in 4 4\nWFCONN 198.51.100.1 in 1 1\nWFSIGNINS 8 4\nWFFWD 0 -'
r="$(judge "$TWO")"
check "two addresses carry 80%: FAIL (an HA pair looks like this)" "${r%%:*}" fail
check "naming both" "$(printf '%s' "$r" | grep -c '203.0.113.7 and 203.0.113.8')" 1
CLIENT_ADDRESSES_CONFIRMED="203.0.113.7, 203.0.113.8"
check "both confirmed: OK" "$(judge "$TWO")" "ok: "
CLIENT_ADDRESSES_CONFIRMED="203.0.113.7"
check "one of them confirmed: still FAIL" "$(judge "$TWO" | cut -d: -f1)" fail
CLIENT_ADDRESSES_CONFIRMED=""
check "one private address: FAIL" "$(judge $'WFCONN 10.20.0.5 in 4 3\nWFSIGNINS 4 3\nWFFWD 0 -' | cut -d: -f1)" fail
check "two people, one address: too few to judge" "$(judge $'WFCONN 203.0.113.7 in 2 3\nWFSIGNINS 2 3\nWFFWD 0 -')" "ok: "
check "three people on one day: too soon to judge" "$(judge $'WFCONN 203.0.113.7 in 3 1\nWFSIGNINS 3 1\nWFFWD 0 -')" "ok: "
FWD=$'WFCONN 203.0.113.1 in 1 2\nWFCONN 203.0.113.2 in 1 2\nWFCONN 203.0.113.3 in 1 2\nWFCONN 203.0.113.4 in 1 2\nWFCONN 203.0.113.5 in 1 2\nWFSIGNINS 5 2\nWFFWD 3 203.0.113.1,203.0.113.2,203.0.113.3'
r="$(judge "$FWD")"
check "most people through something that forwards, unnamed (a CDN): FAIL" "${r%%:*}" fail
check "saying so" "$(printf '%s' "$r" | grep -c "3 of 5 people")" 1
check "half or fewer: not this rule" "$(judge "${FWD/WFFWD 3/WFFWD 2}")" "ok: "
CLIENT_ADDRESSES_CONFIRMED="203.0.113.1 203.0.113.2 203.0.113.3"
check "every address they came through confirmed: OK" "$(judge "$FWD")" "ok: "
CLIENT_ADDRESSES_CONFIRMED=""
check "no sign-in yet: nothing found here (doctor.sh says not checked yet)" "$(judge $'WFSIGNINS 0 0\nWFFWD 0 -')" "ok: "

echo "client address self-test: ${PASS} passed, ${FAILN} failed"
[ "$FAILN" -eq 0 ]
