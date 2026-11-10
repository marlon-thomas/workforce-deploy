# shellcheck shell=bash
# signatures.sh — a Workforce image is used only once its signature checks out (Workforce issue 422,
# ADR-0032 §3). Sourced by bin/install.sh, bin/update.sh and bin/verify-image.sh.
#
# A registry tag is not a trust anchor: anything that can push to the package can move `0.2.130` or
# `latest`. The signature is. Each release's images are signed in CI with the release key, with no
# transparency log, and the key's public half is cosign.pub at the root of this bundle. So, for the
# version asked for:
#   1. the tag is resolved to a digest, once;
#   2. `cosign verify --key cosign.pub --insecure-ignore-tlog=true` checks that digest: the release key
#      signed exactly those bytes, or nothing is used;
#   3. the digest is pulled, never the tag, and the image must say it is that version
#      (org.opencontainers.image.version, which the signed digest covers). A signed image of another
#      version moved under this tag is refused, as the controller refuses a manifest for another
#      version (controller/src/release/verify.mjs);
#   4. .env names the digest (APP_DIGEST), so compose runs those bytes and no others.
#
# cosign.pub comes from the private repository's committed copy, carried here by a reviewed change. It
# is never fetched at run time. Until the owner makes the release key (Workforce issue 353) there is
# none, and every Workforce image is refused.
#
# cosign itself runs from its official image, pinned by digest like every other tool here (ADR-0015;
# bin/digest-check.py checks the pin daily). That index digest is the v3.1.4 release that Sigstore
# signed (keyless@projectsigstore.iam.gserviceaccount.com), the same cosign version that signs releases
# in CI. Nothing is installed on the host.

SIGNATURES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RELEASE_KEY="${SIGNATURES_ROOT}/cosign.pub"
COSIGN_IMAGE="ghcr.io/sigstore/cosign/cosign:v3.1.4@sha256:0f06154836d2de34f887a5c273506d52ca43edaa1d9e53e6510fa78a48f69c2d"
RELEASE_VERSION_LABEL="org.opencontainers.image.version"

# release_key_problem — why no image can be checked, in words; nothing when the key is there.
release_key_problem() {
  if [ ! -e "$RELEASE_KEY" ]; then
    echo "No release key yet: this bundle has no cosign.pub, so no Workforce image can be checked and none is used. See Workforce issue 353."
  elif [ ! -f "$RELEASE_KEY" ] || [ ! -r "$RELEASE_KEY" ]; then
    echo "cosign.pub can't be read here, so no Workforce image can be checked and none is used."
  elif grep -q 'PRIVATE' "$RELEASE_KEY" \
       || [ "$(grep -c -- '-----BEGIN PUBLIC KEY-----' "$RELEASE_KEY")" != 1 ] \
       || [ "$(grep -c -- '-----END PUBLIC KEY-----' "$RELEASE_KEY")" != 1 ]; then
    echo "cosign.pub is not one public key, so no Workforce image can be checked and none is used. Put back the committed copy (git checkout -- cosign.pub)."
  fi
}

