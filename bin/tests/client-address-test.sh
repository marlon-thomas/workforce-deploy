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
  "network ls") [ -n "${FAKE_NO_NETS:-}" ] || { echo n1; echo n2; } ;;
  "network inspect") case "$*" in *n1*) echo 172.18.0.0/16 ;; *) echo 172.19.0.0/16; echo fd00:5:0:1::/64 ;; esac ;;
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
check "inside this stack's IPv6 network (review finding 12)" "$(ok "fd00:5:0:1::9")" refused
check "a range around it" "$(ok "fd00:5::/48")" refused
check "another IPv6 range" "$(ok "fd00:6::/48")" ok
# Before the first install the stack has no networks yet (review finding 6): Docker's default pools are refused.
check "no networks yet: Docker's pools' 172.16.0.0/12" "$(FAKE_NO_NETS=1 ok "172.16.0.0/12")" refused
check "no networks yet: an address in 172.20.0.0/16" "$(FAKE_NO_NETS=1 ok "172.20.0.5")" refused
check "no networks yet: 192.168.0.0/16's /20s" "$(FAKE_NO_NETS=1 ok "192.168.1.10/32")" refused
check "no networks yet: saying when to name it" "$(FAKE_NO_NETS=1 gateway_proxies_problem "172.20.0.5" | grep -c 'after the first install')" 1
check "no networks yet: a public proxy is fine" "$(FAKE_NO_NETS=1 ok "203.0.113.10 198.51.100.0/24")" ok
check "no networks yet: 172.16.0.0/16 (outside Docker's pools)" "$(FAKE_NO_NETS=1 ok "172.16.4.4")" ok
check "networks made: a LAN proxy in 192.168 outside them is fine" "$(ok "192.168.1.10/32")" ok

