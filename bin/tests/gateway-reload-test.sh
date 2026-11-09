#!/usr/bin/env bash
# gateway-reload-test.sh — hermetic self-test of bin/gateway-reload.sh (issue 289): the real
# decision and check code runs against a simulated gateway (the docker and curl seams are stubs);
# the configuration hashes are the real canonical-JSON ones. Also guards the wiring: compose
# mounts the gateway folder, and every deploy path runs the script. No Docker, no network.
# Run by bin/ci-validate.sh.
#   ./bin/tests/gateway-reload-test.sh      exit 0 = all pass
# Variables are read by the sourced script, stubs are called indirectly:
# shellcheck disable=SC2034,SC2317
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# shellcheck source=../gateway-reload.sh
. "$HERE/../gateway-reload.sh"
set +e   # the tests check exit codes themselves

PASS=0; FAILN=0
ok()  { PASS=$((PASS+1)); }
bad() { FAILN=$((FAILN+1)); printf 'FAIL: %s\n' "$*"; }
check() { if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$3] got [$2]"; fi; }
contains() { case "$2" in *"$3"*) ok ;; *) bad "$1: [$3] not in output: $2" ;; esac; }

# --- a bundle folder; what its Caddyfiles adapt to is canned JSON
mkdir -p "$WORK/bundle/gateway" "$WORK/tmp"; cd "$WORK/bundle" || exit 1
: > gateway/Caddyfile; : > gateway/Caddyfile.localca
GW_TMP="$WORK/tmp"; APP_HOSTNAME=app.example.test
OLD_CSP="default-src 'self'; frame-ancestors 'none'"
NEW_CSP="default-src 'self'; frame-src 'self' blob:; frame-ancestors 'none'"
# adapted <csp> — the shape `caddy adapt` prints (its own field order, compact)
adapted() { printf '{"apps":{"http":{"servers":{"srv0":{"listen":[":443"],"routes":[{"handle":[{"handler":"headers","response":{"set":{"Content-Security-Policy":["%s"]},"deferred":true}}]}]}}}}}\n' "$1"; }
# admin <csp> — the same configuration as the admin API returns it (sorted keys, other spacing)
admin() { printf '{"apps": {"http": {"servers": {"srv0": {"listen": [":443"], "routes": [{"handle": [{"handler": "headers", "response": {"deferred": true, "set": {"Content-Security-Policy": ["%s"]}}}]}]}}}}}\n' "$1"; }

# --- the simulated gateway
reset() {
  GATEWAY_CADDYFILE=./gateway/Caddyfile.localca
  G_STATE=running; G_SEES=1; G_BAD=0; G_ADMIN=1; G_VALID=1; G_RELOAD=ok; G_HTTP=308; G_CSP=auto
  G_FILE="$(adapted "$NEW_CSP")"; G_RUN="$(admin "$NEW_CSP")"
  RELOADS=0; RECREATES=0; VALIDATES=0
}
gw_state()       { printf '%s\n' "$G_STATE"; }
gw_sees_config() { [ "$G_SEES" = 1 ]; }
gw_render() {
  if [ "$G_BAD" = 1 ]; then echo "Error: adapting config using caddyfile: ${GW_IN}:3: unrecognized directive: bogus" >&2; return 1; fi
  printf '%s\n' "$G_FILE"
}
gw_running() { if [ "$G_ADMIN" = 1 ]; then printf '%s\n' "$G_RUN"; else echo "wget: can't connect to remote host" >&2; return 1; fi; }
gw_reload() {
  RELOADS=$((RELOADS+1))
  case "$G_RELOAD" in
    ok)   G_RUN="$G_FILE" ;;
    noop) ;;   # says yes, keeps the old configuration
    fail) echo "Error: loading new config: http app module: start: listening on :443: address already in use"; return 1 ;;
  esac
}
gw_validate() {
  VALIDATES=$((VALIDATES+1))
  if [ "$G_BAD" = 1 ] || [ "$G_VALID" = 0 ]; then echo "Error: loading initial config: tls: open /etc/caddy/tls/tls.crt: no such file"; return 1; fi
}
gw_recreate() { RECREATES=$((RECREATES+1)); G_STATE=running; G_SEES=1; G_ADMIN=1; G_RUN="$G_FILE"; }
probe_http() { echo "$G_HTTP"; }
probe_csp() { if [ "$G_CSP" = auto ]; then printf '%s' "$G_RUN" | json_tool csp | head -1; else printf '%s' "$G_CSP"; fi; }
pause() { :; }
run() { gateway_converge > "$WORK/out" 2>&1; RC=$?; OUT="$(cat "$WORK/out")"; }
calls() { echo "reload=$RELOADS validate=$VALIDATES recreate=$RECREATES"; }

