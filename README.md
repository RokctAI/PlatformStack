# RokctAI PlatformStack

**Version:** 2.4.1

PlatformStack is the infrastructure and orchestration layer for the RokctAI platform — a Frappe-based, multi-tenant application platform. It defines how the platform is built, deployed, and operated across three distinct runtime modes: a **Control Hub**, **Tenant Spokes**, and **IoT/Edge Spokes**.

---

## Architecture

PlatformStack uses a hub-and-spoke model. The **Control Hub** is the central orchestrator that manages SSL, routing, and the shared trial tenant pool. **Tenant Spokes** run isolated instances for each customer, and **IoT/Edge Spokes** are trimmed-down instances optimized for low-RAM devices such as drones and sensors.

```
┌──────────────────────────────────────────────────┐
│              Control Hub (Master VPS)             │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐         │
│  │   Nginx │  │  Exim4  │  │  Bench  │         │
│  └─────────┘  └─────────┘  └─────────┘         │
│       │             │              │             │
│  ┌────▼────┐  ┌─────▼─────┐ ┌─────▼─────┐      │
│  │  Redis  │  │ PostgreSQL│ │  rpanel   │      │
│  └─────────┘  └───────────┘ └───────────┘      │
└──────────────────────────────────────────────────┘
           │                    │
     ┌─────▼─────┐      ┌──────▼──────┐
     │Tenant Spoke│     │ IoT Edge Spoke│
     │  (isolated)│     │  (minimal)   │
     └────────────┘      └─────────────┘
```

All services run as Docker containers with persistent named volumes for databases, sites, logs, mail configuration, and nginx data.

---

## Components

### Control Hub (`MODE=full`)

