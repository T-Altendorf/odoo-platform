# Deploying & developing gemini_addons18

This repo is the **authoritative source** of the Odoo 18 solution. It ships a
complete Docker stack (Odoo + PostgreSQL). Odoo core is the official `odoo:18`
image (this repo's custom code lives in `/mnt/extra-addons`); pin the image for
reproducibility instead of vendoring the multi-hundred-MB Odoo source.

```
docker-compose.yml            prod / Dokploy (Odoo + Postgres)
docker-compose.override.yml   local dev overlay (ports, live mount, reload)
Dockerfile                    odoo:18 + python reqs + entrypoint
docker/entrypoint.sh          render conf <- env, wait db, auto -i/-u, serve
docker/odoo.conf.template     all odoo.conf keys <- ${ENV}
.env.example                  every tunable
```

Everything is configured through `.env` (`cp .env.example .env`). Nothing odoo
needs is hard-coded.

---

## Local development

Requirements: Docker + Docker Compose, and the `_vendor` submodules populated:

```bash
git submodule update --init --recursive
cp .env.example .env          # then edit secrets
make up                       # build + start (publishes 8069/8072, live reload)
make logs
```

First run on a fresh database — create and init it once:

```bash
INIT_DB=odoo make up          # creates db "odoo" with base + own modules
# then clear INIT_DB from .env so it doesn't re-check every boot
# open http://localhost:8069  (master pw = ADMIN_PASSWD)
```

### Debugging (VS Code + debugpy)

The repo ships `.vscode/launch.json` + `tasks.json` (debugger setup is shared;
personal `.vscode` scratch stays gitignored).

```bash
make debug            # = DEBUG=1 DEBUGPY_WAIT=1 docker compose up --build
```

Then in VS Code run **"Odoo: Attach (Docker debugpy)"** (port 5678). Breakpoints
in your modules map via `${workspaceFolder} -> /mnt/extra-addons`. `DEBUGPY_WAIT`
blocks boot until you attach; drop it to start immediately and attach anytime.
Debugging forces single-process (the dev overlay already sets `WORKERS=0`).

> Prefer running Odoo natively (no Docker) against your local source? The
> multi-root `odoo18.code-workspace` still has the **"Python: Odoo"** launch
> config that runs `odoo-bin` directly.

The dev overlay bind-mounts the repo into the container, so editing python/xml
hot-reloads (`--dev=reload,qweb,xml`). Useful targets (`make help`):

| target            | what |
|-------------------|------|
| `make up/down`    | start / stop stack |
| `make logs`       | tail odoo |
| `make shell`      | bash in container |
| `make odoo-shell` | odoo python shell |
| `make psql`       | psql into the db |
| `make upgrade`    | `-u` own modules (`m=mod1,mod2` to target) |
| `make submodules` | bump `_vendor` to latest 18.0 |

> The override disables boot-time auto-upgrade so restarts are fast. Upgrade
> explicitly with `make upgrade`.

---

## Production via Dokploy

1. **Create app** → type **Compose**, point it at this git repo, branch `18.0`,
   compose file `docker-compose.yml`. Enable **recursive submodule** clone so
   `third_party_addons/_vendor` is populated.
2. **Environment** → paste your `.env` values (at minimum `ADMIN_PASSWD`,
   `DB_PASSWORD`). For a fresh database set `INIT_DB=<name>` on the first
   deploy, then clear it. Set `UPGRADE_DB=<name>` for ongoing upgrades.
3. **Domain** — two options:
   - *UI (simplest):* add a domain mapped to service `odoo`, port `8069`.
   - *Compose labels:* set `DOMAIN` in env, uncomment the Traefik `labels` +
     `networks` blocks in `docker-compose.yml`. The second router sends
     `/websocket` to `GEVENT_PORT` (needed when `WORKERS>0`).
4. **Deploy.** On boot the entrypoint renders the config, waits for Postgres,
   creates any `INIT_DB` databases, upgrades every `UPGRADE_DB` database, and
   serves. Missing dbs in `UPGRADE_DB` are skipped (never auto-created).

`PROXY_MODE=True` is required behind Traefik. Volumes `db-data` and `odoo-data`
(filestore + sessions) persist across redeploys.

### Ports & reverse proxy (no host ports in prod)

In production the odoo container publishes **zero** host ports — it only
`expose`s 8069 (http) and 8072 (websocket) on the docker network. A reverse
proxy on that same network maps your domain to those internal ports. This is the
docker-native version of your host-nginx `upstream 127.0.0.1:8070` — the
upstream just becomes the **service name + internal port**:

| your old host nginx        | dockerized                |
|----------------------------|---------------------------|
| `server 127.0.0.1:8070;`   | `server odoo:8069;`       |
| `server 127.0.0.1:8073;`   | `server odoo:8072;`       |
| nginx listens 80/443       | only the proxy publishes ports |

Two ways to run the proxy:

- **Dokploy/Traefik** — set the domain in the UI (or the `${DOMAIN}` labels in
  `docker-compose.yml`). Traefik sets `X-Forwarded-*` and terminates TLS; you
  publish nothing. The second router sends `/websocket` to 8072 (needed when
  `WORKERS>0`).
- **Self-managed nginx** (mirrors your current vhost exactly):
  ```bash
  docker compose -f docker-compose.yml -f docker-compose.nginx.yml up -d
  ```
  Config lives in `deploy/nginx/templates/default.conf.template` (driven by
  `${DOMAIN}`). Mount your existing `/etc/letsencrypt` to terminate TLS there,
  or keep it HTTP behind Dokploy. Don't combine with the dev override.

Multi-tenant: your nginx sends `X-Odoo-dbfilter ^UUs.*` (the `dbfilter_from_header`
module). `DB_NAME=False` is the default. List your tenant dbs in `UPGRADE_DB`
(e.g. `UPGRADE_DB=UUs,UUs_Test`) so boot-time `-u` runs on each.

### Databases, the manager, and a test/staging instance

Odoo selects the database **before login**, and the setting is **global** — so
"admin sees all DBs, users see only one" is impossible within a single instance.
The web DB manager (`/web/database/manager`) is gated only by the master password
(`ADMIN_PASSWD`), and it's fully disabled when `LIST_DB=False`.

Recommended layout — **prod stays locked, a second app is your admin/test console:**

| | prod app | test / admin app |
|---|---|---|
| `DOMAIN` | odoo.example.com | test.example.com |
| `DB_NAME` | `False` | `False` |
| `DBFILTER` | `^prod$` (or via header) | `.*` (manager lists every DB) |
| `LIST_DB` | `False` (clean, no manager) | `True` (DB manager enabled) |
| `UPGRADE_DB` | `prod` | `test` |
| `WORKERS` | `2` | `0` (cheap) |

Prod users land on `odoo` with no picker and no manager exposed. The test app's
manager can create/backup/restore **all** DBs (including prod) when it points at
the same Postgres — protect it with a strong `ADMIN_PASSWD`.

**Cost of the second app is small, and you control it:**
- The `gemini-odoo18` image layers are **shared** on disk — not doubled.
- An idle Odoo uses ~0% CPU; the only real cost is ~250–350MB RAM at `WORKERS=0`.
- **Stop it in Dokploy when you're not testing → ~0 overhead.** Start on demand.

**Don't even need a second Odoo for DB *management*** — the CLI covers it:
```
make dblist                        # list all databases
make dbtest from=odoo to=test      # clone prod -> fresh test copy
make dbbackup db=odoo              # dump to ./backups
make dbrestore db=test file=...    # restore
make dbcreate db=foo               # create + init base + own modules
make dbdrop db=test                # drop
```
A second running Odoo is only worth it when you want to *click around* in test
data. After cloning prod into a test DB, neutralize outgoing mail / crons before
using it.

Sharing one Postgres between two Dokploy apps: give the test app no `db` service
and set `DB_HOST` to the prod Postgres over a shared Dokploy network — **or**
just let the test app run its own Postgres (~40MB, fully isolated, safer staging).

### Reproducible builds
Pin the base image by digest in `.env`:
```
ODOO_IMAGE=odoo@sha256:<digest>
```
Vendor module versions are pinned by the `_vendor` submodule commits. Bump them
deliberately with `make submodules && git add third_party_addons/_vendor`.

---

## How module automation works

The entrypoint manages databases via two env vars:

- **`INIT_DB`** — one-shot fresh database creation. Comma-separated list of db
  names. Each db gets `base` + `UPGRADE_MODULES` + `INSTALL_MODULES` installed,
  and the admin password set to `ODOO_ADMIN_PASSWORD`. Already-existing dbs are
  skipped. **Set it, deploy once, then clear it.**
- **`UPGRADE_DB`** — comma-separated list of dbs to run `-i` / `-u` on every
  boot. Missing dbs are **skipped with a warning** (never auto-created). Empty
  or `"False"` = skip all upgrades (fast restart).

`UPGRADE_MODULES` (default = the five own modules) runs `-u` — safe because
their code is version-controlled here. `INSTALL_MODULES` runs `-i` (use once
per fresh DB, then clear).

Examples:
```bash
UPGRADE_DB=UUs                   # upgrade one db every boot
UPGRADE_DB=UUs,UUs_Test          # upgrade multiple dbs
UPGRADE_DB=                      # skip upgrades entirely (fast restart)
INIT_DB=NewClient                # create a fresh db (one-shot, then clear)
```

## Python requirements
The image installs, at build time:
- every `third_party_addons/{_vendor,_static_vendor}/*/requirements.txt`
- the repo-root `requirements.txt` (own/custom extras)

Set build arg `INSTALL_VENDOR_REQS=0` for a slim image and curate
`requirements.txt` yourself. `_static_vendor` modules have no requirements file
today — add their deps to the root `requirements.txt` (or drop one beside the
copied module).
