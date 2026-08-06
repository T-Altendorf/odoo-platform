#!/usr/bin/env python3
"""Honest health probe for the Odoo container.

The point of this script is to fail when Odoo is broken. That sounds obvious,
but the two endpoints you would reach for first BOTH report success on a
database that Odoo cannot actually use:

  * /web/health is `auth='none'` and returns {"status": "pass"} unconditionally
    (addons/web/controllers/home.py). Even ?db_server_status=1 only opens a
    cursor on the `postgres` maintenance database — it never loads the registry
    and never reads a table. It answers "is this process listening", not "does
    Odoo work".

  * /web/login is worse, because it looks like a real page. When the registry is
    unusable Odoo catches RegistryError, logs a warning, and re-serves the
    request through _serve_nodb() (odoo/http.py). /web/login is on the explicit
    reroute list, so it renders a perfectly good HTTP 200 login form backed by
    no database at all.

Both would have reported healthy through an outage where every ORM read raised
"column res_partner.calendar_email does not exist".

So we probe a route that CANNOT degrade quietly: an `auth='public'` one.
_serve_nodb() dispatches against root.nodb_routing_map, which only contains
`auth='none'` routes — so a public route is simply absent there and 404s instead
of pretending. And resolving `auth='public'` binds the public user, which reads
res.users -> res.partner: the exact query shape that broke.

/web/manifest.webmanifest (addons/web/controllers/webmanifest.py) is the
cheapest such route in core `web`: GET, readonly=True, and it touches
ir.config_parameter, ir.module.module and ir.ui.menu on the way through.

  200 -> healthy: HTTP is up, registry loaded, ORM reads succeed
  404 -> registry unusable; Odoo has fallen back to no-db serving
  500 -> registry loaded but an ORM read failed (schema drift is the usual cause)

Everything is tunable by environment variable so a product can point the probe
somewhere else without rebuilding this logic.
"""

import os
import sys
import urllib.error
import urllib.request

# A public (db-requiring) route. If you override this, keep it `auth='public'`
# or better — an `auth='none'` route silently reintroduces the false-green bug
# this whole script exists to avoid.
DEFAULT_PATH = "/web/manifest.webmanifest"


def resolve_host():
    """Pick the Host header that makes DBFILTER select a real database.

    odoo/http.py db_filter() strips the port and takes the FIRST LABEL of the
    Host as %d ("www.example.com:80" -> "example"). It never resolves that label
    as a name, so the bare database name is itself a valid Host: with
    DBFILTER=(?i)^%d$, sending "Host: mydb" selects database "mydb".

    That matters because the probe talks to 127.0.0.1, which %d would reduce to
    "127" — matching nothing, so Odoo serves db-less and the probe reports a
    false failure. Defaulting the Host to DB_NAME avoids that, and is harmless
    when DBFILTER is a fixed regex (^mydb$) that ignores the host entirely.

    Returns (host, warning). An empty host means "send no Host override".
    """
    host = os.environ.get("HEALTHCHECK_HOST", "").strip()
    if host:
        return host, None

    db_name = os.environ.get("DB_NAME", "").strip()
    if db_name and db_name != "False":
        # db_name may be a comma-separated list of exposed dbs; probe the first.
        return db_name.split(",")[0].strip(), None

    # Multi-db (DB_NAME=False) with a host-routed filter: there is no single
    # database to infer, so the probe cannot select one and will report
    # unhealthy. Say so, or it reads as an outage rather than a config gap.
    dbfilter = os.environ.get("DBFILTER", "")
    if "%d" in dbfilter or "%h" in dbfilter:
        return "", (f"DBFILTER={dbfilter!r} routes by host, but neither "
                    "HEALTHCHECK_HOST nor DB_NAME is set — the probe cannot "
                    "select a database and will report unhealthy. Set "
                    "HEALTHCHECK_HOST to a hostname matching one database.")
    return "", None


def main() -> int:
    if os.environ.get("HEALTHCHECK_DISABLE") == "1":
        return 0

    port = os.environ.get("HTTP_PORT", "8069")
    path = os.environ.get("HEALTHCHECK_PATH", DEFAULT_PATH)
    host, warning = resolve_host()
    if warning:
        print(f"healthcheck: {warning}", file=sys.stderr)
    try:
        timeout = float(os.environ.get("HEALTHCHECK_TIMEOUT", "10"))
    except ValueError:
        timeout = 10.0

    url = f"http://127.0.0.1:{port}{path}"
    request = urllib.request.Request(url, method="GET")
    if host:
        request.add_header("Host", host)

    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            status = response.status
    except urllib.error.HTTPError as exc:
        status = exc.code
    except Exception as exc:
        # Connection refused / DNS / timeout: the server is not serving at all.
        print(f"unhealthy: cannot reach {url}: {type(exc).__name__}: {exc}",
              file=sys.stderr)
        return 1

    if status == 200:
        return 0

    if status == 404:
        detail = ("registry unusable — Odoo fell back to serving without a "
                  "database (check the log for 'Database or registry unusable')")
    elif status >= 500:
        detail = ("the ORM raised while serving — a missing column or other "
                  "schema drift is the usual cause; check the log")
    else:
        detail = "unexpected status"

    print(f"unhealthy: HTTP {status} from {path} — {detail}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
