#!/usr/bin/env bash
# verify-image.sh — check a Workforce release's signature, then pull it by its digest (Workforce issue 422).
#
#   ./bin/verify-image.sh <version> [<repository>]
#
# Prints <repository>@sha256:<digest> once the release key (cosign.pub) has signed exactly that digest and
# the image says it is <version>; exits non-zero, printing nothing on stdout, otherwise. The repository is
# API_IMAGE from .env, or the published one before there is a .env (install.sh's first phase). The
# checks are bin/lib/signatures.sh's, the same ones install.sh and update.sh make.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib/common.sh
. ./bin/lib/common.sh
# shellcheck source=lib/signatures.sh
. ./bin/lib/signatures.sh

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "Usage: ./bin/verify-image.sh <version> [<repository>]" >&2; exit 2; }
REPOSITORY="${2:-}"
if [ -z "$REPOSITORY" ] && [ -f .env ]; then
  REPOSITORY="$(sed -n 's/^API_IMAGE=//p' .env | tail -1)"
fi
REPOSITORY="${REPOSITORY:-ghcr.io/marlon-thomas/workforce-suite}"
use_docker_socket
verified_pull "$REPOSITORY" "$VERSION"
