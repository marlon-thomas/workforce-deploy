# Runbook — first real-server deployment (Option B test)

Takes a fresh Ubuntu 24.04 VPS from zero to `https://workforce.<your-domain>` in about
30 minutes. Written for a non-specialist; every step is copy-paste.

## 0. What you need before starting

- A VPS with **Ubuntu 24.04** (Hetzner/DO/Contabo — any provider works; the images
  are x86_64. Contabo note: use Ubuntu, not their "app templates"; install Docker in
  step 4). Contabo sizes: their cheapest Cloud VPS with 8 GB RAM is comfortable.
- A domain you control (registrar login). Two subdomains will point at the server.
- Ports **80 and 443** reachable — the installer opens the machine's own firewall;
  if your provider has a separate cloud-firewall panel, open 22/80/443 there too.
- A **GitHub personal access token** with `read:packages` scope (classic tokens:
  Settings → Developer settings → Tokens (classic)). The container images are in a
  private GHCR registry until licensing ships; the server needs this token once.

## 1. Create the server + open the cloud firewall (web forms only)

1. Create the droplet/server (Ubuntu 24.04, smallest plan is fine).
2. Note the server's **IP address**.
3. In the provider's **firewall** settings (Hetzner: Firewalls; DO: Networking →
   Firewalls), allow inbound:
   - **TCP 22** (SSH)
   - **TCP 80** (web + certificate issuance)
   - **TCP 443** (web)
   Attach the firewall to the server.

> The machine's own firewall is handled by the installer (ufw/firewalld auto-detected).
> The **cloud** firewall is a separate layer only you can open — this is the step most
> often missed; the doctor's "reachability" check names it if it's wrong.

## 2. Point DNS at the server

At your registrar, create two **A records** pointing at the server IP:

| Record | Type | Value |
|---|---|---|
| `workforce.<your-domain>` | A | `<server IP>` |
| `auth.<your-domain>` | A | `<server IP>` |

DNS propagation: usually minutes. The installer waits and re-checks both for you.

## 3–5. Run the installer as root — it does the rest

Open the provider's **console** (black window in the browser) — you are root there:

```bash
git clone https://github.com/marlon-thomas/workforce-deploy.git
cd workforce-deploy
./bin/install.sh
```

(The deployment bundle is a small **public** repository — no GitHub account needed to
clone it. Only the container-image pull later requires the token.)

The installer bootstraps the whole machine by itself:

1. Creates a **`workforce_app_sa` service user** (the system is never operated as
   root — it sets the login password with you) and hands over
2. Installs **Docker** if missing, adds the service user to the docker group
3. Asks for the **GitHub token** (`read:packages`) and logs in to the image registry
4. Opens the **firewall** (80/443) on the machine
5. Asks the **four questions** (hostname, email, admin password, backup target)
6. Starts everything and ends with the green/red health table

That's the whole deployment. The remaining manual steps are DNS (step 2) and the
cloud firewall (step 1) — layers outside the machine the installer cannot touch.

## 5. Log in to the image registry (one-time)

The images are private while licensing is in development. Create a **classic PAT with
`read:packages`** on GitHub (Settings → Developer settings), then:

```bash
docker login ghcr.io -u marlon-thomas -p <YOUR_TOKEN>
```

## 5b. Get the code and run the wizard

```bash
git clone https://github.com/marlon-thomas/workforce_suite.git
cd workforce_suite/deploy
./bin/install.sh
```

The wizard asks **four questions**:

1. Your organisation's **domain** → `your-domain.co.uk` — the installer derives
   `workforce.<domain>` (staff) and `auth.<domain>` (sign-in), shows both, and
   verifies both point at this machine (waiting if not)
2. Email for certificate notices
3. Administrator password (Enter = generate one and show it once)
4. Off-site backup target (Enter = local only — fine for the test)

Then it opens the firewall, generates all secrets, pulls the published images
(`ghcr.io/marlon-thomas/workforce-suite:0.2.0` — the registry login from step 5
authorises the pull), starts the 13-service stack,
connects the sign-in server, and finishes with a green/red health table.

## 6. First sign-in

- App: `https://workforce.<your-domain>` → the onboarding wizard runs
- Sign-in server: `https://auth.<your-domain>` (user `admin`, the password from step 5)

## 7. When something looks wrong

```bash
./bin/doctor.sh
```
Paste the output to support. The "reachability" row failing almost always means the
**cloud firewall** (step 1) is missing 80/443, or DNS (step 2) isn't propagated.

## 8. Finished testing?

```bash
./bin/uninstall.sh     # stops everything, keeps a final backup, data kept unless you type DELETE-DATA
```
Then destroy the VPS at the provider. Total cost: pennies of hourly billing.

## Hardening notes (for production, not the test)

- ~~Rootless Docker~~ — **implemented**: the daemon runs as the `workforce_app_sa` user by default (no root-equivalent daemon). `--system-docker` reverts for hosts without userns.
- The installer creates a user-level deployment; nothing it installs runs as root
  (containers run as `app`/`authentik`/`postgres` users with read-only root filesystems)
- Off-site backups: provide an S3/rsync target at install time
- License enforcement arrives with deployment-spec backlog #5
