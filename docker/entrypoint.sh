#!/usr/bin/env bash
# Render odoo.conf from env -> wait for postgres -> auto (install)/upgrade our
# own modules -> exec the server. Runs as the unprivileged `odoo` user.
set -euo pipefail

# --- Defaults (every value overridable via env / .env) -----------------------
: "${DB_HOST:=db}"
: "${DB_PORT:=5432}"
: "${DB_USER:=odoo}"
: "${DB_PASSWORD:=odoo}"
: "${DB_NAME:=odoo}"
: "${DB_MAXCONN:=64}"
: "${LIST_DB:=False}"
# Empty/unset -> single-db filter derived from DB_NAME.
if [ -z "${DBFILTER:-}" ]; then DBFILTER="^${DB_NAME}\$"; fi

: "${ADMIN_PASSWD:=admin}"
: "${DATA_DIR:=/var/lib/odoo}"

: "${HTTP_PORT:=8069}"
: "${GEVENT_PORT:=8072}"
: "${PROXY_MODE:=True}"
: "${WORKERS:=2}"
: "${MAX_CRON_THREADS:=1}"

: "${LIMIT_MEMORY_SOFT:=2147483648}"
: "${LIMIT_MEMORY_HARD:=8589934592}"
: "${LIMIT_REQUEST:=1073741824}"
: "${LIMIT_TIME_CPU:=3600}"
: "${LIMIT_TIME_REAL:=7200}"

: "${LOG_LEVEL:=info}"

# Core addons + our repo root + the cherry-picked third-party modules.
# NEVER add third_party_addons/_vendor here (see repo README).
: "${ADDONS_PATH:=/usr/lib/python3/dist-packages/odoo/addons,/mnt/extra-addons,/mnt/extra-addons/third_party_addons/_selected}"

: "${ODOO_RC:=/var/lib/odoo/odoo.conf}"

# Module automation. UPGRADE_MODULES runs `-u` on every boot (our own modules,
# pinned via submodule commits -> safe to keep in sync). INSTALL_MODULES runs
# `-i` (use once on a fresh database, then clear it).
: "${UPGRADE_MODULES:=consistent_time_format,gemini_importer,gemini_production,mrp_bom_structure_xlsx,organize_urself}"
: "${INSTALL_MODULES:=}"
# Which DB the -i/-u steps target. Defaults to DB_NAME, but for header-based
# multi-tenant (DB_NAME=False + dbfilter_from_header) point it at a real db.
: "${UPGRADE_DB:=${DB_NAME}}"

# Debugger (debugpy). DEBUG=1 -> run Odoo under debugpy on DEBUGPY_PORT.
# DEBUGPY_WAIT=1 -> block until the IDE attaches.
: "${DEBUG:=0}"
: "${DEBUGPY_PORT:=5678}"
: "${DEBUGPY_WAIT:=}"

export DB_HOST DB_PORT DB_USER DB_PASSWORD DB_NAME DB_MAXCONN DBFILTER LIST_DB \
       ADMIN_PASSWD DATA_DIR HTTP_PORT GEVENT_PORT PROXY_MODE WORKERS \
       MAX_CRON_THREADS LIMIT_MEMORY_SOFT LIMIT_MEMORY_HARD LIMIT_REQUEST \
       LIMIT_TIME_CPU LIMIT_TIME_REAL LOG_LEVEL ADDONS_PATH

# --- Render config -----------------------------------------------------------
envsubst < /etc/odoo/odoo.conf.template > "$ODOO_RC"
echo "[entrypoint] rendered $ODOO_RC"

# --- Wait for postgres -------------------------------------------------------
echo "[entrypoint] waiting for postgres at ${DB_HOST}:${DB_PORT} ..."
until (echo > "/dev/tcp/${DB_HOST}/${DB_PORT}") 2>/dev/null; do
    sleep 1
done
echo "[entrypoint] postgres is up"

# --- Auto install / upgrade --------------------------------------------------
: "${ODOO_ADMIN_PASSWORD:=admin}"

db_exists() {
    PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" \
        -tAc "SELECT 1 FROM pg_database WHERE datname='$1'" postgres 2>/dev/null | grep -q 1
}

run_step() {  # <flag> <modules>
    local flag="$1" mods="$2"
    if [ -n "$mods" ] && [ "$UPGRADE_DB" != "False" ]; then
        echo "[entrypoint] odoo ${flag} ${mods} (db=${UPGRADE_DB})"
        odoo -c "$ODOO_RC" -d "$UPGRADE_DB" "$flag" "$mods" --stop-after-init
    fi
}

if [ "$UPGRADE_DB" != "False" ]; then
    if ! db_exists "$UPGRADE_DB"; then
        echo "[entrypoint] fresh DB '$UPGRADE_DB' — initialising with base + own modules"
        install_list="base"
        [ -n "${UPGRADE_MODULES}" ] && install_list="${install_list},${UPGRADE_MODULES}"
        [ -n "${INSTALL_MODULES}" ] && install_list="${install_list},${INSTALL_MODULES}"
        odoo -c "$ODOO_RC" -d "$UPGRADE_DB" -i "$install_list" --stop-after-init
        # Set admin password via ORM so it's properly hashed.
        odoo shell -c "$ODOO_RC" -d "$UPGRADE_DB" --no-http <<PYEOF
admin = env['res.users'].browse(2)
admin.password = '$ODOO_ADMIN_PASSWORD'
env.cr.commit()
print(f"[entrypoint] admin password set for {admin.login}")
PYEOF
    else
        run_step -i "${INSTALL_MODULES}"
        run_step -u "${UPGRADE_MODULES}"
    fi
fi

# --- Serve -------------------------------------------------------------------
echo "[entrypoint] starting odoo"
if [ "${DEBUG}" = "1" ]; then
    wait_flag=""
    [ -n "${DEBUGPY_WAIT}" ] && wait_flag="--wait-for-client"
    echo "[entrypoint] debugpy listening on 0.0.0.0:${DEBUGPY_PORT} ${wait_flag}"
    exec python3 -m debugpy --listen "0.0.0.0:${DEBUGPY_PORT}" ${wait_flag} \
        "$(command -v odoo)" -c "$ODOO_RC" "$@"
fi
exec odoo -c "$ODOO_RC" "$@"
