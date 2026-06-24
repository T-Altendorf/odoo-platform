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

# The whole authoritative repo (custom modules + third_party_addons incl.
# populated _vendor submodules and _selected symlinks) lands here.
COPY . /mnt/extra-addons

# Install python requirements.
#   - every third_party_addons/{_vendor,_static_vendor}/*/requirements.txt
#   - the repo-root requirements.txt (own / custom extras)
# Set INSTALL_VENDOR_REQS=0 to skip vendor reqs for a slim, fast build.
ARG INSTALL_VENDOR_REQS=1
RUN set -eux; \
    if [ "$INSTALL_VENDOR_REQS" = "1" ]; then \
        find /mnt/extra-addons/third_party_addons/_vendor \
             /mnt/extra-addons/third_party_addons/_static_vendor \
             -maxdepth 2 -name requirements.txt -print \
             -exec pip install --no-cache-dir --break-system-packages -r {} \; ; \
    fi; \
    if [ -f /mnt/extra-addons/requirements.txt ]; then \
        pip install --no-cache-dir --break-system-packages -r /mnt/extra-addons/requirements.txt; \
    fi

COPY docker/odoo.conf.template /etc/odoo/odoo.conf.template
COPY docker/entrypoint.sh /usr/local/bin/gemini-entrypoint.sh
RUN chmod +x /usr/local/bin/gemini-entrypoint.sh \
    && chown -R odoo:odoo /mnt/extra-addons /etc/odoo

USER odoo

ENTRYPOINT ["/usr/local/bin/gemini-entrypoint.sh"]
CMD []
