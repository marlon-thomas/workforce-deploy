#!/usr/bin/env bash
# install.sh — Care Angels Workforce Suite, B-mode appliance installer
# (deployment-spec §B2: "paste one line, answer four questions").
#
# Run as root on a fresh VPS:   ./bin/install.sh
# Local/no-TLS test run:        ./bin/install.sh --smoke
# Classic system docker:        ./bin/install.sh --system-docker
#
# Journey (root phase): service user -> bundle relocation to /opt -> Docker (rootless
# by default) -> registry login -> hand over. Journey (service-user phase): the four
# questions -> secrets -> images -> the running stack -> health check.
set -euo pipefail

cd "$(dirname "$0")/.."   # bundle root

SMOKE=0
SYSTEM_DOCKER=0
for arg in "$@"; do
  case "$arg" in
    --smoke) SMOKE=1 ;;
    --system-docker) SYSTEM_DOCKER=1 ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m ->\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mXX\033[0m %s\n' "$*"; exit 1; }

# ============================================================ helper functions

open_port() {
  # The machine needs exactly three inbound ports: 22 (ssh — already open), 80+443.
  # CLOUD firewalls (Hetzner/DO/Contabo panels) are a separate layer the installer
  # cannot touch — doctor.sh verifies reachability end-to-end.
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
  # Internet + registry reachability — safe to run before the questions.
  say "Checking internet and registry reachability…"
  PING_OK=$(curl -4 -fsS -o /dev/null -w '%{http_code}' --max-time 8 https://get.docker.com 2>/dev/null || echo 0)
  [ "$PING_OK" != "0" ] || fail "This machine cannot reach the internet (get.docker.com unreachable).
     On Contabo/other providers the server may need its firewall panel opened, or
     IPv6 misconfiguration is breaking outbound access — try: curl -4 https://ifconfig.me"
  GH_OK=$(curl -4 -fsS -o /dev/null -w '%{http_code}' --max-time 8 https://ghcr.io/v2/ 2>/dev/null || echo 0)
  [ "$GH_OK" != "0" ] || fail "ghcr.io is unreachable from this machine (network filtering?)"
  echo "     Internet OK, ghcr.io reachable."
}

pull_stack_images() {
  # Pull every stack image with retries — large layers over flaky links (or GHCR/DH
  # connection resets mid-transfer) abort `compose up`; retrying just the pulls
  # resumes from cached layers, so each attempt gets strictly closer to done.
  say "Pulling the stack images (retries automatically on network resets)…"
  ATTEMPT=1
  MAX=6
  while true; do
    if docker compose pull; then
      echo "     All images pulled."
      return 0
    fi
    if [ "$ATTEMPT" -ge "$MAX" ]; then
      fail "Image pulls kept failing after $MAX attempts. The stack is stopped.
     Run me again — pulls resume from where they left off (cached layers are kept)."
    fi
    warn "Pull attempt $ATTEMPT hit a network error — waiting 15s and resuming (attempt $((ATTEMPT+1))/$MAX)…"
    ATTEMPT=$((ATTEMPT+1))
    sleep 15
  done
}

preflight_and_pull() {
  # The application image, with diagnosis. Needs .env (API_IMAGE/APP_VERSION).
  # Retries: large layers over flaky dual-stack links get reset mid-transfer
  # (observed on Contabo over IPv6) — each retry resumes from cached layers.
  say "Fetching the application image (retries automatically on network resets)…"
  PULL_ERR=""
  ATTEMPT=1
  while true; do
    PULL_ERR="$(docker pull "${API_IMAGE}:${APP_VERSION}" 2>&1 >/dev/null | tail -2)"
    if [ -z "$PULL_ERR" ]; then
      break   # success
    fi
    if [ "$ATTEMPT" -ge 4 ]; then
      break   # fall through to diagnosis with the last error captured
    fi
    warn "Pull attempt $ATTEMPT failed — waiting 15s and resuming (cached layers are kept)…"
    ATTEMPT=$((ATTEMPT+1))
    sleep 15
  done

  if [ -n "$PULL_ERR" ]; then
    echo "     last error: $PULL_ERR"
    # Distinguish credential problems from missing images: the manifest probe
    # needs no pull rights beyond the token, so a 200 here with a failed pull
    # means credentials are fine and the problem is network/transport.
    if docker manifest inspect "${API_IMAGE}:${APP_VERSION}" >/dev/null 2>&1; then
      case "$PULL_ERR" in
        *denied*|*authentication*|*unauthorized*)
          fail "The image exists but your stored registry credential cannot pull it
     (expired/revoked GitHub token or missing read:packages scope).
     Fix: docker login ghcr.io -u <github-user>   (fresh read:packages token),
     then re-run me.";;
        *"connection reset"*|*timeout*|*EOF*)
          warn "Credentials are fine — the failure is the network path (the server's
     IPv6 route to the registry resets mid-transfer on some hosts).
     Forcing IPv4 preference for this machine…"
          sysctl -w net.ipv4.tcp_disallow=0 >/dev/null 2>&1 || true
          grep -q "precedence ::ffff:0:0/96  100" /etc/gai.conf 2>/dev/null \
            || echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
          warn "IPv4 preferred for future connections. Re-run me — the pull resumes
     from cached layers (or run it as the service user: docker pull ${API_IMAGE}:${APP_VERSION})"
          fail "Re-run me after the IPv4 preference change (one command: ./bin/install.sh).";;
        *)
          fail "Could not pull ${API_IMAGE}:${APP_VERSION} — see the last error above.";;
      esac
    else
      fail "The image ${API_IMAGE}:${APP_VERSION} does not exist (or the token cannot
     see it). If the token is fresh and scoped read:packages, check the image name
     in .env."
    fi
  fi
}