# 1. canonical hashing: key order and spacing don't count, content does; CSP values are found
check "hash ignores order and spacing" "$(adapted "$NEW_CSP" | json_tool hash)" "$(admin "$NEW_CSP" | json_tool hash)"
if [ "$(adapted "$NEW_CSP" | json_tool hash)" != "$(adapted "$OLD_CSP" | json_tool hash)" ]; then ok; else bad "hash sees a changed header"; fi
check "csp values" "$(adapted "$NEW_CSP" | json_tool csp)" "$NEW_CSP"

# 2. unchanged: nothing reloads or restarts, the result is still checked
reset; run
check "unchanged exit" "$RC" 0
check "unchanged touches nothing" "$(calls)" "reload=0 validate=0 recreate=0"
contains "unchanged says so" "$OUT" "gateway unchanged: runs ./gateway/Caddyfile.localca"
contains "unchanged csp" "$OUT" "serves its Content-Security-Policy"

# 3. the incident: the Caddyfile changed under a running gateway -> caddy reload, no restart
reset; G_RUN="$(admin "$OLD_CSP")"; run
check "changed exit" "$RC" 0
check "changed reloads only" "$(calls)" "reload=1 validate=0 recreate=0"
contains "changed says why" "$OUT" "configuration changed (running sha256"
contains "changed reloaded" "$OUT" "gateway reloaded: runs ./gateway/Caddyfile.localca"

# 4. reload says yes but the gateway keeps the old configuration: a clear failure
reset; G_RUN="$(admin "$OLD_CSP")"; G_RELOAD=noop; run
check "stale exit" "$RC" 1
contains "stale names it" "$OUT" "still runs another configuration"

# 5. the new Caddyfile does not load: the gateway is not touched
reset; G_RUN="$(admin "$OLD_CSP")"; G_BAD=1; run
check "bad exit" "$RC" 1
check "bad touches nothing" "$(calls)" "reload=0 validate=0 recreate=0"
contains "bad gives caddy's reason" "$OUT" "unrecognized directive: bogus"
contains "bad keeps serving" "$OUT" "keeps serving its current configuration"

# 6. the gateway is not running: validated, then started
reset; G_STATE=exited; G_ADMIN=0; run
check "stopped exit" "$RC" 0
check "stopped validates, then starts" "$(calls)" "reload=0 validate=1 recreate=1"
contains "stopped state" "$OUT" "not running (exited)"
contains "stopped started" "$OUT" "gateway started"

# 7. not running and the Caddyfile is invalid: never started into a broken configuration
reset; G_STATE=""; G_VALID=0; run
check "stopped+invalid exit" "$RC" 1
check "stopped+invalid not started" "$(calls)" "reload=0 validate=1 recreate=0"
contains "stopped+invalid reason" "$OUT" "does not pass caddy validate"

# 8. a gateway from before the folder mount can't see the file: recreated (once, on upgrade)
reset; G_SEES=0; G_RUN="$(admin "$OLD_CSP")"; run
check "single-file mount exit" "$RC" 0
check "single-file mount recreated" "$(calls)" "reload=0 validate=1 recreate=1"
contains "single-file mount why" "$OUT" "created before compose.yaml mounted the gateway folder"

