# 🚀 RokctAI PlatformStack

**PlatformStack** is the authoritative infrastructure, orchestration, and containerization layer for the RokctAI ecosystem. It defines the "Golden State" of the Frappe-based multi-tenant environment and the specialized edge-intelligence spokes.

> [!CAUTION]
> **Proprietary & Protected Architecture**
> This repository is not a standalone product. Successful builds and deployments require access to private RokctAI Monorepo overrides, protected application blueprints, and authorized GitHub secrets. Unauthorized use will result in failure during the "Golden Build" orchestration phase.

---

## 🏛️ System Architecture

PlatformStack operates on a **Unified Hub & Spoke** model, designed for high-availability cloud operations and low-latency edge intelligence.

### 1. Control Hub (Orchestrator)
The central nervous system of the platform. Manages identity, global routing, SSL termination, and the lifecycle of all spokes.
- **Stack**: Nginx (Reverse Proxy), Exim4 + OpenDKIM (Production Mail), Frappe Bench, Redis Cluster.
- **Database**: PostgreSQL 16 with `pgvector`, `cube`, and `earthdistance`.
- **Target**: Cloud VPS / Dedicated Infrastructure.

### 2. Tenant Spokes (Cloud Business)
Isolated, high-performance Frappe instances managed by the Control Hub.
- **Memory Profile**: 2GB Optimized.
- **Capability**: Headless API, background workers, and persistent business logic.

### 3. IoT/Edge Spokes (Dual-Layer)
Specialized for hardware-integration and edge-computing (e.g., Drones, Sensors).
- **The Mission Brain (Frappe Spoke)**: The primary controller running the `brain` app. Acts as the Source of Truth for missions. (Python/Postgres).
- **The Reflexes (Edge Intelligence)**: Ultra-lean, Go-based service for high-speed sensor fusion, vision processing, and local AI inference (Go/PocketBase/Ollama).

---

## 🛠️ The Golden Build Engine

At the heart of PlatformStack is `build_ecosystem.sh` — a sophisticated build orchestrator that ensures every deployment is consistent, stabilized, and hardened.

- **Python 3.14+**: Universal environment management via `uv`.
- **Monorepo Overrides**: Seamlessly applies private blueprints and module overrides from the central monorepo.
- **ROK AI Tooling**: Deep integration of the `rok` CLI agent framework for autonomous orchestration.
- **Ecosystem Hacks**: Automated patching for PostgreSQL stability, API deprecations, and non-TTY CI environments.

---

## 📂 Repository Structure

```text
rokctPlatformStack/
├── platform/
│   ├── Dockerfile              # The multi-stage Golden Build
│   ├── postgres.Dockerfile     # Vector-optimized PostgreSQL
│   ├── docker-entrypoint.sh    # Intelligent volume seeding
│   ├── docker-compose.yml      # Control Hub stack
│   ├── docker-compose.tenant.yml
│   ├── docker-compose.iot.yml  # Official Drone Brain
│   └── scripts/
│       ├── build_ecosystem.sh  # Build Orchestrator
│       └── exim4_bootstrap.sh  # Production Mail Setup
└── version.json                # Platform versioning (v2.4.1)
```

---

## 🚀 Quick Deployment

### Cloud Control Hub
```bash
cd platform && docker compose up -d
```

### Drone Mission Brain (IoT)
```bash
cd platform && docker compose -f docker-compose.iot.yml up -d
```

### Edge Intelligence Reflexes (Go)
*Located in `Monorepo/IoT`*
```bash
cd ../Monorepo/IoT && docker compose up -d
```

---

## 🧪 CI/CD & Compliance

Our pipeline ensures absolute stability before any image is promoted:
1.  **Security Scan**: Dependency and secret auditing.
2.  **The Golden Build**: Workspace synthesis and `build_ecosystem.sh` verification.
3.  **Compliance Test**: Site health checks and app-installation validation.
4.  **Blue/Green Upgrade Test**: Verifies zero-downtime migration paths.
5.  **AI-Generated Releases**: Release notes and changelogs compiled by the ROK Brain.

---

## ⚖️ License & Copyright

(c) 2024-2026 Rokct Intelligence (pty) Ltd. All rights reserved.
**Confidential - Internal Use Only**
