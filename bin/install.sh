#!/usr/bin/env bash
# install.sh — Care Angels Workforce Suite, B-mode appliance installer
# (deployment-spec §B2: "paste one line, answer four questions").
#
# Run as root on a fresh VPS:   ./bin/install.sh
# Local/no-TLS test run:        ./bin/install.sh --smoke
# Classic system docker:        ./bin/install.sh --system-docker
#
# This script is the INTERACTIVE front door only:
#   root phase  : service user, bundle relocation, Docker, registry login
#   prompts     : domain, email, admin password, backup target
#   convergent  : EVERYTHING else is delegated to the Ansible playbook
#                 (deploy/ansible/) — declarative, idempotent, re-runnable.
set -euo pipefail

cd "$(dirname "$0")/.."   # bundle root

SMOKE=0
SYSTEM_DOCKER=0
ENV_NAME_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --smoke) SMOKE=1 ;;
    --system-docker) SYSTEM_DOCKER=1 ;;
    --env) ENV_NAME_ARG="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
  shift
done
[ -n "${ENV_NAME_ARG}" ] && { [ "${ENV_NAME_ARG}" = "test" ] || [ "${ENV_NAME_ARG}" = "prod" ] \
  || { echo "Unknown environment: ${ENV_NAME_ARG} (test|prod)"; exit 1; }; }

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m ->\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mXX\033[0m %s\n' "$*"; exit 1; }

# ============================================================ helpers

open_port() {
  PORT="$1"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "$PORT/tcp" >/dev/null 2>&1 && say "Firewall (ufw): allowing ${PORT}/tcp" \
      || warn "Firewall (ufw): could not allow ${PORT}/tcp — check 'ufw status'."
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$PORT/tcp" >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1 \
      && say "Firewall (firewalld): allowing ${PORT}/tcp" \
      || warn "Firewall (firewalld): could not allow ${PORT}/tcp."
  else
    warn "No active firewall detected on this machine — ports 80/443 depend on your cloud provider's firewall."
  fi
}

verify_dns() {
  OK=1
  for H in "$APP_HOSTNAME" "$AUTH_HOSTNAME"; do
    RESOLVED="$(getent hosts "$H" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')"
    if [ -z "${RESOLVED}" ]; then
      echo "     '${H}' does not resolve yet."
      OK=0
    elif [ -n "${PUBLIC_IP}" ] && [[ " ${RESOLVED} " != *" ${PUBLIC_IP} "* ]]; then
      echo "     '${H}' points at ${RESOLVED}, but this machine is ${PUBLIC_IP}."
      OK=0
    fi
  done
  if [ "$OK" -eq 1 ]; then
    echo "     DNS OK: both hostnames point at this machine."
    return 0
  fi
  return 1
}

preflight_network() {
  say "Checking internet and registry reachability…"
  PING_OK=$(curl -4 -fsS -o /dev/null -w '%{http_code}' --max-time 8 https://get.docker.com 2>/dev/null || echo 0)
  [ "$PING_OK" != "0" ] || fail "This machine cannot reach the internet (get.docker.com unreachable).
     On Contabo/other providers the server may need its firewall panel opened, or
     IPv6 misconfiguration is breaking outbound access — try: curl -4 https://ifconfig.me"
  GH_OK=$(curl -4 -fsS -o /dev/null -w '%{http_code}' --max-time 8 https://ghcr.io/v2/ 2>/dev/null || echo 0)
  [ "$GH_OK" != "0" ] || fail "ghcr.io is unreachable from this machine (network filtering?)"
  echo "     Internet OK, ghcr.io reachable."
}

preflight_and_pull() {
  # The application image, with retries and honest diagnosis. Needs .env.
  say "Fetching the application image (retries automatically on network resets)…"
  PULL_ERR=""
  ATTEMPT=1
  while true; do
    PULL_ERR="$(docker pull "${API_IMAGE}:${APP_VERSION}" 2>&1 >/dev/null | tail -2)"
    if [ -z "$PULL_ERR" ]; then break; fi
    if [ "$ATTEMPT" -ge 4 ]; then break; fi
    warn "Pull attempt $ATTEMPT failed — waiting 15s and resuming (cached layers are kept)…"
    ATTEMPT=$((ATTEMPT+1))
    sleep 15
  done

  if [ -n "$PULL_ERR" ]; then
    echo "     last error: $PULL_ERR"
    if docker manifest inspect "${API_IMAGE}:${APP_VERSION}" >/dev/null 2>&1; then
      case "$PULL_ERR" in
        *"connection reset"*|*timeout*|*EOF*)
          warn "Credentials are fine — the network path to the registry resets
     mid-transfer on this host (IPv6 route observed on Contabo). Preferring IPv4…"
          grep -q "precedence ::ffff:0:0/96" /etc/gai.conf 2>/dev/null \
            || echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
          fail "IPv4 preference set — re-run me and the pull resumes from cached layers."
          ;;
        *denied*|*authentication*|*unauthorized*)
          fail "The image exists but your stored registry credential cannot pull it
     (expired/revoked GitHub token or missing read:packages scope).
     Fix: docker login ghcr.io -u <github-user>   (fresh read:packages token),
     then re-run me."
          ;;
        *)
          fail "Could not pull ${API_IMAGE}:${APP_VERSION} — see the last error above."
          ;;
      esac
    else
      fail "The image ${API_IMAGE}:${APP_VERSION} does not exist (or the token cannot
     see it). If the token is fresh and scoped read:packages, check the image name
     in .env."
    fi
  fi
}

