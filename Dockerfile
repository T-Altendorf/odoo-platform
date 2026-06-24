# syntax=docker/dockerfile:1
#
# Authoritative deploy image for the gemini_addons18 Odoo 18 ecosystem.
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
#   - the repo-root requirements.txt (own / custom extras)
# Set INSTALL_VENDOR_REQS=0 to skip vendor reqs for a slim, fast build.
ARG INSTALL_VENDOR_REQS=1

# --- CACHE & PATH OPTIMIZATION: BIND MOUNT ---
# We use a read-only bind mount to expose the context files directly to pip.
# Docker caches this step entirely based on the contents of the requirements.txt files.
# Changing your custom Odoo modules (.py, .xml) will NOT invalidate this cache.
RUN --mount=type=bind,target=/tmp/src \
    --mount=type=cache,target=/root/.cache/pip \
    set -eux; \
    if [ "$INSTALL_VENDOR_REQS" = "1" ] && [ -d /tmp/src/third_party_addons ]; then \
        find /tmp/src/third_party_addons/_vendor \
             /tmp/src/third_party_addons/_static_vendor \
             -maxdepth 2 -name requirements.txt -print \
             -exec pip install --break-system-packages -r {} \; ; \
    fi; \
    if [ -f /tmp/src/requirements.txt ]; then \
        pip install --break-system-packages -r /tmp/src/requirements.txt; \
    fi

# Now copy the whole repository for runtime. 
# Modifying your code will only hit this layer and below!
COPY . /mnt/extra-addons

COPY docker/odoo.conf.template /etc/odoo/odoo.conf.template
COPY docker/entrypoint.sh /usr/local/bin/gemini-entrypoint.sh
RUN chmod +x /usr/local/bin/gemini-entrypoint.sh \
    && chown -R odoo:odoo /mnt/extra-addons /etc/odoo

USER odoo

ENTRYPOINT ["/usr/local/bin/gemini-entrypoint.sh"]
CMD []