# ---- IPv6 ranges (review finding 12)
check "ip6_hex expands" "$(ip6_hex 2001:DB8::1)" 20010db8000000000000000000000001
check "ip6_hex: all eight groups" "$(ip6_hex 1:2:3:4:5:6:7:8)" 00010002000300040005000600070008
check "ip6_hex: not an address" "$(ip6_hex 1::2::3 || echo no)" no
check "ip6_hex: too many groups" "$(ip6_hex 1:2:3:4:5:6:7:8:9 || echo no)" no
check "ip6_hex: a trailing colon" "$(ip6_hex 1:2:3:4:5:6:7: || echo no)" no
o6() { cidr6_overlap "$1" "$2" && echo yes || echo no; }
check "a /64 inside a /48" "$(o6 2001:db8:aa:1::/64 2001:db8:aa::/48)" yes
check "a /64 outside it" "$(o6 2001:db8:ab:1::/64 2001:db8:aa::/48)" no
check "a /47 boundary" "$(o6 2001:db8:ab::/64 2001:db8:aa::/47)" yes
check "an address inside a /64" "$(o6 2001:db8:aa:1::/64 2001:db8:aa:1:5::7)" yes
check "the next /64" "$(o6 2001:db8:aa:2::/64 2001:db8:aa:1:5::7)" no

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
check "with the stack's networks" "$CA_NETWORKS_KNOWN $(printf '%s' "$CA_NETWORKS" | paste -sd' ' -)" "yes 172.18.0.0/16 172.19.0.0/16 fd00:5:0:1::/64"
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
# The controller image's sed is busybox on musl, which refuses a bound over 255 (bin/tests/controller-busybox-e2e.sh
# runs this file there): the reason up to 300 characters, and networks however many, up to the 4096-byte head.
rec() { printf '{"schema":1,"checkedAt":"2026-11-14T10:00:00Z","probeAddress":"172.18.0.9","seen":"198.51.100.11","forgedIgnored":false,"ok":false,"why":%s,"networks":%s}\n' "$1" "$2" > status/client-address.json; }
why300="$(printf 'w%.0s' $(seq 1 300))"
rec "\"$why300\"" '["172.18.0.0/16"]'; client_address_read
check "a reason of 300 characters is read" "$? ${#why300} $([ "$CA_WHY" = "$why300" ] && echo same) $CA_NETWORKS" "0 300 same 172.18.0.0/16"
rec "\"${why300}x\"" '["172.18.0.0/16"]'; client_address_read
check "one of 301 is not" "$? [$CA_WHY] $CA_NETWORKS" "0 [] 172.18.0.0/16"
why_utf8="$(printf '\303\251%.0s' $(seq 1 300))"
rec "\"$why_utf8\"" null; client_address_read
check "300 characters of two bytes each are 300 characters" "$([ "$CA_WHY" = "$why_utf8" ] && echo same)" same
rec '"a \"quoted\" reason"' null; client_address_read
check "a reason with an escape is not used" "$? [$CA_WHY]" "0 []"
rec '""' null; client_address_read
check "an empty reason is none" "[$CA_WHY]" "[]"
nets="$(for i in $(seq 1 100); do printf '"fd00:abcd:ef01:%x::/64",' "$i"; done)"; nets="${nets%,}"
rec '"x"' "[$nets]"; client_address_read
check "100 IPv6 networks (over 2000 characters) are all read" \
  "$CA_NETWORKS_KNOWN $(printf '%s\n' "$CA_NETWORKS" | grep -c .) $([ "${#nets}" -gt 2000 ] && echo long)" "yes 100 long"
check "the first and the last" "$(printf '%s\n' "$CA_NETWORKS" | sed -n '1p;$p' | paste -sd' ' -)" "fd00:abcd:ef01:1::/64 fd00:abcd:ef01:64::/64"
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
  OWN_SET=(10.0.2.0/24 127.0.0.0/8 172.18.0.0/16 ${OWN_SET_EXTRA:-})
  client_address_signins "$1"
  printf '%s: %s' "$CA_STATE" "$CA_DETAIL"
}
CLIENT_ADDRESSES_CONFIRMED=""
SPREAD=$'WFCONN 203.0.113.1 in 2 3\nWFCONN 198.51.100.2 in 2 2\nWFCONN 192.0.2.3 in 1 1\nWFCONN 203.0.113.9 in 1 1\nWFSIGNINS 5 3\nWFFWD 0 -\nWFALERTS 0 0 0'
check "people from several addresses: OK" "$(judge "$SPREAD")" "ok: "
r="$(judge $'WFCONN 172.18.0.1 in 4 3\nWFSIGNINS 4 3\nWFFWD 0 -')"
check "sign-ins from this server's own network: FAIL" "${r%%:*}" fail
check "naming it" "$(printf '%s' "$r" | grep -c '172.18.0.1, this server')" 1
r="$(OWN_SET_EXTRA=2001:db8:aa::/48 judge $'WFCONN 2001:db8:aa:1::/64 in 1 1\nWFSIGNINS 1 1\nWFFWD 0 -')"
check "sign-ins from an IPv6 proxy named by its range: FAIL (review finding 12)" "${r%%:*}" fail
check "naming the /64" "$(printf '%s' "$r" | grep -c '2001:db8:aa:1::/64, this server')" 1
check "a /64 outside the named range: not this rule" "$(OWN_SET_EXTRA=2001:db8:aa::/48 judge $'WFCONN 2001:db8:ab:1::/64 in 1 1\nWFSIGNINS 1 1\nWFFWD 0 -')" "ok: "
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
# Ranges confirm every connection in them (review finding 13: the TEST appliance's tailnet).
TAILNET=$'WFCONN 100.101.7.8 in 3 2\nWFSIGNINS 3 2\nWFFWD 0 -'
check "testers from one tailnet device: FAIL unconfirmed" "$(judge "$TAILNET" | cut -d: -f1)" fail
CLIENT_ADDRESSES_CONFIRMED="100.64.0.0/10"
check "the tailnet confirmed as a range (environments/test.env): OK" "$(judge "$TAILNET")" "ok: "
check "the TEST environment confirms it" "$(grep -c '^CLIENT_ADDRESSES_CONFIRMED=100.64.0.0/10$' "$HERE/../../environments/test.env")" 1
CLIENT_ADDRESSES_CONFIRMED="2001:db8:7::/48,203.0.113.0/29"
check "an IPv6 range confirms a /64 in it" "$(client_address_confirmed 2001:db8:7:3::/64 && echo yes || echo no)" yes
check "but not one outside it" "$(client_address_confirmed 2001:db8:8:3::/64 && echo yes || echo no)" no
check "an IPv4 range confirms an address in it" "$(client_address_confirmed 203.0.113.6 && echo yes || echo no)" yes
check "but not the next" "$(client_address_confirmed 203.0.113.8 && echo yes || echo no)" no
CLIENT_ADDRESSES_CONFIRMED=""
# The program's summary lines come first, and the whole is over every connection (review finding 9): with more
# connections than doctor.sh reads, the summaries are still there, and a cut list doesn't fake a concentration.
AK_ORDER="$(printf '%s\n' "$CLIENT_ADDRESS_AK" | grep -nE '^print\("WF(SIGNINS|INSUM|FWD|ALERTS|CONN)' | cut -d: -f1 | paste -sd' ' -)"
check "the program prints its summaries before any connection" \
  "$(printf '%s\n' "$CLIENT_ADDRESS_AK" | awk '/^print\("WF(SIGNINS|INSUM|FWD|ALERTS)/ {s = NR} /print\("WFCONN"/ && !c {c = NR} END {print (s < c) ? "yes" : "no"}')" yes
check "and lists at most 1000 connections" "$(printf '%s\n' "$CLIENT_ADDRESS_AK" | grep -c '\[:500\]:')" 2
check "never public addresses that only tried" "$(printf '%s\n' "$CLIENT_ADDRESS_AK" | grep -c 'kind == "try" and public(conn)')" 1
check "doctor.sh keeps the whole" "$(grep -c 'WF(CONN|SIGNINS|INSUM|FWD|ALERTS|CRED)' "$HERE/../doctor.sh")" 1
# Review of 15 November 2026, finding 5: the application's account is checked on every run, among the summaries.
check "the program checks Workforce's account for event access and other groups" \
  "$(printf '%s\n' "$CLIENT_ADDRESS_AK" | grep -c '^print("WFCRED", "missing" if svc is None else ",".join(bad) or "ok")$') $(printf '%s\n' "$CLIENT_ADDRESS_AK" | grep -c 'svc.has_perm("authentik_events.view_event") or RoleObjectPermission')" "1 1"
check "before any connection" \
  "$(printf '%s\n' "$CLIENT_ADDRESS_AK" | awk '/^print\("WFCRED"/ {s = NR} /print\("WFCONN"/ && !c {c = NR} END {print (s && s < c) ? "yes" : "no"}')" yes
check "doctor.sh fails the row on anything but ok" "$(grep -c 'oprow "sign-in server account" fail' "$HERE/../doctor.sh")" 1
[ -n "$AK_ORDER" ] || check "the program's print lines" "" found
CUT=$'WFSIGNINS 10 4\nWFINSUM 10\nWFFWD 0 -\nWFALERTS 0 0 0\nWFCONN 203.0.113.7 in 5 4'
check "a cut list: half from one address is no concentration" "$(judge "$CUT")" "ok: "
check "without the whole it would have looked like one" "$(judge "$(printf '%s\n' "$CUT" | grep -v WFINSUM)" | cut -d: -f1)" warn
check "no sign-in yet: nothing found here (doctor.sh says not checked yet)" "$(judge $'WFSIGNINS 0 0\nWFFWD 0 -')" "ok: "

# ---- the sign-in limits' settings (Workforce issue 462, contract R.3 and R.4)
lim() { SIGN_IN_WORKPLACE_SOURCE_LIMIT="$1" SIGN_IN_WORKPLACE_NETWORK_LIMIT="$2" CLIENT_ADDRESSES_CONFIRMED="$3" sign_in_limits_problem; }
check "limits: none set: fine" "$(lim "" "" "")" ""
check "limits: the widest allowed: fine" "$(lim 100 1000 "")" ""
check "limits: the narrowest: fine" "$(lim 20 100 "")" ""
check "limits: 19 refused" "$(lim 19 "" "" | grep -c 'from 20 to 100')" 1
check "limits: 101 refused" "$(lim 101 "" "" | grep -c 'from 20 to 100')" 1
check "limits: not a number refused" "$(lim fifty "" "" | grep -c 'from 20 to 100')" 1
check "limits: a network limit of 99 refused" "$(lim "" 99 "" | grep -c 'from 100 to 1000')" 1
check "limits: a source limit not below the network's refused" "$(lim 100 100 "" | grep -c 'must be below')" 1
check "limits: confirmed addresses, keys and ranges: fine" "$(lim "" "" "203.0.113.7,2001:db8:1:2::/64,198.51.100.0/24,100.64.0.0/10")" ""
check "limits: a confirmed range wider than an IPv4 /8 refused" "$(lim "" "" "0.0.0.0/0" | grep -c 'far too wide')" 1
check "limits: wider than an IPv6 /32 refused" "$(lim "" "" "2001::/16" | grep -c 'far too wide')" 1
check "limits: nonsense refused" "$(lim "" "" "office" | grep -c 'is not an address')" 1
# Review of 15 November 2026, findings 3 and 17: what an entry does for the limits, as the sign-in server reads it.
clc() { CLIENT_ADDRESSES_CONFIRMED="$1" confirmed_limit_counts; }
check "confirmed for the limits: none" "$(clc "")" "0 0 0"
check "an address, a /24 and a /64 make workplace connections; a /56 and a /48 workplace networks; a /16, the TEST tailnet's /10 and an IPv6 /32 raise no limit" \
  "$(clc "203.0.113.7 198.51.100.0/24,2001:db8:1:2::/64 [2001:db8:9::5] 2001:db8:3::/56 2001:db8:4::/48 198.18.0.0/16 100.64.0.0/10 2001:db8::/32")" "4 2 3"
check "unreadable entries aren't counted" "$(clc "office 2001:db8:1:2::/64")" "1 0 0"

echo "client address self-test: ${PASS} passed, ${FAILN} failed"
[ "$FAILN" -eq 0 ]