run_ansible_site() {
  # ALL convergent provisioning (packages→users→docker→authentik→blueprint→
  # truststore→app stack→readiness) is declarative Ansible state — the playbook
  # converges this machine to the declared state idempotently. The shell only
  # handles the interactive parts.

  # GitHub token for the playbook's registry-login task (both paths). Extracted
  # from the service user's docker config — set at bootstrap, present on both
  # fresh and resumed installs.
  GITHUB_TOKEN="$(grep -o '"auth": "[^"]*"' "/home/${SERVICE_USER:-workforce_app_sa}/.docker/config.json" 2>/dev/null | cut -d'"' -f4 | base64 -d 2>/dev/null | cut -d: -f2 || echo "")"

  say "Installing Ansible (one-time)…"
  if ! command -v ansible-playbook >/dev/null 2>&1; then
    pip3 install --quiet ansible-core 2>/dev/null \
      || python3 -m pip install --quiet ansible-core \
      || pip install --user --quiet ansible-core
    export PATH="$HOME/.local/bin:$PATH"
  fi
  export ANSIBLE_COLLECTIONS_PATH="${HOME}/.ansible/collections"
  if ! ansible-galaxy collection list community.docker >/dev/null 2>&1; then
    ansible-galaxy collection install community.general community.docker ansible.posix --quiet
  fi

  say "Converging the platform (ansible playbook — identity plane, blueprint, app plane)…"
  ansible-playbook -i inventories/prod/hosts.yml ansible/site.yml \
    --connection=local -e "ansible_connection=local" \
    -e "app_hostname=${APP_HOSTNAME}" \
    -e "auth_hostname=${AUTH_HOSTNAME}" \
    -e "env_name=${ENV_NAME:-prod}" \
    -e "service_user=${SERVICE_USER:-workforce_app_sa}" \
    -e "github_token=${GITHUB_TOKEN}" \
    -e "ak_admin_password=${ADMIN_PASSWORD}" \
    -e "acme_email=${ACME_EMAIL}"
}

bootstrap() {
  # Root phase only. Runs once; hands over to the service user.
  if [ "$(id -u)" -ne 0 ]; then
    return 0
  fi

  echo ""
  echo "Setting up a service user (the system is never operated as root)…"
  SERVICE_USER="${SERVICE_USER:-workforce_app_sa}"
  if id "$SERVICE_USER" >/dev/null 2>&1; then
    echo "   user '$SERVICE_USER' already exists."
  else
    adduser --disabled-password --gecos "Care Angels Workforce service account,,," "$SERVICE_USER"
    usermod -aG sudo "$SERVICE_USER"
    echo "   user '$SERVICE_USER' created (sudo member)."
    while true; do
      if passwd "$SERVICE_USER"; then break; fi
      echo "   Passwords did not match or were rejected — try again."
    done
    echo "   Service account password set."
  fi

  TARGET="/opt/workforce-deploy"
  CURRENT="$(cd "$(dirname "$0")/.." && pwd)"
  if [ "$CURRENT" != "$TARGET" ]; then
    echo "Moving the deployment bundle to $TARGET (the service user cannot live under /root)…"
    mkdir -p "$(dirname "$TARGET")"
    if [ -d "$TARGET" ] && [ -f "$TARGET/.env" ]; then
      # Full-tree sync: newly added bundle directories (the ansible/ lesson)
      # can never be missed by an itemised copy. Generated state survives
      # because .env/secrets/backups are only present in $TARGET.
      cp -a "$CURRENT/." "$TARGET/"
    else
      rm -rf "$TARGET"
      mkdir -p "$TARGET"
      cp -a "$CURRENT/." "$TARGET/"
    fi
    cd "$TARGET"
    rm -rf "$CURRENT"
    mkdir -p "$CURRENT"
    cat > "$CURRENT/README-MOVED.txt" <<MOVED
The Care Angels Workforce deployment bundle has moved to:

    $TARGET

All commands run there (as the $SERVICE_USER user), e.g.:

    cd $TARGET && ./bin/doctor.sh

This directory is only a pointer — the real deployment (including .env
and secrets) lives at the path above.
MOVED
    echo "   (the original clone at $CURRENT is now a pointer to $TARGET)"
  fi
  chown -R "$SERVICE_USER:$SERVICE_USER" "$TARGET"

  if [ "${SYSTEM_DOCKER}" -eq 1 ]; then
    echo "Installing Docker (system daemon — --system-docker requested)…"
    command -v docker >/dev/null 2>&1 || curl -fsSL https://get.docker.com | sh
    usermod -aG docker "$SERVICE_USER" 2>/dev/null || true
    mkdir -p "/home/${SERVICE_USER}/.docker"
    chown -R "$SERVICE_USER:$SERVICE_USER" "/home/${SERVICE_USER}/.docker"
  elif command -v dockerd-rootless-setuptool.sh >/dev/null 2>&1 \
       && sudo -u "$SERVICE_USER" env HOME="/home/${SERVICE_USER}" \
            XDG_RUNTIME_DIR="/run/user/$(id -u "$SERVICE_USER")" \
            systemctl --user is-active docker >/dev/null 2>&1; then
    echo "Rootless Docker is already active for $SERVICE_USER."
  else
    echo "Installing Docker (rootless mode for $SERVICE_USER)…"
    command -v docker >/dev/null 2>&1 || curl -fsSL https://get.docker.com | sh
    usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$SERVICE_USER"
    loginctl enable-linger "$SERVICE_USER"
    apt-get -qq install -y uidmap dbus-user-session >/dev/null 2>&1 || true
    sysctl -w net.ipv4.ip_unprivileged_port_start=80 >/dev/null
    grep -q "ip_unprivileged_port_start" /etc/sysctl.conf 2>/dev/null \
      || echo "net.ipv4.ip_unprivileged_port_start=80" >> /etc/sysctl.conf
    if ! sudo -u "$SERVICE_USER" env HOME="/home/${SERVICE_USER}" \
        XDG_RUNTIME_DIR="/run/user/$(id -u "$SERVICE_USER")" \
        dockerd-rootless-setuptool.sh install; then
      fail "Rootless Docker setup failed. If this kernel lacks unprivileged user
     namespaces (some OpenVZ/LXC images), re-run with --system-docker."
    fi
    sudo -u "$SERVICE_USER" env HOME="/home/${SERVICE_USER}" \
      XDG_RUNTIME_DIR="/run/user/$(id -u "$SERVICE_USER")" \
      systemctl --user enable --now docker
    mkdir -p "/home/${SERVICE_USER}/.docker"
    chown -R "$SERVICE_USER:$SERVICE_USER" "/home/${SERVICE_USER}/.docker"
    cat > "/home/${SERVICE_USER}/.profile.d-docker" <<PROF
export DOCKER_HOST=unix:///run/user/$(id -u "$SERVICE_USER")/docker.sock
export XDG_RUNTIME_DIR=/run/user/$(id -u "$SERVICE_USER")
PROF
    if ! grep -q "profile.d-docker" "/home/${SERVICE_USER}/.bashrc" 2>/dev/null; then
      echo '. "$HOME/.profile.d-docker"' >> "/home/${SERVICE_USER}/.bashrc"
    fi
    chown "$SERVICE_USER:$SERVICE_USER" "/home/${SERVICE_USER}/.bashrc" "/home/${SERVICE_USER}/.profile.d-docker"
  fi

  if ! sudo -u "$SERVICE_USER" sh -c 'grep -q ghcr.io ~/.docker/config.json' 2>/dev/null; then
    echo ""
    echo "The container images are pulled from GitHub's registry (private while"
    echo "licensing is in development). A GitHub personal access token with"
    echo "read:packages is required (Settings -> Developer settings -> Tokens classic)."
    printf "GitHub username [marlon-thomas]: "
    read -r GH_USER
    GH_USER="${GH_USER:-marlon-thomas}"
    echo -n "GitHub token (read:packages): "
    read -rs GH_TOKEN
    echo ""
    sudo -u "$SERVICE_USER" env HOME="/home/${SERVICE_USER}" \
      GH_USER="$GH_USER" GH_TOKEN="$GH_TOKEN" \
      sh -c 'echo "$GH_TOKEN" | docker login ghcr.io -u "$GH_USER" --password-stdin' \
      || fail "Registry login failed — the token needs read:packages scope."
  fi

  echo ""
  echo "Bootstrap complete. Continuing as '$SERVICE_USER' from $TARGET…"
  FLAGS=""
  [ "${SMOKE}" -eq 1 ] && FLAGS="--smoke"
  [ "${SYSTEM_DOCKER}" -eq 1 ] && FLAGS="${FLAGS} --system-docker"
  # shellcheck disable=SC2086
  exec sudo -u "$SERVICE_USER" bash "$TARGET/bin/install.sh" $FLAGS
}

resume_or_start() {
  # Environment defaults (from --env or environments/<name>.env): pre-fills the
# domain so prompt 1 only needs Enter in known environments.
if [ -n "${ENV_NAME_ARG}" ] && [ -f "environments/${ENV_NAME_ARG}.env" ]; then
  say "Loading environment: ${ENV_NAME_ARG} (environments/${ENV_NAME_ARG}.env)"
  # shellcheck disable=SC1091
  . "environments/${ENV_NAME_ARG}.env"
fi

if [ -f .env ]; then
    warn "This deployment is already configured (.env exists) — resuming…"
    # The handover from root doesn't carry SERVICE_USER into this shell.
    SERVICE_USER="${SERVICE_USER:-workforce_app_sa}"
    # shellcheck disable=SC1091
    . ./.env
    if [ "${API_IMAGE}" = "ghcr.io/careangels/workforce-suite" ]; then
      sed -i 's|^API_IMAGE=.*|API_IMAGE=ghcr.io/marlon-thomas/workforce-suite|' .env
      API_IMAGE="ghcr.io/marlon-thomas/workforce-suite"
      warn "Migrated the image registry path in .env (early placeholder)."
    fi
    preflight_network
    preflight_and_pull
    # ADMIN_PASSWORD for the playbook: resume uses a fresh random value — the
    # blueprint's user entry is state:created, so it only applies to a NEW user
    # and never reverts an existing admin password.
    ADMIN_PASSWORD="$(openssl rand -base64 18)"
    run_ansible_site
    ./bin/doctor.sh
    echo ""
    echo "Re-run ./bin/update.sh <version> to change versions."
    exit 0
  fi

  [ -f compose.yaml ] || fail "compose.yaml not found — run me from the deployment bundle directory."
  [ -f ansible/site.yml ] || fail "ansible/site.yml not found — the bundle is incomplete."
  preflight_network
}

# ============================================================ main

bootstrap
resume_or_start

# ---------------------------------------------------------------- the four questions
PUBLIC_IP="$(curl -4 -fsS --max-time 8 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
if [ -n "${BASE_DOMAIN:-}" ]; then
  echo "1/4  Organisation web domain (from environment file): ${BASE_DOMAIN}"
else
  printf "1/4  What is your organisation's web domain? (e.g. carehome.org.uk): "
  read -r BASE_DOMAIN
  [ -n "${BASE_DOMAIN}" ] || fail "A domain is required."
fi
BASE_DOMAIN="${BASE_DOMAIN#http://}"; BASE_DOMAIN="${BASE_DOMAIN#https://}"
BASE_DOMAIN="${BASE_DOMAIN%/}"
case "$BASE_DOMAIN" in
  workforce.*|auth.*) BASE_DOMAIN="${BASE_DOMAIN#*.}" ;;