The master VPS deployment. Manages SSL termination (Let's Encrypt via Certbot), reverse proxy routing, outgoing mail, cron jobs, and the shared trial tenant pool.

**Services:** Nginx, Exim4, OpenDKIM, Frappe Bench, PostgreSQL, Redis

**Ports:** 80 (HTTP), 443 (HTTPS), 8000 (API)

**Image:** `ghcr.io/rokctai/monorepo/rpanel-control`

**Apps included:** `rpanel`, `control`, `paas`, `rcore`, `brain`

### Tenant Spoke (`MODE=api`)

An isolated spoke used by the Control Hub to spin up individual tenant instances. Headless — serves only the API via Gunicorn plus workers and scheduler.

**Memory limit:** 2 GB

**Image:** `ghcr.io/rokctai/monorepo/rpanel-tenant`

**Apps:** `rcore`, `brain` (erpnext and payments are stripped)

### IoT/Edge Spoke (`MODE=iot`)

A minimal spoke optimized for low-RAM edge devices such as drones and remote sensors. No web overhead, workers and scheduler only.

**Memory limit:** 1 GB

**Image:** `ghcr.io/rokctai/monorepo/rpanel-iot`

**Apps:** Strips `erpnext`, `payments`, `paas`, and `rok`

### Database (`rpanel-db`)

PostgreSQL 16 with the `pgvector`, `cube`, and `earthdistance` extensions pre-installed and auto-enabled on every new database.

**Image:** `ghcr.io/rokctai/monorepo/rpanel-db`

---

## Repository Structure

```
```
rokctPlatformStack/
├── version.json
├── platform/
│   ├── Dockerfile
│   ├── postgres.Dockerfile
│   ├── docker-entrypoint.sh
│   ├── docker-compose.yml
│   ├── docker-compose.tenant.yml
│   ├── docker-compose.iot.yml
│   └── scripts/
│       ├── build_ecosystem.sh
│       └── exim4_bootstrap.sh
```

---

## Fresh VPS Install

PlatformStack includes a full VPS installer (`install.sh`) for bare-metal or fresh VPS provisioning. It is versioned (`v8.9.3-STABLE`) and accepts a `DEPLOY_MODE` environment variable:

```bash
# Full VPS install (system packages, PostgreSQL/Exim4, Redis, Nginx, bench, rpanel)
DEPLOY_MODE=fresh DB_TYPE=postgres ./install.sh

# Bench-only mode (user + bench init, no system deps)
DEPLOY_MODE=bench ./install.sh
```

The installer handles:

- OS detection (Debian/Ubuntu) and package installation: Redis, PostgreSQL 16 (+pgvector), MariaDB (optional), Exim4, OpenDKIM, Nginx, wkhtmltopdf, Node.js 22
- Python 3.14 bootstrapping via `uv`
- Swap setup on low-RAM systems (≤4 GB)
- Database hardening (`pg_hba.conf` → md5 auth)
- Automatic security updates (`unattended-upgrades`), fail2ban
- `frappe-bench` initialization, rpanel app fetch+install, asset build
- Let's Encrypt SSL via Certbot/Nginx

Key environment variables for the installer:

| Variable | Default | Description |
|---|---|---|
| `DEPLOY_MODE` | `fresh` | `fresh` or `bench` |
| `DB_TYPE` | `postgres` | `postgres` or `mariadb` |
| `DB_HOST` | `localhost` | Database host (set to remote for external DB) |
| `DOMAIN_NAME` | `rpanel.local` | Site domain |
| `SKIP_ASSETS` | — | Set to skip esbuild during CI |
| `SKIP_SSL` | `true` in CI | Skip Certbot step |

---

## Docker Images

| Image | Target | Purpose |
|---|---|---|
| `rpanel-control` | `full` | Control Hub with Nginx + Exim + Bench |
| `rpanel-tenant` | `tenant` | Headless tenant API spoke |
| `rpanel-iot` | `iot` | Minimal IoT/edge spoke |
| `rpanel-db` | postgres.Dockerfile | PostgreSQL 16 + pgvector |

---

## CI Pipeline

The CI pipeline runs on every push to `main` or `develop`. It reuses a set of shared workflows from a central `RokctAI/shared-workflows` repository so all projects share the same quality gate, release logic, and upgrade testing.

### 1. Change Detection

Compares the current commit against the base. If only whitespace changed, the rest of the pipeline is skipped and a `trivial` label is applied to the PR. This avoids wasting compute on formatting-only pushes.

### 2. PR Resurrection

If a PR has new commits pushed to it after becoming stale, the PR resurrection step automatically re-opens closed or stale PRs so review work is not lost.

### 3. Security

Dependency and secret scanning runs before anything else. A failure here blocks lint and CI.

### 4. Lint

Code quality checks run across all supported languages. On `main` and `develop`, auto-fix mode is enabled — lint violations are corrected and committed back automatically. On other branches, lint failures block the pipeline.

### 5. CI / Build

What happens in this step depends on the project type:

**Frappe / Python:**

The CI job is designed to be project-agnostic — it does not hard-code an app name. Instead, it discovers the app by inspecting `pyproject.toml` or `setup.py`, syncs workspace code into the bench at `apps/<detected-name>/`, appends the app name to `apps.txt`, creates a test site, runs `migrate`, `install-app`, and then `run-tests --app <name>`. Before any of that, it boots a database service (PostgreSQL, or MariaDB) and three Redis instances on well-known ports, so the test site has everything it needs.

In **bootstrap mode** the list of apps is declared as an input and the job downloads and runs `install.sh` to build the entire bench workspace from scratch before syncing code on top of it.

### 6. Upgrade Test

After a successful release, a dedicated job validates a live Blue/Green upgrade path. It deploys the previous stable version, waits for site health, triggers a self-upgrade, then confirms the upgraded app boots cleanly. It also provisions a real tenant through the Control Hub to verify the spoke-spawning pipeline end-to-end.

### 7. Release

Handles versioning, tagging, changelog generation, and artefact packaging. The release strategy is configurable:

- **Immediate** — the default. Every qualifying commit on `main` produces a stable release.
- **Weekly** — pushes to `main` produce a release candidate (`-rc` suffix). A scheduled Friday run promotes the accumulated RCs to stable via a version-bump PR.

Release features include LTS branch and tag creation on major version bumps, one-time RC release cleanup after promotion, AI-generated changelogs with a three-tier fallback (Brain API → Groq Llama 3.3 70B → plain git log), delta ZIP generation against the previous stable release, and contributor extraction with `Co-authored-by` trailers pulled from PR metadata.

### Release Workflow

The quality gate and CI pipeline feed into the release workflow. On every qualifying commit the release job runs: it extracts the version, determines the release mode from the strategy and branch, tags the commit, generates a delta ZIP of changed files against the previous stable release, and writes AI-assisted release notes with generated contributor attributions.

---

## Golden Build

The `build_ecosystem.sh` script is the authoritative build orchestrator. It:

- Bootstraps Python 3.14 via `uv`
- Starts Redis instances and waits for external PostgreSQL to be ready
- Initialises or restores a `frappe-bench` workspace
- Fetches and patches apps: `control`, `rcore`, `brain`, `payments`, `erpnext`, `lending`, `rpanel`
- Applies monorepo overrides and blueprints (dynamic module / hook injection via `.rokct/app_blueprints.json`)
- Installs the `rok` AI tooling (`tools/rok`)
- Runs post-fetch ecosystem hacks: namespace aliasing, import guards, deprecation patches
- Migrates the site, installs stack dependencies (`install_stack.py`), bakes platform assets, and generates a golden DB seed
- Runs a strict compliance verification against all DocTypes, imports, and patch logs

The Docker multi-stage build bakes a pre-initialised site into the image and seeds it to the named volume on first boot.

---

## Mail (Exim4 + DKIM)

The Exim4 bootstrap script (`scripts/exim4_bootstrap.sh`) configures a production-ready mail stack on the Control Hub:

- SMTP on ports `25` and `587`
- TLS via Let's Encrypt certificates
- DKIM key generation (2048-bit RSA), DNS record printing, and signing of all outbound mail
- SMTP AUTH (PLAIN / LOGIN over TLS)
- Catch-all forwarding to a configurable address

Environment variables: `PRIMARY_HOSTNAME`, `MAIL_DOMAINS`, `FORWARD_TO`, `DKIM_SELECTOR`, `SMTP_AUTH_USER`, `SMTP_AUTH_PASS`

---

## Environment Variables

### Docker Compose

| Variable | Default | Description |
|---|---|---|
| `MODE` | — | `full` / `api` / `iot` — runtime mode |
| `SITE_NAME` | `platform.rokct.ai` / `rpanel.local` | Frappe site name |
| `DB_HOST` | `db` | PostgreSQL host |
| `DB_PASSWORD` | `admin` | Database password |
| `ADMIN_PASSWORD` | `admin` | Frappe admin password |
| `DB_ROOT_PASSWORD` | `admin` | PostgreSQL root password |
| `REDIS_CACHE` | `redis://redis:6379/0` | Redis cache URL |
| `REDIS_QUEUE` | `redis://redis:6379/1` | Redis queue URL |
| `REDIS_SOCKETIO` | `redis://redis:6379/2` | Redis Socket.IO URL |
| `INSTALL_APPS` | — | Space-separated extra apps for new tenant sites |
| `PRIMARY_HOSTNAME` | `mail.juvo.app` | Primary mail hostname (Control Hub) |
| `MAIL_DOMAINS` | `juvo.app rokct.ai` | Domains for mail / DKIM |
| `FORWARD_TO` | `sinyage@gmail.com` | Catch-all mail forwarding address |
| `GITHUB_TOKEN` | — | GitHub token for fetching private repos during build |

---

## Quick Start

### Control Hub

```bash
cd platform
docker compose up -d
```

The Control Hub will automatically initialise the default site on first boot, including seeding from the golden build if available.

### Tenant Spoke

```bash
cd platform
SITE_NAME=tenant1.example.com docker compose -f docker-compose.tenant.yml up -d
```

### IoT Spoke

```bash
cd platform
SITE_NAME=drone-local docker compose -f docker-compose.iot.yml up -d
```

---

## ROK AI Tooling

PlatformStack installs and runs **ROK** (`tools/rok`), the RokctAI agent framework, inside the Frappe bench environment. It is installed as an editable Python package and is available as the `rok` CLI during builds and in container sessions. The `build_ecosystem.sh` script applies a patch to the ROK `pyproject.toml` to resolve a duplicate `rok` key conflict under `[project.scripts]` for Python 3.14 compatibility.

---

## Monorepo Integration

PlatformStack is designed to be built from within the **RokctAI Monorepo**. During CI, the Monorepo's `monorepo_overrides` directory is mounted into the Docker build context and into the Frappe CI job so that per-app overrides, private modules (`modules.txt`, `hooks.py`), and platform assets (via `.rokct/app_blueprints.json`) are applied at build time before the golden seed is created. Baked platform assets from `rcore` are committed back to the Monorepo automatically at the end of each build.

---

## Dependabot

Configured in `.github/dependabot` to open monthly pull requests for both `pip` (Frappe/Python) and `npm` (Node.js) dependencies. PRs are created but never auto-merged.

---

## License

(c) 2024 Rokct Intelligence (pty) Ltd. All rights reserved.
