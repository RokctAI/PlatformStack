# RokctAI PlatformStack

PlatformStack is the infrastructure and orchestration layer for the RokctAI platform — a Frappe-based, multi-tenant application platform. It defines how the platform is built, deployed, and operated. Current version: **2.4.1**.

---

## Architecture

PlatformStack uses a hub-and-spoke model. The **Control Hub** is the central orchestrator that manages SSL, routing, and the shared trial tenant pool. **Tenant Spokes** run isolated instances for each customer, and **IoT/Edge Spokes** are trimmed-down instances optimized for low-RAM devices such as drones and sensors.

```
┌──────────────────────────────────────────────┐
│             Control Hub                       │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐      │
│  │  Nginx  │  │  Exim4  │  │  Bench  │      │
│  └─────────┘  └─────────┘  └─────────┘      │
│       │              │              │         │
│  ┌────▼────┐  ┌─────▼─────┐ ┌─────▼─────┐   │
│  │  Redis  │  │PostgreSQL │ │  rpanel   │   │
│  └─────────┘  └───────────┘ └───────────┘   │
└──────────────────────────────────────────────┘
              │                    │
        ┌─────▼─────┐       ┌──────▼──────┐
        │Tenant Spoke│      │ IoT Edge    │
        │ (isolated) │      │ Spoke       │
        └────────────┘      └─────────────┘
```

All services run as Docker containers with persistent named volumes for databases, sites, logs, mail configuration, and nginx data.

---

## Components

### Control Hub

The master VPS deployment. Manages SSL termination, reverse proxy routing, outgoing mail, cron jobs, and the shared trial tenant pool.

- **Services:** Nginx, Exim4, OpenDKIM, Frappe Bench, PostgreSQL, Redis
- **Ports:** 80 (HTTP), 443 (HTTPS), 8000 (API)
- **Image:** `ghcr.io/rokctai/monorepo/rpanel-control`
- **Apps:** `rpanel`, `control`, `paas`, `rcore`, `brain`

### Tenant Spoke

An isolated spoke used by the Control Hub to spin up individual tenant instances. Headless — serves only the API via Gunicorn plus workers and scheduler.

- **Memory limit:** 2 GB
- **Image:** `ghcr.io/rokctai/monorepo/rpanel-tenant`
- **Apps:** `rcore`, `brain`

### IoT/Edge Spoke

A minimal spoke optimized for low-RAM edge devices. No web overhead, workers and scheduler only.

- **Memory limit:** 1 GB
- **Image:** `ghcr.io/rokctai/monorepo/rpanel-iot`
- **Apps:** none of `erpnext`, `payments`, `paas`, or `rok`

### Database

PostgreSQL 16 with the `pgvector`, `cube`, and `earthdistance` extensions pre-installed and auto-enabled on every new database.

- **Image:** `ghcr.io/rokctai/monorepo/rpanel-db`

---

## Repository Structure

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

PlatformStack includes a full VPS installer for bare-metal or fresh VPS provisioning. It handles OS detection, system package installation, database setup, mail configuration, and the Frappe bench — all in one script.

```bash
# Full VPS install
DEPLOY_MODE=fresh DB_TYPE=postgres ./install.sh

# Bench-only (no system deps)
DEPLOY_MODE=bench ./install.sh
```

The installer handles: OS detection (Debian/Ubuntu), Redis, PostgreSQL 16 (+pgvector), MariaDB (optional), Exim4, OpenDKIM, Nginx, wkhtmltopdf, Node.js 22, Python 3.14 via `uv`, swap setup on low-RAM systems, database hardening, automatic security updates, `frappe-bench` initialization, rpanel app fetch+install, and Let's Encrypt SSL.

---

## Docker Images

| Image | Purpose |
|---|---|
| `rpanel-control` | Control Hub with Nginx + Exim + Bench |
| `rpanel-tenant` | Headless tenant API spoke |
| `rpanel-iot` | Minimal IoT/edge spoke |
| `rpanel-db` | PostgreSQL 16 + pgvector |

