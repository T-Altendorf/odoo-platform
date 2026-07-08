#!/usr/bin/env bash
# Regenerate src/third_party_addons/_selected from the product's selection.txt.
#
# Run from the PRODUCT repo root (or just `make selection`).
#
# selection.txt format — one module per line, path relative to
# src/third_party_addons/:
#
#   _vendor/oca_knowledge/document_page
#   _vendor/organize_urself/organize_urself
#   _static_vendor/auto_database_backup
#
# Blank lines and '#' comments are ignored. The symlink name is the basename.
# Symlinks in _selected that are NOT listed get pruned. Symlinks are always
# RELATIVE (../_vendor/...) — absolute links break in Docker/CI checkouts.
set -euo pipefail

SELECTION_FILE="${SELECTION:-selection.txt}"
TPA="src/third_party_addons"
SELECTED="$TPA/_selected"

[ -f "$SELECTION_FILE" ] || { echo "ERROR: $SELECTION_FILE not found (run from the product repo root)" >&2; exit 1; }
[ -d "$TPA" ] || { echo "ERROR: $TPA not found (run from the product repo root)" >&2; exit 1; }
mkdir -p "$SELECTED"

# Collect wanted module names + create/refresh links.
wanted=()
while IFS= read -r line; do
    line="${line%%#*}"                      # strip trailing comments
    line="$(echo "$line" | xargs)"          # trim
    [ -z "$line" ] && continue
    name="$(basename "$line")"
    target="../$line"
    wanted+=("$name")
    if [ ! -e "$TPA/$line" ]; then
        echo "WARN: $TPA/$line does not exist (submodule not initialized?) — linking anyway" >&2
    elif [ ! -e "$TPA/$line/__manifest__.py" ]; then
        echo "WARN: $TPA/$line has no __manifest__.py — is this an Odoo module?" >&2
    fi
    ln -snf "$target" "$SELECTED/$name"
    echo "  link  $name -> $target"
done < "$SELECTION_FILE"

# Prune symlinks not in the selection.
for existing in "$SELECTED"/*; do
    [ -e "$existing" ] || [ -L "$existing" ] || continue
    name="$(basename "$existing")"
    if [ ! -L "$existing" ]; then
        echo "WARN: $SELECTED/$name is not a symlink — leaving it alone" >&2
        continue
    fi
    keep=0
    for w in "${wanted[@]}"; do [ "$w" = "$name" ] && keep=1 && break; done
    if [ "$keep" = 0 ]; then
        rm "$existing"
        echo "  prune $name"
    fi
done

echo "done: $SELECTED reflects $SELECTION_FILE (${#wanted[@]} modules). Commit the symlinks."