esac
APP_SUB="${WF_SUBDOMAIN:-workforce}"
AUTH_SUB="${AUTH_SUBDOMAIN:-auth}"
APP_HOSTNAME="${APP_SUB}.${BASE_DOMAIN}"
AUTH_HOSTNAME="${AUTH_SUB}.${BASE_DOMAIN}"
echo "     The app will be served at:  ${APP_HOSTNAME}"
echo "     Sign-in will be served at:  ${AUTH_HOSTNAME}"

if [ "${SMOKE}" -eq 0 ]; then
  say "Opening the firewall for the web (80/tcp, 443/tcp)…"
  open_port 80
  open_port 443
  say "Checking that both addresses point at this machine (this can take a few minutes
      on a fresh domain — create TWO 'A' records: ${APP_HOSTNAME} and ${AUTH_HOSTNAME}
      -> ${PUBLIC_IP})…"
  for i in $(seq 1 60); do
    verify_dns && break
    [ "$i" = 60 ] && fail "DNS still not pointing here. At your domain provider create
     two 'A' records: ${APP_HOSTNAME} -> ${PUBLIC_IP} and ${AUTH_HOSTNAME} -> ${PUBLIC_IP},
     then re-run me."
    sleep 15
  done
else
  warn "--smoke: DNS verification skipped."
