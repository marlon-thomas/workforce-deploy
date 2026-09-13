#!/usr/bin/env bash
# gen-test-ca.sh — RUN ON THE WORKSTATION, never inside the appliance.
#
# Creates a private certificate authority for the TEST environment only and
# issues a leaf certificate for the test hostnames, so local TLS is trusted
# with no public CA involved (no rate limits, works offline, real TLS).
# Production keeps using real Let's Encrypt — this tool must never be run
# against the prod environment file.
#
# Why the CA lives OUTSIDE the repo, in the persistent host state dir: the
# public deploy bundle (workforce-deploy) is cloned onto fresh VMs, so any
# key committed to git would be public. The CA material is therefore kept
# beside the DuckDNS token (~/.config/workforce-dev), never in source.
#
# Idempotent: the root CA is created once and reused; the leaf is re-issued
# on every run so it always matches the CURRENT hostnames in the env file
# (change a subdomain in test.env and re-run me).
#
# Usage: ./bin/gen-test-ca.sh [env-name]      (default: test)
set -euo pipefail

cd "$(dirname "$0")/.."          # deploy/
ENV_NAME="${1:-test}"
ENV_FILE="environments/${ENV_NAME}.env"
[ -f "$ENV_FILE" ] || { echo "No ${ENV_FILE}"; exit 1; }

case "${ENV_NAME}" in
  prod|production)
    echo "Refusing to build a private CA for '${ENV_NAME}' — production uses real"
    echo "Let's Encrypt certificates. Run me only for the test environment." >&2
    exit 1 ;;
esac

# --- derive hostnames exactly the way install.sh does (single source: the env file) ---
# shellcheck disable=SC1090
. <(grep -E '^(BASE_DOMAIN|WF_SUBDOMAIN|AUTH_SUBDOMAIN)=' "$ENV_FILE")
APP_HOST="${WF_SUBDOMAIN}.${BASE_DOMAIN}"
AUTH_HOST="${AUTH_SUBDOMAIN}.${BASE_DOMAIN}"

CA_DIR="${HOME}/.config/workforce-dev/testca"
mkdir -p "$CA_DIR"; chmod 700 "$CA_DIR"
CA_KEY="${CA_DIR}/ca.key"; CA_CRT="${CA_DIR}/ca.crt"
LEAF_KEY="${CA_DIR}/tls.key"; LEAF_CRT="${CA_DIR}/tls.crt"

say(){ printf '\033[1;32m==>\033[0m %s\n' "$*"; }
say "Private CA dir: ${CA_DIR}   hostnames: ${APP_HOST}, ${AUTH_HOST}"

if [ ! -f "$CA_CRT" ] || [ ! -f "$CA_KEY" ]; then
  say "Generating a new 10-year root CA…"
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$CA_KEY" -out "$CA_CRT" \
    -subj "/O=Care Angels Workforce/CN=Care Angels Test Root CA (do not use in production)" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign"
  chmod 600 "$CA_KEY"
else
  say "Reusing the existing root CA."
fi

say "Issuing the leaf certificate (re-issued every run to match the hostnames)…"
openssl req -newkey rsa:2048 -sha256 -nodes \
  -keyout "$LEAF_KEY" -out "${CA_DIR}/tls.csr" \
  -subj "/CN=${APP_HOST}"
printf 'subjectAltName=DNS:%s,DNS:%s\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' \
  "$APP_HOST" "$AUTH_HOST" > "${CA_DIR}/leaf.ext"
openssl x509 -req -in "${CA_DIR}/tls.csr" -CA "$CA_CRT" -CAkey "$CA_KEY" \
  -CAcreateserial -days 825 -sha256 -extfile "${CA_DIR}/leaf.ext" \
  -out "$LEAF_CRT"
chmod 600 "$LEAF_KEY"; rm -f "${CA_DIR}/tls.csr" "${CA_DIR}/leaf.ext"

say "Root CA is ready. To make this machine's BROWSER trust it (once per machine):"
if command -v dnf >/dev/null 2>&1 || [ -d /etc/pki/ca-trust ]; then
  echo "     Fedora/RHEL:   sudo cp '${CA_CRT}' /etc/pki/ca-trust/source/anchors/ && sudo update-ca-trust"
elif command -v apt-get >/dev/null 2>&1 || command -v update-ca-certificates >/dev/null 2>&1; then
  echo "     Debian/Ubuntu: sudo cp '${CA_CRT}' /usr/local/share/ca-certificates/care-angels-testca.crt && sudo update-ca-certificates"
fi
say "Done. bootstrap.py will ship tls.crt/tls.key into the test VM automatically."
