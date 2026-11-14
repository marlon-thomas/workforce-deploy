# shellcheck shell=bash
# client-address.sh — Workforce issue 462 (ADR-0039, amendment of 14 November 2026; contract section 2): does the
# sign-in server see each person's own address? Sourced by bin/doctor.sh, bin/install.sh and bin/update.sh (after
# bin/lib/common.sh). No output of its own except what each function says it prints.
#
# Wrong passwords pause one account on one connection. If every request looked as if it came from the gateway (the
# rootless Docker default port driver, a load balancer nobody named) or a forged header could choose the address,
# that would be wrong for everyone, silently. So:
#   - GATEWAY_TRUSTED_PROXIES (the operator's own proxies, if any) is checked before it is used: space-separated
#     addresses or CIDRs, never this stack's own networks, loopback or everything;
#   - the probe asks the sign-in server through the gateway with forged headers which address it sees, and keeps the
#     answer in status/client-address.json (the controller writes the same record after each apply);
#   - doctor.sh's "client addresses" row (status/health.json → Workforce's Setup) reads that record and the addresses
#     sign-ins really came from.

CLIENT_ADDRESS_FILE="${CLIENT_ADDRESS_FILE:-status/client-address.json}"
CLIENT_ADDRESS_FLOW=workforce-client-address
# Forged headers, from TEST-NET-2 (never a real peer): none of them may choose the address.
CLIENT_ADDRESS_FORGED=(
  -H 'X-Forwarded-For: 198.51.100.11, 198.51.100.12' -H 'X-Real-IP: 198.51.100.13' -H 'Forwarded: for=198.51.100.14'
  -H 'X-authentik-remote-ip: 198.51.100.15' -H 'True-Client-IP: 198.51.100.16' -H 'X-Client-IP: 198.51.100.17'
  -H 'CF-Connecting-IP: 198.51.100.18'
)