bootstrap() {
  # Runs ONLY as root: creates the service user, relocates the bundle to /opt,
  # installs Docker (rootless by default), performs the registry login AS the
  # service user, then re-execs the installer as that user. Everything after the
  # handover runs unprivileged.
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
    # The service-account password is mandatory — a locked account breaks day-2
    # operation. Loop until passwd succeeds.
    while true; do
      if passwd "$SERVICE_USER"; then break; fi
      echo "   Passwords did not match or were rejected — try again."
    done
    echo "   Service account password set."
  fi

  # Relocate the bundle to /opt — a dir under /root blocks the service user no
  # matter how files are chowned (traversal through 0700 /root is denied).
  TARGET="/opt/workforce-deploy"
  CURRENT="$(cd "$(dirname "$0")/.." && pwd)"
  if [ "$CURRENT" != "$TARGET" ]; then
    echo "Moving the deployment bundle to $TARGET (the service user cannot live under /root)…"
    mkdir -p "$(dirname "$TARGET")"
    if [ -d "$TARGET" ] && [ -f "$TARGET/.env" ]; then
      # A previous install lives there — refresh tooling, keep its .env/secrets.
      cp -a "$CURRENT"/bin "$CURRENT"/gateway "$CURRENT"/blueprints "$CURRENT"/compose.yaml "$CURRENT"/.env.example "$CURRENT"/README.md "$CURRENT"/RUNBOOK.md "$TARGET/" 2>/dev/null || true
    else
      rm -rf "$TARGET"
      mkdir -p "$TARGET"
      cp -a "$CURRENT/." "$TARGET/"
    fi
    # Replace the original clone with a pointer file — a stale copy without .env
    # is a trap (compose runs from it fail with confusing interpolation errors).
    # The running script's CWD is inside $CURRENT — move out first or every child
    # shell dies with getcwd() failed (the running bash keeps its script fd open,
    # so unlinking is safe once the CWD has moved).
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

  # ---- Docker: rootless by default (the daemon runs as the service user — no
  #      root-equivalent socket on the host; deployment-spec §B4 hardening).
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
    # Prerequisites: unprivileged userns, subuid/subgid ranges, lingering, uidmap.
    usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$SERVICE_USER"
    loginctl enable-linger "$SERVICE_USER"
    apt-get -qq install -y uidmap dbus-user-session >/dev/null 2>&1 || true
    # Rootless daemons cannot bind <1024: raise the floor so the gateway binds 80/443.
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
    # Pin the socket + runtime dir for the service user's shells — every later
    # script (doctor/update/backup) uses plain `docker`.
    cat > "/home/${SERVICE_USER}/.profile.d-docker" <<PROF
export DOCKER_HOST=unix:///run/user/$(id -u "$SERVICE_USER")/docker.sock
export XDG_RUNTIME_DIR=/run/user/$(id -u "$SERVICE_USER")
PROF
    if ! grep -q "profile.d-docker" "/home/${SERVICE_USER}/.bashrc" 2>/dev/null; then
      echo '. "$HOME/.profile.d-docker"' >> "/home/${SERVICE_USER}/.bashrc"
    fi
    chown "$SERVICE_USER:$SERVICE_USER" "/home/${SERVICE_USER}/.bashrc" "/home/${SERVICE_USER}/.profile.d-docker"
  fi

  # ---- Registry login (images are private until licensing ships). Performed AS
  #      the service user so credentials land in THEIR docker config.
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
    # HOME pinned to the service user — sudo -E would keep root's HOME and docker
    # would try to store credentials in /root/.docker (denied).
    sudo -u "$SERVICE_USER" env HOME="/home/${SERVICE_USER}" \
      GH_USER="$GH_USER" GH_TOKEN="$GH_TOKEN" \
      sh -c 'echo "$GH_TOKEN" | docker login ghcr.io -u "$GH_USER" --password-stdin' \
      || fail "Registry login failed — the token needs read:packages scope."
  fi

  # Hand over: re-exec as the service user from /opt.
  echo ""
  echo "Bootstrap complete. Continuing as '$SERVICE_USER' from $TARGET…"
  FLAGS=""
  [ "${SMOKE}" -eq 1 ] && FLAGS="--smoke"
  [ "${SYSTEM_DOCKER}" -eq 1 ] && FLAGS="${FLAGS} --system-docker"
  # shellcheck disable=SC2086
  exec sudo -u "$SERVICE_USER" bash "$TARGET/bin/install.sh" $FLAGS
}

