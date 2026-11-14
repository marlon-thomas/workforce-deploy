#!/usr/bin/env bash
# gateway-client-address-e2e.sh — Workforce issue 462 (contract 2.1): every gateway file, run by the pinned Caddy, with
# an echo service standing in for the application, the sign-in server and webmail, so what each one receives can be
# read back:
#   - from an ordinary client (not one of GATEWAY_TRUSTED_PROXIES) forged forwarded headers are replaced: exactly one
#     X-Forwarded-For and one X-Real-IP, the client's own address, and none of the other headers that could name a
#     client (Forwarded, True-Client-IP, X-Client-IP, CF-Connecting-IP, authentik's X-authentik-remote-ip and outpost
#     token, …);
#   - from a proxy named in GATEWAY_TRUSTED_PROXIES, X-Forwarded-For is read right to left and the first address that
#     isn't a named proxy wins: a forged left-hand entry can't choose it;
#   - a request with a forwarding header from a peer nobody named is marked X-Workforce-Forwarded: 1 (contract 2.3 b,
#     fix round); one without, or from a named proxy, is not, and a client's own copy of the mark never passes.
# Host names under .localhost, so Caddy issues its own certificates and never asks a public CA (Caddyfile.duckdns's
# DNS-01 line needs a plugin the stock image lacks, so it is left out of that file's copy here; the rest is the file).
# Needs Docker. Every container and network it makes is removed at the end. Exit 0 = all pass.
#   ./bin/tests/gateway-client-address-e2e.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
pin() { awk -v s="  $1:" '$0 == s {on=1} on && /image:/ {print $2; exit}' "$REPO/compose.yaml"; }
CADDY_IMAGE="$(pin gateway | sed -E 's/^\$\{GATEWAY_IMAGE:-(.*)\}$/\1/')"
ECHO_IMAGE="$(pin authentik-server)"     # any pinned image with python3; this one is pulled for the other tests
CURL_IMAGE="$(pin discovery-gate)"
P="wf-gw-e2e-$$"
WORK="$(mktemp -d)"
cleanup() {
  docker rm -f "$P-gw" "$P-echo" "$P-client" >/dev/null 2>&1 || true
  docker network rm "$P-net" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
PASS=0; FAILN=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAILN=$((FAILN+1)); printf 'FAIL: %s: expected [%s] got [%s]\n' "$1" "$3" "$2"; fi; }

mkdir -p "$WORK/gateway" "$WORK/tls"
cp "$REPO"/gateway/Caddyfile* "$WORK/gateway/"
sed -i '/acme_dns duckdns/d' "$WORK/gateway/Caddyfile.duckdns"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=auth.localhost \
  -addext "subjectAltName=DNS:auth.localhost,DNS:app.localhost,DNS:webmail.localhost" \
  -keyout "$WORK/tls/tls.key" -out "$WORK/tls/tls.crt" >/dev/null 2>&1 || { echo "no test certificate"; exit 1; }
cat > "$WORK/echo.py" <<'PY'
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps([[k, v] for k, v in self.headers.items()]).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass
for port in (8080, 9000, 80):
    import threading
    s = ThreadingHTTPServer(("0.0.0.0", port), H)
    threading.Thread(target=s.serve_forever, daemon=True).start()
threading.Event().wait()
PY
chmod -R a+rX "$WORK"
docker network create "$P-net" >/dev/null || exit 1
docker run -d --name "$P-echo" --network "$P-net" --network-alias api --network-alias authentik-server \
  --network-alias webmail -v "$WORK/echo.py:/echo.py:ro" --user 0 --entrypoint python "$ECHO_IMAGE" /echo.py >/dev/null || exit 1
