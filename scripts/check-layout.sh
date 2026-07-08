#!/usr/bin/env bash
# Enforce the src/ layout contract.
#
# EXACTLY two dirs may live under src/:
#   custom_addons/       first-party modules   (on addons_path)
#   third_party_addons/  everything vendored   (only _selected is on addons_path)
#
# addons_path lists only custom_addons + third_party_addons/_selected, so a
# module dropped anywhere else under src/ would silently fail to load. This
# guard turns that silent failure into a loud one. Run from the PRODUCT repo
# root (or `make check`).
set -euo pipefail

SRC="src"
ALLOWED=("custom_addons" "third_party_addons")

[ -d "$SRC" ] || { echo "ERROR: $SRC/ not found (run from the product repo root)" >&2; exit 1; }

bad=0
for entry in "$SRC"/*; do
    [ -e "$entry" ] || continue                # empty glob
    name="$(basename "$entry")"
    ok=0
    for a in "${ALLOWED[@]}"; do [ "$name" = "$a" ] && ok=1 && break; done
    if [ "$ok" = 0 ]; then
        echo "ERROR: src/$name is not allowed under src/." >&2
        bad=1
    fi
done

if [ "$bad" != 0 ]; then
    echo "       Only these may live under src/: ${ALLOWED[*]}" >&2
    echo "       Put first-party modules in src/custom_addons/, vendored ones under src/third_party_addons/." >&2
    exit 1
fi

echo "src/ layout OK: only ${ALLOWED[*]}"
