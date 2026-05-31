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

> Last audited: _(agent fills this in)_

| # | Layer | Status | Covered by | Notes |
|---|-------|--------|------------|-------|
| 1 | Frontend & foundations | PARTIAL | RokctAI_frontend | Next.js present; Flutter source lives inside paas builder, not a standalone repo in .repo |
| 2 | APIs & backend logic | COVERED | rcore, paas, rpanel, control | Frappe headless REST; rCore tenant logic; rPaaS shim/provisioning; rPanel hosting API; control orchestration |
| 3 | Database & storage | COVERED | PlatformStack, rpanel | PostgreSQL 16 + pgvector; rPanel adds MariaDB management for hosted sites |
| 4 | Auth, permissions & RLS | COVERED | PlatformStack, rcore, rpanel | Frappe RBAC + token auth; rCore tenant isolation; rPanel 2FA + audit logs |
| 5 | Security | COVERED | PlatformStack, shared-workflows, rpanel | Nginx SSL, DKIM/SPF; dep scanning in CI; WAF (ModSecurity+OWASP CRS), Fail2Ban, ClamAV, GPG-encrypted backups |
| 6 | Rate limiting | GAP | — | Nginx present but no limit_req_zone or throttling rules found in any repo |
| 7 | Caching & CDN | PARTIAL | PlatformStack | Redis cache + queue configured; no CDN layer or edge caching rules defined |
| 8 | Load balancing & scaling | COVERED | PlatformStack, rpanel | Nginx + gunicorn workers; Hub & Spoke topology; rPanel Cluster Mode |
| 9 | Cloud, compute & containers | COVERED | PlatformStack, rpanel | Multi-stage Dockerfiles; docker-compose per profile (hub, tenant, IoT); SSH provisioning |
| 10 | Hosting & deployment | COVERED | PlatformStack, paas, rpanel | VPS bootstrap + bench CLI; rPaaS plan-based provisioning; rPanel site/server management |
| 11 | CI/CD & version control | COVERED | shared-workflows | universal-pipeline (Security→Lint→CI→Release); Frappe-aware CI; AI release notes; blue/green upgrade test |
| 12 | Error tracking & observability | PARTIAL | rpanel | rPanel health monitoring + SSL/site status reports; no Sentry, structured logging, metrics, or alerting |
| 13 | Availability & recovery | COVERED | rpanel | Automated backups (full/DB/files); S3/GDrive/Dropbox; one-click restore; backup scheduling |

---

## Gaps

> Last audited: _(agent fills this in)_

### GAP — Layer 6: Rate limiting

No implementation found across any repo. Nginx is present in PlatformStack but
no `limit_req_zone`, `limit_req`, or equivalent throttling directives were found.
No middleware-level rate limiting exists in rCore, rPaaS, or rPanel.

**Risk:** API endpoints and Frappe REST routes are unthrottled. A malicious client
or misconfigured integration could exhaust gunicorn workers or flood the database.

**Recommended fix — add to PlatformStack Nginx config:**
```nginx
limit_req_zone $binary_remote_addr zone=api:10m rate=30r/m;
limit_req_zone $binary_remote_addr zone=auth:10m rate=5r/m;

location /api/ {
    limit_req zone=api burst=10 nodelay;
}
location /api/method/login {
    limit_req zone=auth burst=3 nodelay;
}
```

---

### PARTIAL — Layer 1: Frontend & foundations

Next.js web frontend exists (`RokctAI_frontend`). Flutter source lives inside
`paas/paas/builder/source_code/` but is not a standalone repo in `.repo`.

**Recommended fix:** If Flutter apps are actively maintained, add their repos
to `.repo` so future audits can verify they are consuming the Frappe API correctly
and are covered by shared-workflows CI.

---

### PARTIAL — Layer 7: Caching & CDN

Redis is configured for cache and queues. Cloudflare is referenced for DNS in
PlatformStack but no CDN page rules, cache-control headers, or edge caching
configuration is defined in any repo.

**Recommended fix:** Add Cloudflare page rules or cache config to
`RokctAI_frontend` for static assets. Enable Cloudflare proxy on the API
subdomain with cache bypass rules for `/api/`.

---

### PARTIAL — Layer 12: Error tracking & observability

rPanel provides basic health monitoring and SSL/website status reports. No
structured logging pipeline, error aggregation (Sentry/Glitchtip), metrics
(Prometheus/Grafana), or alerting is present in any repo.

**Recommended fix:** Self-host Glitchtip on the Control Hub. Add `SENTRY_DSN`
to `.env/production.env` and instrument rCore and rPaaS with `sentry-sdk`.
Add Uptime Kuma on the Hub for endpoint monitoring with Telegram/email alerts.

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