---

## CI Pipeline

On every push to `main` or `develop`, the pipeline runs through these stages:

### 1. Change Detection

Compares the current commit against the base. If only whitespace changed, the rest of the pipeline is skipped and a `trivial` label is applied to the PR.

### 2. PR Resurrection

If a PR has new commits pushed after becoming stale, it is automatically re-opened so review work is not lost.

### 3. Security

Dependency and secret scanning. A failure here blocks lint and CI.

### 4. Lint

Code quality checks. On `main` and `develop`, auto-fix mode is enabled — violations are corrected and committed back automatically. On other branches, lint failures block the pipeline.

### 5. CI / Build

A project-agnostic job. It discovers the app by inspecting `pyproject.toml` or `setup.py`, syncs workspace code into the bench at `apps/<detected-name>/`, appends the app name to `apps.txt`, creates a test site, runs `migrate`, `install-app`, and then `run-tests --app <name>`. It boots a database service and three Redis instances first so the test site has everything it needs. In bootstrap mode, `install.sh` is downloaded and run to build the entire bench workspace from scratch before syncing code on top.

### 6. Upgrade Test

Validates a live Blue/Green upgrade path after a successful release. Deploys the previous stable version, waits for site health, triggers a self-upgrade, confirms the upgraded app boots cleanly, then provisions a real tenant through the Control Hub to verify the spoke-spawning pipeline end-to-end.

### 7. Release

Handles versioning, tagging, changelog generation, and artefact packaging. Two strategies:

- **Immediate** — the default. Every qualifying commit on `main` produces a stable release.
- **Weekly** — pushes to `main` produce a release candidate (`-rc` suffix). A scheduled run promotes accumulated RCs to stable via a version-bump PR.

### Release features

- LTS branch and tag creation on major version bumps
- One-time RC release cleanup after promotion
- AI-generated changelogs — tries Brain API first, falls back to Groq Llama 3.3 70B, then plain git log
- Delta ZIP generation against the previous stable release
- Contributor extraction with `Co-authored-by` trailers from PR metadata

---

## Golden Build

The `build_ecosystem.sh` script is the authoritative build orchestrator. It bootstraps Python 3.14, starts Redis, waits for PostgreSQL, initialises the bench, fetches and patches apps, applies monorepo overrides and blueprints, installs the `rok` tooling, runs post-fetch ecosystem hacks, migrates the site, installs stack dependencies, bakes platform assets, generates a golden DB seed, and runs a strict compliance verification. The Docker multi-stage build bakes a pre-initialised site into the image and seeds it to the named volume on first boot.

---

## Mail

The Exim4 bootstrap script configures a production-ready mail stack on the Control Hub: SMTP on ports 25 and 587, TLS via Let's Encrypt, DKIM signing on all outbound mail, SMTP AUTH over TLS, and catch-all forwarding.

---

## Environment Variables

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
| `INSTALL_APPS` | — | Extra apps for new tenant sites |
| `GITHUB_TOKEN` | — | GitHub token for fetching private repos during build |

---

## Quick Start

```bash
# Control Hub
cd platform && docker compose up -d

# Tenant Spoke
cd platform && SITE_NAME=tenant1.example.com docker compose -f docker-compose.tenant.yml up -d

# IoT Spoke
cd platform && SITE_NAME=drone-local docker compose -f docker-compose.iot.yml up -d
```

---

## ROK AI Tooling

PlatformStack installs the `rok` CLI — the RokctAI agent framework. It is installed as an editable Python package inside the Frappe bench and used as the orchestration agent during builds and container sessions.

---

## Dependabot

Configured to open monthly pull requests for `pip` (Frappe/Python) and `npm` (Node.js) dependencies. PRs are created but never auto-merged.

---

## License

(c) 2024 Rokct Intelligence (pty) Ltd. All rights reserved.
