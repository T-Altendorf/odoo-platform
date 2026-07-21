#!/usr/bin/env bash
# Keep selection_reasons.md honest: every module the product loads — vendor
# modules from selection.txt AND first-party modules in src/custom_addons/ —
# must carry a one-line "why do we have this" entry:
#
#   - `module_name` — why this module is part of the product.
#
# Entries can live anywhere in the document (group them by concern, not by
# vendor). Two modes:
#
#   --sync   (run by `make selection`) create the file if missing and append a
#            TODO stub for every undocumented module inside the marked
#            "unsorted" section. Move the stub to its concern section and
#            replace the TODO with a real reason.
#   --check  (run by the pre-commit hook) fail listing every module that has
#            no entry or still says TODO.
#
# Run from the PRODUCT repo root.
set -euo pipefail

MODE="${1:---check}"
REASONS="${REASONS_FILE:-selection_reasons.md}"
SELECTION_FILE="${SELECTION:-selection.txt}"
CUSTOM="src/custom_addons"
BEGIN_MARK="<!-- unsorted-modules:begin (make selection appends stubs here) -->"
END_MARK="<!-- unsorted-modules:end -->"

# Every module name the product loads, one per line.
modules() {
    if [ -f "$SELECTION_FILE" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            line="${line%%#*}"
            line="$(echo "$line" | xargs)"
            [ -z "$line" ] && continue
            basename "$line"
        done < "$SELECTION_FILE"
    fi
    if [ -d "$CUSTOM" ]; then
        for dir in "$CUSTOM"/*/; do
            [ -f "$dir/__manifest__.py" ] || continue
            basename "$dir"
        done
    fi
}

# The entry line for a module, if any: a list bullet starting with `name`.
entry_line() {
    # `|| :` — under set -e -o pipefail a no-match grep would kill the script.
    grep -E "^[[:space:]]*[-*][[:space:]]+\`$1\`" "$REASONS" 2>/dev/null | head -1 || :
}

case "$MODE" in
--sync)
    if [ ! -f "$REASONS" ]; then
        cat > "$REASONS" <<EOF
# Module selection — why we load what we load

One entry per loaded module (vendor from \`selection.txt\` + first-party from
\`src/custom_addons/\`), grouped by concern. Format (enforced by pre-commit):

    - \`module_name\` — one line: why this product needs it.

\`make selection\` appends stubs for new modules below; move each stub into
its concern section and write the reason.

$BEGIN_MARK
$END_MARK
EOF
        echo "created $REASONS"
    fi
    if ! grep -qF "$BEGIN_MARK" "$REASONS"; then
        printf '\n%s\n%s\n' "$BEGIN_MARK" "$END_MARK" >> "$REASONS"
    fi
    stubs=""
    while IFS= read -r name; do
        [ -n "$(entry_line "$name")" ] && continue
        stubs="${stubs}- \`$name\` — TODO: why do we load this?\n"
    done < <(modules | sort -u)
    if [ -n "$stubs" ]; then
        awk -v marker="$END_MARK" -v stubs="$stubs" \
            'index($0, marker) { printf "%s", stubs } { print }' \
            "$REASONS" > "$REASONS.tmp" && mv "$REASONS.tmp" "$REASONS"
        printf "added stubs to $REASONS:\n$stubs"
        echo "-> fill in the whys (pre-commit fails on TODO entries)"
    fi
    ;;
--check)
    missing=""
    todo=""
    while IFS= read -r name; do
        line="$(entry_line "$name")"
        if [ -z "$line" ]; then
            missing="$missing $name"
        elif printf '%s' "$line" | grep -q "TODO"; then
            todo="$todo $name"
        fi
    done < <(modules | sort -u)
    if [ -n "$missing$todo" ]; then
        [ -n "$missing" ] && echo "ERROR: no entry in $REASONS for:$missing" >&2
        [ -n "$todo" ] && echo "ERROR: TODO entry in $REASONS for:$todo" >&2
        echo "Each loaded module needs: - \`name\` — <why we have it>." >&2
        echo "Run 'make selection' to append stubs, then write the reasons." >&2
        exit 1
    fi
    ;;
*)
    echo "usage: selection-reasons.sh [--sync|--check]" >&2
    exit 2
    ;;
esac
