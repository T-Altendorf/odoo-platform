# odoo-platform

Shared Odoo 18 deployment machinery — Docker image, compose stack, entrypoint,
dev/ops Makefile, and the module-selection generator. Maintained **once** here;
consumed by every product repo as a **git submodule at `platform/`**.

A *product repo* owns only its content:

```
product-repo/
├── platform/                  <-- THIS repo (submodule)
├── docker-compose.yml         <-- 3 lines (include, below)
├── Makefile                   <-- 2 lines (config + include, below)
├── selection.txt              <-- which vendor modules to load
├── requirements.txt           <-- extra python deps for own modules
├── .env / .env.example        <-- deployment config + secrets
├── .gitmodules                <-- the product's OWN vendor submodules
└── src/
    ├── my_module_a/           <-- own modules
    └── third_party_addons/
        ├── _vendor/           <-- submodules (NEVER on addons_path)
        ├── _static_vendor/    <-- committed snapshots (NEVER on addons_path)
        └── _selected/         <-- generated symlinks (the ONLY vendor dir on addons_path)
```

## Integration (once per product repo)

```bash
git submodule add https://github.com/T-Altendorf/odoo-platform.git platform
```

**docker-compose.yml** (product root — this is what Dokploy deploys):

```yaml
include:
  - path: platform/docker-compose.yml
    project_directory: .
```

**Makefile** (product root):

```make
OWN_MODULES ?= my_module_a,my_module_b
include platform/Makefile
```

**selection.txt** (product root) — one module per line, path relative to
`src/third_party_addons/`:

```
_vendor/oca_knowledge/document_page
_vendor/my_private_addon_repo/my_module
_static_vendor/auto_database_backup
```

Then `make selection` regenerates `src/third_party_addons/_selected/` (relative
symlinks, stale links pruned) — **commit the symlinks**; deploys and fresh
clones need no build step.

## Rules

* **NEVER** put `_vendor` or `_static_vendor` on `addons_path` — only
  `_selected`. Duplicate module names across vendor repos would otherwise load
  nondeterministically.
* **NEVER** hand-edit `_selected` — edit `selection.txt`, run `make selection`.
* Symlinks must stay **relative** (`../_vendor/...`); absolute paths break in
  Docker/CI checkouts. The generator guarantees this.
* Product-specific knobs (`OWN_MODULES`, `UPGRADE_MODULES`, image name, PG
  tuning `PG_*`) live in the product's Makefile/.env — this repo has **no**
  product defaults.

## Day-to-day (run in the product repo root)

| command | effect |
| --- | --- |
| `make up` / `make debug` | dev stack (ports, live mount, reload / debugpy) |
| `make build` | build the prod image |
| `make selection` | regenerate `_selected` from `selection.txt` |
| `make submodules` | bump all `_vendor` submodules to latest upstream |
| `make platform` | bump this platform submodule |
| `make upgrade` / `make init` / `make db*` | module + database ops (see `make help`) |

Deployment specifics (Dokploy, Traefik/nginx routing, backups): see
[DEPLOY.md](DEPLOY.md) — paths there are written from the product-repo-root
perspective.
