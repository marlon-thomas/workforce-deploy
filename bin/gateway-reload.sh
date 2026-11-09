#!/usr/bin/env bash
# gateway-reload.sh — make the running gateway serve the Caddyfile this bundle holds (issue 289).
#
# Caddy reads its configuration only when it starts, so a deploy that changed gateway/Caddyfile*
# left the gateway serving the old one until someone restarted it by hand. The installer's
# playbook, update.sh and every converge (deploy_to_test.py, deploy_to_prod.py) run this script:
#
#   1. compare: `caddy adapt` the Caddyfile named by GATEWAY_CADDYFILE inside the gateway container
#      (its environment fills the {$VAR}s), ask the running gateway what it runs (its admin API,
#      which listens only inside the container), and compare the sha256 of both as canonical JSON.
#      Equal: nothing to do, nothing restarts.
#   2. different: `caddy reload`, which has no downtime. A reload Caddy refuses (the configuration
#      does not load, or fails as it starts listening) is rolled back by Caddy itself, so the gateway
#      keeps serving the old one; the script stops there and never recreates a gateway that serves.
#      Only a gateway that can't be reloaded at all (not running, created before compose.yaml
#      mounted the gateway folder, not answering docker exec, admin API silent) is recreated, after
#      `caddy validate` in a one-off container. Validate opens no listeners, so it catches a bad
#      configuration but not one that fails only as it starts; the check below then reports it.
#   3. check: the gateway answers, its admin API reports the new configuration's hash, and the
#      Content-Security-Policy it serves for the app is one the new configuration sets.
#
# On failure the last lines ("XX  Gateway …") say what state the gateway is in and what to do;
# update.sh and deploylib.py repeat them rather than guess.
#
# Usage (on the server, in the bundle folder; safe to run any time):
#   ./bin/gateway-reload.sh        exit 0 = the gateway runs this bundle's configuration
#                                  exit 1 = the gateway was not changed (2 = the script could not run)
#                                  exit 3 = the gateway was changed but is not confirmed
set -euo pipefail

# Caddy's default admin address. It is inside the gateway container only (no port is published).
GW_ADMIN_URL="http://127.0.0.1:2019/config/"
# A path the gateway answers itself (`respond /api/public/mail/* 404` in every shipped Caddyfile),
# so the app's security headers come back even while the app is still starting.
GW_PROBE_PATH="/api/public/mail/gateway-check"
GW_TMP="${GW_TMP:-}"

gw_say()  { printf '==> %s\n' "$*"; }
gw_fail() { printf 'XX  %s\n' "$*"; }
# gw_tail <file> — the reason in a command's output: caddy's "Error:" line, else the last line.
gw_tail() { grep -m1 '^Error' "$1" 2>/dev/null || grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -n 1; }
pause()   { sleep "$1"; }

# json_tool hash|csp < config.json — "hash": sha256 of the canonical JSON (sorted keys, no
# spaces), so `caddy adapt` output and the admin API's own encoding compare equal. "csp": every
# Content-Security-Policy value the configuration sets, one per line.
json_tool() {
  python3 -I -c '
import hashlib, json, sys
cfg = json.load(sys.stdin)
if sys.argv[1] == "hash":
    canon = json.dumps(cfg, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    print(hashlib.sha256(canon.encode()).hexdigest())
else:
    def walk(o):
        if isinstance(o, dict):
            for k, v in o.items():
                if k.lower() == "content-security-policy" and isinstance(v, list):
                    print("\n".join(s for s in v if isinstance(s, str)))
                else:
                    walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)
    walk(cfg)
' "$1"
}

# ------------------------------------------------------------------ the gateway (stubbed in tests)
gw_state()       { docker compose ps -a --format '{{.State}}' gateway 2>/dev/null | head -1 || true; }
gw_exec()        { docker compose exec -T gateway "$@"; }
# gw_sees_config — "yes" / "no": can the gateway see the Caddyfile? Nothing = docker exec failed.
# shellcheck disable=SC2016  # expanded inside the container
gw_sees_config() { gw_exec sh -c 'if [ -f "$1" ]; then echo yes; else echo no; fi' sh "$GW_IN" 2>/dev/null || true; }
gw_render()      { gw_exec caddy adapt --config "$GW_IN" --adapter caddyfile; }
gw_running()     { gw_exec wget -qO- "$GW_ADMIN_URL"; }
gw_reload()      { gw_exec caddy reload --config "$GW_IN" --adapter caddyfile; }
# A one-off container with the gateway's own image, mounts and environment; no ports published.
gw_validate()    { docker compose run --rm --no-deps -T gateway caddy validate --config "$GW_IN" --adapter caddyfile; }
gw_recreate()    { docker compose up -d --no-deps --force-recreate gateway; }
# probe_http — the HTTP status the gateway gives the app's name on port 80 (000 = no answer).
probe_http() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
    --resolve "${APP_HOSTNAME}:80:127.0.0.1" "http://${APP_HOSTNAME}/" 2>/dev/null || true
}
# probe_csp — the Content-Security-Policy served for the app over HTTPS (empty = none, or no answer).
probe_csp() {
  curl -sk -o /dev/null -D - --max-time 8 \
    --resolve "${APP_HOSTNAME}:443:127.0.0.1" "https://${APP_HOSTNAME}${GW_PROBE_PATH}" 2>/dev/null \
    | tr -d '\r' | awk 'tolower($0) ~ /^content-security-policy:/ { sub(/^[^:]*:[ \t]*/, ""); print; exit }' || true
}

