#!/usr/bin/env bash
# install.sh — Care Angels Workforce Suite, B-mode appliance installer
# (deployment-spec §B2: "paste one line, answer four questions").
#
# Run from the deploy/ directory:  ./bin/install.sh
# Local/no-TLS test run:           ./bin/install.sh --smoke
#
# The four prompts (everything else is generated):
#   1. Public hostname of the app (DNS verified against this host, with a
#      plain-English wait loop)
#   2. Email for TLS certificate notices
#   3. First administrator password (or empty -> generated, printed ONCE)
#   4. Off-site backup target (optional; empty -> local only)
set -euo pipefail

cd "$(dirname "$0")/.."   # deploy/

SMOKE=0
for arg in "$@"; do
  case "$arg" in
    --smoke) SMOKE=1 ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m ->\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mXX\033[0m %s\n' "$*"; exit 1; }

# ---------------------------------------------------------------- bootstrap levels
# The installer is designed to be run ONCE, as root, on a fresh VPS. It handles the
# whole journey: service user -> Docker -> registry login -> the four questions ->
# the running stack. Re-running as the service user afterwards skips straight to
# configuration/updates (everything below is idempotent).
NEED_BOOTSTRAP=0
if [ "$(id -u)" -eq 0 ]; then
  NEED_BOOTSTRAP=1
elif command -v docker >/dev/null && docker info >/dev/null 2>&1; then
  NEED_BOOTSTRAP=0
else
  NEED_BOOTSTRAP=1
fi

if [ "${NEED_BOOTSTRAP}" -eq 1 ] && [ "$(id -u)" -ne 0 ] && ! sudo -n true 2>/dev/null; then
  fail "Root privileges are needed (create user, install Docker, open the firewall). Run me with sudo."
fi

bootstrap() {
  # ---- 0. A normal user (never operate the system as root) --------------------
  if [ "$(id -u)" -eq 0 ]; then
    echo ""
    echo "Setting up a service user (the system is never operated as root)…"
    SERVICE_USER="${SERVICE_USER:-workforce_app_sa}"
    if id "$SERVICE_USER" >/dev/null 2>&1; then
      echo "   user '$SERVICE_USER' already exists."
    else
      adduser --disabled-password --gecos "Care Angels Workforce service account,,," "$SERVICE_USER"
      usermod -aG sudo "$SERVICE_USER"
      echo "   user '$SERVICE_USER' created (sudo member). Set a login password now:"
      passwd "$SERVICE_USER" || true
    fi
    DEPLOY_DIR="$(pwd)"
    chown -R "$SERVICE_USER:$SERVICE_USER" "$DEPLOY_DIR"

    # ---- 3. Docker (engine + compose plugin) ----------------------------------
    if command -v docker >/dev/null 2>&1; then
      echo "Docker is already installed."
    else
      echo "Installing Docker…"
      curl -fsSL https://get.docker.com | sh
    fi
    SERVICE_USER="${SERVICE_USER:-workforce_app_sa}"
    usermod -aG docker "$SERVICE_USER" 2>/dev/null || true

    # ---- 4. Registry login (images are private until licensing ships) ---------
    if ! grep -q "ghcr.io" "/home/${SERVICE_USER}/.docker/config.json" 2>/dev/null; then
      echo ""
      echo "The container images are pulled from GitHub's registry (private while"
      echo "licensing is in development). A GitHub personal access token with"
      echo "read:packages is required (Settings -> Developer settings -> Tokens classic)."
      printf "GitHub username [marlon-thomas]: "
      read -r GH_USER
      GH_USER="${GH_USER:-marlon-thomas}"
      docker login ghcr.io -u "$GH_USER" || fail "Registry login failed — the token needs read:packages scope."
    fi

    # Hand over: re-exec the rest of the installer as the service user.
    echo ""
    echo "Bootstrap complete. Continuing as '$SERVICE_USER'…"
    if [ "${SMOKE}" -eq 1 ]; then
      exec sudo -E -u "$SERVICE_USER" env SMOKE=1 bash "$0" --smoke "$@"
    fi
    exec sudo -u "$SERVICE_USER" bash "$0" "$@"
  fi
}

# ---------------------------------------------------------------- firewall
# The system needs exactly three inbound ports: 22 (ssh — already open), 80+443 (the app).
# Docker publishes 80/443 directly via iptables, bypassing ufw; we still open them in
# ufw so the rules are explicit and survive Docker being restarted differently.
# CLOUD FIREWALLS (Hetzner/DO/etc.) are a separate layer we cannot touch — the runbook
# tells the user to allow 80/443 there; doctor.sh verifies reachability end-to-end.
open_port() {
  PORT="$1"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "$PORT/tcp" >/dev/null 2>&1 && say "Firewall (ufw): allowing ${PORT}/tcp" \
      || warn "Firewall (ufw): could not allow ${PORT}/tcp — check 'ufw status'."
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$PORT/tcp" >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1 \
      && say "Firewall (firewalld): allowing ${PORT}/tcp" \
      || warn "Firewall (firewalld): could not allow ${PORT}/tcp — check 'firewall-cmd --list-ports'."
  else
    warn "No active firewall detected on this machine — ports 80/443 depend on your cloud provider's firewall."
  fi
}

bootstrap

if [ -f .env ]; then
  warn "This deployment is already configured (deploy/.env exists)."
  echo "   Use ./bin/update.sh to change versions, or delete .env to reconfigure from scratch."
  exit 0
fi

# ---------------------------------------------------------------- prompt 1/4
PUBLIC_IP="$(curl -4 -fsS --max-time 8 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
printf '1/4  What web address will staff use? (e.g. workforce.carehome.org.uk): '
read -r APP_HOSTNAME
[ -n "${APP_HOSTNAME}" ] || fail "A hostname is required."

verify_dns() {
  RESOLVED="$(getent hosts "$APP_HOSTNAME" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')"
  if [ -z "${RESOLVED}" ]; then
    echo "     '${APP_HOSTNAME}' does not resolve yet."
    return 1
  fi
  if [ -n "${PUBLIC_IP}" ] && [[ " ${RESOLVED} " != *" ${PUBLIC_IP} "* ]]; then
    echo "     '${APP_HOSTNAME}' points at ${RESOLVED}, but this machine is ${PUBLIC_IP}."
    return 1
  fi
  echo "     DNS OK: ${APP_HOSTNAME} -> ${PUBLIC_IP:-this host}"
  return 0
}
if [ "${SMOKE}" -eq 0 ]; then
  say "Opening the firewall for the web (80/tcp, 443/tcp)…"
  open_port 80
  open_port 443
  say "Checking the address points at this machine (this can take a few minutes on a fresh domain)…"
  for i in $(seq 1 60); do
    verify_dns && break
    [ "$i" = 60 ] && fail "DNS still not pointing here. Update it at your domain provider
     (an 'A' record: ${APP_HOSTNAME} -> ${PUBLIC_IP}) and re-run me."
    sleep 15
  done
else
  warn "--smoke: DNS verification skipped."
fi
AUTH_HOSTNAME="auth.${APP_HOSTNAME#*.}"   # workforce.example.com -> auth.example.com

# ---------------------------------------------------------------- prompt 2/4
printf '2/4  Email for security-certificate notices: '
read -r ACME_EMAIL
[ -n "${ACME_EMAIL}" ] || fail "An email is required (certificate expiry notices)."

# ---------------------------------------------------------------- prompt 3/4
printf '3/4  Pick a password for the first administrator (Enter = generate a strong one): '
read -rs ADMIN_PASSWORD
echo ""
if [ -z "${ADMIN_PASSWORD}" ]; then
  ADMIN_PASSWORD="$(openssl rand -base64 18)"
  GENERATED_ADMIN=1
else
  GENERATED_ADMIN=0
fi

# ---------------------------------------------------------------- prompt 4/4
printf '4/4  Off-site backups — paste a target (rsync host:path or s3://bucket) or press Enter for local-only: '
read -r BACKUP_TARGET

# ---------------------------------------------------------------- generate
say "Generating secrets (they are never displayed)…"
mkdir -p secrets backups blueprints
gen() { [ -s "secrets/$1" ] || openssl rand -base64 32 | tr -d '\n' > "secrets/$1"; }
gen db_password; gen minio_access; gen minio_secret
gen ak_db_password; gen ak_secret
# authentik 2024.12 no longer supports *_FILE for its own settings and cannot write
# /etc as a non-root user — its documented /etc/authentik/config.yml is delivered as a
# Docker secret composed from the other two secrets.
{
  echo "secret_key: $(cat secrets/ak_secret)"
  echo "postgresql:"
  echo "  password: $(cat secrets/ak_db_password)"
} > secrets/ak_config.yml
OIDC_CLIENT_ID="workforce-$(openssl rand -hex 4)"
echo "$OIDC_CLIENT_ID" > secrets/oidc_client_id
openssl rand -base64 32 | tr -d '\n' > secrets/oidc_client_secret
chmod 600 secrets/*
touch secrets/oidc_client_id secrets/oidc_client_secret
chmod 600 secrets/oidc_client_id secrets/oidc_client_secret

say "Writing configuration…"
cat > .env <<ENV
APP_HOSTNAME=${APP_HOSTNAME}
AUTH_HOSTNAME=${AUTH_HOSTNAME}
ACME_EMAIL=${ACME_EMAIL}

DB_NAME=workforce
DB_USER=workforce_app

MINIO_BUCKET=workforce-evidence

AK_DB_NAME=authentik
AK_DB_USER=authentik

OIDC_ISSUER=https://${AUTH_HOSTNAME}/application/o/workforce/

API_IMAGE=ghcr.io/careangels/workforce-suite
APP_VERSION=${APP_VERSION:-latest}

BACKUP_TARGET=${BACKUP_TARGET}
ENV

if [ "${SMOKE}" -eq 1 ]; then
  # Local/no-TLS run: OIDC discovery stands down until authentik is provisioned.
  warn "--smoke: the api will boot without the sign-in chain (smoke profile)."
fi

# Pull fallback: GHCR first; if the org's IP is rate-limited and a Docker Hub mirror
# is configured (optional DOCKERHUB_USER in .env), switch to it transparently.
HUB_USER="${DOCKERHUB_USER:-}"
if [ -n "${HUB_USER}" ]; then
  say "Fetching images…"
  if ! docker pull "${API_IMAGE}:${APP_VERSION}" >/dev/null 2>&1; then
    if docker pull "docker.io/${HUB_USER}/workforce-suite:${APP_VERSION}" >/dev/null 2>&1; then
      say "GHCR unavailable from this network — using the Docker Hub mirror."
      sed -i.bak "s|^API_IMAGE=.*|API_IMAGE=docker.io/${HUB_USER}/workforce-suite|" .env
    else
      fail "Could not fetch the images from GHCR or the Docker Hub mirror. Check your internet connection."
    fi
  fi
fi

say "Starting the platform (this downloads and starts everything; first run takes a while)…"
if [ "${SMOKE}" -eq 1 ]; then
  docker compose -f compose.yaml -f compose.smoke.yaml up -d
else
  docker compose up -d
fi

say "Connecting the workforce system to the sign-in server (authentik applies the blueprint on startup)…"
if [ "${SMOKE}" -eq 1 ]; then
  warn "--smoke: sign-in is wired for localhost (no TLS) — production runs use https."
fi
# Render the provisioning blueprint (deployment-spec §B5): OIDC provider + application +
# first administrator. authentik applies it natively on every startup (idempotent).
AK_ADMIN_PASSWORD="${ADMIN_PASSWORD}"
export AK_ADMIN_PASSWORD
sed   -e "s|\${OIDC_CLIENT_ID}|$(cat secrets/oidc_client_id)|g" \
  -e "s|\${OIDC_CLIENT_SECRET}|$(cat secrets/oidc_client_secret)|g" \
  -e "s|\${WF_REDIRECT_URI}|https://${APP_HOSTNAME}/login/oauth2/code/oidc|g" \
  -e "s|\${ACME_EMAIL}|${ACME_EMAIL}|g" \
  -e "s|\${AK_ADMIN_PASSWORD}|${AK_ADMIN_PASSWORD}|g" \
  blueprints/workforce-app.yaml.template > blueprints/workforce-app.yaml 2>/dev/null \
  || sed \
  -e "s|\${OIDC_CLIENT_ID}|$(cat secrets/oidc_client_id)|g" \
  -e "s|\${OIDC_CLIENT_SECRET}|$(cat secrets/oidc_client_secret)|g" \
  -e "s|\${WF_REDIRECT_URI}|https://${APP_HOSTNAME}/login/oauth2/code/oidc|g" \
  -e "s|\${ACME_EMAIL}|${ACME_EMAIL}|g" \
  -e "s|\${AK_ADMIN_PASSWORD}|${AK_ADMIN_PASSWORD}|g" \
  blueprints/workforce-app.yaml.template > blueprints/workforce-app.yaml
chmod 600 blueprints/workforce-app.yaml
docker compose up -d authentik-server authentik-worker

say "Final health check:"
if [ "${SMOKE}" -eq 1 ]; then
  ./bin/doctor.sh --smoke || true
else
  ./bin/doctor.sh || true
fi

cat <<DONE

------------------------------------------------------------------------
${GENERATED_ADMIN:+  Your administrator password (shown once — save it now):
      ${ADMIN_PASSWORD}
}
  Staff will use:  https://${APP_HOSTNAME}
  First sign-in:   https://${AUTH_HOSTNAME}  (administrator account)
  Then the setup wizard inside the app completes your organisation.

  Backups run nightly to ./backups${BACKUP_TARGET:+ and off-site to ${BACKUP_TARGET}}.
  Useful commands (from this directory):
    ./bin/doctor.sh    health check (send output to support when something looks wrong)
    ./bin/update.sh    upgrade when a new version is announced
    ./bin/backup.sh    make a backup right now
------------------------------------------------------------------------
DONE
