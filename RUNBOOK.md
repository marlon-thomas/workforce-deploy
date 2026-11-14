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
./bin/install.sh --env prod
```

(The deployment bundle is a small **public** repository — no GitHub account needed to
clone it. Only the container-image pull later requires the token.)

The installer has to know which release to install, and it stops before changing anything
when nothing names one:

| Installing | Run |
|---|---|
| An organisation's own server | `./bin/install.sh --env prod` (the release `environments/prod.env` names in `APP_VERSION`) |
| The hosted platform | `./bin/install.sh --env prod --hosted` (prod.env, with `environments/hosted.env`'s few differences on top) |
| A particular release | add `--version <release>`, e.g. `--version 0.2.130`; the release notes name the latest |
| The TEST appliance | nothing by hand: `python3 bin/deploy_to_test.py` runs `./bin/install.sh --env test` |

On a server already installed, the installer keeps the version in `.env` and refuses another one:
change versions with `./bin/update.sh <release>`.

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

### The six questions

You need no separate `docker login`: the installer asks for the token itself (item 3 above) and
logs the service user in. The questions:

1. Your organisation's **domain** → `your-domain.co.uk` — the installer derives
   `workforce.<domain>` (staff) and `auth.<domain>` (sign-in), shows both, and
   verifies both point at this machine (waiting if not)
2. Email for certificate notices
3. Administrator password (Enter = generate one and show it once; one you type needs at least 16
   characters, see "Wrong tries and the lock"), then the emergency
   administrator's **recovery email**: an address you control that is not hosted on this server
4. Off-site backup target (Enter = local only — fine for the test). With a target, it then asks for
   the public key off-site copies are encrypted to, or generates a key pair and shows the private key
   once: store it off the server before typing `SAVED`. See "Off-site backup targets".
5. **Outgoing email**: the relay that delivers Workforce's email (reminders, invitations,
   password resets, server alerts). Pick Microsoft 365, Google Workspace, Brevo, SMTP2GO,
   Amazon SES (London), Mailgun (EU) or another provider's host and port (STARTTLS, usually 587;
   465 doesn't work), then the user name, password or SMTP key, and the From address. Enter =
   none for now (emails are only logged). Ask the provider for the sender domain's SPF and DKIM
   records, or the email lands in spam. Skipped when the environment file sets `SMTP_HOST`.
6. **Server alerts**: an address *not* hosted on this server for health alerts (§7b), and
   optionally an outside uptime check's ping URL (§7c). When both a relay and an alert address
   are set, the installer sends a test alert at the end.

Then it opens the firewall, generates all secrets, checks that the release is signed with the
Workforce release key and pulls the application image by that signed digest (see "Release
signatures" below; the token from item 3 authorises the pull), starts the stack, connects the
sign-in server, and finishes with a green/red health table.

### Release signatures

A registry tag can be moved by anyone who can push to the package, so the installer and
`./bin/update.sh` never trust one. For the version asked for they resolve the tag to a digest,
check with `cosign verify --key cosign.pub --insecure-ignore-tlog=true` that the release key signed
exactly that digest, pull that digest, and check that the image says it is that version. `.env`
then names the digest (`APP_DIGEST`), and that is what runs. An image that doesn't verify is
refused, and nothing is changed. `./bin/verify-image.sh <version>` makes the same check by hand.

- `cosign.pub`, at the top of this bundle, is the release key's public half: a committed copy of
  the one in the Workforce source repository, carried here by a reviewed change. It is never
  downloaded while installing or updating. **Until the release key exists there is no
  `cosign.pub`, and every Workforce image is refused** ("No release key yet").
- cosign runs from its official image, pinned by digest (`bin/lib/signatures.sh`); nothing is
  installed on the server. It talks to the image registry only: no transparency log or other
  public service.
- The DNS-01 gateway (`TLS_MODE=dns01`), which Workforce builds, runs by the digest pinned in
  `bin/lib/common.sh` (`GATEWAY_DNS01_IMAGE`), never by its `latest` tag. `./bin/update.sh` moves
  `.env` to the bundle's pin.

**A server installed before releases were signed** (0.2.129 and earlier) runs its version by
its tag, and `./bin/doctor.sh` warns ("release signature"). That version was never signed, so
until the server moves to a signed release, everything that would use it again is refused:
re-running `./bin/install.sh`, `./bin/update.sh <running version>` (the usual way to re-apply a
setting changed in `.env`), and `./bin/recover.sh` onto another server. Update it first:

```bash
./bin/update.sh <first signed release>     # checks the signature, then runs that digest
```

From then on the same-version commands work again. Take a fresh backup after that update: a
backup made on an unsigned version can't be recovered onto a new server, which would have to
install that same unsigned version.

## 6. First sign-in

- App: `https://workforce.<your-domain>` → the onboarding wizard runs
- Sign-in server: `https://auth.<your-domain>` (user `admin`, the password from question 3 above)
- `admin` is the **emergency administrator** (setup and recovery only — no staff record, no
  mailbox). Once the organisation exists, set up your own account in Setup → Administrator
  accounts and work from that. Give the emergency account a recovery email outside this server:
  `ADMIN_RECOVERY_EMAIL` in `.env`, then `./bin/update.sh <running version>` (README → "The
  emergency administrator and its recovery email"). On a server installed before releases
  were signed, update to a signed release first ("Release signatures" above).

### Wrong passwords: the pause and the throttle

Workforce issue 462 (ADR-0039, amendment of 14 November 2026). Nothing is ever locked for the whole account:

- **The pause.** Five wrong passwords for one name from one connection (the client's internet address; an IPv6
  address by its /64) within 15 minutes pause that name **on that connection** until 15 minutes after the fifth
  ("Too many wrong passwords for this name, from this connection…"). Requests during the pause are refused before
  the password is checked and aren't counted, so they can't stretch it. The same person can sign in at once from
  another connection (a phone's mobile data). Every account is treated alike, `admin` included, and a name nobody
  has gets exactly the same answers, so the page never tells anyone which names exist.
- **The throttle.** Ten wrong passwords from one connection within 15 minutes, whatever names were typed, hold that
  connection for 15 minutes for every name ("Too many wrong passwords from this connection…"); for IPv6 also thirty
  from one /48. A **workplace** (a connection, or a /48, where three or more staff typed the right password in the
  last 30 days) is never throttled, so nobody in the building can keep the office out; each person's own pause
  still applies there.
- **Codes** keep their own count: five wrong codes for an account within 15 minutes, then 15 minutes' wait from the
  fifth ("That code was wrong too many times…"). Only someone with the password reaches the code step.

**What lifts a pause:** time; a new password ("Forgot your password?" never skips the code); **Unlock sign-in** on
the person's record in Workforce (a registered manager or director; a data administrator if the organisation
switched it on), which lets them try again from every connection and changes nothing else; for `admin`,
`./bin/reset-admin.sh`, which sets a new password and lifts its pause the same way. Nothing lifts a throttle or the
codes' wait but time. Spread attempts (one connection trying five or more names in an hour, one account tried from
three or more connections in an hour or twenty times in a day) are recorded as alerts, never locks: Workforce shows
each organisation its own on Today, and `doctor.sh` counts them ("sign-in attacks").

