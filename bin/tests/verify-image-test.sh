#!/usr/bin/env bash
# Self-test for bin/lib/signatures.sh: a Workforce image is used only by the digest the release key signed
# (Workforce issue 422). Hermetic: temp files and a fake `docker` on PATH that plays the registry and cosign
# and logs what it was asked. bin/tests/verify-image-e2e.sh does the same against a real registry and cosign.
#   ./bin/tests/verify-image-test.sh      exit 0 = all pass
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bundle/bin/lib" "$WORK/fakebin"
cp "$HERE/../lib/signatures.sh" "$WORK/bundle/bin/lib/"
# shellcheck source=../lib/signatures.sh
. "$WORK/bundle/bin/lib/signatures.sh"

PASS=0; FAILN=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAILN=$((FAILN+1)); printf 'FAIL: %s: expected [%s] got [%s]\n' "$1" "$3" "$2"; fi; }
contains() { case "$2" in *"$3"*) PASS=$((PASS+1)) ;; *) FAILN=$((FAILN+1)); printf 'FAIL: %s: [%s] not in: %s\n' "$1" "$3" "$2" ;; esac; }
lacks() { case "$2" in *"$3"*) FAILN=$((FAILN+1)); printf 'FAIL: %s: [%s] should not be in: %s\n' "$1" "$3" "$2" ;; *) PASS=$((PASS+1)) ;; esac; }

REPO=ghcr.io/example/workforce-suite
D="sha256:$(printf '%064d' 0 | tr 0 b)"
OTHER="sha256:$(printf '%064d' 0 | tr 0 c)"

# The fake docker: FAKE_RESOLVE is what triangulate prints (empty = the tag isn't there), FAKE_VERIFY its exit
# status, FAKE_LABEL the pulled image's version label. Every call is logged, one per line.
cat > "$WORK/fakebin/docker" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LOG"
case "$1" in
  info) echo '["name=seccomp,profile=builtin"]' ;;
  run)
    args=" $* "
    case "$args" in
      *" triangulate "*)
        [ -n "${FAKE_RESOLVE:-}" ] || { echo "Error: MANIFEST_UNKNOWN: manifest unknown" >&2; exit 1; }
        echo "$FAKE_RESOLVE" ;;
      *" verify "*)
        [ "${FAKE_VERIFY:-0}" = 0 ] || { echo "Error: no matching signatures: invalid signature when validating ASN.1 encoded signature" >&2; exit 1; }
        echo '[{"critical":{}}]' ;;
      *) exit 9 ;;
    esac ;;
  pull) [ "${FAKE_PULL:-0}" = 0 ] || { echo "Error response from daemon: denied" >&2; exit 1; } ;;
  image) [ -n "${FAKE_LABEL+x}" ] || exit 1; echo "$FAKE_LABEL" ;;
  *) exit 9 ;;
esac
FAKE
chmod +x "$WORK/fakebin/docker"
export PATH="$WORK/fakebin:$PATH" FAKE_LOG="$WORK/docker.log"
: > "$FAKE_LOG"

# --- the key file
out="$(release_key_problem)"
contains "no cosign.pub: refused" "$out" "No release key yet"
contains "no cosign.pub: names the issue" "$out" "issue 353"
out="$(verified_image "$REPO" 1.2.3 2>&1)"; rc=$?
check "no cosign.pub: verified_image refuses" "$rc" 1
contains "no cosign.pub: says why" "$out" "No release key yet"
check "no cosign.pub: the registry is never asked" "$(cat "$FAKE_LOG")" ""

