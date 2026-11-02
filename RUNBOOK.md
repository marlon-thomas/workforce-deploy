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
5. Asks the **six questions** (hostname, email, admin password, backup target, outgoing email, alert address)
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

The wizard asks **six questions**:

1. Your organisation's **domain** → `your-domain.co.uk` — the installer derives
   `workforce.<domain>` (staff) and `auth.<domain>` (sign-in), shows both, and
   verifies both point at this machine (waiting if not)
2. Email for certificate notices
3. Administrator password (Enter = generate one and show it once), then the emergency
   administrator's **recovery email**: an address you control that is not hosted on this server
4. Off-site backup target (Enter = local only — fine for the test)
5. **Outgoing email**: the relay that delivers Workforce's email (reminders, invitations,
   password resets, server alerts). Pick Microsoft 365, Google Workspace, Brevo, SMTP2GO,
   Amazon SES (London), Mailgun (EU) or another provider's host and port (STARTTLS, usually 587;
   465 doesn't work), then the user name, password or SMTP key, and the From address. Enter =
   none for now (emails are only logged). Ask the provider for the sender domain's SPF and DKIM
   records, or the email lands in spam. Skipped when the environment file sets `SMTP_HOST`.
6. **Server alerts**: an address *not* hosted on this server for health alerts (§7b), and
   optionally an outside uptime check's ping URL (§7c). When both a relay and an alert address
   are set, the installer sends a test alert at the end.

Then it opens the firewall, generates all secrets, pulls the published images
(`ghcr.io/marlon-thomas/workforce-suite:0.2.0` — the registry login from step 5
authorises the pull), starts the 13-service stack,
connects the sign-in server, and finishes with a green/red health table.

## 6. First sign-in