# ip4_ok <text> — a dotted-quad IPv4 address (each part 0-255). Checked before any arithmetic: bash arithmetic on
# an unchecked string can run commands.
ip4_ok() {
  [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local o
  for o in "${BASH_REMATCH[@]:1}"; do [ "$((10#$o))" -le 255 ] || return 1; done
}
ip4_int() { local IFS=.; set -- $1; echo $(( (10#$1 << 24) + (10#$2 << 16) + (10#$3 << 8) + 10#$4 )); }
# cidr4_ok <text> — an IPv4 address or CIDR (a bare address is /32). Prints "address bits".
cidr4_split() {
  local a="${1%/*}" b=32
  [ "$a" = "$1" ] || b="${1#*/}"
  ip4_ok "$a" && [[ "$b" =~ ^[0-9]{1,2}$ ]] && [ "$((10#$b))" -le 32 ] || return 1
  printf '%s %d\n' "$a" "$((10#$b))"
}
# in_cidr4 <IPv4> <CIDR> — the address lies in the range (both checked; IPv6 never matches here).
in_cidr4() {
  ip4_ok "$1" || return 1
  local s; s="$(cidr4_split "$2")" || return 1
  local net="${s% *}" bits="${s#* }" mask
  mask=$(( bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
  [ $(( $(ip4_int "$1") & mask )) -eq $(( $(ip4_int "$net") & mask )) ]
}
# cidr4_overlap <CIDR> <CIDR> — the two ranges share an address.
cidr4_overlap() {
  local a b
  a="$(cidr4_split "$1")" && b="$(cidr4_split "$2")" || return 1
  in_cidr4 "${a% *}" "$2" || in_cidr4 "${b% *}" "$1"
}
# ip6_hex <address> — the 32 hex digits of an IPv6 address (no zone, no IPv4 tail), or non-zero. Plain text only:
# nothing here goes through bash arithmetic before it is checked.
ip6_hex() {
  local a="${1,,}" head tail g out="" n=0 i
  local -a H=() T=()
  [[ "$a" =~ ^[0-9a-f:]{2,39}$ ]] || return 1
  case "$a" in *:::*) return 1 ;; esac
  if [[ "$a" == *::* ]]; then
    head="${a%%::*}"; tail="${a#*::}"
    [[ "$tail" != *::* ]] || return 1
    [ -z "$head" ] || IFS=: read -r -a H <<< "$head"
    [ -z "$tail" ] || IFS=: read -r -a T <<< "$tail"
    n=$(( 8 - ${#H[@]} - ${#T[@]} ))
    [ "$n" -ge 1 ] || return 1
  else
    IFS=: read -r -a H <<< "$a"
    [ "${#H[@]}" -eq 8 ] && [[ "$a" != *: ]] || return 1
  fi
  for g in "${H[@]}"; do [[ "$g" =~ ^[0-9a-f]{1,4}$ ]] || return 1; out+="$(printf '%4s' "$g" | tr ' ' 0)"; done
  for (( i = 0; i < n; i++ )); do out+=0000; done
  for g in "${T[@]}"; do [[ "$g" =~ ^[0-9a-f]{1,4}$ ]] || return 1; out+="$(printf '%4s' "$g" | tr ' ' 0)"; done
  [ "${#out}" -eq 32 ] || return 1
  printf '%s\n' "$out"
}
# cidr6_split <text> — an IPv6 address or CIDR (a bare address is /128). Prints "hex bits".
cidr6_split() {
  local a="${1%/*}" b=128 h
  [ "$a" = "$1" ] || b="${1#*/}"
  [[ "$b" =~ ^[0-9]{1,3}$ ]] && [ "$((10#$b))" -le 128 ] || return 1
  h="$(ip6_hex "$a")" || return 1
  printf '%s %d\n' "$h" "$((10#$b))"
}
# cidr6_overlap <CIDR> <CIDR> — the two IPv6 ranges share an address (a connection key such as 2001:db8:1:2::/64 is
# a range too).
cidr6_overlap() {
  local a b ha hb m k r
  a="$(cidr6_split "$1")" && b="$(cidr6_split "$2")" || return 1
  ha="${a% *}"; hb="${b% *}"; m="${a#* }"; [ "${b#* }" -ge "$m" ] || m="${b#* }"
  k=$(( m / 4 )); r=$(( m % 4 ))
  [ "${ha:0:k}" = "${hb:0:k}" ] || return 1
  [ "$r" -eq 0 ] && return 0
  [ $(( (16#${ha:k:1} ^ 16#${hb:k:1}) >> (4 - r) )) -eq 0 ]
}
# cidr_overlap <CIDR> <CIDR> — either family; IPv4 never overlaps IPv6.
cidr_overlap() {
  case "$1|$2" in
    *:*\|*:*) cidr6_overlap "$1" "$2" ;;
    *:*\|*|*\|*:*) return 1 ;;
    *) cidr4_overlap "$1" "$2" ;;
  esac
}

# ip_private <key> — a connection key in a private range: 10/8, 172.16/12, 192.168/16, 100.64/10 (carrier and
# tailnet addresses), fc00::/7.
ip_private() {
  case "$1" in
    fc*|fd*) return 0 ;;
  esac
  local r
  for r in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10; do in_cidr4 "$1" "$r" && return 0; done
  return 1
}

# stack_networks — the subnets of this installation's own Docker networks, one per line (the controller's proxy
# lets the health job list the project's networks, as on the host).
stack_networks() {
  local project="${COMPOSE_PROJECT_NAME:-$(basename "$PWD")}" id
  for id in $(docker network ls -q --filter "label=com.docker.compose.project=${project}" 2>/dev/null); do
    docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' "$id" 2>/dev/null
  done | grep -E '^[0-9a-fA-F.:]+/[0-9]{1,3}$' | sort -u
}

# gateway_proxies_problem [value] — why GATEWAY_TRUSTED_PROXIES (or the value given) can't be used, or nothing.
# Space-separated IPv4 or IPv6 addresses or CIDRs (Caddy reads it so; a comma is refused, not guessed at). Never
# everything, loopback, link-local, the rootless network's own 10.0.2.0/24, or any of this stack's networks (IPv4 or
# IPv6), and before they exist nothing in Docker's default pools: a proxy named there would let any container
# choose a client's address.
gateway_proxies_problem() {
  local value="${1-${GATEWAY_TRUSTED_PROXIES:-}}" r n nets
  [ -n "${value// /}" ] || return 0
  nets="$(stack_networks || true)"
  case "$value" in *,*) echo "GATEWAY_TRUSTED_PROXIES is separated by commas: use spaces (203.0.113.10/32 203.0.113.11/32)"; return 0 ;; esac
  for r in $value; do
    case "$r" in
      0.0.0.0/0|::/0|0.0.0.0|::) echo "GATEWAY_TRUSTED_PROXIES must not trust everyone ($r)"; return 0 ;;
      *:*)
        [[ "$r" =~ ^[0-9a-fA-F:]+(/[0-9]{1,3})?$ ]] || { echo "GATEWAY_TRUSTED_PROXIES: '$r' is not an address or CIDR"; return 0; }
        case "${r,,}" in ::1|::1/*|fe8*|fe9*|fea*|feb*|::/*) echo "GATEWAY_TRUSTED_PROXIES must not name loopback or link-local ($r)"; return 0 ;; esac
        [ "${r#*/}" = "$r" ] || [ "${r#*/}" -ge 32 ] || { echo "GATEWAY_TRUSTED_PROXIES: $r is far too wide for a proxy"; return 0; }
        cidr6_split "$r" >/dev/null || { echo "GATEWAY_TRUSTED_PROXIES: '$r' is not an address or CIDR"; return 0; }
        while read -r n; do
          [ -n "$n" ] || continue
          if cidr6_overlap "$r" "$n"; then echo "GATEWAY_TRUSTED_PROXIES must not name one of this server's Docker networks ($r overlaps $n)"; return 0; fi
        done < <(printf '%s\n' "$nets" | grep : || true) ;;
      *)
        cidr4_split "$r" >/dev/null || { echo "GATEWAY_TRUSTED_PROXIES: '$r' is not an address or CIDR"; return 0; }
        [ "$(cidr4_split "$r" | cut -d' ' -f2)" -ge 8 ] || { echo "GATEWAY_TRUSTED_PROXIES: $r is far too wide for a proxy"; return 0; }
        for n in 127.0.0.0/8 169.254.0.0/16 10.0.2.0/24; do
          if cidr4_overlap "$r" "$n"; then echo "GATEWAY_TRUSTED_PROXIES must not name this server's own addresses ($r overlaps $n)"; return 0; fi
        done
        while read -r n; do
          [ -n "$n" ] || continue
          if cidr4_overlap "$r" "$n"; then echo "GATEWAY_TRUSTED_PROXIES must not name one of this server's Docker networks ($r overlaps $n)"; return 0; fi
        done < <(printf '%s\n' "$nets" | grep -v : || true)
        # Before the first install there are no networks yet to compare with (review finding 6): Docker will make
        # them from its default pools, and the gateway would then trust its own networks and the Docker gateway some
        # clients arrive through. So nothing in those pools until they exist; update.sh checks the real ones.
        if ! printf '%s\n' "$nets" | grep -q '^[0-9]'; then
          for n in $(docker_default_pools); do
            if cidr4_overlap "$r" "$n"; then echo "GATEWAY_TRUSTED_PROXIES: $r overlaps Docker's default network pools ($n), where this server's own networks will be made. Name it after the first install: ./bin/update.sh then checks it against the networks Docker chose"; return 0; fi
          done
        fi ;;
    esac
  done
}
# docker_default_pools — the ranges Docker makes networks from unless its daemon is told otherwise: 172.17.0.0/16 to
# 172.31.0.0/16, then 192.168.0.0/16.
docker_default_pools() {
  local i
  for i in $(seq 17 31); do printf '172.%d.0.0/16\n' "$i"; done
  printf '192.168.0.0/16\n'
}

# client_address_front — the gateway's outside-facing Docker network (compose.yaml's `front`) of this installation,
# or CA_PROBE_NETWORK when set (bin/tests/authentik-lock-e2e.sh).
client_address_front() {
  if [ -n "${CA_PROBE_NETWORK:-}" ]; then printf '%s\n' "$CA_PROBE_NETWORK"; return 0; fi
  local project="${COMPOSE_PROJECT_NAME:-$(basename "$PWD")}"
  docker network ls -q --filter "label=com.docker.compose.project=${project}" \
    --filter "label=com.docker.compose.network=front" 2>/dev/null | head -n 1
}
# The curl image compose.yaml pins for discovery-gate (already on the server: the update's checks use it).
client_address_curl_image() {
  awk '$0 == "  discovery-gate:" {on=1} on && /image:/ {print $2; exit}' "${CA_COMPOSE_FILE:-compose.yaml}" 2>/dev/null
}

# client_address_probe — asks the sign-in server, through the gateway, with forged headers, which address it sees;
# writes CLIENT_ADDRESS_FILE (whole or not at all). From a one-off of the pinned curl image on the gateway's
# outside-facing network (`front`), as the controller's probe does: it reaches the same listener, the same
# trusted-proxy rule and the same header snippet as a request from outside (it is not one of the gateway's trusted
# proxies). Returns 0 when the answer is the probe's own address. Prints one line saying what it found.
client_address_probe() {
  local out ok=false seen="" own="" code why="" now ignored=false net image
  net="$(client_address_front)"; image="$(client_address_curl_image)"
  if [ -n "$net" ] && [ -n "$image" ]; then
    out="$(docker run --rm --network "$net" --pull never --user 100:101 --read-only --cap-drop ALL \
      --security-opt no-new-privileges:true --memory 64m "$image" -sk --max-time 10 \
      --connect-to "${AUTH_HOSTNAME}:443:gateway:443" "${CLIENT_ADDRESS_FORGED[@]}" \
      "https://${AUTH_HOSTNAME}/api/v3/flows/executor/${CLIENT_ADDRESS_FLOW}/" -w '\n%{local_ip}\n%{http_code}' 2>/dev/null)" || true
  else
    out=""
  fi
  code="$(printf '%s\n' "$out" | tail -n 1)"
  own="$(printf '%s\n' "$out" | tail -n 2 | head -n 1)"
  seen="$(printf '%s' "$out" | grep -oE "workforce-client-address=[0-9A-Fa-f.:/]{2,64}" | head -n 1 | cut -d= -f2 | tr 'A-F' 'a-f')"
  ip4_ok "$own" || own=""
  if [ -z "$seen" ]; then why="the sign-in server's address check didn't answer (${code:-no answer})"
  elif [[ "$seen" == 198.51.100.* ]]; then why="a forged header chose the address ($seen): the gateway doesn't replace forwarded headers"
  elif [ -n "$own" ] && [ "$seen" = "$own" ]; then ok=true; ignored=true
  else why="the sign-in server saw ${seen}, not the probe's own address ${own:-(unknown)}"; ignored=true
  fi
  [[ "$seen" =~ ^[0-9a-f.:/]{2,64}$ ]] || seen=""
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local json tmp
  local nets
  if nets="$(stack_networks)" && [ -n "$nets" ]; then
    nets="[$(printf '%s\n' "$nets" | head -n 50 | sed 's/.*/"&"/' | paste -sd, -)]"
  else
    nets=null
  fi
  json="$(printf '{"schema":1,"checkedAt":"%s","probeAddress":%s,"seen":%s,"forgedIgnored":%s,"ok":%s,"why":%s,"networks":%s}' \
    "$now" "$( [ -n "$own" ] && printf '"%s"' "$own" || printf null)" "$( [ -n "$seen" ] && printf '"%s"' "$seen" || printf null)" \
    "$ignored" "$ok" "$( [ -n "$why" ] && printf '"%s"' "${why//\"/}" || printf null)" "$nets")"
  mkdir -p "$(dirname "$CLIENT_ADDRESS_FILE")"
  tmp="${CLIENT_ADDRESS_FILE}.$$.tmp"
  printf '%s\n' "$json" > "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$CLIENT_ADDRESS_FILE"
  if [ "$ok" = true ]; then echo "the sign-in server sees each client's own address (forged headers ignored)"; return 0; fi
  echo "$why"
  return 1
}

# client_address_read — sets CA_AT (epoch), CA_OK (true|false), CA_SEEN, CA_PROBE, CA_WHY from CLIENT_ADDRESS_FILE,
# each empty where missing or not what the probe writes (the controller writes it under its own layout, so nothing
# in it is used unchecked). Returns 1 when there is no record, 2 when it can't be read as it should.
client_address_read() {
  local j at
  CA_AT=""; CA_OK=""; CA_SEEN=""; CA_PROBE=""; CA_WHY=""; CA_NETWORKS=""; CA_NETWORKS_KNOWN=no
  [ -e "$CLIENT_ADDRESS_FILE" ] || [ -L "$CLIENT_ADDRESS_FILE" ] || return 1
  [ ! -L "$CLIENT_ADDRESS_FILE" ] && [ -f "$CLIENT_ADDRESS_FILE" ] || return 2
  j="$(timeout 3 head -c 4096 "$CLIENT_ADDRESS_FILE" 2>/dev/null | tr -d '\r\n')" || return 2
  case "$j" in '{"schema":1,'*) ;; *) return 2 ;; esac
  at="$(bs_field "$j" checkedAt '"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,6})?Z"' | tr -d '"')"
  [ -z "$at" ] || CA_AT="$(date -u -d "$(printf '%s' "${at%%.*}" | tr 'T' ' ' | tr -d 'Z')" +%s 2>/dev/null)" || CA_AT=""
  CA_OK="$(bs_field "$j" ok 'true|false')"
  CA_SEEN="$(bs_field "$j" seen '"[0-9a-f.:/]{2,64}"' | tr -d '"')"
  CA_PROBE="$(bs_field "$j" probeAddress '"[0-9a-f.:/]{2,64}"' | tr -d '"')"
  CA_WHY="$(bs_field "$j" why '"[^"\\]{1,300}"' | tr -d '"')"
  # The stack's own networks, as the controller (or the probe here) read them from Docker; null when it couldn't.
  local nets
  nets="$(printf '%s' "$j" | sed -nE 's/.*"networks":\[([^]]{0,2000})\].*/\1/p' | head -n 1)"
  if printf '%s' "$j" | grep -qE '"networks":\['; then
    CA_NETWORKS_KNOWN=yes
    CA_NETWORKS="$(printf '%s' "$nets" | tr ',' '\n' | tr -d '" ' | grep -E '^[0-9a-fA-F.:]+/[0-9]{1,3}$' || true)"
  fi
  [ -n "$CA_AT" ] && [ -n "$CA_OK" ] || return 2
  # Never a time ahead of now (five minutes for clocks): an old check mustn't look fresh.
  [ "$CA_AT" -le "$(( $(date +%s) + 300 ))" ] || return 2
  return 0
}

# What the sign-in server recorded about where sign-ins came from (doctor.sh's part b), counted inside authentik:
# connection keys only, never a name. The summary lines first, so that no number of connections can push them out
# of what doctor.sh reads (review finding 9: a /48 spreading tries over thousands of /64s did), then the
# connections, at most 1000 lines:
#   WFSIGNINS <accounts> <days>                sign-ins of the last 7 days, all together
#   WFINSUM <n>                                over every sign-in connection, its accounts added up (the
#                                              concentration rule's whole, however many connections are listed)
#   WFFWD <accounts> <key,key,…>               of those, accounts whose right password came through a peer nobody named
#                                              in GATEWAY_TRUSTED_PROXIES (wf_fwd), and from where (at most 20)
#   WFALERTS <connection-spread> <account-spread> <throttled>   alerts of the last day (contract 3.6)
#   WFCONN <key> <in|try> <accounts> <days>    a connection sign-ins (in) or password tries (try) came from: every
#                                              one outside the public internet (this server's own networks are
#                                              there; at most 500), then the public sign-in ones, most accounts
#                                              first (at most 500). Public addresses that only tried a password are
#                                              never listed: an attacker has as many as they like.
# An account is the real account (its pk) wherever the records name one, whichever form of its name was typed.
# The program is passed word for word (the controller's allow-list compares it): change both together.
# shellcheck disable=SC2016
CLIENT_ADDRESS_AK='import ipaddress
from datetime import timedelta
from django.utils.timezone import now
from authentik.events.models import Event
def key(a):
    a = str(a or "").strip().lower()
    try:
        ip = ipaddress.ip_address(a[:-3] if a.endswith("/64") else a)
    except ValueError:
        return a
    if ip.version == 6 and ip.ipv4_mapped is not None:
        return str(ip.ipv4_mapped)
    return str(ip) if ip.version == 4 else str(ipaddress.ip_network((ip, 64), strict=False))
def public(k):
    try:
        return ipaddress.ip_network(k, strict=False).is_global
    except ValueError:
        return False
t = now()
seen = {}
people = set()
days = set()
fwd = {}
rows = Event.objects.filter(created__gte=t - timedelta(days=7), action__in=("login", "custom_workforce_password_right", "custom_workforce_password_try"))
for action, ip, ctx, user, created in rows.values_list("action", "client_ip", "context", "user", "created").iterator():
    ctx = ctx if isinstance(ctx, dict) else {}
    if action == "login":
        conn, who, kind = key(ip), "u:%s" % ((user or {}).get("pk") if isinstance(user, dict) else ""), "in"
    else:
        pk = ctx.get("wf_user_pk")
        who = "u:%s" % pk if isinstance(pk, int) else str(ctx.get("wf_account") or "")
        conn, kind = key(ctx.get("wf_conn")), "in" if action.endswith("right") else "try"
    if not conn or (kind == "try" and public(conn)):
        continue
    s = seen.setdefault((conn, kind), [set(), set()])
    s[0].add(who)
    s[1].add(created.date())
    if kind == "in":
        people.add(who)
        days.add(created.date())
        if ctx.get("wf_fwd") is True:
            fwd.setdefault(who, set()).add(conn)
print("WFSIGNINS", len(people), len(days))
print("WFINSUM", sum(len(w) for (c, k), (w, d) in seen.items() if k == "in"))
print("WFFWD", len(fwd), ",".join(sorted(set(c.replace(" ", "") for cs in fwd.values() for c in cs))[:20]) or "-")
alerts = Event.objects.filter(created__gte=t - timedelta(days=1), action="custom_workforce_password_alert")
kinds = [str((c or {}).get("wf_kind")) for c in alerts.values_list("context", flat=True)]
print("WFALERTS", kinds.count("connection-spread"), kinds.count("account-spread"), kinds.count("throttled"))
inside = sorted((c, k, len(w), len(d)) for (c, k), (w, d) in seen.items() if not public(c))
outside = sorted(((len(w), c, len(d)) for (c, k), (w, d) in seen.items() if k == "in" and public(c)), key=lambda x: (-x[0], x[1]))
for c, k, n, d in inside[:500]:
    print("WFCONN", c.replace(" ", ""), k, n, d)
for n, c, d in outside[:500]:
    print("WFCONN", c.replace(" ", ""), "in", n, d)'

# client_addresses_confirmed <key> — the operator confirmed this address as an office's own connection
# (CLIENT_ADDRESSES_CONFIRMED: addresses, connection keys or ranges, separated by commas or spaces). Used by the
# readiness check's concentration and forwarding rules only; never by the gateway or the sign-in server. A range
# confirms every connection inside it (the TEST appliance confirms its tailnet, 100.64.0.0/10: environments/test.env).
client_address_confirmed() {
  local c list="${CLIENT_ADDRESSES_CONFIRMED:-}"
  for c in ${list//,/ }; do
    c="${c,,}"
    [ "$c" = "$1" ] && return 0   # IPv6: the connection key, e.g. 2001:db8:1:2::/64, as the check names it
    case "$c|$1" in
      *:*/*\|*:*) # an IPv6 range: the whole /64 inside it
        local cb="${c#*/}"
        [[ "$cb" =~ ^[0-9]{1,3}$ ]] && [ "$((10#$cb))" -le 64 ] && cidr6_overlap "$1" "$c" && return 0 ;;
      *:*|*\|*:*) ;;
      */*\|*) in_cidr4 "$1" "$c" && return 0 ;;
    esac
  done
  return 1
}

# ---- doctor.sh's "client addresses" row, part (b) (contract 2.3 b). The row is the worst of its parts.
CA_STATE=ok; CA_DETAIL=""; CA_CONFIRMED_NOTE=""
ca_count() { case "${1:-}" in ""|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
ca_worse() { # ca_worse <ok|warn|skip|fail> <words> — keep the worst part (fail > skip > warn > ok)
  local rank_new rank_old
  rank() { case "$1" in fail) echo 3 ;; skip) echo 2 ;; warn) echo 1 ;; *) echo 0 ;; esac; }
  rank_new="$(rank "$1")"; rank_old="$(rank "$CA_STATE")"
  if [ "$rank_new" -gt "$rank_old" ]; then CA_STATE="$1"; CA_DETAIL="$2"; fi
}
OWN_SET=(10.0.2.0/24 127.0.0.0/8)
own_address() { # own_address <key> — a connection key in this server's own set (or a named proxy)
  case "$1" in ::/64|fe8*|fe9*|fea*|feb*) return 0 ;; esac
  local r
  for r in "${OWN_SET[@]}"; do
    case "$r" in *:*) cidr6_overlap "$1" "$r" && return 0 ;; *) in_cidr4 "$1" "$r" && return 0 ;; esac
  done
  return 1
}

# client_address_signins <WF… lines> — judges where sign-ins came from (CLIENT_ADDRESS_AK's output): this server's own
# networks (OWN_SET), concentration on one or two addresses, forwarding from a peer nobody named. Sets CA_PEOPLE,
# SIGNIN_ALERTS and, through ca_worse, CA_STATE and CA_DETAIL.
client_address_signins() {
  local CA_OUT="$1" IN_CONNS TOTAL TOP1 TOP2 CONC UNCONFIRMED PRIVATE WORDS FWD_UNCONFIRMED k key
  CA_FWD=""; CA_FWD_FROM=""
  local IN_SUM
  read -r _ CA_PEOPLE CA_DAYS <<< "$(printf '%s\n' "$CA_OUT" | grep '^WFSIGNINS ' | tail -n 1)"
  read -r _ IN_SUM <<< "$(printf '%s\n' "$CA_OUT" | grep '^WFINSUM ' | tail -n 1)"
  read -r _ CA_FWD CA_FWD_FROM <<< "$(printf '%s\n' "$CA_OUT" | grep '^WFFWD ' | tail -n 1)"
  SIGNIN_ALERTS="$(printf '%s\n' "$CA_OUT" | grep '^WFALERTS ' | tail -n 1)"
  # Sign-in connections by how many accounts signed in from each, most first (an account counts once per address).
  IN_CONNS="$(printf '%s\n' "$CA_OUT" | awk '$1 == "WFCONN" && $3 == "in" && $2 ~ /^[0-9a-f.:\/]+$/ && $4 ~ /^[0-9]+$/ {print $4, $2}' | sort -k1,1nr -k2,2 || true)"
  while read -r _ key _ _ _; do
    [[ "$key" =~ ^[0-9a-f.:/]{2,64}$ ]] || continue
    if own_address "$key"; then
      ca_worse fail "Sign-ins arrive from ${key}, this server's own network. The sign-in limits would treat everyone as one person. See RUNBOOK §7a."
    fi
  done < <(printf '%s\n' "$CA_OUT" | grep '^WFCONN ')
  # Concentration (contract 2.3 b, fix round): 3 or more accounts over 2 or more days, and at most 2 addresses carry
  # 80% or more of them. That is what a load balancer, an HA pair or a CDN nobody named looks like, and also what one
  # or two offices look like: the operator says which (GATEWAY_TRUSTED_PROXIES, or CLIENT_ADDRESSES_CONFIRMED).
  if ca_count "$CA_PEOPLE" && ca_count "$CA_DAYS" && [ "$CA_PEOPLE" -ge 3 ] && [ "$CA_DAYS" -ge 2 ] && [ -n "$IN_CONNS" ]; then
    TOTAL="$(printf '%s\n' "$IN_CONNS" | awk '{s += $1} END {print s + 0}')"
    # Over every sign-in connection, not only those listed (the program lists at most 500 public ones).
    if ca_count "${IN_SUM:-}" && [ "$IN_SUM" -gt "$TOTAL" ]; then TOTAL="$IN_SUM"; fi
    TOP1="$(printf '%s\n' "$IN_CONNS" | sed -n 1p)"; TOP2="$(printf '%s\n' "$IN_CONNS" | sed -n 2p)"
    CONC=()
    if [ $(( ${TOP1%% *} * 100 )) -ge $(( TOTAL * 80 )) ]; then CONC=("${TOP1#* }")
    elif [ -n "$TOP2" ] && [ $(( (${TOP1%% *} + ${TOP2%% *}) * 100 )) -ge $(( TOTAL * 80 )) ]; then CONC=("${TOP1#* }" "${TOP2#* }"); fi
    if [ "${#CONC[@]}" -gt 0 ]; then
      UNCONFIRMED=0; PRIVATE=0
      for k in "${CONC[@]}"; do
        client_address_confirmed "$k" || UNCONFIRMED=1
        ! ip_private "$k" || PRIVATE=1
      done
      WORDS="${CONC[*]}"; WORDS="${WORDS// / and }"
      if [ "$UNCONFIRMED" -eq 0 ]; then
        CA_CONFIRMED_NOTE="most sign-ins come from ${WORDS}, confirmed as your offices' own connections"
      elif [ "${#CONC[@]}" -eq 1 ] && [ "$PRIVATE" -eq 0 ]; then
        ca_worse warn "Every sign-in in the last 7 days came from one internet address, ${WORDS}. If that's your office, confirm it in CLIENT_ADDRESSES_CONFIRMED; if it's a load balancer or proxy, name it in GATEWAY_TRUSTED_PROXIES (RUNBOOK §7a)."
      else
        ca_worse fail "Most sign-ins come from ${WORDS}. If that's a load balancer or proxy in front of this server, name it in GATEWAY_TRUSTED_PROXIES; if they're your offices, confirm them in CLIENT_ADDRESSES_CONFIRMED (RUNBOOK §7a)."
      fi
    fi
  fi
  # Forwarding from an unnamed peer (fix round): a proxy with many outgoing addresses (a CDN) isn't caught by
  # concentration, but it forwards. More than half the accounts signing in that way fails, unless every address they
  # came through is confirmed.
  if ca_count "$CA_PEOPLE" && ca_count "${CA_FWD:-x}" && [ "$CA_PEOPLE" -gt 0 ] && [ $(( CA_FWD * 2 )) -gt "$CA_PEOPLE" ]; then
    FWD_UNCONFIRMED=0
    for k in ${CA_FWD_FROM//,/ }; do
      [ "$k" = - ] && continue
      client_address_confirmed "$k" || FWD_UNCONFIRMED=1
    done
    [ "${CA_FWD_FROM:--}" != - ] || FWD_UNCONFIRMED=1
    if [ "$FWD_UNCONFIRMED" -eq 1 ]; then
      ca_worse fail "${CA_FWD} of ${CA_PEOPLE} people signed in through something that forwards addresses (a CDN or proxy) that GATEWAY_TRUSTED_PROXIES doesn't name: the sign-in limits see the proxy, not them. Name it there (RUNBOOK §7a)."
    fi
  fi
}