Because nothing adds up guesses at `admin` from many addresses, its password is what stops them. The installer's
and `reset-admin.sh`'s are 24 random characters; one you type into the installer needs at least 16; one chosen later
("Forgot your password?", or Change password in Workforce's account menu) needs at least 16 that aren't easy to
guess. authentik's own change-password page refuses `admin`. **On a server installed or updated before this rule:**
if `admin`'s password is shorter than 16 characters, or easy to guess, change it now (Workforce's account menu, or
`./bin/reset-admin.sh`).

All of this needs the sign-in server to see each person's own address (§7a). Workforce's Setup says "not ready"
until the health check's "client addresses" row is OK.

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
gone whenever `WORKFORCE_SERVER_HEALTH_VISIBLE` is false, `WORKFORCE_HOSTED` is true, or the database holds
more than one organisation.

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

Wrong passwords pause one person on one **connection** (§6), and the audit and signature certificates record the
address, so the sign-in server must see each client's own address, and nothing a browser sends may choose it.

**How the address is decided.** The gateway alone decides it, once, and sends exactly that one address on to the
sign-in server, the application and webmail (`X-Forwarded-For` and `X-Real-IP`), removing every other header that
could name a client (`Forwarded`, `True-Client-IP`, `CF-Connecting-IP`, authentik's own `X-authentik-remote-ip`, …).
With nothing in front of the gateway the address is the connection's own, and forged headers are ignored. The
sign-in server takes `X-Forwarded-For` only from the stack's own private networks
(`AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS` in `compose.yaml`), which only the stack's own containers join.

**What keeps real addresses:**

- Rootless Docker with the `slirp4netns` port driver (the installer's default; how to switch an older server is
  below). The default `builtin` driver shows every client as the Docker gateway (`172.x.0.1`): not supported.
- System (rootful) Docker publishing with iptables. With the userland proxy and Compose networks without IPv6, every
  IPv6 client arrives as the bridge's IPv4 gateway: give the networks IPv6, or publish only on IPv4 (no AAAA record).
- The appliance controller (the same rules for its Docker).
- **Your own load balancer or reverse proxy** in front of the gateway: supported only when it sets
  `X-Forwarded-For` and is named in `GATEWAY_TRUSTED_PROXIES` in `.env` (its addresses or CIDRs, **separated by
  spaces, the whole value in single quotes**, e.g. `GATEWAY_TRUSTED_PROXIES='203.0.113.10/32 203.0.113.11/32'`:
  without the quotes the scripts can't read `.env`, and `update.sh`, `doctor.sh` and the backup refuse to run until
  it's fixed), then `./bin/update.sh <running version>`. Name **every** proxy or CDN in front, including all of a CDN's outgoing ranges. The gateway then reads
  `X-Forwarded-For` right to left and takes the first address that isn't one of them, so a forged left-hand entry
  can't choose it. `install.sh` and `update.sh` refuse a value that names everyone, loopback, link-local, the
  rootless network's `10.0.2.0/24` or one of this stack's Docker networks (IPv4 or IPv6). Before the first install
  those networks don't exist yet, so `install.sh` also refuses anything in Docker's default pools (`172.17.0.0/16`
  to `172.31.0.0/16`, `192.168.0.0/16`): name a proxy there after the first install, with `./bin/update.sh`.
- Not supported: a TCP pass-through that translates addresses, and the PROXY protocol (a later issue if needed).

**Your offices.** When most sign-ins come through one or two internet addresses, that looks exactly like a proxy
nobody named, so the check asks you to say which it is. If they are your offices' own connections, list them in
`CLIENT_ADDRESSES_CONFIRMED` in `.env`, separated by commas with no spaces, or the whole value in single quotes
(an IPv6 connection as the check names it, e.g. `2001:db8:1:2::/64`; a range such as `203.0.113.0/29` confirms
every address in it). It is read by the check only, never to let anyone in or to skip a limit. The TEST appliance
confirms its tailnet (`100.64.0.0/10`, `environments/test.env`), so testers signing in as several people from one
device don't turn the row red; on an existing TEST box, `./bin/update.sh` adds it.

**The check** (`./bin/doctor.sh`, row "client addresses"; Workforce's Setup shows it as "Sign-in limits see each
person's own connection", and only OK is ready):

- **The probe.** After every install and update (and daily under the controller; on the host `doctor.sh` runs it
  when its record is a day old), a request with forged headers goes to the sign-in server through the gateway, as an
  outside request does. It must come back with the probe's own address. Kept in `status/client-address.json`; older
  than 8 days counts as not checked.
- **Where sign-ins came from** in the last 7 days, as the sign-in server recorded them (addresses only, no names):
  - FAIL when any came from the server's own networks (the Docker networks, `10.0.2.0/24`, loopback) or from a
    proxy named in `GATEWAY_TRUSTED_PROXIES`;
  - with 3 or more people over 2 or more days, when one or two addresses carry 80% or more of them and aren't in
    `CLIENT_ADDRESSES_CONFIRMED`: WARN for one public address, FAIL otherwise (two, or a private one);
  - FAIL when more than half of the people signed in through something that forwards addresses (a CDN or proxy)
    which `GATEWAY_TRUSTED_PROXIES` doesn't name (the gateway marks such requests);
  - SKIP ("Not checked yet") until someone has signed in from outside: sign in to Workforce from your own computer,
    then look again.
- WARN, FAIL and SKIP are all "not ready" in Setup. The row names the address it saw and what to do.

Rootless Docker's default port driver shows every client as the Docker gateway (`172.x`). New installs use the
`slirp4netns` driver, which keeps the real address (it's a little slower, which doesn't matter here).
`./bin/doctor.sh` shows it as "port driver" (FAIL when the client-address check fails too). To change one, as root,
once (the stack restarts, about a minute of downtime):

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

**Under the appliance controller** (Workforce ADR-0032, issue 447) the watch is one of the
controller's jobs and holds no mail password: it leaves each email for the controller
(`alerts/request.json`), which sends it with the relay settings it holds, to `OPS_ALERT_EMAIL`
only — each one once, at most 4 an hour and 12 a day; one held back by those limits waits for
them — and says what became of it (`alerts-status/result.json`). Until the controller says it
sent an alert, the watch keeps it pending, and asks again if the controller gave up on it. The
helper's own notices (a changed alert address or relay, the test alert) still go straight to
the relay. The doctor's database queries run as `workforce_health`, a role with SELECT on only
the columns they read and nothing else, which the `health-db-init` and `ak-health-db-init`
one-shots make afresh at every start (password: `secrets/health_db_password`, generated by
install and update). Its sessions are read-only by default, but that is a setting it could
change, and the database trusts its own local socket: what holds it is that it has no other
privilege, and that the controller runs only fixed queries as it. The last backup and off-site rows come from
`backup-status/last.json`, which `backup.sh` writes there.

**What it watches** — every doctor row, including the ones that exist for it:

| Row | FAIL when | WARN when |
|---|---|---|
| `service …`, `database`, `sign-in server`, … | a container is down, the app or sign-in is not answering | — |
| `last backup` | the newest archive in `backups/` is over 26 h old (or there is none, 26 h after install) | none yet on a new install |
| `off-site backup` | a target with no usable `BACKUP_ENCRYPT_RECIPIENT`, so nothing is going off-site (at most WARN under `--gate`) | no `BACKUP_TARGET`, or the last off-site copy failed |
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

**Sign-in rows.** "client addresses" (§7a) is a FAIL that emails like any other (at most WARN during an install or
update, so neither is failed or rolled back by it); Workforce's Setup treats anything but OK there as "not ready".
"sign-in attacks" counts the sign-in server's alerts of the last day (connections trying many names, accounts tried
from many places, connections throttled): a WARN, never a lock; Workforce shows each organisation its own on Today.

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
              "offsite": { "configured": true, "kind": "S3", "encrypted": true, "lastCopy": "OK" } }
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
- **Who sees it.** The registered manager, director and data administrator, and only on a server an
  organisation runs for itself. **On the hosted platform `WORKFORCE_HOSTED=true` hides it** (set by
  `environments/hosted.env`; each organisation has its own database there, so the app can't tell), and
  **where one database holds more than one organisation the app hides it by itself** (Workforce issue
  341), because a tenant must not see server details. Set
  `WORKFORCE_SERVER_HEALTH_VISIBLE=false` in `.env` and run `docker compose up -d api` to turn the
  page off on a one-organisation server too and have Setup status say only what is configured.
- **The off-site result** comes from the newest run in `backups/cron.log`: the nightly one, or a backup
  or off-site test started from the app, which log there too. A copy made by running `./bin/backup.sh`
  by hand doesn't change it. `encrypted` is true when there's a target and a usable recipient. A target
  without one sends nothing, so `lastCopy` is then `FAILED` whatever an older run logged, and the
  `off-site backup` row says why.

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
To move the pin, append the new version to `LADDER` in that script, then run
`./bin/tests/authentik-policies-e2e.sh` (the sign-in policies that use authentik's own code, and
`reset-admin.sh`, on the new image) and set its `VERIFIED_AUTHENTIK` to the new version once it passes:
`bin/tests/blueprint-test.sh` fails until you do. An error in the wrong-tries lock would refuse every sign-in.

If a step fails, fix the cause and re-run the script: it resumes from the version that is running.
To go back instead, read `authentik_version` from the `pre-authentik-upgrade` backup's `MANIFEST`,
then run `./bin/upgrade-authentik.sh --hold <that version>` and `./bin/restore.sh <that backup>`.
`restore.sh` refuses a sign-in database from a different authentik version.

## Restore drill (deployment-spec D-DEP9)

Prove a backup restores — on an operator machine with Incus, never on the
appliance. Copy an archive off the box (or from the off-site target), then:

    GHCR_TOKEN_FILE=~/.config/workforce-dev/ghcr-read.token \
      ./bin/restore-drill.sh backups/<archive>.tar.gz

An encrypted off-site copy also needs its private key, in a file on the machine running the drill.
It reaches the drill container through stdin only; delete that file afterwards:

    GHCR_TOKEN_FILE=~/.config/workforce-dev/ghcr-read.token BACKUP_IDENTITY_FILE=<key file> \
      ./bin/restore-drill.sh <archive>.tar.gz.age

On the devbox, the drill needs an Incus project that allows nesting and a fixed address, because the
bridges there don't hand out DHCP addresses:

```bash
DRILL_INCUS="sudo -n incus --project appliance" DRILL_ADDRESS=10.230.4.57/24 DRILL_GATEWAY=10.230.4.1 \
  GHCR_TOKEN_FILE=~/.config/workforce-dev/ghcr-read.token BACKUP_IDENTITY_FILE=<private key file> \
  ./bin/restore-drill.sh <archive>.tar.gz.age
```

An evidence count of 0 passes only because there was nothing to restore: if the server holds no evidence
files, that part of the restore hasn't been tested. The drill doesn't check what landed in the mail
database, or start the app on the restored data.

It restores into a throw-away container with `bin/restore.sh --data-only`
and checks app DB, sign-in DB and evidence object counts; exit 0 = PASS. It proves the data, not
the settings and secrets a copy also holds: `./bin/recover.sh --check` looks at those, and
"Recovering onto a new server" is the whole thing.
Not yet scheduled — run it at least monthly (nightly once automated).

## Hardening notes (for production, not the test)

- ~~Rootless Docker~~ — **implemented**: the daemon runs as the `workforce_app_sa` user by default (no root-equivalent daemon). `--system-docker` reverts for hosts without userns.
- The installer creates a user-level deployment; nothing it installs runs as root
- Least privilege per service (Workforce issue 53; `compose.yaml` says why beside each): every service has its own
  unprivileged user, a read-only root file system with sized tmpfs folders, every capability dropped and only the
  ones it can't start without added back, `no-new-privileges`, only the networks it talks on (Gotenberg on an
  internal network, ClamAV on its own), and memory and process limits. Started as root: the api, worker and migrate
  (their entrypoint becomes the app user before java starts), backup (it holds the docker socket) and the
  `volume-owners` one-shot. Not read-only: init, backup and webmail. `bin/check-hardening.py` fails CI if any of
  this is lost, and on an image not pinned by digest; `bin/digest-check.py` checks every pin daily.
- Seccomp and AppArmor: the TEST appliance's rootless Docker (inside an unprivileged Incus container) applies
  neither, so a problem either would cause can't show there (Workforce issue 414).
- Off-site backups: provide an S3/rsync target at install time, and keep the private key off the server
- License enforcement arrives with deployment-spec backlog #5

## Off-site backup targets

`BACKUP_TARGET` in `.env` is `s3://bucket/path` or an rsync target (`user@host:path`). For S3, also put
`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and `AWS_DEFAULT_REGION` in `.env`. For rsync over SSH, put a private
key allowed on the target in `secrets/backup_ssh_key` (the nightly job runs in a container with no SSH agent); the
target's host key is remembered on first use. The target needs `rsync`. Restrict the key to writing, so that someone who
takes over this server can't read or delete your older backups: in the target account's `authorized_keys`, put
`command="/usr/bin/rrsync -wo /srv/backups",restrict ssh-ed25519 AAAA…` (`rrsync` also needs `python3`). Then
`BACKUP_TARGET=user@host:`; copies land in `/srv/backups/backups/`. Nothing prunes the target, so it keeps growing
until you remove old copies there. After changing either, use **Test the off-site copy** on Setup → Server
health (or `./bin/backup.sh --offsite-only`), which sends the newest archive by the same code as the nightly run.

### Encryption

Off-site copies hold database dumps, evidence files and mail, so staff and care records, and the server's `.env` and
`secrets/`, so that a copy is enough to rebuild the server (see "Recovering onto a new server"). They're encrypted with
[age](https://age-encryption.org) before they leave the server and arrive as `<name>.tar.gz.age`. This server holds only
the public key (the recipient), as `BACKUP_ENCRYPT_RECIPIENT=age1…` in `.env`. The private key that opens them is never
on it.

- **The private key opens every secret as well as the data.** Whoever has it and a copy has the database passwords, the
  sign-in server's secret, the mail and backup credentials, and all the staff and care records. Guard it accordingly.
- **Old copies hold the secrets of their day.** A password you've since changed, or a key you've since rotated, is still
  in every older copy. If a secret was exposed, change it, and remember those copies still hold the old one, which is one
  more reason to remove old copies from the target. Recovering from an old copy also brings back its old secrets, so
  anything changed since at the far end (a relay password, S3 credentials) may need setting again.

- **What this protects against.** Anyone who gets at the target, or a stolen copy of it, or who takes over this server,
  can't read the off-site copies. Neither can this server. The copies in `backups/` here stay unencrypted, because they
  sit on the same disk as the live data they copy. They're protected by the server's own access, not by this, and they
  never hold `.env` or `secrets/`.
- **No recipient means no off-site copy.** With a target and no usable recipient, nothing leaves the server and nothing
  is ever sent as plaintext. `backups/cron.log` says why, the `off-site backup` row of `./bin/doctor.sh` FAILS, the health
  watch emails `OPS_ALERT_EMAIL`, and Setup → Server health shows it. Backups carry on here.
- **Losing the private key loses the off-site backups.** Nobody can recover it for you. Keep it in a password manager
  **and** a printed copy somewhere safe, both off this server.
- **Disk.** S3 copies are streamed. rsync can only send a file, so an rsync copy briefly needs free space the size of the
  archive, for an encrypted file in `backups/.offsite-send/` that goes as soon as the copy ends.

**On a new installation,** question 4 asks for it. Paste a public key you made yourself, or press Enter to generate a pair:
the private key is shown once, and only on the screen. Store it, then type `SAVED`.

**On an existing installation,** on a computer of your own with [age installed](https://age-encryption.org) (or, on the
server, `docker run --rm --log-driver none alpine:3.20 sh -c 'apk add -q age && age-keygen'`, which keeps nothing), make
a pair:

    age-keygen -o workforce-backup-key.txt     # prints "Public key: age1…"

Store that file off the server as above. Then, on the server:

    printf 'BACKUP_ENCRYPT_RECIPIENT=age1…\n' >> .env     # the public key, and nothing else from that file
    docker compose up -d backup                           # adds age to the backup container
    ./bin/backup.sh --verify-key -                         # paste the private key; proves it matches
    ./bin/backup.sh --offsite-only                         # sends the newest backup, encrypted

**Older copies on the target** that aren't encrypted stay readable by anyone who can reach them. Remove them yourself once
an encrypted copy is there (a name ending `.tar.gz` without `.age`); nothing here deletes them, and a write-only key
couldn't.

**Check the key once a year, without a restore:**

    ./bin/backup.sh --verify-key -                                  # paste it when asked; or give a file instead of -
    ./bin/backup.sh --verify-key - <a copy fetched from the target>  # and that this copy opens with it

The key is read from stdin or a file, never the command line, and never kept. It encrypts a test blob to the recipient and
opens it with the key, which proves the pair. It then decrypts the first bytes of a real copy, if there is one to reach: the
newest on an S3 target whose credentials can read it, or one you fetched and named. A write-only rsync key can't read
back, so fetch one with your own access to the target. Exit 0 = they match, 6 = they don't, 1 = it couldn't check. Off the
server, `age-keygen -y <key file>` prints the public key, to compare with `.env` by eye.

**Rotating the key** (it may have been exposed, or someone who knew it has left): make a new pair, store it, replace the
line in `.env`, run `./bin/backup.sh --verify-key -`, then `./bin/backup.sh --offsite-only`. No restart is needed, since `.env`
is read at every run. Copies already on the target stay encrypted to the older key, so keep that key for as long as you keep
those copies. If it was exposed, remove them from the target once new copies are there.

**Restoring from an off-site copy.** Fetch it from the target with your own access (a write-only key can't), then:

    ./bin/restore.sh --identity - <archive>.tar.gz.age       # paste the key when asked, or pipe it in
    ./bin/restore.sh --identity <key file> <archive>.tar.gz.age

Neither `--identity` nor anything else ever takes the key itself on the command line, and it isn't logged. On a server, prefer
`-`, so that the key never lands on its disk. No `age` needs installing: without it, a throw-away container decrypts, with
the key held in memory. It verifies the decrypted archive exactly as it does a plain one. The wrong key is refused before
anything changes, as is a damaged file. To prove a copy restores without touching a live system, see "Restore drill".

`restore.sh` only ever puts the data back: it reads no further than the data in a copy, and leaves this server's `.env` and
`secrets/` as they are. To put those back too, on a new server, see "Recovering onto a new server".

### By hand

A copy is two gzip parts: the data, then the settings and secrets. Plain tar stops at the end of the first. You should only
need this if `restore.sh` says a copy's data looks whole but what follows it is damaged, and there's no earlier copy. Decrypt
it into `secrets/`, the one closed folder, because the file holds every secret, and restore that:

    age -d -i <key file> -o secrets/unpacked.tar.gz <copy>.tar.gz.age
    ./bin/restore.sh secrets/unpacked.tar.gz
    rm secrets/unpacked.tar.gz

`age` may report an error at the end of a damaged copy, and the file still holds what came before it. `restore.sh` then checks
the data against its checksums, so bad data is still refused. This brings back the data only. The settings and secrets are
what's damaged, so treat it as "If the copy has no settings and secrets", under "Recovering onto a new server".

## Recovering onto a new server

For when the server is gone: a dead disk, a provider failure, a break-in. It takes a new server with nothing on it, and
puts back Workforce as it was when the copy was made. Anything entered after that copy is lost.

### What you must already have, kept somewhere other than the server

- **The private key** that opens the off-site copies (`AGE-SECRET-KEY-1…`). Without it the copies can't be opened by anyone.
- **Your own access to the off-site target**, to fetch a copy. The server's own key can only write there.
- **A GitHub token with `read:packages`**, to pull the images. A new one will do: Settings → Developer settings → Tokens (classic).
- **Control of your DNS**, to point the names at the new server.

Everything else, including the settings you gave the installer and every password, is inside the copy.

### The steps

1. **Start the clock**, and write down the time (see "How long it took", below).
2. **Create a new server** with Ubuntu 24.04, at least as big as the old one, as in steps 0 and 1 at the top of this
   runbook. Open 22, 80 and 443 in the provider's firewall, and 25 if staff email was on. Use a new server: this replaces
   the secrets, and it refuses to run on one that's already set up.
3. **If the old server could still be running, turn it off**, so that the two don't both send reminders and mail.
4. **Point DNS at the new server.** At your domain provider, change the A records for the app and sign-in names
   (`workforce.<your-domain>`, `auth.<your-domain>`) to the new address. If staff email was on, change the webmail and mail
   names too, and the rest under "If staff email was on" below. Security certificates can't be issued until these point
   at the new server, so the recovery waits up to 15 minutes for them, then stops and says so. Keeping those records' TTL
   low, say 5 minutes, makes this quicker on the day.
5. **Fetch the newest copy** with your own access to the target, then put it on the new server, for example
   `scp <name>.tar.gz.age root@<new address>:/root/`. **After a break-in, don't use the newest. Use one from before the
   break-in.** Anyone can encrypt a file to your public key, and the old server could write to the target, so someone who
   had that server could have left a copy of their own there, and it would open and restore like any other.
6. **Run the recovery** as root on the new server:

   ```bash
   git clone https://github.com/marlon-thomas/workforce-deploy.git /opt/workforce-deploy
   cd /opt/workforce-deploy
   ./bin/recover.sh --identity - /root/<name>.tar.gz.age
   ```

   Clone it to exactly that place: the recovery refuses to run from anywhere else, so that nothing lying beside a clone gets
   copied in. When asked, paste just the line starting `AGE-SECRET-KEY-1` from the key file, then the GitHub token, and leave it
   to run: it asks nothing else. Neither is shown. The
   key is never written down, and the token is kept in the service account's Docker login, as on any install. It installs Docker and every service using the secrets from the copy, then
   restores the data, and tells you how long that took. Expect a good half hour, more with a lot of evidence.

   - The token can come from a file: `--registry-token-file <file>`. Delete the file afterwards.
   - On a machine that can't run rootless Docker, add `--system-docker`, as for the installer.
   - **If it stops,** fix what it says and run the same command again, with the same copy. It carries on from where it got
     to, and refuses a different copy, because the secrets already in place only go with that copy's data. To use another,
     start again on a new, empty server.
   - **If it stops after saying the data is back,** the data won't be replaced again, even if you run this again, as people may
     be using it by now. Fix what the health check says. Running the same command again then only repeats the check, and
     finishes. The `recovery` row of `./bin/doctor.sh` is a reminder until you do.
   - **Backups wait for it.** Until the data is back the server holds an empty install, so backups stand down rather than send
     that off-site as your newest copy.
   - **If it says the backup's sign-in database is from another authentik version,** do what it says as `workforce_app_sa`:
     `./bin/upgrade-authentik.sh --hold <version>`. Run the recovery again as root, then `./bin/upgrade-authentik.sh`.
7. **Remove the copy** from `/root` when you've finished checking. It's encrypted, so this is only about disk space.

### What a person should then check

The machine's own checks can't tell you these. Go through them in a browser:

- **Sign in with your real account**, not `admin`. This is the check that matters most: a problem with sign-in can leave
  every health check green.
- **People** shows your staff.
- **The training matrix** shows what you expect.
- **Open an evidence file.**
- **Webmail**, if staff email was on: sign in and read a message.
- **Setup → Server health** is green, or says plainly what isn't. It can take 15 minutes to catch up.
- **A new backup reaches the off-site target.** As `workforce_app_sa`, in `/opt/workforce-deploy`, run
  `docker compose exec -T -w /opt/workforce-deploy backup ./bin/backup.sh`, then look for the new file on the target. Run it
  in the backup container, as the nightly job does: the host has no rsync, so a run there keeps the copy local. This is what puts you back to being protected. An rsync target's address will be
  trusted afresh on first use.

Then, as root, `passwd workforce_app_sa` if you want a password on the service account: the recovery doesn't set one.
If you're here because of a break-in, change the secrets too: they're the same ones the old server had. Make a new age key
pair ("Rotating the key"), and change the passwords you hold elsewhere (relay, S3, GitHub token).

### If staff email was on

As well as the names above, point the MX record's mail host at the new address, update the address in your SPF record if it
names the old one, and ask the provider to set reverse DNS on the new address. Mail arriving while the old server was
gone waits at the sender for a few days, then bounces.

### How long it took

Keep these from every recovery and every practice run, because they're what you'd tell your organisation to expect:

- **Time to recover**: from the time in step 1 until the checks above pass. `recover.sh` prints how long its last run took.
- **Data lost**: from the time the copy was made (it's in the file's name) until the server was lost. A nightly backup means up to a
  day.

Practise before you need it. A full practice needs the names in the copy to point at the practice server, so it means a
planned outage, or a test installation's own copy. In between, at least once a year, run "Restore drill" for the data, and
this for the rest. It proves a copy holds what a recovery needs, every file matching its checksum, without changing anything.
It reads the whole copy, writes none of it down, and works on any Linux computer with this repository, GNU tar, and either
`age` or Docker:

    ./bin/recover.sh --check --identity - <name>.tar.gz.age

Exit 0 = yes, 3 = it's an older copy with data only, 6 = the wrong key, 1 = it's damaged.

### If the copy has no settings and secrets

Copies made before this was added hold only the data, and `recover.sh` says so and stops. Backups from a server's own
`backups/` folder never hold them. Those can still be restored, with more work and more lost:

    ./bin/install.sh --env prod                       # answer the questions as for a new server, with the same names
    ./bin/restore.sh --identity - <name>.tar.gz.age   # or ./bin/restore.sh <name>.tar.gz, for a plain one

`restore.sh` makes signing in work again by itself: it takes the sign-in key from the restored database, and restarts the
application to trust it. If the health check's `sign-in key` row ever fails, `./bin/refresh-signing-key.sh` does the same.
What did not survive, and what to do:

- **Passwords.** Everyone signs in with the password they had at the time of the backup, including `admin`. The password the
  new install made up opens nothing, so `secrets/initial-admin-password` is removed. If nobody knows the `admin` password,
  use "Forgot your password?" on the sign-in page with the recovery address (`ADMIN_RECOVERY_EMAIL`), which emails a link
  if email is working and the address is outside the server. If that can't work, `./bin/reset-admin.sh`.
- **Organisations' own AI keys.** They were encrypted with the old `secrets/ai_credential_key`, so enter them again in Setup → AI assistant.
- **Phone and browser notifications.** Each device has to switch them on again, because the push keys are new.
- **Staff email.** Its settings were in the old `.env`: switch it on again in Setup → Email. Its database is restored only
  if the mail server is set up first, so if mail matters, do that before the restore.
- **Everything else in the old `.env`**: the relay, alerts, feedback. Set them again, from your own notes or the installer's questions.
- **The off-site target's key** (`secrets/backup_ssh_key`), for rsync: put one back and allow it on the target.
