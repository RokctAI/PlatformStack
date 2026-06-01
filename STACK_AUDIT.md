# Stack Audit

This file is read and updated by an AI agent. Its job is to audit the RokctAI
production stack against the 13 layers defined below, identify gaps, and rewrite
the `## Current Coverage` and `## Gaps` sections with findings. The agent must
not modify any other section of this file.

---

## Bootstrap

### Detect environment

```bash
if [[ "$OS" == "Windows_NT" ]] || [[ "$(uname -s)" == *"MINGW"* ]] || [[ "$(uname -s)" == *"MSYS"* ]]; then
  ENVIRONMENT="windows"
else
  ENVIRONMENT="unix"
fi
```

### Unix — clone via token

Source the token from the env file. Never write it to any file or include it in
the audit output. Keep it in memory only for the clone step.

```bash
source .env/production.env

# Clone control (private)
git clone https://x-access-token:$GITHUB_TOKEN@github.com/RokctAI/control.git

# Clone PlatformStack to access .repo
git clone https://x-access-token:$GITHUB_TOKEN@github.com/RokctAI/PlatformStack.git
```

Read `.repo` from `./PlatformStack/.repo` to get the full repo list. Clone each
remaining repo using the same token pattern for any private ones.

### Windows — find repos locally

```powershell
$searchRoots = @("$env:USERPROFILE\Work", "$env:USERPROFILE\Projects", "C:\Work", "C:\Projects")
$repos = @{}
foreach ($root in $searchRoots) {
  if (Test-Path $root) {
    Get-ChildItem -Path $root -Recurse -Depth 2 -Filter ".git" -Force |
      ForEach-Object { $repos[$_.Directory.Name] = $_.Directory.FullName }
  }
}
```

Read `.repo` from the locally found PlatformStack directory to get the full list.

---

## How to Audit Each Repo

For every repo in `.repo`:
1. Confirm it is accessible.
2. Read `README.md`, `pyproject.toml`, `setup.py`, `requirements.txt`,
   top-level folder names, any `docker-compose*.yml`, and `Dockerfile` if present.
3. Do not deep-read every source file — top-level structure and README is enough.
4. Note the purpose and key features visible from those files.

---

## The 13 Layers

Evaluate every repo against each layer. Assign one status per layer:

- **COVERED** — explicit, functional implementation found and verifiable.
- **PARTIAL** — exists but incomplete (e.g. Redis present but no CDN; health checks but no alerting).
- **GAP** — no repo in the fleet addresses this layer at all.

Never assume coverage. If you cannot find evidence, mark PARTIAL or GAP.

| # | Layer | What counts as coverage |
|---|-------|------------------------|
| 1 | Frontend & foundations | Next.js web app, Flutter mobile apps, any client consuming Frappe headlessly |
| 2 | APIs & backend logic | Frappe whitelisted endpoints, REST API definitions, business logic DocTypes, shim layers |
| 3 | Database & storage | DB engine config, ORM DocType definitions, migrations, object storage integration |
| 4 | Auth, permissions & RLS | Frappe RBAC, role definitions, tenant isolation, 2FA, data masking, session management |
| 5 | Security | SSL/TLS automation, WAF, firewall rules, Fail2Ban, malware scanning, dep auditing in CI |
| 6 | Rate limiting | Nginx limit_req_zone, API throttling middleware, quota enforcement |
| 7 | Caching & CDN | Redis cache/queue config, CDN rules, edge caching, cache invalidation strategy |
| 8 | Load balancing & scaling | Nginx upstream config, gunicorn workers, multi-server management, auto-scaling |
| 9 | Cloud, compute & containers | Dockerfiles, docker-compose profiles, container orchestration, VPS provisioning |
| 10 | Hosting & deployment | install.sh, bench bootstrap, env config, site provisioning, plan-based deploy |
| 11 | CI/CD & version control | GitHub Actions workflows, build/test/release pipelines, branch strategy, version tagging |
| 12 | Error tracking & observability | Structured logging, error reporting, metrics, uptime monitoring, alerting |
| 13 | Availability & recovery | Backup schedules, cloud backup destinations, restore procedures, failover, DR runbook |

---

## Current Coverage

> Last audited: 2026-06-01