printf -- '-----BEGIN ENCRYPTED SIGSTORE PRIVATE KEY-----\nabc\n-----END ENCRYPTED SIGSTORE PRIVATE KEY-----\n' > "$WORK/bundle/cosign.pub"
contains "a private key as cosign.pub" "$(release_key_problem)" "not one public key"
printf -- '-----BEGIN PUBLIC KEY-----\nabc\n-----END PUBLIC KEY-----\n-----BEGIN PUBLIC KEY-----\ndef\n-----END PUBLIC KEY-----\n' > "$WORK/bundle/cosign.pub"
contains "two keys in cosign.pub" "$(release_key_problem)" "not one public key"
: > "$WORK/bundle/cosign.pub"
contains "an empty cosign.pub" "$(release_key_problem)" "not one public key"
printf -- '-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEexample\n-----END PUBLIC KEY-----\n' > "$WORK/bundle/cosign.pub"
check "one public key" "$(release_key_problem)" ""

# --- what can be checked
check "a repository and a version" "$(release_ref_problem "$REPO" 1.2.3)" ""
contains "latest is not a version" "$(release_ref_problem "$REPO" latest)" "'latest' is not a version"
contains "a version with a space" "$(release_ref_problem "$REPO" '1.2 3')" "is not a version"
contains "a version that is shell" "$(release_ref_problem "$REPO" '1;rm -rf /')" "is not a version"
contains "a repository with a tag in it" "$(release_ref_problem "$REPO:1.2.3" 1.2.3)" "is not an image repository"
contains "a repository with capitals" "$(release_ref_problem "ghcr.io/Example/x" 1.2.3)" "is not an image repository"

# --- signed: the digest, verified by digest with the committed key, cosign pinned and locked down
: > "$FAKE_LOG"
got="$(FAKE_RESOLVE="$REPO@$D" FAKE_VERIFY=0 verified_image "$REPO" 1.2.3 2>"$WORK/err")"; rc=$?
check "signed: accepted" "$rc" 0
check "signed: the digest, not the tag" "$got" "$REPO@$D"
log="$(cat "$FAKE_LOG")"
contains "resolved once, by tag" "$log" "triangulate --type digest $REPO:1.2.3"
contains "verified by digest with cosign.pub, no transparency log" "$log" "verify --key /release/cosign.pub --insecure-ignore-tlog=true $REPO@$D"
lacks "never verified by tag" "$(grep ' verify ' "$FAKE_LOG")" "$REPO:1.2.3"
contains "cosign is the pinned image" "$log" "$COSIGN_IMAGE"
contains "the committed key, read-only" "$log" "-v $WORK/bundle/cosign.pub:/release/cosign.pub:ro"
contains "cosign: no capabilities" "$log" "--cap-drop ALL"
contains "cosign: read-only" "$log" "--read-only"
contains "cosign: no new privileges" "$log" "--security-opt no-new-privileges:true"
lacks "nothing pulled by verified_image" "$log" "pull"
pinned=no; [[ "$COSIGN_IMAGE" =~ @sha256:[0-9a-f]{64}$ ]] && pinned=yes
check "cosign pinned by digest" "$pinned" yes

# --- refusals: non-zero, a reason, nothing on stdout
refused() {   # LABEL WANT-IN-STDERR  (env set by the caller)
  local out rc
  out="$(verified_image "$REPO" 1.2.3 2>"$WORK/err")"; rc=$?
  check "$1: refused" "$rc" 1
  check "$1: nothing to run" "$out" ""
  contains "$1: says why" "$(cat "$WORK/err")" "$2"
}
FAKE_RESOLVE="$REPO@$D" FAKE_VERIFY=1 refused "not signed with the key" "is not signed with the Workforce release key"
FAKE_RESOLVE="" refused "the tag isn't there" "Could not find $REPO:1.2.3"
FAKE_RESOLVE="ghcr.io/example/elsewhere@$D" refused "resolved to another repository" "no usable digest"
FAKE_RESOLVE="$REPO@sha256:short" refused "resolved to no digest" "no usable digest"
FAKE_RESOLVE="$REPO:1.2.3" refused "resolved to a tag" "no usable digest"

