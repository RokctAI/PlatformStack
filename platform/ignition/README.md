# Ignition + Frappe v16 + composed rokctapp image

`platform/ignition.Dockerfile`, target `ignition_rokctapp`, builds one image
that runs a composed product app on Ignition (`python -m pulsar.ignition`)
instead of bench. The default product is `rokctapp`: one Frappe app, `rcore`,
composed from The-Rokct-Protocol template
`core/utils/frappe/composer/rokctapp.json`.

What is inside:

| Path | What |
|---|---|
| `/opt/ignition/apps/frappe` | stock Frappe at `FRAPPE_REF` (default `version-16-hotfix`) plus the build-time patches below |
| `/opt/ignition/apps/rcore` | the composed app, from `compose_product.py` with `ROKCT_COMPOSE_STRICT=1` |
| `/opt/ignition/env` | Python 3.14 venv: frappe and rcore (editable), rcore's `requirements.txt`, Pulsar's requirements |
| `/opt/pulsar/pulsar` | Ignition (Pulsar) from a RokctAI/core checkout; the moved modules are shims |
| `/opt/sdk` | the SDK `pulsar/ported` folders from RokctAI/pay, productivity and zones; `PULSAR_SDK_ROOT=/opt/sdk` |
| `/opt/ignition/sites/apps.txt` | `frappe`, then `rcore` |
| `/opt/ignition/sites/common_site_config.json` | `{"db_type": "postgres"}` (build arg `DB_TYPE`) |
| `/opt/ignition/ignition_build.json` | provenance: frappe SHA and patches applied, protocol and shell SHAs, every module's pinned SHA, `modules.txt`, `db_type` |
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
      --build-context pay=../pay \
      --build-context productivity=../productivity \
      --build-context zones=../zones \
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

## Database: Postgres

The image targets Postgres. rokctapp cannot run on MariaDB: rcore's `users`
module and Frappe v16's own `Users` module are the same `Module Def` key under
MariaDB's case-insensitive collation. `build_ignition_root.sh --db-type`
(build arg `DB_TYPE`, default `postgres`) writes `db_type` into
`sites/common_site_config.json`, and the entrypoint writes the same default
(`IGNITION_DB_TYPE`) when a fresh `sites` volume has no config yet. A config
the stack writes is never changed.

## Frappe patches (build time, no fork)

Frappe is stock `frappe/frappe` at `FRAPPE_REF`. After the clone,
`build_ignition_root.sh` runs `platform/scripts/patch_frappe_v16.py
<root>/apps/frappe`, which applies these patches:

| Patch | File | Why |
|---|---|---|
| `fixtures-duplicate-key` | `frappe/utils/fixtures.py` | The same change the bench build makes (`build_ecosystem.sh`, "Patching fixtures.py for PostgreSQL unique constraints"). On Postgres the second fixture sync (`migrate`) raises a duplicate key on records an earlier sync inserted. The patch skips that fixture file and rolls back. |
| `link-filters-json-list` | `frappe/core/doctype/doctype/doctype.py` | Postgres returns the `json` column `DocField.link_filters` already decoded (a list). MariaDB returns text. `validate_link_filters` calls `json.loads()` on it and throws "Filters must be valid JSON" when rcore's fixtures add Custom Fields. The patch accepts a list as is. |

Each patch replaces one exact block of text. Running the step again does
nothing, because a patch that is already applied is left alone. If a target
block is not found exactly once, or the patched file does not compile, the
build fails, so a Frappe change that moves the code is seen at build time.
The applied patch names are written to `ignition_build.json`
(`frappe.patches`), and the image smoke test checks them. To drop a patch
when Frappe fixes the issue upstream, remove its entry from `PATCHES` in the
script.

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
`IGNITION_DB_ROOT_PASSWORD` at run time. The superuser `new-site` connects
as is `IGNITION_DB_ROOT_USER`, else `db_root_username` or `root_login` in
that file, else `postgres` on Postgres (needs the Ignition change in
RokctAI/core that makes this configurable; older Ignition always used `root`).
Then:

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
- MariaDB cannot host rokctapp (see "Database: Postgres"); the image
  defaults to Postgres.
- The two Postgres problems of stock Frappe v16 (fixture duplicate key,
  `link_filters` as a list) are fixed by the build-time patches above.
- The stack must create the `cube` and `earthdistance` (and `vector`)
  extensions as a superuser; rcore's `after_install` only warns.
