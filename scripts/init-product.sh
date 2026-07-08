#!/usr/bin/env bash
# Scaffold a brand-new Odoo product ("tenant") repo around this platform.
#
#   bash scripts/init-product.sh <product-name> [target-dir]
#
# Creates a git repo that consumes odoo-platform as a submodule at platform/,
# with the enforced src/ layout (custom_addons + third_party_addons) and all
# thin config files. After it finishes you only: add vendor submodules, list
# them in selection.txt, `make selection`, create the GitHub repo, push.
#
# PLATFORM_URL env overrides the platform remote (defaults to this repo's
# origin, else the canonical T-Altendorf URL).
set -euo pipefail

NAME="${1:?usage: init-product.sh <product-name> [target-dir]}"
TARGET="${2:-$NAME}"

# Resolve the platform remote to add as a submodule.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${PLATFORM_URL:-}" ]; then
    PLATFORM_URL="$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || true)"
    PLATFORM_URL="${PLATFORM_URL:-https://github.com/T-Altendorf/odoo-platform.git}"
fi

[ -e "$TARGET" ] && { echo "ERROR: $TARGET already exists — refusing to overwrite" >&2; exit 1; }

echo "==> scaffolding '$NAME' in $TARGET (platform: $PLATFORM_URL)"
mkdir -p "$TARGET"
cd "$TARGET"
git init -q

# --- platform submodule ------------------------------------------------------
git submodule add -q "$PLATFORM_URL" platform
echo "    added platform submodule"

# --- enforced src/ skeleton --------------------------------------------------
mkdir -p src/custom_addons \
         src/third_party_addons/_vendor \
         src/third_party_addons/_static_vendor \
         src/third_party_addons/_selected
# .gitkeep so the empty category dirs survive the commit.
touch src/custom_addons/.gitkeep \
      src/third_party_addons/_vendor/.gitkeep \
      src/third_party_addons/_static_vendor/.gitkeep \
      src/third_party_addons/_selected/.gitkeep

# --- thin config files -------------------------------------------------------
cat > docker-compose.yml <<'YAML'
# Thin wrapper — ALL deployment machinery lives in the odoo-platform submodule
# (./platform). Dokploy deploys this file; docker compose resolves the include
# with paths relative to this repo root. See platform/README.md.
include:
  - path: platform/docker-compose.yml
    project_directory: .
YAML

cat > Makefile <<YAML
# Product config only — every target lives in the odoo-platform submodule.
# \`make help\` for the list; see platform/README.md for the integration contract.
OWN_MODULES ?=

include platform/Makefile
YAML

cat > selection.txt <<'TXT'
# Vendor modules this product loads. Paths relative to src/third_party_addons/.
# After editing:  make selection   (regenerates _selected symlinks; commit them)
# Rules: see platform/README.md — never put _vendor/_static_vendor on addons_path.

# _vendor/oca_knowledge/document_page
# _static_vendor/auto_database_backup
TXT

cat > requirements.txt <<'TXT'
# Extra python deps for this product's OWN modules. Vendor deps are installed
# automatically from src/third_party_addons/{_vendor,_static_vendor}/*/requirements.txt.
TXT

cat > .env.example <<TXT
# Copy to .env and adjust. Everything Odoo needs lives here.
#   cp .env.example .env

# --- Odoo base image ---------------------------------------------------------
ODOO_IMAGE=odoo:18.0
INSTALL_VENDOR_REQS=1
IMAGE_NAME=${NAME}
IMAGE_TAG=latest

# --- Database ----------------------------------------------------------------
# Postgres tuning (defaults assume ~8GB RAM for Postgres; scale to the server:
# shared_buffers ~= 25% of Postgres RAM, effective_cache_size ~= 50-75%).
# PG_SHARED_BUFFERS=2GB
# PG_EFFECTIVE_CACHE_SIZE=6GB
# PG_WORK_MEM=32MB
# PG_MAINTENANCE_WORK_MEM=256MB
# PG_MAX_CONNECTIONS=100
DB_USER=odoo
DB_PASSWORD=change-me-db
DB_NAME=False
LIST_DB=False
DB_EXPOSE_PORT=5432

# --- Odoo server -------------------------------------------------------------
ADMIN_PASSWD=change-me-admin
ODOO_ADMIN_PASSWORD=admin
HTTP_PORT=8069
GEVENT_PORT=8072
PROXY_MODE=True
WORKERS=2
MAX_CRON_THREADS=1
LOG_LEVEL=info

# --- Module automation -------------------------------------------------------
UPGRADE_DB=
UPGRADE_MODULES=
INSTALL_MODULES=
INIT_DB=

# --- Debugger (dev only) -----------------------------------------------------
DEBUG=0
DEBUGPY_PORT=5678
DEBUGPY_WAIT=

# --- Domain ------------------------------------------------------------------
DOMAIN=odoo.example.com
TXT

cat > .gitignore <<'TXT'
# Local dev config (per-machine, never committed)
/odoo.conf
.env
*.code-workspace

# Personal .vscode scratch, but share the dev debugger setup
.vscode/*
!.vscode/launch.json
!.vscode/tasks.json
!.vscode/extensions.json

# Python / OS
__pycache__/
*.py[cod]
.DS_Store

# Local backups
/backups/
TXT

cat > README.md <<TXT
# ${NAME} — Odoo 18 Product Repo

Content-only repo (first-party modules + vendor selection + deploy config).
All deployment machinery lives in the [odoo-platform](${PLATFORM_URL%.git})
submodule at \`platform/\`. See **[platform/README.md](platform/README.md)**.

## Layout (enforced by \`make check\`)
\`\`\`
src/
├── custom_addons/        <-- your first-party modules (on addons_path)
└── third_party_addons/
    ├── _vendor/          <-- vendor submodules      (NEVER on addons_path)
    ├── _static_vendor/   <-- committed snapshots     (NEVER on addons_path)
    └── _selected/        <-- generated symlinks (the ONLY vendor dir loaded)
\`\`\`

## Quick start
\`\`\`bash
# add a vendor repo, then pick its modules
git submodule add -b 18.0 https://github.com/OCA/knowledge.git src/third_party_addons/_vendor/oca_knowledge
echo "_vendor/oca_knowledge/document_page" >> selection.txt
make selection            # build _selected symlinks (commit them)

cp .env.example .env      # then edit secrets
make up                   # dev stack (ports, live mount, reload)
\`\`\`
TXT

# --- verify + first commit ---------------------------------------------------
echo "==> verifying layout"
bash platform/scripts/check-layout.sh

git add -A
git commit -q -m "Scaffold ${NAME} around odoo-platform submodule"
echo "    committed initial scaffold"

cat <<EOF

Done. '${NAME}' scaffolded in $TARGET

Next:
  1. cd $TARGET
  2. Put first-party modules in src/custom_addons/
  3. Add vendor repos: git submodule add -b 18.0 <url> src/third_party_addons/_vendor/<name>
     then list modules in selection.txt and run: make selection
  4. Set OWN_MODULES in the Makefile
  5. Create the GitHub repo and push:
       gh repo create <owner>/${NAME} --private --source=. --remote=origin --push
  6. Point Dokploy at it (recursive submodule clone + private-repo auth).
EOF
