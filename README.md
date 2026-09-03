# Deployment — from scratch

This guide takes a clean Linux host to a working, TLS-secured deployment. Follow it in order;
each step depends only on the ones before it. Nothing here touches the application source —
all organisation-specific values are supplied in **one file** (`deploy/.env`) plus secret files.

## 0. Prerequisites

- A Linux host with **Docker** and the compose plugin
- **Two DNS A/AAAA records** pointing at the host (IPv4 and IPv6 as applicable):
  - `APP_HOSTNAME` — the workforce app (e.g. `workforce.example.com`)
  - `AUTH_HOSTNAME` — the authentik sign-in server (e.g. `auth.example.com`)
  - TLS certificates are obtained automatically (Let's Encrypt) using `ACME_EMAIL` — make sure
    port 80 and 443 are reachable from the internet when you first start the stack
- Outbound internet access (image pulls, certificate issuance)

## 1. Get the code and create your configuration

```bash
git clone <your-repository> workforce && cd workforce
cp deploy/.env.example deploy/.env
```

Edit `deploy/.env` — this single file holds every non-secret value:

| Key | What it is | Example |
|-----|------------|---------|
| `APP_HOSTNAME` | Public hostname of the app | `workforce.example.com` |
| `AUTH_HOSTNAME` | Public hostname of the sign-in server | `auth.example.com` |
| `ACME_EMAIL` | Email for TLS certificate expiry notices | `it@example.com` |
| `DB_NAME` / `DB_USER` | Application database (leave defaults unless you have a reason) | `workforce` / `workforce_app` |
| `MINIO_BUCKET` | Evidence storage bucket | `workforce-evidence` |
| `API_IMAGE` (**required**) | Image name the api/worker/migration containers are built as and run from. No tag — the tag comes from `APP_VERSION`. Locally built (no registry needed): `workforce-api`. From your own registry: `ghcr.io/your-org/workforce-api` | `workforce-api` |
| `OIDC_ISSUER` | Issuer URL of the authentik application (created in step 3) | `https://auth.example.com/application/o/workforce/` |
| `APP_VERSION` | Release tag to deploy | `0.1.0` |

**Secrets are separate.** Create `deploy/secrets/` and write each value to its own file:

```bash
mkdir -p deploy/secrets && chmod 700 deploy/secrets
openssl rand -base64 24 > deploy/secrets/db_password
openssl rand -base64 24 > deploy/secrets/minio_access
openssl rand -base64 24 > deploy/secrets/minio_secret
openssl rand -hex 32 > deploy/secrets/ak_secret
openssl rand -base64 18 > deploy/secrets/ak_db_password
# oidc_client_id / oidc_client_secret come later (step 3)
chmod 600 deploy/secrets/*
```

## 2. First boot (login is disabled until authentik is configured)

Start everything except the OIDC-gated login — the app is reachable, but you cannot sign in yet:

```bash
docker compose -f deploy/compose.yaml up -d
```

Wait for health (a few minutes on first start — migrations run, ClamAV downloads its
signature database):

```bash
docker compose -f deploy/compose.yaml ps
```

## 3. Configure authentik (the sign-in server)

1. Open `https://$AUTH_HOSTNAME` and sign in. On first boot authentik asks you to set an
   admin password (token via `docker compose exec authentik-server ak create_admin_recovery_link`).
2. Create **Providers → OAuth2/OpenID Connect**:
   - Name/slug: e.g. `workforce` (this slug appears inside the issuer URL)
   - **Redirect URI (exact):** `https://$APP_HOSTNAME/login/oauth2/code/oidc`
   - Client type: confidential; note the generated **client id** and **client secret**
3. Create **Applications → Application** bound to that provider.
4. Copy the provider's **issuer URL** (shown on the provider page) into `OIDC_ISSUER` in
   `deploy/.env`, and write the client credentials:

   ```bash
   printf 'your-client-id' > deploy/secrets/oidc_client_id
   printf 'your-client-secret' > deploy/secrets/oidc_client_secret
   ```

5. Assign your own user to the application and grant them the `ADMINISTRATOR` role in
   authentik (group/role mapping) — the onboarding wizard and admin screens require it.

**Upgrading from an earlier release?** The redirect URI changed from
`.../login/oauth2/code/care-angels` to `.../login/oauth2/code/oidc`. Add the **new** URI in
authentik *before* deploying this release (keep the old one temporarily), deploy, verify
sign-in, then remove the old URI. Both URIs can coexist, so there is no downtime window.

## 4. Restart with authentication enabled

```bash
docker compose -f deploy/compose.yaml up -d
```

Open `https://$APP_HOSTNAME` — you are redirected to authentik, sign in, and land on the
**onboarding wizard**.

## 5. Onboard your organisation (in-app)

The wizard walks through: organisation identity (name, timezone, logo — this name appears on
every screen and report), your care setting (a seed pack of the statutory/mandatory training,
roles and Care Certificate policy regulators expect), a review, your locations, and an optional
staff CSV import. Everything is editable later under **Admin** and **Settings**.

## Updating

```bash
git pull
# set APP_VERSION in deploy/.env to the new release tag
docker compose -f deploy/compose.yaml up -d
```

Migrations run automatically on start. Read the release notes for any authentik-side steps
(like the redirect-URI change above) **before** restarting.

### Migrating from a release before `API_IMAGE` existed

Older releases defaulted the container image to a built-in name. This release makes
`API_IMAGE` a required setting. If `docker compose up` stops with
"`API_IMAGE is missing a value`", add one line to `deploy/.env` naming the image you already
use (check `docker images` for the name your previous deployment built):

```bash
echo 'API_IMAGE=<your-existing-image-name>' >> deploy/.env
docker compose -f deploy/compose.yaml up -d
```

Nothing else changes — the same local image continues to be used.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `redirect_uri` mismatch at sign-in | authentik does not allow the callback URI | Add exactly `https://$APP_HOSTNAME/login/oauth2/code/oidc` to the provider's redirect URIs |
| No TLS certificate issued | Port 80/443 blocked, or DNS not propagated | Check firewall and DNS; certificates are retried automatically |
| App unhealthy after start | Database not ready yet | Wait; migrations run on first start |
| Evidence uploads fail | ClamAV still downloading signatures | Wait for the `clamav` container to become healthy |

## Backups

Back up the `postgres` data volume (application database + authentik) and the MinIO data
volume (evidence objects) on a schedule; test restores. The in-app **hard reset export** is
not a backup — it is a tenant data bundle for reset purposes.