fi

printf '2/4  Email for security-certificate notices: '
read -r ACME_EMAIL
[ -n "${ACME_EMAIL}" ] || fail "An email is required (certificate expiry notices)."

printf '3/4  Pick a password for the first administrator (Enter = generate a strong one): '
read -rs ADMIN_PASSWORD
echo ""
if [ -z "${ADMIN_PASSWORD}" ]; then
  ADMIN_PASSWORD="$(openssl rand -base64 18)"
  GENERATED_ADMIN=1
else
  GENERATED_ADMIN=0
  printf '     Confirm the administrator password: '
  read -rs ADMIN_PASSWORD2
  echo ""
  [ "${ADMIN_PASSWORD}" = "${ADMIN_PASSWORD2}" ] || fail "The administrator passwords did not match — re-run me."
fi

printf '4/4  Off-site backups — paste a target (rsync host:path or s3://bucket) or press Enter for local-only: '
read -r BACKUP_TARGET

# ---------------------------------------------------------------- secrets + config
say "Generating secrets (they are never displayed)…"
mkdir -p secrets backups blueprints
gen() { [ -s "secrets/$1" ] || openssl rand -base64 32 | tr -d '\n' > "secrets/$1"; }
gen db_password; gen minio_access; gen minio_secret
gen ak_db_password; gen ak_secret
{
  echo "secret_key: $(cat secrets/ak_secret)"
  echo "postgresql:"
  echo "  password: $(cat secrets/ak_db_password)"
} > secrets/ak_config.yml
OIDC_CLIENT_ID="workforce-$(openssl rand -hex 4)"
echo "$OIDC_CLIENT_ID" > secrets/oidc_client_id
openssl rand -base64 32 | tr -d '\n' > secrets/oidc_client_secret
chmod 600 secrets/*
chmod 444 secrets/ak_config.yml   # bind-mounted into authentik (rootless uid mapping)

say "Writing configuration…"
cat > .env <<ENV
ENV_NAME=prod
APP_HOSTNAME=${APP_HOSTNAME}
AUTH_HOSTNAME=${AUTH_HOSTNAME}
ACME_EMAIL=${ACME_EMAIL}

DB_NAME=workforce
DB_USER=workforce_app

MINIO_BUCKET=workforce-evidence

AK_DB_NAME=authentik
AK_DB_USER=authentik

OIDC_ISSUER=https://${AUTH_HOSTNAME}/application/o/workforce/

API_IMAGE=ghcr.io/marlon-thomas/workforce-suite
APP_VERSION=${APP_VERSION:-0.2.2}

BACKUP_TARGET=${BACKUP_TARGET}
ENV
chmod 600 .env

# Load for the preflight/pull + the ansible extra-vars.
# shellcheck disable=SC1091
. ./.env
preflight_network
preflight_and_pull

# ---------------------------------------------------------------- converge (ansible)
# Everything below is declarative Ansible state (../ansible/): the identity plane
# starts first and the playbook WAITS for the OIDC discovery document to answer 200
# (blueprint applied, provider published) before building the app plane. The api
# boots against a finished issuer — no OIDC race.
run_ansible_site

# ---------------------------------------------------------------- health check
say "Final health check:"
if [ "${SMOKE}" -eq 1 ]; then
  ./bin/doctor.sh --smoke || true
else
  ./bin/doctor.sh || true
fi

# ---------------------------------------------------------------- summary
cat <<DONE

------------------------------------------------------------------------
  Staff will use:  https://${APP_HOSTNAME}
  First sign-in:   https://${AUTH_HOSTNAME}  (user: admin)
  Then the setup wizard inside the app completes your organisation.

  Backups run nightly to ./backups${BACKUP_TARGET:+ and off-site to ${BACKUP_TARGET}}.
  Useful commands (from this directory):
    ./bin/doctor.sh    health check (send output to support when something looks wrong)
    ./bin/update.sh    upgrade when a new version is announced
    ./bin/backup.sh    make a backup right now
------------------------------------------------------------------------
DONE

if [ "${GENERATED_ADMIN}" -eq 1 ]; then
  echo "  Your administrator password (shown once — save it now):"
  echo "      ${ADMIN_PASSWORD}"
  echo ""
fi