# --- verified_pull: the digest is pulled, and the image must say it is that version
: > "$FAKE_LOG"
got="$(FAKE_RESOLVE="$REPO@$D" FAKE_LABEL=1.2.3 verified_pull "$REPO" 1.2.3 2>"$WORK/err")"; rc=$?
check "pull: accepted" "$rc" 0
check "pull: prints the digest" "$got" "$REPO@$D"
contains "pull: by digest" "$(cat "$FAKE_LOG")" "pull -q $REPO@$D"
lacks "pull: never by tag" "$(grep '^pull' "$FAKE_LOG")" "$REPO:1.2.3"
got="$(FAKE_RESOLVE="$REPO@$D" FAKE_LABEL=1.2.2 verified_pull "$REPO" 1.2.3 2>"$WORK/err")"; rc=$?
check "another version's signed image under the tag: refused" "$rc" 1
check "another version's signed image: nothing to run" "$got" ""
contains "another version's signed image: says why" "$(cat "$WORK/err")" "names a signed image of version '1.2.2', not 1.2.3"
got="$(FAKE_RESOLVE="$REPO@$D" FAKE_LABEL='' verified_pull "$REPO" 1.2.3 2>"$WORK/err")"; rc=$?
check "no version label: refused" "$rc" 1
got="$(FAKE_RESOLVE="$REPO@$D" FAKE_PULL=1 FAKE_LABEL=1.2.3 verified_pull "$REPO" 1.2.3 2>"$WORK/err")"; rc=$?
check "pull fails: refused" "$rc" 1
contains "pull fails: says why" "$(cat "$WORK/err")" "Could not pull $REPO@$D"
got="$(FAKE_RESOLVE="$REPO@$D" FAKE_VERIFY=1 FAKE_LABEL=1.2.3 verified_pull "$REPO" 1.2.3 2>/dev/null)"; rc=$?
check "unsigned: verified_pull refuses" "$rc" 1

# --- rootless Docker: cosign runs as the container's root, which is the service user
cat > "$WORK/fakebin/docker-rootless" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LOG"
case "$1" in info) echo '["name=seccomp,profile=builtin","name=rootless"]' ;; *) exit 0 ;; esac
FAKE
chmod +x "$WORK/fakebin/docker-rootless"
mkdir -p "$WORK/rl"; cp "$WORK/fakebin/docker-rootless" "$WORK/rl/docker"
: > "$FAKE_LOG"
PATH="$WORK/rl:$PATH" cosign_run version >/dev/null 2>&1
contains "rootless: --user 0:0" "$(cat "$FAKE_LOG")" "--user 0:0"
: > "$FAKE_LOG"
cosign_run version >/dev/null 2>&1
contains "system daemon: the caller's uid" "$(grep '^run' "$FAKE_LOG")" "--user $(id -u):$(id -g)"
mkdir -p "$WORK/home/.docker"; echo '{}' > "$WORK/home/.docker/config.json"
: > "$FAKE_LOG"
HOME="$WORK/home" DOCKER_CONFIG='' cosign_run version >/dev/null 2>&1
contains "the registry login, read-only" "$(grep '^run' "$FAKE_LOG")" "-v $WORK/home/.docker/config.json:/auth/config.json:ro"

# --- pin_app_digest
cd "$WORK" || exit 1
printf 'API_IMAGE=%s\nAPP_VERSION=1.2.3\n' "$REPO" > .env
pin_app_digest "$D"; check "pin: appended" "$(grep -c "^APP_DIGEST=$D$" .env)" 1
pin_app_digest "$OTHER"; check "pin: replaced" "$(grep '^APP_DIGEST=' .env)" "APP_DIGEST=$OTHER"
check "pin: one line" "$(grep -c '^APP_DIGEST=' .env)" 1
pin_app_digest "sha256:nope; rm -rf /"; check "pin: not a digest, refused" "$?" 1
check "pin: not a digest, .env untouched" "$(grep '^APP_DIGEST=' .env)" "APP_DIGEST=$OTHER"

printf 'verify-image self-test: %d passed, %d failed\n' "$PASS" "$FAILN"
[ "$FAILN" -eq 0 ]