resume_or_start() {
  if [ -f .env ]; then
    # Resume: configuration exists — migrate, pull, start, check.
    warn "This deployment is already configured (.env exists) — resuming…"
    # shellcheck disable=SC1091
    . ./.env
    # Silent migration: early bundles shipped a placeholder image name that never
    # existed. .env is generated at install time, so git pull does not update it.
    if [ "${API_IMAGE}" = "ghcr.io/careangels/workforce-suite" ]; then
      sed -i 's|^API_IMAGE=.*|API_IMAGE=ghcr.io/marlon-thomas/workforce-suite|' .env
      API_IMAGE="ghcr.io/marlon-thomas/workforce-suite"
      warn "Migrated the image registry path in .env (early placeholder)."
    fi
    preflight_and_pull

    # (Re)render the provisioning blueprint — the resume path never rendered it
    # (earlier installers only rendered on the fresh path), leaving authentik with
    # no OIDC provider and the api crash-looping on discovery.
    say "Rendering the sign-in blueprint…"
    if [ -f secrets/oidc_client_id ] && [ -f secrets/oidc_client_secret ] \
       && grep -q "OIDC_ISSUER=https://" .env; then
      APP_HOSTNAME_RESUMED="$(grep '^APP_HOSTNAME=' .env | cut -d= -f2-)"
      ACME_EMAIL_RESUMED="$(grep '^ACME_EMAIL=' .env | cut -d= -f2-)"
      AK_ADMIN_PASSWORD_RESUMED="$(openssl rand -base64 18)"
      sed   -e "s|\${OIDC_CLIENT_ID}|$(cat secrets/oidc_client_id)|g" \
        -e "s|\${OIDC_CLIENT_SECRET}|$(cat secrets/oidc_client_secret)|g" \
        -e "s|\${WF_REDIRECT_URI}|https://${APP_HOSTNAME_RESUMED}/login/oauth2/code/oidc|g" \
        -e "s|\${ACME_EMAIL}|${ACME_EMAIL_RESUMED}|g" \
        -e "s|\${AK_ADMIN_PASSWORD}|${AK_ADMIN_PASSWORD_RESUMED}|g" \
        blueprints/workforce-app.yaml.template > blueprints/workforce-app.yaml
      chmod 644 blueprints/workforce-app.yaml
    fi

    say "Fetching remaining images and starting the stack…"
    pull_stack_images
    docker compose up -d
    sleep 20
    ./bin/doctor.sh
    echo ""
    echo "Re-run ./bin/update.sh <version> to change versions."
    exit 0
  fi

  # Sanity: the wizard must run from the bundle root (compose.yaml present).
  [ -f compose.yaml ] || fail "compose.yaml not found — run me from the deployment bundle directory."

  # Network preflight before the questions: fail fast on connectivity problems.
  preflight_network
}

