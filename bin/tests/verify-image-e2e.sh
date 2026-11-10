#!/usr/bin/env bash
# verify-image-e2e.sh — bin/lib/signatures.sh end to end, with nothing faked: a registry on this machine,
# images built here, the pinned cosign image signing them as CI does (scripts/ci/sign-release.sh in the
# private repository: a key, a signing config naming no service, no transparency log), and the real
# library checking them. The keys are throwaway ones made in a temporary folder and deleted at the end;
# the release key is never involved.
#   - a release signed with the key it is checked against: its digest, pulled, version checked
#   - an unsigned tag, one signed with another key, and a signed image of another version moved under
#     the tag: all refused, and nothing printed for compose to run
#   - no cosign.pub, or a private key in its place: refused before the registry is asked anything
# Needs Docker and the network (it pulls registry:3 and the pinned cosign image). Not one of the
# hermetic *-test.sh scripts, so bin/ci-validate.sh doesn't run it.
#   ./bin/tests/verify-image-e2e.sh      exit 0 = all pass
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
REGISTRY_IMAGE="registry:3.0.0@sha256:6c5666b861f3505b116bb9aa9b25175e71210414bd010d92035ff64018f9457e"
WORK="$(mktemp -d)"
NAME="wf-verify-e2e-$$"
cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker image ls --format '{{.Repository}}:{{.Tag}}' | grep "^127.0.0.1:${PORT:-0}/" | xargs -r docker image rm -f >/dev/null 2>&1 || true
  rm -rf "${WORK:?}"
}
trap cleanup EXIT

PASS=0; FAILN=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAILN=$((FAILN+1)); printf 'FAIL: %s: expected [%s] got [%s]\n' "$1" "$3" "$2"; fi; }
contains() { case "$2" in *"$3"*) PASS=$((PASS+1)) ;; *) FAILN=$((FAILN+1)); printf 'FAIL: %s: [%s] not in: %s\n' "$1" "$3" "$2" ;; esac; }

# A bundle of its own, so its cosign.pub is the throwaway key's.
mkdir -p "$WORK/bundle/bin/lib" "$WORK/keys" "$WORK/ctx"
cp "$REPO/bin/lib/signatures.sh" "$WORK/bundle/bin/lib/"
# shellcheck source=../lib/signatures.sh
. "$WORK/bundle/bin/lib/signatures.sh"
export COSIGN_NETWORK=host

docker run -d --name "$NAME" -p 127.0.0.1::5000 "$REGISTRY_IMAGE" >/dev/null || { echo "could not start a registry"; exit 1; }
PORT="$(docker port "$NAME" 5000/tcp | head -1 | sed 's/.*://')"
REPOSITORY="127.0.0.1:${PORT}/wf/workforce-suite"
for _ in 1 2 3 4 5 6 7 8 9 10; do curl -fsS "http://127.0.0.1:${PORT}/v2/" >/dev/null 2>&1 && break; sleep 1; done

# signer KEYPREFIX ARG... — the pinned cosign, as CI runs it, with the throwaway keys at /keys.
COSIGN_PASSWORD="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"; export COSIGN_PASSWORD
printf '{"mediaType":"application/vnd.dev.sigstore.signingconfig.v0.2+json"}\n' > "$WORK/keys/no-services.json"
signer() {
  docker run --rm --log-driver none --network host --user "$(id -u):$(id -g)" --read-only --tmpfs /tmp \
    -e HOME=/tmp -e COSIGN_PASSWORD -v "$WORK/keys:/keys" -w /keys "$COSIGN_IMAGE" "$@"
}
signer generate-key-pair --output-key-prefix one >/dev/null 2>&1 || { echo "could not make a key"; exit 1; }
signer generate-key-pair --output-key-prefix two >/dev/null 2>&1 || { echo "could not make a second key"; exit 1; }

