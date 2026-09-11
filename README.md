# Care Angels Workforce Platform — Training Matrix (Phase 1)

Secure, multi-tenant workforce training-matrix platform for supported-living and social-care
operators. Built by AI agents with minimal manual intervention; human review reserved for auth,
tenancy, and backup/restore before production.

## Stack

| Area | Choice |
|------|--------|
| Backend | Java 25, Spring Boot 4.1 (MVC), Spring Security OIDC |
| DB access | jOOQ (generated) + Flyway migrations |
| Database | PostgreSQL |
| Auth | authentik (standalone IdP), OIDC Authorization Code + PKCE |
| Jobs | db-scheduler (PostgreSQL-backed) |
| Reports | Apache POI (XLSX/CSV), Gotenberg (PDF) |
| Evidence | MinIO (S3-compatible) + ClamAV |
| Frontend | React + TypeScript + Vite, TanStack Table/Virtual |
| Deploy | Self-contained Docker Compose suite |

## Quick start (any OS)

```bash
git clone https://github.com/marlon-thomas/workforce-deploy.git
cd workforce-deploy
python3 scripts/setup.py --all      # OS-agnostic toolchain (winget/brew/apt/dnf)
cd environments && vagrant up       # Ubuntu 24.04 test appliance (any host OS)
cd ../bin
python3 bootstrap.py --vagrant --env test
# → installer prompts → doctor 18/18 → https://localhost:8443
```

The suite runs identically on Linux, Windows, and macOS development machines.
See **docs/architecture/first-deployment-runbook.md** for the production (VPS)
deployment runbook.

## Day-2 commands

| Command | Purpose |
|---|---|
| `./bin/doctor.sh` | 18-point health check — paste to support when something looks wrong |
| `./bin/update.sh <version>` | backup-first upgrade with automatic rollback |
| `./bin/backup.sh` | manual backup (nightly cron already runs) |
| `./bin/restore.sh <archive>` | restore a backup (verified into a scratch DB first) |
| `./bin/reset-admin.sh` | administrator password reset (support-verified phrase) |
| `./bin/uninstall.sh` | stop everything; data kept unless DELETE-DATA |

See RUNBOOK.md for the full step-by-step guide.