# release_ref_problem REPOSITORY VERSION — why that can't be a release to check; nothing when it can.
release_ref_problem() {
  if ! [[ "${1:-}" =~ ^[a-z0-9][a-z0-9.-]*(:[0-9]{1,5})?(/[a-z0-9][a-z0-9._-]*)+$ ]]; then
    echo "'${1:-}' is not an image repository."
  elif [ "${2:-}" = latest ]; then
    echo "'latest' is not a version: name the release (e.g. 0.2.130)."
  elif ! [[ "${2:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
    echo "'${2:-}' is not a version."
  fi
}

# cosign_run ARG... — cosign in its pinned image, with this bundle's cosign.pub at /release/cosign.pub
# and the registry login (the docker config) read-only. It can only read those two files and talk to
# the registry: no capabilities, read-only, memory for its scratch, nothing logged by docker.
# COSIGN_NETWORK is for bin/tests/verify-image-e2e.sh, whose registry is on this machine.
cosign_run() {
  local cfg="${DOCKER_CONFIG:-${HOME:-/nonexistent}/.docker}" user
  local -a mounts=()
  # The docker config is 0600 and the service user's. Under rootless Docker the container's root is
  # that user; under the system daemon, the container runs as the same uid.
  if docker info --format '{{json .SecurityOptions}}' 2>/dev/null | grep -q rootless; then
    user="0:0"
  else
    user="$(id -u):$(id -g)"
  fi
  [ -f "$cfg/config.json" ] && mounts+=(-v "$cfg/config.json:/auth/config.json:ro")
  [ -f "$RELEASE_KEY" ] && mounts+=(-v "$RELEASE_KEY:/release/cosign.pub:ro")
  docker run --rm --log-driver none --network "${COSIGN_NETWORK:-bridge}" --user "$user" \
    --read-only --tmpfs /tmp:size=16m --cap-drop ALL --security-opt no-new-privileges:true \
    -e HOME=/tmp -e DOCKER_CONFIG=/auth "${mounts[@]}" "$COSIGN_IMAGE" "$@" </dev/null
}

# last_line — the last non-empty line of stdin, for a one-line reason.
last_line() { awk 'NF { l = $0 } END { print l }'; }

# release_digest REPOSITORY VERSION — the digest the tag names now (sha256:...), resolved once.
release_digest() {
  local out err ref d
  err="$(mktemp)"
  if ! out="$(cosign_run triangulate --type digest "$1:$2" 2>"$err")"; then
    echo "Could not find $1:$2 in the registry: $(last_line < "$err")" >&2
    rm -f "$err"; return 1
  fi
  rm -f "$err"
  ref="$(printf '%s\n' "$out" | last_line)"
  d="${ref##*@}"
  if [ "${ref%@*}" != "$1" ] || ! [[ "$d" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "The registry gave no usable digest for $1:$2 ('$ref')." >&2
    return 1
  fi
  printf '%s\n' "$d"
}

# verify_release_signature REPOSITORY@DIGEST — the release key signed exactly that digest.
verify_release_signature() {
  local err
  err="$(mktemp)"
  if ! cosign_run verify --key /release/cosign.pub --insecure-ignore-tlog=true "$1" >/dev/null 2>"$err"; then
    echo "REFUSED: $1 is not signed with the Workforce release key (cosign.pub): $(last_line < "$err")" >&2
    rm -f "$err"; return 1
  fi
  rm -f "$err"
}

# verified_image REPOSITORY VERSION — prints REPOSITORY@DIGEST once the release key's signature on that
# digest checks out. Pulls nothing. On any doubt: a reason on stderr, non-zero, and nothing printed.
verified_image() {
  local p d
  p="$(release_key_problem)"; [ -z "$p" ] || { echo "$p" >&2; return 1; }
  p="$(release_ref_problem "$1" "$2")"; [ -z "$p" ] || { echo "$p" >&2; return 1; }
  d="$(release_digest "$1" "$2")" || return 1
  verify_release_signature "$1@$d" || return 1
  printf '%s@%s\n' "$1" "$d"
}

# release_version_problem REPOSITORY@DIGEST VERSION — the pulled image says it is VERSION; nothing when
# it does. Its labels are part of the signed digest, so they can be trusted once the signature has.
release_version_problem() {
  local got
  got="$(docker image inspect --format "{{index .Config.Labels \"$RELEASE_VERSION_LABEL\"}}" "$1" 2>/dev/null)" \
    || { echo "REFUSED: $1 is not on this machine to check its version."; return 0; }
  [ "$got" = "$2" ] \
    || echo "REFUSED: the tag $2 names a signed image of version '${got:-none}', not $2. Nothing of it is used; report it to support."
}

# verified_pull REPOSITORY VERSION — verified_image, then pull that digest and check its version.
# Prints REPOSITORY@DIGEST.
verified_pull() {
  local ref err p
  ref="$(verified_image "$1" "$2")" || return 1
  err="$(mktemp)"
  if ! docker pull -q "$ref" >/dev/null 2>"$err"; then
    echo "Could not pull $ref: $(last_line < "$err")" >&2
    rm -f "$err"; return 1
  fi
  rm -f "$err"
  p="$(release_version_problem "$ref" "$2")"; [ -z "$p" ] || { echo "$p" >&2; return 1; }
  printf '%s\n' "$ref"
}

# pin_app_digest DIGEST — .env names the checked digest, which compose.yaml runs (APP_DIGEST).
pin_app_digest() {
  [[ "${1:-}" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
  [ -f .env ] || return 1
  if grep -q '^APP_DIGEST=' .env; then
    sed -i "s|^APP_DIGEST=.*|APP_DIGEST=$1|" .env
  else
    printf 'APP_DIGEST=%s\n' "$1" >> .env
  fi
}