# image VERSION [LABEL] — build and push REPOSITORY:VERSION labelled LABEL (default VERSION); its digest.
image() {
  local out
  printf '%s\n' "$1-${2:-$1}" > "$WORK/ctx/f"
  printf 'FROM scratch\nCOPY f /f\n' > "$WORK/ctx/Dockerfile"
  docker build -q --provenance=false --label "org.opencontainers.image.version=${2:-$1}" \
    -t "$REPOSITORY:$1" "$WORK/ctx" >/dev/null 2>&1 || { echo "build failed" >&2; return 1; }
  out="$(docker push "$REPOSITORY:$1" 2>&1)" || { echo "push failed: $out" >&2; return 1; }
  grep -o 'digest: sha256:[0-9a-f]\{64\}' <<<"$out" | tail -1 | cut -d' ' -f2
}
sign() { signer sign --yes --key "/keys/$1.key" --signing-config /keys/no-services.json "$2" > "$WORK/sign.log" 2>&1 \
  || { echo "signing failed: $(tail -2 "$WORK/sign.log")"; return 1; }
  if grep -qi 'tlog entry created' "$WORK/sign.log"; then echo "signing wrote to a transparency log"; return 1; fi; }

D1="$(image 1.2.3)"; sign one "$REPOSITORY@$D1"
D2="$(image 1.2.4)"                                     # never signed
D3="$(image 1.2.5)"; sign two "$REPOSITORY@$D3"        # signed with another key
docker tag "$REPOSITORY:1.2.3" "$REPOSITORY:1.2.6" && docker push -q "$REPOSITORY:1.2.6" >/dev/null 2>&1   # 1.2.3's signed bytes, moved
docker image rm -f "$REPOSITORY:1.2.3" "$REPOSITORY:1.2.4" "$REPOSITORY:1.2.5" "$REPOSITORY:1.2.6" >/dev/null 2>&1

# --- no key, then a private key where the public one belongs: refused before anything else
out="$(verified_image "$REPOSITORY" 1.2.3 2>&1)"; rc=$?
check "no cosign.pub: refused" "$rc" 1
contains "no cosign.pub: says why" "$out" "No release key yet"
contains "no cosign.pub: names the issue" "$out" "issue 353"
cp "$WORK/keys/one.key" "$WORK/bundle/cosign.pub"
out="$(verified_image "$REPOSITORY" 1.2.3 2>&1)"; rc=$?
check "a private key as cosign.pub: refused" "$rc" 1
contains "a private key as cosign.pub: says why" "$out" "not one public key"

cp "$WORK/keys/one.pub" "$WORK/bundle/cosign.pub"

# --- the release, signed with this key
got="$(verified_pull "$REPOSITORY" 1.2.3 2>"$WORK/err")"; rc=$?
check "signed release: accepted" "$rc" 0
check "signed release: its digest, not its tag" "$got" "$REPOSITORY@$D1"
check "signed release: pulled by digest" "$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "$REPOSITORY@$D1" 2>/dev/null)" "1.2.3"
check "signed release: verified_image agrees" "$(verified_image "$REPOSITORY" 1.2.3 2>/dev/null)" "$REPOSITORY@$D1"

# --- refusals: non-zero, a reason, and nothing on stdout
refused() {   # LABEL VERSION WANT
  local out err rc
  out="$(verified_pull "$REPOSITORY" "$2" 2>"$WORK/err")"; rc=$?; err="$(cat "$WORK/err")"
  check "$1: refused" "$rc" 1
  check "$1: nothing to run" "$out" ""
  contains "$1: says why" "$err" "$3"
}
refused "unsigned" 1.2.4 "is not signed with the Workforce release key"
refused "signed with another key" 1.2.5 "is not signed with the Workforce release key"
refused "another version's signed image under this tag" 1.2.6 "names a signed image of version '1.2.3', not 1.2.6"
refused "a tag that isn't there" 9.9.9 "Could not find"
refused "latest" latest "'latest' is not a version"
check "unsigned: never pulled" "$(docker image inspect "$REPOSITORY@$D2" >/dev/null 2>&1; echo $?)" 1
check "other key: never pulled" "$(docker image inspect "$REPOSITORY@$D3" >/dev/null 2>&1; echo $?)" 1

printf 'verify-image e2e: %d passed, %d failed\n' "$PASS" "$FAILN"
[ "$FAILN" -eq 0 ]
