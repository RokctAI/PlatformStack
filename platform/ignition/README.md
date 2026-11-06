# Ignition + Frappe v16 + composed rokctapp image

`platform/ignition.Dockerfile`, target `ignition_rokctapp`, builds one image
that runs a composed product app on Ignition (`python -m pulsar.ignition`)
instead of bench. The default product is `rokctapp`: one Frappe app, `rcore`,
composed from The-Rokct-Protocol template
`core/utils/frappe/composer/rokctapp.json`.

What is inside:

| Path | What |
|---|---|
| `/opt/ignition/apps/frappe` | Frappe at `FRAPPE_REF` (default `version-16-hotfix`) |
| `/opt/ignition/apps/rcore` | the composed app, from `compose_product.py` with `ROKCT_COMPOSE_STRICT=1` |
| `/opt/ignition/env` | Python 3.14 venv: frappe and rcore (editable), rcore's `requirements.txt`, Pulsar's requirements |
| `/opt/pulsar/pulsar` | Ignition (Pulsar) from a RokctAI/core checkout |
| `/opt/ignition/sites/apps.txt` | `frappe`, then `rcore` |
| `/opt/ignition/ignition_build.json` | provenance: frappe SHA, protocol and shell SHAs, every module's pinned SHA, `modules.txt` |
| `/usr/local/bin/bench` | Ignition's bench wrapper (common bench forms run the Ignition equivalent) |

Not inside: bench, nginx, socketio, exim, a database, Redis, built desk
assets (`sites/assets`). The API works without assets; the desk UI does not.

## Build

BuildKit is required (secret mount and a named build context). From the
PlatformStack root:

    MONOREPO_PAT=... platform/scripts/build_ignition_image.sh --core ../core

which runs

    docker build -f platform/ignition.Dockerfile \
      --build-context core=../core \
      --secret id=git_token,env=MONOREPO_PAT \
      --build-arg PRODUCT=rokctapp \
      --build-arg PROTOCOL_REF=main --build-arg RCORE_REF=main \
      --build-arg FRAPPE_REF=version-16-hotfix \
      --target ignition_rokctapp -t ignition-rokctapp:local .

and then smoke-tests the image: the runner starts, `frappe` (16.x), `rcore`
and `pulsar.ignition` import, `apps.txt` starts with `frappe, rcore`, no
token is left in the image, and `bench status` works.

The token is needed because the composer clones private module repos and the
composed `requirements.txt` has private git dependencies. It is a BuildKit
secret, mounted only for the build step that needs it, and reaches git
through environment variables of that step only. It is never a build arg,
never in a layer, a git config or a remote URL. Pin `PROTOCOL_REF` and
`RCORE_REF` to SHAs for a release; module refs that say `main` are pinned to
SHAs at build time either way and logged in `ignition_build.json`.

The `rokctapp-image` job in `.github/workflows/ignition.yml` runs the same
script (on `workflow_dispatch`, and on pull requests that touch these files).

## Without Docker

`platform/scripts/build_ignition_root.sh` does the same build into a plain
directory (the Dockerfile calls it too):

    platform/scripts/build_ignition_root.sh --root /tmp/ign-root
    platform/scripts/build_ignition_root.sh --root /tmp/ign-root --python python3.14

The first form composes and clones only (enough to inspect the composed
app); `--python` also creates `env/` and installs everything. Frappe v16
needs Python 3.14 and, to build `mysqlclient`, the MariaDB client headers
(`libmariadb-dev`, `pkg-config`). `--protocol-repo file:///path/to/clone`
composes from a local protocol clone, to try a template change before it is
merged.

## Run

The Ignition root is `/opt/ignition`. Code is root-owned and read-only for
the runtime user (uid 10001). Only `sites/`, `backups/` and `logs/` are
volumes, so a new image always brings its own apps; the entrypoint puts the
baked app list back into `sites/apps.txt` on every start (frappe first, any
other listed app kept after it).

The stack (a later step) writes `sites/common_site_config.json` with
`db_type`, `db_host`, `db_port`, `redis_cache`, `redis_queue`,
`redis_socketio`, and passes `IGNITION_ADMIN_PASSWORD` and
`IGNITION_DB_ROOT_PASSWORD` at run time. Then:

    docker run --rm -v sites:/opt/ignition/sites ... ignition-rokctapp \
      new-site tenant.example --persona tenant --apps rcore
    docker run -d -p 8000:8000 -v sites:/opt/ignition/sites ignition-rokctapp serve
    docker run -d -v sites:/opt/ignition/sites ignition-rokctapp worker
    docker run -d -v sites:/opt/ignition/sites ignition-rokctapp scheduler

No `--app-path` is needed: rcore is already installed in the image's venv.

## Known gaps (first sandbox run, 2026-11-06)

A root built by `build_ignition_root.sh` was run through Ignition against a
local Postgres 16, MariaDB 10.11 and Redis (no Docker). What the image does
not handle yet:

- Composed `requirements.txt` lists `designer-compliance` as a bare name
  (not on PyPI); pip fails until designer#23 (git pin) is merged.
- `rokctapp.json` composes `erp` without the `projects` and `support`
  modules from the productivity repo, which erp imports at module level
  (Sales Invoice, Sales Order, Pick List, Expense Claim, Workstation, ...).
  Install stops at the first such DocType.
- On MariaDB, rcore's `users` module collides with Frappe v16's own `Users`
  module (`Module Def` primary key, case-insensitive collation).
- On Postgres, vanilla Frappe v16 needs the same `fixtures.py`
  duplicate-key patch the bench build applies (`build_ecosystem.sh`), or the
  second fixture sync (migrate) fails; and `DocField.link_filters` comes back
  from the `json` column as a list, which Frappe's own
  `validate_link_filters` rejects when rcore's fixtures add Custom Fields.
- The stack must create the `cube` and `earthdistance` (and `vector`)
  extensions as a superuser; rcore's `after_install` only warns.