# 9. admin API silent: the fallback is a recreate
reset; G_ADMIN=0; run
check "admin silent exit" "$RC" 0
check "admin silent recreated" "$(calls)" "reload=0 validate=1 recreate=1"

# 10. reload refused although the configuration is valid: recreate; invalid: left alone
reset; G_RUN="$(admin "$OLD_CSP")"; G_RELOAD=fail; run
check "reload refused exit" "$RC" 0
check "reload refused recreated" "$(calls)" "reload=1 validate=1 recreate=1"
contains "reload refused reason" "$OUT" "address already in use"
reset; G_RUN="$(admin "$OLD_CSP")"; G_RELOAD=fail; G_VALID=0; run
check "reload refused+invalid exit" "$RC" 1
check "reload refused+invalid kept" "$(calls)" "reload=1 validate=1 recreate=0"

# 11. the served Content-Security-Policy is not the new one: a clear failure
reset; G_CSP="$OLD_CSP"; run
check "old csp exit" "$RC" 1
contains "old csp names it" "$OUT" "serves a Content-Security-Policy that ./gateway/Caddyfile.localca does not set"

# 12. no HTTPS answer yet (certificate being issued): a note, not a failure
reset; G_CSP=""; run
check "no https exit" "$RC" 0
contains "no https note" "$OUT" "no Content-Security-Policy over HTTPS to compare yet"

# 13. the gateway does not answer at all: a clear failure
reset; G_HTTP=000; run
check "no answer exit" "$RC" 1
contains "no answer names it" "$OUT" "does not answer on port 80"

# 14. GATEWAY_CADDYFILE: in ./gateway only, and present; the default is ./gateway/Caddyfile
for bad_path in /etc/caddy/Caddyfile ./Caddyfile ./gateway/../secrets/x ./gateway/; do
  reset; GATEWAY_CADDYFILE="$bad_path"; run
  check "path $bad_path refused" "$RC" 1
  check "path $bad_path touches nothing" "$(calls)" "reload=0 validate=0 recreate=0"
done
reset; GATEWAY_CADDYFILE=./gateway/Caddyfile.missing; run
contains "missing file" "$OUT" "is not in this bundle"
reset; unset GATEWAY_CADDYFILE; gw_paths
check "default path" "$GW_IN" "/etc/caddy/gateway/Caddyfile"
# compose runs /etc/caddy/${GATEWAY_CADDYFILE}: the same file the script reloads
for f in ./gateway/Caddyfile ./gateway/Caddyfile.localca gateway/Caddyfile.localca; do
  GATEWAY_CADDYFILE="$f"; gw_paths
  check "compose path = reload path ($f)" "$(realpath -m "/etc/caddy/$f")" "$GW_IN"
done

# 15. wiring: the folder is mounted, never the single file, and every deploy path runs the script
cd "$ROOT" || exit 1
contains "compose mounts the folder" "$(cat compose.yaml)" "- ./gateway:/etc/caddy/gateway:ro"
contains "compose runs the named file" "$(cat compose.yaml)" '"--config", "/etc/caddy/${GATEWAY_CADDYFILE:-./gateway/Caddyfile}"'
check "no single-file Caddyfile mount" "$(grep -l ':/etc/caddy/Caddyfile' compose*.yaml)" ""
contains "update.sh runs it" "$(cat bin/update.sh)" "./bin/gateway-reload.sh ||"
contains "installer playbook runs it" "$(cat ansible/roles/workforce/tasks/main.yml)" "ansible.builtin.command: ./bin/gateway-reload.sh"
contains "converge runs it" "$(cat bin/deploylib.py)" "./bin/gateway-reload.sh"
contains "deploy_to_test runs it" "$(cat bin/deploy_to_test.py)" "deploylib.reload_gateway(run)"
contains "deploy_to_prod runs it" "$(cat bin/deploy_to_prod.py)" "deploylib.reload_gateway(ssh.run)"
check "the script is executable" "$([ -x bin/gateway-reload.sh ] && echo yes)" "yes"

echo "gateway-reload-test: ${PASS} passed, ${FAILN} failed"
[ "$FAILN" -eq 0 ]