# ============================================================ main

bootstrap
resume_or_start

# ---------------------------------------------------------------- the four questions
PUBLIC_IP="$(curl -4 -fsS --max-time 8 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
printf "1/4  What is your organisation's web domain? (e.g. carehome.org.uk): "
read -r BASE_DOMAIN
[ -n "${BASE_DOMAIN}" ] || fail "A domain is required."
BASE_DOMAIN="${BASE_DOMAIN#http://}"; BASE_DOMAIN="${BASE_DOMAIN#https://}"
BASE_DOMAIN="${BASE_DOMAIN%/}"
case "$BASE_DOMAIN" in
  # Tolerate pasting a full hostname: strip a leading workforce./auth. prefix.
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

# ---------------------------------------------------------------- generate secrets
say "Generating secrets (they are never displayed)…"
mkdir -p secrets backups blueprints
gen() { [ -s "secrets/$1" ] || openssl rand -base64 32 | tr -d '\n' > "secrets/$1"; }
gen db_password; gen minio_access; gen minio_secret
gen ak_db_password; gen ak_secret
# authentik 2024.12 cannot write /etc as a non-root user and dropped *_FILE support —
# its documented /etc/authentik/config.yml is delivered as a Docker secret composed
# here from the other two secrets.
{
  echo "secret_key: $(cat secrets/ak_secret)"
  echo "postgresql:"
  echo "  password: $(cat secrets/ak_db_password)"
} > secrets/ak_config.yml
OIDC_CLIENT_ID="workforce-$(openssl rand -hex 4)"
echo "$OIDC_CLIENT_ID" > secrets/oidc_client_id
openssl rand -base64 32 | tr -d '\n' > secrets/oidc_client_secret
# All secrets are 0600 — EXCEPT ak_config.yml, which is bind-mounted into the
# authentik containers and must be 0444: under the rootless daemon's uid mapping,
# a 0600/0644 owner-only... (0644 owner-read-only is fine for other users, but the
# mapped in-container user is NOT the owner) — 0444 is required for the in-container
# user to read it (observed live: 0644 → PermissionError).
chmod 600 secrets/*
chmod 444 secrets/ak_config.yml

# ---------------------------------------------------------------- write config
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

API_IMAGE=ghcr.io/marlon-thomas/workforce-suite
APP_VERSION=${APP_VERSION:-0.2.1}

BACKUP_TARGET=${BACKUP_TARGET}
ENV
chmod 600 .env

# Load the freshly written config for the preflight/pull helper.
# shellcheck disable=SC1091
. ./.env
preflight_and_pull

# ---------------------------------------------------------------- start the stack
# SEQUENCED START (the OIDC race): authentik must be fully up AND its blueprint
# applied BEFORE the api boots — the api's first act is fetching the OIDC discovery
# document, and a 502 there is fatal at context-initialisation. Two phases:
#   1. identity plane: authentik (+ its db/redis) waits until the discovery
#      document answers 200 — the blueprint is applied and the provider exists
#   2. app plane: api + worker + gateway boot against a finished issuer
say "Starting the identity plane (authentik, first boot migrates its database — takes minutes)…"
pull_stack_images
if [ "${SMOKE}" -eq 1 ]; then
  docker compose -f compose.yaml -f compose.smoke.yaml up -d
else
  docker compose up -d authentik-postgres ak-redis authentik-server authentik-worker \
    postgres object-storage clamav gotenberg
fi

if [ "${SMOKE}" -ne 1 ]; then
  say "Waiting for sign-in to be ready and the blueprint applied (up to ~5 minutes)…"
  BP_OK=0
  for i in $(seq 1 60); do
    CODE="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 \
      "https://${AUTH_HOSTNAME}/application/o/workforce/.well-known/openid-configuration" 2>/dev/null || echo 000)"
    if [ "$CODE" = "200" ]; then
      echo "     Sign-in plane ready, provider published (attempt $i)."
      BP_OK=1
      break
    fi
    printf '     waiting… attempt %d/60 (discovery answered %s)\r' "$i" "$CODE"
    sleep 10
  done
  echo ""
  [ "$BP_OK" -eq 1 ] || warn "The OIDC discovery document did not publish in 5 minutes. The api will
     retry its discovery fetch on restart; if it stays down, check
     docker compose logs authentik-worker (blueprint errors) and re-run me."
fi

# Build the api JVM truststore from the gateway's served chain — under STAGING
# certificates the api's JVM cannot validate authentik's chain otherwise. Harmless
# in production mode (the chain validates against the JVM's own truststore anyway;
# adding it only pins the exact chain).
if [ "${SMOKE}" -ne 1 ]; then
  say "Preparing the api trust store from the sign-in certificate…"
  echo | openssl s_client -connect "${AUTH_HOSTNAME}:443" -servername "${AUTH_HOSTNAME}" 2>/dev/null \
    | openssl x509 -outform DER > /tmp/auth-cert.der
  if [ -s /tmp/auth-cert.der ]; then
    keytool -importcert -noprompt -alias careangels-gateway \
      -file /tmp/auth-cert.der -keystore secrets/api-truststore.jks \
      -storepass changeit >/dev/null 2>&1 \
      && chmod 644 secrets/api-truststore.jks \
      && say "Trust store ready (api will trust the sign-in certificate)." \
      || warn "Could not build the trust store — if the api crash-loops on TLS,
     production certificates (Caddyfile switch back) resolve it."
    rm -f /tmp/auth-cert.der
  fi
fi

say "Starting the application plane (api, worker, gateway)…"
if [ "${SMOKE}" -eq 1 ]; then
  docker compose -f compose.yaml -f compose.smoke.yaml up -d
else
  docker compose up -d
fi

# First boot convergence: wait (bounded) for the api's identity endpoint through the
# gateway so the final doctor reflects a ready system, not a booting one.
if [ "${SMOKE}" -ne 1 ]; then
  say "Waiting for the application to become ready…"
  JVM_STAGING_NOTE=0
  for i in $(seq 1 60); do
    CODE="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "https://${APP_HOSTNAME}/api/v1/build-meta" 2>/dev/null || echo 000)"
    if [ "$CODE" = "200" ]; then echo "     Application is up (attempt $i)."; break; fi
    # Visible progress: a silent 10-minute wait looks like a hang.
    printf '     waiting… attempt %d/60 (gateway answered %s)\r' "$i" "$CODE"
    if [ "$i" = 20 ] && [ "$JVM_STAGING_NOTE" -eq 0 ]; then
      JVM_STAGING_NOTE=1
      warn "If the gateway is using STAGING certificates (rate-limit override), the api's
     JVM cannot validate authentik's chain — discovery keeps failing until
     production certificates return. That is expected in this mode."
    fi
    [ "$i" = 60 ] && { echo ""; warn "The application did not become ready in 10 minutes. Checking whether it is
     crash-looping: docker compose ps && docker compose logs api --tail 30
     If logs show 'Started WorkforceApplication', it is fine — re-run ./bin/doctor.sh."; }
    sleep 10
  done
  echo ""
fi

# ---------------------------------------------------------------- blueprint
say "Connecting the workforce system to the sign-in server (authentik applies the blueprint on startup)…"
if [ "${SMOKE}" -eq 1 ]; then
  warn "--smoke: sign-in is wired for localhost (no TLS) — production runs use https."
fi
# Render the provisioning blueprint (deployment-spec §B5): OIDC provider + application
# + first administrator. authentik applies it natively on every startup (idempotent).
AK_ADMIN_PASSWORD="${ADMIN_PASSWORD}"
sed   -e "s|\${OIDC_CLIENT_ID}|$(cat secrets/oidc_client_id)|g" \
  -e "s|\${OIDC_CLIENT_SECRET}|$(cat secrets/oidc_client_secret)|g" \
  -e "s|\${WF_REDIRECT_URI}|https://${APP_HOSTNAME}/login/oauth2/code/oidc|g" \
  -e "s|\${ACME_EMAIL}|${ACME_EMAIL}|g" \
  -e "s|\${AK_ADMIN_PASSWORD}|${AK_ADMIN_PASSWORD}|g" \
  blueprints/workforce-app.yaml.template > blueprints/workforce-app.yaml
# 644, not 600: the file is bind-mounted into authentik, and under the rootless
# daemon's uid mapping a 0600 host file is unreadable to the in-container user —
# blueprint discovery silently skips it (the ak_config.yml lesson, now applied here).
chmod 644 blueprints/workforce-app.yaml
docker compose up -d authentik-server authentik-worker

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