# ------------------------------------------------------------------ decisions
# gw_paths — GW_CADDYFILE (bundle path) and GW_IN (the same file inside the container). compose.yaml
# mounts ./gateway at /etc/caddy/gateway, so the Caddyfile must be a file in that folder.
gw_paths() {
  GW_CADDYFILE="${GATEWAY_CADDYFILE:-./gateway/Caddyfile}"
  case "$GW_CADDYFILE" in
    *..*) gw_fail "GATEWAY_CADDYFILE=${GW_CADDYFILE} leaves ./gateway"; return 1 ;;
    ./gateway/?*|gateway/?*) ;;
    *) gw_fail "GATEWAY_CADDYFILE=${GW_CADDYFILE} is not in ./gateway, the only folder compose.yaml mounts into the gateway"
       return 1 ;;
  esac
  if [ ! -f "$GW_CADDYFILE" ]; then gw_fail "${GW_CADDYFILE} (GATEWAY_CADDYFILE) is not in this bundle"; return 1; fi
  GW_IN="/etc/caddy/${GW_CADDYFILE#./}"
}

# gw_replace <why> — only for a gateway that can't be reloaded: validate in a one-off container,
# then (re)create it. From the recreate on, the gateway counts as changed (GW_TOUCHED).
gw_replace() {
  gw_say "$1: validating ${GW_CADDYFILE}, then recreating the gateway…"
  if ! gw_validate > "$GW_TMP/validate.out" 2>&1; then
    gw_fail "${GW_CADDYFILE} does not pass caddy validate: $(gw_tail "$GW_TMP/validate.out")"
    return 1
  fi
  GW_TOUCHED=1
  if ! gw_recreate > "$GW_TMP/recreate.out" 2>&1; then
    gw_fail "docker compose could not recreate the gateway: $(gw_tail "$GW_TMP/recreate.out")"
    return 1
  fi
}

# gw_hashes — render this bundle's configuration in the running gateway (GW_WANT) and read the one
# it runs (GW_HAVE, empty when the admin API does not answer). Returns 1 when the Caddyfile does
# not adapt, with the reason in $GW_TMP/render.err.
gw_hashes() {
  GW_WANT=""; GW_HAVE=""
  gw_render > "$GW_TMP/want.json" 2> "$GW_TMP/render.err" || return 1
  GW_WANT="$(json_tool hash < "$GW_TMP/want.json" 2>> "$GW_TMP/render.err")" || return 1
  if gw_running > "$GW_TMP/have.json" 2>/dev/null; then
    GW_HAVE="$(json_tool hash < "$GW_TMP/have.json" 2>/dev/null)" || GW_HAVE=""
  fi
}

# gw_check <what happened> — the gateway answers, runs the new configuration and serves its CSP.
gw_check() {
  local what="$1" code="000" i csp note
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    code="$(probe_http)"; [ "${code:-000}" != 000 ] && break
    [ "$i" -lt 15 ] && pause 2
  done
  if [ "${code:-000}" = 000 ]; then
    gw_fail "The gateway does not answer on port 80 (${what}). See: docker compose logs --tail 50 gateway"
    return 1
  fi
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if ! gw_hashes; then
      gw_fail "${GW_CADDYFILE} does not load in the gateway: $(gw_tail "$GW_TMP/render.err")"
      return 1
    fi
    [ -n "$GW_HAVE" ] && [ "$GW_HAVE" = "$GW_WANT" ] && break
    [ "$i" -lt 10 ] && pause 1
  done
  if [ -z "$GW_HAVE" ]; then
    gw_fail "The gateway's admin API (inside the container) does not answer, so its configuration can't be confirmed (${what})."
    return 1
  fi
  if [ "$GW_HAVE" != "$GW_WANT" ]; then
    gw_fail "The gateway still runs another configuration (sha256 ${GW_HAVE:0:12}) than ${GW_CADDYFILE} (sha256 ${GW_WANT:0:12}) (${what})."
    return 1
  fi
  csp="$(probe_csp)"
  if [ -n "$csp" ]; then
    json_tool csp < "$GW_TMP/want.json" > "$GW_TMP/csp.txt" 2>/dev/null || : > "$GW_TMP/csp.txt"
    if ! grep -Fxq -- "$csp" "$GW_TMP/csp.txt"; then
      gw_fail "The gateway serves a Content-Security-Policy that ${GW_CADDYFILE} does not set: ${csp}"
      return 1
    fi
    note="serves its Content-Security-Policy"
  else
    note="no Content-Security-Policy over HTTPS to compare yet (certificate not issued?)"
  fi
  gw_say "gateway ${what}: runs ${GW_CADDYFILE} (sha256 ${GW_WANT:0:12}), answers (HTTP ${code}), ${note}"
}

