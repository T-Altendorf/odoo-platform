# syntax=docker/dockerfile:1
#
# Authoritative deploy image for an Odoo 18 product repo that consumes this
# platform as a submodule at ./platform. Build context = PRODUCT repo root
# (see platform/docker-compose.yml).
# Base = official Odoo 18 image (clean upstream == our checkout). Pin it for
# reproducibility via ODOO_IMAGE (tag or, better, a sha256 digest) in .env.
#
ARG ODOO_IMAGE=odoo:18.0
FROM ${ODOO_IMAGE}

USER root

# Build deps for python wheels that some vendor modules need (cryptography,
# paramiko, PyMuPDF, numpy, ...). gettext-base gives us `envsubst` at runtime.
# NOTE: don't add libpq-dev — the odoo image already ships libpq5 from the PGDG
# repo (newer than Ubuntu's), and libpq-dev would force a conflicting downgrade.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        gettext-base \
    && rm -rf /var/lib/apt/lists/*

# The odoo image's system Python is PEP 668 "externally managed" -> allow pip
# to install into it (this image IS our environment).
ENV PIP_BREAK_SYSTEM_PACKAGES=1 \
    PIP_ROOT_USER_ACTION=ignore \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Install python requirements.
#   - every third_party_addons/{_vendor,_static_vendor}/*/requirements.txt
#   - manifest external_dependencies for modules NOT covered by any
#     requirements.txt (Cybrosys etc. ship none — see manifest-pydeps.py)
#   - the product-root requirements.txt (own / custom extras) — installed
#     LAST so product pins win
# Set INSTALL_VENDOR_REQS=0 to skip vendor reqs for a slim, fast build.
ARG INSTALL_VENDOR_REQS=1

# --- CACHE & PATH OPTIMIZATION: TARGETED BIND MOUNTS ---
# Bind ONLY the dependency sources (not the whole context) so editing our own
# modules can't bust this layer. The pip install only re-runs when the root
# requirements.txt or a vendor module changes.
RUN --mount=type=bind,source=requirements.txt,target=/tmp/src/requirements.txt \
    --mount=type=bind,source=src/third_party_addons/_vendor,target=/tmp/src/third_party_addons/_vendor \
    --mount=type=bind,source=src/third_party_addons/_static_vendor,target=/tmp/src/third_party_addons/_static_vendor \
    --mount=type=bind,source=platform/scripts/manifest-pydeps.py,target=/tmp/src/manifest-pydeps.py \
    --mount=type=cache,target=/root/.cache/pip \
    set -eux; \
    # FIX: Surgically bypass the Debian lock for typing-extensions and upgrade pyOpenSSL
    # BEFORE running the vendor requirements, preventing the GEN_EMAIL crash.
    pip install --break-system-packages --ignore-installed typing-extensions pyOpenSSL; \
    if [ "$INSTALL_VENDOR_REQS" = "1" ] && [ -d /tmp/src/third_party_addons ]; then \
        find /tmp/src/third_party_addons/_vendor \
             /tmp/src/third_party_addons/_static_vendor \
             -maxdepth 2 -name requirements.txt -print \
             -exec pip install --break-system-packages -r {} \; ; \
        # Fallback: manifest external_dependencies for modules with no
        # requirements.txt anywhere between them and their vendor root.
        # Odoo 18 checks these names against installed dist metadata, so
        # pip-installing them verbatim is exactly what the check expects.
        python3 /tmp/src/manifest-pydeps.py \
             /tmp/src/third_party_addons/_vendor \
             /tmp/src/third_party_addons/_static_vendor \
             > /tmp/manifest-reqs.txt; \
        if [ -s /tmp/manifest-reqs.txt ]; then \
            pip install --break-system-packages -r /tmp/manifest-reqs.txt; \
        fi; \
    fi; \
    if [ -f /tmp/src/requirements.txt ]; then \
        pip install --break-system-packages -r /tmp/src/requirements.txt; \
    fi

# Now copy the src tree for runtime.
# Modifying your code will only hit this layer and below!
#
# NOTE: addons live at /opt/extra-addons, NOT the odoo image's /opt/extra-addons.
# The base image declares `VOLUME /opt/extra-addons`, so anything baked there is
# copied into an ANONYMOUS volume once and then shadowed by that stale volume on
# every redeploy — code changes never reach runtime. /opt/extra-addons is a plain
# image path, so the built code is always what runs. Keep addons off any VOLUME
# path (ADDONS_PATH in the entrypoint points here too).
COPY src /opt/extra-addons

# Guard: fail the build LOUDLY if git submodules weren't checked out (or the
# build context dropped them, e.g. `git archive`). Every _selected entry is a
# relative symlink into _vendor/_static_vendor; a _vendor-backed link dangles
# when its submodule is uninitialized. Verifying each resolves to a real
# __manifest__.py validates the whole chain (submodule content + relative
# symlink) in the actual image — generically, with no product-specific module
# list to maintain (an empty/absent _selected is fine: nothing to check).
RUN set -eu; \
    sel=/opt/extra-addons/third_party_addons/_selected; \
    miss=0; \
    if [ -d "$sel" ]; then \
        for link in "$sel"/*; do \
            [ -e "$link" ] || [ -L "$link" ] || continue; \
            name=$(basename "$link"); \
            if [ ! -f "$link/__manifest__.py" ]; then \
                echo "ERROR: vendored module '$name' is missing (_selected/$name/__manifest__.py did not resolve)." >&2; \
                miss=1; \
            fi; \
        done; \
    fi; \
    if [ "$miss" != 0 ]; then \
        echo "       git submodules are not checked out in the build context." >&2; \
        echo "       Fix: 'git submodule update --init --recursive' before build" >&2; \
        echo "       (in Dokploy/CI, enable submodules; note 'git archive' drops them)." >&2; \
        exit 1; \
    fi; \
    echo "[build] _selected symlinks all resolve — submodules present"

COPY platform/docker/odoo.conf.template /etc/odoo/odoo.conf.template
COPY platform/docker/entrypoint.sh /usr/local/bin/odoo-entrypoint.sh
RUN chmod +x /usr/local/bin/odoo-entrypoint.sh \
    && chown -R odoo:odoo /opt/extra-addons /etc/odoo

USER odoo

ENTRYPOINT ["/usr/local/bin/odoo-entrypoint.sh"]
CMD []