- App: `https://workforce.<your-domain>` → the onboarding wizard runs
- Sign-in server: `https://auth.<your-domain>` (user `admin`, the password from step 5)
- `admin` is the **emergency administrator** (setup and recovery only — no staff record, no
  mailbox). Once the organisation exists, set up your own account in Setup → Administrator
  accounts and work from that. Give the emergency account a recovery email outside this server:
  `ADMIN_RECOVERY_EMAIL` in `.env`, then `./bin/update.sh <running version>` (README → "The
  emergency administrator and its recovery email").

## 6a. Jobs from the app

**Start here, not with a shell.** The registered manager or a director can run the routine jobs from
Setup in Workforce, and nobody needs to sign in to the server for them:

| Job | Where | By hand, if the app can't |
|---|---|---|
| Back up now; test the off-site copy | Setup → Server health | `./bin/backup.sh`; `./bin/backup.sh --offsite-only` |
| Staff email on and off | Setup → Email | `./bin/staff-mail.sh on\|off` (top of the script) |
| Outgoing email relay, with a test send before saving | Setup → Email | `SMTP_*` in `.env`, then `docker compose up -d worker api` |
| Alert address and uptime ping address, then a test alert | Setup → Server health | §7b, §7c |

Updates, restore, the recovery address, DNS and port 25 stay outside the app (Workforce ADR-0026, ADR-0031).

**How it works.** The app has no docker socket, no shell, and no write access to `.env` or `secrets/`.
It leaves a request in `actions/requests/`; `bin/server-actions.sh`, run by cron in the `backup`
container, treats it as hostile, does only what's on its fixed list, and writes a result to
`actions/results/`. A request not picked up in 2 minutes expires and never runs later. One job at a
time, each with a time limit. Everything it does is in `logs/server-actions.log`, with secrets masked;
the app's audit trail says who asked. Changes to the relay, the alert address and staff email also
send a note to the alert address.

| Path | Owner, mode | Who |
|---|---|---|
| `actions/requests/` | uid 999 (the app), 0700; files 0600 | The app writes. The helper, root in its container, reads and deletes. A password is on disk only until the helper reads it |
| `actions/results/` | helper, 0755; files 0644 | The helper writes. Mounted read-only into `api` only. Never holds a secret |
| `actions/work/` | helper, 0700 | The lock, the file being read, requests already seen |

The helper sets those modes on every run, so `actions/requests/` can't be listed by the service account
on the host (it belongs to a mapped uid under rootless docker). Removing the whole bundle needs root.
`backup.sh` doesn't archive `actions/`, and git ignores it.

**Turning it off.** `SERVER_ACTIONS=off` in `.env` stops the helper at its next pass, needs no restart,
and doesn't rely on the app: requests get a written refusal. `WORKFORCE_SERVER_ACTIONS=false` then
`docker compose up -d api` takes the buttons away; **the hosted platform sets this**, and they're also
gone whenever `WORKFORCE_SERVER_HEALTH_VISIBLE` is false.

**When the app says the helper isn't running.** `docker compose ps backup`, then
`docker compose up -d backup`. `actions/results/helper.json` is rewritten about every minute, so its
time shows whether cron is alive. `docker compose logs backup` shows a failed `apk add` (the container
installs `jq`, `curl` and the others when it starts, so it needs the network then). An older install
gets the new schedule the first time the container is recreated, which `update.sh` does.

**What it can't reach.** Port 25 and DNS. Inside a container the helper can't see the host's
`net.ipv4.ip_unprivileged_port_start`, so "staff email on" finds out when the mail server fails to
start: it puts the settings back and says to run, once, as root,
`sysctl -w net.ipv4.ip_unprivileged_port_start=25`.

**Relay passwords.** Stored in `.env` in single quotes. Refused: a single quote, a backslash (compose
reads `\'` as not closing the quote, so a value ending in one stops the whole stack), non-ASCII, `${`
and `#{` (the app's settings resolve placeholders), and fewer than 6 characters. The installer now
refuses a password ending in a backslash too.

**Test appliance.** `SERVER_ACTIONS_PLAIN_RELAY=mailpit:1025` lets that one relay be saved without
STARTTLS. It's only read from `.env`, so the app can't ask for it. **Never set it in production.**

## 7. When something looks wrong

```bash
./bin/doctor.sh
```
Paste the output to support. The "reachability" row failing almost always means the
**cloud firewall** (step 1) is missing 80/443, or DNS (step 2) isn't propagated.

`./bin/doctor.sh --plain` prints the same rows without colour, one per line
(`STATUS<TAB>check<TAB>detail`) for scripts. Install, update and restore run it as
`./bin/doctor.sh --gate`: the operational checks (backup age, disk, staff mail,
notifications, alerting) then report at most WARN, so they never fail an install or roll
back a good update. Run it by hand without `--gate` to see them as FAILs.

## 7a. Client addresses

Rootless Docker's default port driver shows every client as the Docker gateway (`172.x`), which puts a
meaningless address on signature certificates, in the audit and in the mail server's filtering. New installs
use the `slirp4netns` driver, which keeps the real address (it's a little slower, which doesn't matter
here). `./bin/doctor.sh` warns under "client addresses" if a server still has the default. To change one, as
root, once (the stack restarts, about a minute of downtime):

```bash
apt-get install -y slirp4netns
d=/home/workforce_app_sa/.config/systemd/user/docker.service.d; mkdir -p "$d"
printf '[Service]\nEnvironment=DOCKERD_ROOTLESS_ROOTLESSKIT_NET=slirp4netns\nEnvironment=DOCKERD_ROOTLESS_ROOTLESSKIT_PORT_DRIVER=slirp4netns\n' > "$d/source-ip.conf"
chown -R workforce_app_sa: "$d"
sudo -u workforce_app_sa XDG_RUNTIME_DIR=/run/user/$(id -u workforce_app_sa) systemctl --user daemon-reload
sudo -u workforce_app_sa XDG_RUNTIME_DIR=/run/user/$(id -u workforce_app_sa) systemctl --user restart docker
```

## 7b. Server alerts (health watch)

So that someone **outside** the server hears about a problem — even when the app, or the
server's own mail server, is what broke.

**What runs.** The `backup` container runs `./bin/healthwatch.sh` every 15 minutes
(next to the 02:00 nightly backup). It runs `./bin/doctor.sh` and emails
`OPS_ALERT_EMAIL` when:

| When | Subject |
|---|---|
| a check newly FAILs (also a WARN turning into a FAIL) | `[Workforce prod workforce.example.com] 2 checks failing: last backup, mail sync` |
| something is still failing, at most once a day | `[…] reminder: 2 checks still failing: …` |
| every FAIL has cleared | `[…] resolved: no checks failing` |

The email lists the failing and warning rows, the server, the time and the command to
investigate (`cd /opt/workforce-deploy && ./bin/doctor.sh`). WARNs alone never send email.
Each run logs one line to `logs/healthwatch.log`; what was failing is kept in
`state/healthwatch.state` (delete it to start afresh). A send that fails is logged and
tried again 15 minutes later.

**What it watches** — every doctor row, including the ones that exist for it:

| Row | FAIL when | WARN when |
|---|---|---|
| `service …`, `database`, `sign-in server`, … | a container is down, the app or sign-in is not answering | — |
| `last backup` | the newest archive in `backups/` is over 26 h old (or there is none, 26 h after install) | none yet on a new install |
| `off-site backup` | — | no `BACKUP_TARGET`, or the last nightly off-site copy failed |
| `disk space`, `disk space (docker)` | under 5 % free | under 15 % free |
| `mail server`, `mail sync` (staff email on) | the mail server is down/unhealthy, an organisation's mail sync fails, or every mailbox fails to sync | some mailboxes have a sync error |
| `notifications` | 3 or more emails failed in 24 h and none were sent | any email failed in 24 h (people without an address are not counted) |
| `ops alerts` | — | `OPS_ALERT_EMAIL` empty (production), an address on this server's own domain, no `SMTP_HOST`, or the watch has not run for an hour |

The database rows read the app database read-only. Inside the container the gateway is
checked at its private address, so "reachability" there means "the gateway answers", not
"the internet can reach the server".

**Where alerts go, and how.** Straight to `SMTP_HOST:SMTP_PORT` with curl (port 465:
implicit TLS; `SMTP_STARTTLS=true`: STARTTLS required; `SMTP_USERNAME` set: login, with the
password in a private temporary file, never on a command line) — never through Workforce and
never through the server's own mail server. So:

- `OPS_ALERT_EMAIL` must be an address **not hosted on this server** (not the staff mail
  domain): the operator's own provider, a phone's email, a support mailbox elsewhere.
  Comma-separated, no spaces.
- `SMTP_HOST` must be an outside relay (not `mail`, the server's own mail server). Without
  `SMTP_HOST`, problems are only logged.
- `OPS_ALERT_FROM` sets the sender (a plain address); empty = `SMTP_FROM`.

Test appliance: `environments/test.env` sets `OPS_ALERT_EMAIL=ops-alerts@example.test`, which
mailpit catches (`http://127.0.0.1:8025` on the box).

**Change the address** from Setup → Server health, which sends a test alert (§6a). By hand:

```bash
./bin/healthwatch.sh --test      # sends a test alert now — check it arrives
./bin/healthwatch.sh --dry-run   # runs the checks, prints what it would send; sends and saves nothing
```

Run on the server, both hand themselves to the backup container, so they use the same network
and tools as the 15-minute schedule (`--here` runs on the host instead). Exit codes: 0 all
passing, 1 something failing, 2 configuration problem (e.g. `OPS_ALERT_EMAIL` empty for
`--test`), 3 the email could not be sent.

**Switching it on for an existing installation, by hand.** Setup → Server health is the first
choice. Without it: `update.sh` does not rewrite `.env` (only the installer does), so add the
setting by hand, then recreate the backup container so it runs the new schedule:

```bash
cd /opt/workforce-deploy
echo 'OPS_ALERT_EMAIL=you@your-own-provider.example' >> .env   # comma-separated, no spaces
# echo 'OPS_ALERT_FROM=alerts@your-domain.example' >> .env     # optional
docker compose up -d backup
./bin/healthwatch.sh --test
```

(The bundle must be at a version that has `bin/healthwatch.sh`; any `update.sh` run after that
recreates the backup container itself.) The watch reads `.env` at every run, so later changes
to `OPS_ALERT_EMAIL` need no restart. New installs take it from `environments/<env>.env`.

**What it cannot do.** A server that is off, or has lost its network, cannot send email about
it. That is what the outside uptime check (§7c) is for.

**What the app sees.** Each run also replaces `status/health.json` (temp file + rename), which is
what Setup → Server health and the server items in Setup status read:

```json
{
  "schema": 1,
  "checkedAt": "2026-11-02T10:15:03Z",
  "version": { "running": "0.2.98", "configured": "0.2.98" },
  "checks": [ { "status": "OK", "check": "database", "detail": "accepting connections" } ],
  "backup": { "lastAt": "2026-11-02T02:00:41Z", "sizeBytes": 73741824, "kept": 9,
              "offsite": { "configured": true, "kind": "S3", "lastCopy": "OK" } }
}
```

- **Masked.** The rows are doctor's, with these hidden wherever they appear: the relay's user name
  and password, the uptime ping URL, `BACKUP_TARGET` and its keys, the contents of the small files
  in `secrets/`, a URL's login, anything after `password=`, `token:` and the like, and long tokens.
  Email addresses keep their first letter and domain. If doctor stopped early, the file says so
  without its last words; the email and `logs/healthwatch.log` still have them. Emails to
  `OPS_ALERT_EMAIL` are not masked: they go to you, not to people using the app.
- **Permissions.** The folder is 0755 and the file 0644, set on every run whatever the umask,
  because the app runs as uid 999. A file it can't read shows as a problem on the page, never as
  a green one. The folder is mounted read-only into the `api` container only, as a folder because
  a mounted file would keep pointing at the old copy after a rename.
- **Failure.** A write that fails is logged (`status file NOT written`) and changes nothing else:
  the alert and the heartbeat have already gone by then. The page reports that the watch hasn't
  been heard from once the file is over an hour old, or that it hasn't reported at all.
- **Who sees it.** The registered manager, director and data administrator. Set
  `WORKFORCE_SERVER_HEALTH_VISIBLE=false` in `.env` and run `docker compose up -d api` to turn the
  page off and have Setup status say only what is configured. **The hosted platform sets it off**,
  because a tenant must not see server details.
- **The off-site result** comes from the newest run in `backups/cron.log`: the nightly one, or a backup
  or off-site test started from the app, which log there too. A copy made by running `./bin/backup.sh`
  by hand doesn't change it.

## 7c. Outside uptime check

Two free outside services cover "the whole server is gone". Both are accounts the operator
creates; both email the same outside address as §7b.

1. **Heartbeat (works for every server, including the tailnet-only test appliance).** The health
   watch pings a URL every 15 minutes; the outside service emails you when the pings stop —
   server off, out of disk, network down, or the watch itself broken.
   - Create a free account at [Healthchecks.io](https://healthchecks.io) (any service with
     "cron job" / "heartbeat" checks works), add a check with **period 15 minutes** and **grace
     15 minutes**, and set its email to your alert address.
   - Copy the check's **ping URL** into `OPS_HEARTBEAT_URL` (the installer asks for it after the
     alert address). It is sent to curl on stdin and never written to logs; treat it like a
     password, since anyone holding it can ping on your behalf.
   - Existing installation: `echo 'OPS_HEARTBEAT_URL=https://hc-ping.com/<your-uuid>' >> .env` —
     the next watch run pings it (no restart). `./bin/doctor.sh` shows "uptime check".
2. **Outside monitor of the public address (production only — the test appliance is not
   reachable from the internet).** A free monitor such as [UptimeRobot](https://uptimerobot.com)
   requests the site every 5 minutes from outside and emails you when it fails:
   - `https://<app host>/api/v1/build-meta` — the app is up (answers JSON with the version);
   - `https://<auth host>/-/health/live/` — sign-in is up.
   This also catches DNS, certificate and firewall problems the server can't see from inside.

## 8. Finished testing?

```bash
./bin/uninstall.sh     # stops everything, keeps a final backup, data kept unless you type DELETE-DATA
```
Then destroy the VPS at the provider. Total cost: pennies of hourly billing.

## Test appliance (Incus)

The TEST environment is the Incus **container** `workforce-test` in project
`appliance` on the devbox — the only supported test platform (the VPS has no
`/dev/kvm`: containers only, no Vagrant/libvirt VMs). Names live in
`environments/test.env` (`INCUS_*`, `TAILSCALE_HOSTNAME`, `GUEST_SSH_KEY`).

Day to day, from a clone of this repo on the devbox:

```bash
python3 bin/deploy_to_test.py --skip-to 5   # converge to test.env:APP_VERSION + verify
python3 bin/deploy_to_test.py --fresh       # restore snapshot 'clean', then converge
python3 bin/deploy_to_test.py --snapshot    # after a verified run: re-take 'clean'
```

Incus access: `incus-admin` membership or passwordless `sudo incus` (the
restricted `incus` group only sees its own per-user project). The deployer never
creates or destroys the container. Creating it is a one-time manual job,
recorded here as it was done on 2026-10-11:

1. A project with its own storage pool, profile (root disk + network) and a
   bridge on `10.230.4.0/24`; then
   `incus launch images:ubuntu/24.04 workforce-test --project appliance`
   with `security.nesting=true` (rootless Docker inside).
2. Host NAT for the bridge, persisted as `incus-nat.service` (MASQUERADE +
   FORWARD accepts — ufw's FORWARD drop otherwise blocks guest egress).
3. Guest DNS: `/etc/resolv.conf` with 1.1.1.1/8.8.8.8 (the systemd-resolved
   symlink removed).
4. `openssh-server` in the guest (bootstrap.py connects over SSH; the
   deployer authorises your key for root and pins the host key via `incus exec`).
5. `python3 bin/deploy_to_test.py` — Tailscale + DuckDNS, the interactive
   install, converge, verify — then `--snapshot` for the `clean` baseline.

## Cutting a production release

Production runs this repo at a release tag, never at `main`: `bin/deploy_to_prod.py` refuses
to start without `DEPLOY_REF` in `environments/prod.env`, installs with `bootstrap.py --ref`, and
on every update checks the box's bundle out at exactly that tag before `update.sh` runs.

1. Deploy the app version to the TEST appliance first and check it there (the test pin).
2. On a branch, set `APP_VERSION` (the app release) and `DEPLOY_REF` (the tag about to be
   made, `vMAJOR.MINOR.PATCH`) in `environments/prod.env`. Merge it once CI is green.
3. Tag that merge commit and push the tag: `git tag v1.0.0 && git push origin v1.0.0`.
4. `git checkout v1.0.0 && python3 bin/deploy_to_prod.py` — it checks the tag is on origin,
   asks you to type the version, then converges and verifies the live app.

Rolling back the apparatus is the same steps with the previous tag; rolling back the app data
is `restore.sh` on the box (see "Upgrading authentik" for the sign-in database).

## Upgrading authentik (the sign-in server)

authentik cannot skip versions or go back. `compose.yaml` pins the version to end on, and
`bin/upgrade-authentik.sh` walks every minor line in between, one healthy step at a time, after
taking a backup. `update.sh` runs it automatically when a new bundle pins a newer authentik.
To move the pin, append the new version to `LADDER` in that script.

If a step fails, fix the cause and re-run the script: it resumes from the version that is running.
To go back instead, read `authentik_version` from the `pre-authentik-upgrade` backup's `MANIFEST`,
then run `./bin/upgrade-authentik.sh --hold <that version>` and `./bin/restore.sh <that backup>`.
`restore.sh` refuses a sign-in database from a different authentik version.

## Restore drill (deployment-spec D-DEP9)

Prove a backup restores — on an operator machine with Incus, never on the
appliance. Copy an archive off the box (or from the off-site target), then:

    GHCR_TOKEN_FILE=~/.config/workforce-dev/ghcr-read.token \
      ./bin/restore-drill.sh backups/<archive>.tar.gz

It restores into a throw-away container with `bin/restore.sh --data-only`
and checks app DB, sign-in DB and evidence object counts; exit 0 = PASS.
Not yet scheduled — run it at least monthly (nightly once automated).

## Hardening notes (for production, not the test)

- ~~Rootless Docker~~ — **implemented**: the daemon runs as the `workforce_app_sa` user by default (no root-equivalent daemon). `--system-docker` reverts for hosts without userns.
- The installer creates a user-level deployment; nothing it installs runs as root
  (containers run as `app`/`authentik`/`postgres` users with read-only root filesystems)
- Off-site backups: provide an S3/rsync target at install time
- License enforcement arrives with deployment-spec backlog #5

## Off-site backup targets

`BACKUP_TARGET` in `.env` is `s3://bucket/path` or an rsync target (`user@host:path`). For S3, also put
`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and `AWS_DEFAULT_REGION` in `.env`. For rsync over SSH, put a private
key allowed on the target in `secrets/backup_ssh_key` (the nightly job runs in a container with no SSH agent); the
target's host key is remembered on first use. The target needs `rsync`. Restrict the key to writing, so that someone who
takes over this server can't read or delete your older backups: in the target account's `authorized_keys`, put
`command="/usr/bin/rrsync -wo /srv/backups",restrict ssh-ed25519 AAAA…` (`rrsync` also needs `python3`). Then
`BACKUP_TARGET=user@host:`; copies land in `/srv/backups/backups/`. Nothing prunes the target, so it keeps growing
until you remove old copies there. An rsync copy is not encrypted, so the target must be somewhere you'd trust with
staff and care records. After changing either, use **Test the off-site copy** on Setup → Server
health (or `./bin/backup.sh --offsite-only`), which sends the newest archive by the same code as the nightly run.