gateway_converge() {
  gw_paths || return 1
  local state sees
  state="$(gw_state)"
  if [ "$state" != running ]; then
    GW_WAS="it is still not running (${state:-no container})"
    gw_replace "The gateway is not running (${state:-no container})" || return 1
    gw_check "started"; return
  fi
  GW_WAS="it still serves its previous configuration"
  sees="$(gw_sees_config)"
  if [ "$sees" != yes ]; then
    if [ "$sees" = no ]; then
      gw_replace "The gateway was created before compose.yaml mounted the gateway folder, so it can't see ${GW_CADDYFILE}" || return 1
    else
      gw_replace "The gateway does not answer docker exec, so it can't be reloaded" || return 1
    fi
    gw_check "recreated"; return
  fi
  if ! gw_hashes; then
    gw_fail "${GW_CADDYFILE} does not load: $(gw_tail "$GW_TMP/render.err")"
    return 1
  fi
  if [ -z "$GW_HAVE" ]; then
    gw_replace "The gateway's admin API does not answer, so it can't be reloaded" || return 1
    gw_check "recreated"; return
  fi
  if [ "$GW_HAVE" = "$GW_WANT" ]; then
    GW_WAS="it already runs this bundle's configuration"
    GW_ADVICE="See: docker compose logs --tail 50 gateway"
    gw_check "unchanged"; return
  fi
  gw_say "The gateway's configuration changed (running sha256 ${GW_HAVE:0:12}, ${GW_CADDYFILE} sha256 ${GW_WANT:0:12}): caddy reload…"
  if ! gw_reload > "$GW_TMP/reload.out" 2>&1; then
    # Caddy has rolled back to the configuration it was serving. Recreating would start a new
    # container on the same Caddyfile, which fails the same way, and crash-loop a gateway that serves.
    gw_fail "Caddy refused the reload and went back to the configuration it was serving: $(gw_tail "$GW_TMP/reload.out")"
    return 1
  fi
  GW_TOUCHED=1
  gw_check "reloaded"
}

# gateway_reload — gateway_converge, then on failure the closing "XX  Gateway …" lines: whether the
# gateway was changed, and what to do. Returns 0 (runs this bundle's configuration), 1 (not
# changed) or 3 (changed, not confirmed).
gateway_reload() {
  GW_TOUCHED=0; GW_WAS="it was not looked at"; GW_ADVICE=""
  gateway_converge && return 0
  if [ "$GW_TOUCHED" = 0 ]; then
    gw_fail "Gateway not changed: ${GW_WAS}. ${GW_ADVICE:-Fix ${GW_CADDYFILE:-the Caddyfile}, then run ./bin/gateway-reload.sh}"
    return 1
  fi
  gw_fail "Gateway changed but not confirmed: it may be down. See: docker compose logs --tail 50 gateway"
  if git rev-parse -q --verify 'HEAD@{1}' >/dev/null 2>&1; then
    gw_fail "Gateway: to go back to the Caddyfile the bundle had before its last update: git checkout HEAD@{1} -- ${GW_CADDYFILE} && ./bin/gateway-reload.sh (then git checkout -- ${GW_CADDYFILE} before the next deploy)"
  else
    gw_fail "Gateway: to go back, put the previous ${GW_CADDYFILE} in place, then run ./bin/gateway-reload.sh"
  fi
  return 3
}

# ------------------------------------------------------------------ entry point
usage() { sed -n '2,28p' "${BASH_SOURCE[0]}"; }

main() {
  case "${1:-}" in
    "") ;;
    -h|--help) usage; return 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; return 2 ;;
  esac
  cd "$(dirname "${BASH_SOURCE[0]}")/.." || return 2
  if [ ! -f .env ]; then echo "No .env here — run ./bin/install.sh first." >&2; return 2; fi
  # shellcheck disable=SC1091
  . ./.env
  # shellcheck source=lib/common.sh
  . ./bin/lib/common.sh
  use_docker_socket
  if [ -z "${APP_HOSTNAME:-}" ]; then gw_fail "APP_HOSTNAME is not set in .env"; return 2; fi
  command -v python3 >/dev/null 2>&1 || { gw_fail "python3 is needed to compare the configurations"; return 2; }
  GW_TMP="$(mktemp -d)"
  trap 'rm -rf "$GW_TMP"' EXIT
  gateway_reload
}

# Run when executed; only define the functions when sourced (bin/tests/gateway-reload-test.sh).
# Called in a `||` list, so each step's failure is handled where it happens, not by errexit.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@" || exit $?
fi