| # | Layer | Status | Covered by | Notes |
|---|-------|--------|------------|-------|
| 1 | Frontend & foundations | COVERED | RokctAI_frontend, paas_customer, paas_driver, paas_pos | Next.js frontend in `RokctAI_frontend`; Flutter mobile apps resolved dynamically via GitOps fallback and mapped to standalone repositories `paas_customer`, `paas_driver`, `paas_pos` in `.repo` |
| 2 | APIs & backend logic | COVERED | rcore, paas, rpanel, control | Orchestrator endpoints in [`control/api.py`](../control/control/api.py); AI & Strategic APIs in [`rcore/api/`](../rcore/rcore/api/); client billing/provisioning in [`paas/api/`](../paas/paas/api/); hosting APIs in [`rpanel/hosting/doctype/`](../rpanel/rpanel/hosting/doctype/) |
| 3 | Database & storage | COVERED | PlatformStack, rpanel | Vector-optimized DB setup in [`postgres.Dockerfile`](platform/postgres.Dockerfile); dual-stack PG/MariaDB orchestration in [`database_manager.py`](../rpanel/rpanel/hosting/database_manager.py) |
| 4 | Auth, permissions & RLS | COVERED | PlatformStack, rcore, rpanel | Transient HMAC boot validation in [`docker-entrypoint.sh`](platform/docker-entrypoint.sh); bootstrap secrets handshake in [`perform_bootstrap_secrets_handshake.py`](../rcore/rcore/api/plan_builder/perform_bootstrap_secrets_handshake.py); 2FA and security logs in [`security_manager.py`](../rpanel/rpanel/hosting/security_manager.py) |
| 5 | Security | COVERED | PlatformStack, shared-workflows, rpanel | SMTP DKIM/SPF TLS in [`exim4_bootstrap.sh`](platform/scripts/exim4_bootstrap.sh); universal dep scanning in [`universal-pipeline.yml`](../shared-workflows/.github/workflows/universal-pipeline.yml); WAF/Fail2Ban/ClamAV in [`security_manager.py`](../rpanel/rpanel/hosting/security_manager.py) and [`modsecurity_manager.py`](../rpanel/rpanel/hosting/modsecurity_manager.py) |
| 6 | Rate limiting | COVERED | rpanel | Global Nginx rate limiting defined in [nginx_manager.py:L219](../rpanel/rpanel/hosting/nginx_manager.py#L219) (`setup_rate_limiting`) defining general (10r/s, burst 20) & login (5r/m) zones, triggered by [install.py:L270](../rpanel/rpanel/install.py#L270) |
| 7 | Caching & CDN | PARTIAL | PlatformStack, rpanel | Redis cache + queue configured; Nginx site configs set expires headers for static asset caching; no external CDN / edge rules defined |
| 8 | Load balancing & scaling | COVERED | PlatformStack, rpanel | Production gunicorn configurations in [`build_ecosystem.sh`](platform/scripts/build_ecosystem.sh); resource-weighted load balancing algorithms in [`server_load_balancer.py`](../rpanel/rpanel/hosting/server_load_balancer.py) |
| 9 | Cloud, compute & containers | COVERED | PlatformStack, rpanel | Multi-stage Docker builds in [`Dockerfile`](platform/Dockerfile) & compose orchestration in [`docker-compose.yml`](platform/docker-compose.yml); SSH container bootstrapping in [`server_provisioner.py`](../rpanel/rpanel/hosting/server_provisioner.py) |
| 10 | Hosting & deployment | COVERED | PlatformStack, paas, rpanel | Bench synthesis and patching in [`build_ecosystem.sh`](platform/scripts/build_ecosystem.sh); plan-based provisioning in [`install.py`](../paas/paas/install.py); remote server setups in [`server_provisioner.py`](../rpanel/rpanel/hosting/server_provisioner.py) |
| 11 | CI/CD & version control | COVERED | shared-workflows | CI/CD pipelines in [`universal-pipeline.yml`](../shared-workflows/.github/workflows/universal-pipeline.yml) and upgrade testing in [`universal-upgrade-test.yml`](../shared-workflows/.github/workflows/universal-upgrade-test.yml) |
| 12 | Error tracking & observability | COVERED | rpanel | Website metrics and uptime checking schedulers defined in [monitoring.py:L199](../rpanel/rpanel/hosting/monitoring.py#L199) (`collect_resource_metrics`) and [monitoring.py:L234](../rpanel/rpanel/hosting/monitoring.py#L234) (`check_uptime`) |
| 13 | Availability & recovery | COVERED | rpanel | Secure backup encryption in [`backup_encryption.py`](../rpanel/rpanel/hosting/backup_encryption.py) and cloud sync integrations configured in [`tasks.py`](../rpanel/rpanel/hosting/tasks.py) |

---

## Gaps

> Last audited: 2026-06-01



### PARTIAL — Layer 7: Caching & CDN

Redis is configured for cache and queues. Cloudflare is referenced for DNS in
PlatformStack but no CDN page rules, cache-control headers, or edge caching
configuration is defined in any repo.

**Recommended fix:** Add Cloudflare page rules or cache config to
`RokctAI_frontend` for static assets. Enable Cloudflare proxy on the API
subdomain with cache bypass rules for `/api/`.

---


## Agent Instructions

1. Bootstrap environment (Unix: clone via token / Windows: find locally).
2. Read `.repo` from PlatformStack — use it as the authoritative repo list.
3. For each repo, read README + top-level structure only.
4. Score each of the 13 layers (COVERED / PARTIAL / GAP).
5. Rewrite `## Current Coverage` and `## Gaps` sections with findings.
6. Add audit timestamp to both sections.
7. Do not modify any other section of this file.
8. Do not write the GITHUB_TOKEN anywhere in this file or any output.
9. Commit this file with message: `audit: stack coverage update [YYYY-MM-DD]`