docker run -d --name "$P-client" --network "$P-net" --entrypoint sleep "$CURL_IMAGE" 3600 >/dev/null || exit 1
CLIENT="$(docker inspect -f "{{(index .NetworkSettings.Networks \"$P-net\").IPAddress}}" "$P-client")"

FORGED=(-H 'X-Forwarded-For: 198.51.100.11, 198.51.100.12' -H 'X-Real-IP: 198.51.100.13' -H 'Forwarded: for=198.51.100.14'
  -H 'X-authentik-remote-ip: 198.51.100.15' -H 'X-authentik-outpost-token: forged' -H 'True-Client-IP: 198.51.100.16'
  -H 'X-Client-IP: 198.51.100.17' -H 'CF-Connecting-IP: 198.51.100.18' -H 'Fastly-Client-IP: 198.51.100.19'
  -H 'X-Cluster-Client-IP: 198.51.100.20' -H 'X-Original-Forwarded-For: 198.51.100.21' -H 'X-Forwarded-Host-Ip: 198.51.100.22')
REMOVED='forwarded x-authentik-remote-ip x-authentik-outpost-token true-client-ip x-client-ip cf-connecting-ip fastly-client-ip x-cluster-client-ip x-original-forwarded-for x-forwarded-host-ip'
ask() { # ask <host> [curl args…] — the headers the upstream received, as "name=value" lines (lower-case names)
  local host="$1" gw; shift
  gw="$(docker inspect -f "{{(index .NetworkSettings.Networks \"$P-net\").IPAddress}}" "$P-gw")"
  docker exec "$P-client" curl -sk --max-time 10 --resolve "$host:443:$gw" "$@" "https://$host/" \
    | python3 -c 'import json,sys
for k, v in json.load(sys.stdin): print(k.lower() + "=" + v)' 2>/dev/null
}
start_gw() { # start_gw <file> <GATEWAY_TRUSTED_PROXIES>
  docker rm -f "$P-gw" >/dev/null 2>&1 || true
  docker run -d --name "$P-gw" --network "$P-net" -e APP_HOSTNAME=app.localhost -e AUTH_HOSTNAME=auth.localhost \
    -e WEBMAIL_HOSTNAME=webmail.localhost -e ACME_EMAIL=e2e@example.org -e GATEWAY_TRUSTED_PROXIES="$2" \
    -v "$WORK/gateway:/etc/caddy/gateway:ro" -v "$WORK/tls:/etc/caddy/tls:ro" "$CADDY_IMAGE" \
    caddy run --config "/etc/caddy/gateway/$1" --adapter caddyfile >/dev/null || return 1
  for _ in $(seq 1 30); do
    [ -n "$(ask "${3:-app.localhost}" 2>/dev/null)" ] && return 0
    sleep 1
  done
  docker logs "$P-gw" 2>&1 | tail -5
  return 1
}

for f in Caddyfile Caddyfile.duckdns Caddyfile.localca Caddyfile.owncert; do
  start_gw "$f" 192.0.2.255/32 || { FAILN=$((FAILN+1)); echo "FAIL: $f: the gateway didn't start"; continue; }
  for host in app.localhost auth.localhost webmail.localhost; do
    got="$(ask "$host" "${FORGED[@]}")"
    check "$f $host: one X-Forwarded-For, the client's own" "$(printf '%s\n' "$got" | grep '^x-forwarded-for=' | tr '\n' ' ')" "x-forwarded-for=$CLIENT "
    check "$f $host: X-Real-IP the same" "$(printf '%s\n' "$got" | grep '^x-real-ip=' | tr '\n' ' ')" "x-real-ip=$CLIENT "
    left=""
    for h in $REMOVED; do printf '%s\n' "$got" | grep -q "^$h=" && left="$left $h"; done
    check "$f $host: every other client header removed" "$left" ""
    check "$f $host: forwarded by a peer nobody named: marked" "$(printf '%s\n' "$got" | grep '^x-workforce-forwarded=' | tr '\n' ' ')" "x-workforce-forwarded=1 "
    got="$(ask "$host" -H 'X-Workforce-Forwarded: 1')"
    check "$f $host: no forwarding header: not marked, the client's own mark gone" "$(printf '%s\n' "$got" | grep '^x-workforce-forwarded=1')" ""
    got="$(ask "$host" -H 'CF-Connecting-IP: 198.51.100.40')"
    check "$f $host: CF-Connecting-IP alone: marked" "$(printf '%s\n' "$got" | grep -c '^x-workforce-forwarded=1')" 1
  done
  # A proxy of the operator's (here the client itself) in front: right to left, the first address not a named proxy.
  start_gw "$f" "203.0.113.200/32 $CLIENT/32" || { FAILN=$((FAILN+1)); echo "FAIL: $f: the gateway didn't start with proxies"; continue; }
  got="$(ask auth.localhost -H 'X-Forwarded-For: 198.51.100.30, 203.0.113.50')"
  check "$f behind a named proxy: the address it saw, not a forged left-hand one" "$(printf '%s\n' "$got" | grep '^x-forwarded-for=')" "x-forwarded-for=203.0.113.50"
  got="$(ask auth.localhost -H 'X-Forwarded-For: 198.51.100.30, 203.0.113.50, 203.0.113.200')"
  check "$f behind two named proxies: still the first address that isn't one" "$(printf '%s\n' "$got" | grep '^x-forwarded-for=')" "x-forwarded-for=203.0.113.50"
  check "$f from a named proxy: not marked" "$(printf '%s\n' "$got" | grep -c '^x-workforce-forwarded=1')" 0
done

# The smoke file: plain HTTP, the application only.
docker rm -f "$P-gw" >/dev/null 2>&1 || true
docker run -d --name "$P-gw" --network "$P-net" -v "$WORK/gateway:/etc/caddy/gateway:ro" "$CADDY_IMAGE" \
  caddy run --config /etc/caddy/gateway/Caddyfile.smoke --adapter caddyfile >/dev/null
sleep 2
gw="$(docker inspect -f "{{(index .NetworkSettings.Networks \"$P-net\").IPAddress}}" "$P-gw")"
got="$(docker exec "$P-client" curl -s --max-time 10 "${FORGED[@]}" "http://$gw/" | python3 -c 'import json,sys
for k, v in json.load(sys.stdin): print(k.lower() + "=" + v)' 2>/dev/null)"
check "Caddyfile.smoke: the client's own address" "$(printf '%s\n' "$got" | grep '^x-forwarded-for=')" "x-forwarded-for=$CLIENT"

echo "gateway client addresses on the pinned Caddy: ${PASS} passed, ${FAILN} failed"
[ "$FAILN" -eq 0 ]
