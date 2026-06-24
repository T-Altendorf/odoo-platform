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

# Create the target directory
RUN mkdir -p /mnt/extra-addons

# --- CACHE OPTIMIZATION: COPY DEPENDENCIES FIRST ---
# By copying ONLY the files needed for requirements first, Docker will cache the 
# pip install step. Changing your custom module code will no longer bust this cache.
# (The [t] and [s] wildcards prevent the build from crashing if these files/folders 
# don't exist in a specific environment).
COPY requirements.tx[t] /mnt/extra-addons/
COPY third_party_addon[s] /mnt/extra-addons/third_party_addons/

# Install python requirements.
# Set INSTALL_VENDOR_REQS=0 to skip vendor reqs for a slim, fast build.
ARG INSTALL_VENDOR_REQS=1
RUN --mount=type=cache,target=/root/.cache/pip \
    set -eux; \
    if [ "$INSTALL_VENDOR_REQS" = "1" ] && [ -d /mnt/extra-addons/third_party_addons ]; then \
        find /mnt/extra-addons/third_party_addons/_vendor \
             /mnt/extra-addons/third_party_addons/_static_vendor \
             -maxdepth 2 -name requirements.txt -print \
             -exec pip install --break-system-packages -r {} \; ; \
    fi; \
    if [ -f /mnt/extra-addons/requirements.txt ]; then \
        pip install --break-system-packages -r /mnt/extra-addons/requirements.txt; \
    fi

# --- COPY THE REST OF THE CODE ---
# Now we copy the rest of the authoritative repo (custom modules, etc.). 
# Changes here only invalidate this layer and below, saving massive time.
COPY . /mnt/extra-addons

COPY docker/odoo.conf.template /etc/odoo/odoo.conf.template
COPY docker/entrypoint.sh /usr/local/bin/gemini-entrypoint.sh
RUN chmod +x /usr/local/bin/gemini-entrypoint.sh \
    && chown -R odoo:odoo /mnt/extra-addons /etc/odoo

USER odoo

ENTRYPOINT ["/usr/local/bin/gemini-entrypoint.sh"]
CMD []