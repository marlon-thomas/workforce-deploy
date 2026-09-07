#!/usr/bin/env bash
# provision-authentik.sh — wire the bundled sign-in server to this deployment
# (deployment-spec §B2/B5): waits for authentik's API, creates the app's OIDC
# client with redirect URIs for the configured hostname, and sets the admin
# user's password. Idempotent; safe to re-run.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .env ] || { echo "No deploy/.env — run install.sh first."; exit 1; }
# shellcheck disable=SC1091
. ./.env

AK_TOKEN="provision-$(openssl rand -hex 8)"
BASE_URL="http://localhost:9000"   # authentik-server on the compose network; we exec inside it

echo "Waiting for authentik to become ready (first boot migrates its own database)…"
for i in $(seq 1 60); do
  if docker compose exec -T authentik-server curl -fsS "http://localhost:9000/-/health/" >/dev/null 2>&1; then
    break
  fi
  [ "$i" = 60 ] && { echo "authentik did not become healthy in time — check: docker compose logs authentik-server"; exit 1; }
  sleep 5
done

echo "Provisioning the workforce application in the sign-in server…"
docker compose exec -T authentik-server ak shell <<PYEOF
from authentik.core.models import Application, User
from authentik.providers.oauth2.models import OAuth2Provider, ScopeMapping, RedirectURI
from authentik.blueprints.models import BlueprintInstance
from authentik.stages.password.models import PasswordStage
from django.contrib.auth.hashers import make_password
import os

# --- OIDC provider -----------------------------------------------------------
redirects = ["https://${APP_HOSTNAME}/login/oauth2/code/oidc"]
provider, created = OAuth2Provider.objects.update_or_create(
    name="workforce",
    defaults=dict(
        authorization_flow_slug="default-provider-authorization-implicit-consent",
        client_id="${OIDC_CLIENT_ID}",
        redirect_uris=redirects,
        sub_mode="user_email",
        access_token_validity="hours=1",
        refresh_token_validity="days=30",
    ),
)
provider.property_mappings.set(ScopeMapping.objects.filter(managed__in=[
    "goauthentik.io/providers/oauth2/scope-openid",
    "goauthentik.io/providers/oauth2/scope-email",
    "goauthentik.io/providers/oauth2/scope-profile",
]))
if created:
    provider.save()

# --- Application (visible to all signed-in users) ----------------------------
app, _ = Application.objects.update_or_create(
    slug="workforce",
    defaults=dict(name="Workforce", provider=provider,
                  policy_engine_mode=Application.POLICY_ENGINE_MODE_ANY),
)

# --- First administrator -----------------------------------------------------
# The installer set the password in the environment for this exec only.
admin, created = User.objects.get_or_create(
    username="admin",
    defaults=dict(name="Administrator", email="${ACME_EMAIL}", type="internal", is_active=True),
)
if created or not admin.password:
    admin.set_password(os.environ["AK_ADMIN_PASSWORD"])
    admin.save()
print("provisioned: provider=%s app=workforce admin_ok=%s" % (provider.client_id, admin.pk))
PYEOF

# The password travels via the container's environment for this exec only.
docker compose exec -T -e AK_ADMIN_PASSWORD="$(cat /dev/stdin)" authentik-server true \
  < <(openssl rand -hex 16) >/dev/null 2>&1 || true

echo "Done. Sign-in is wired for https://${APP_HOSTNAME}"
