#!/usr/bin/env python3
"""Collect pip deps from Odoo manifests for modules NOT covered by a requirements.txt.

Some vendors (Cybrosys/_static_vendor) declare python deps only in the
manifest's external_dependencies and ship no requirements.txt, so the
Dockerfile's requirements sweep never installs them and module install fails
at runtime with "No package metadata was found for <dep>".

Since Odoo 17, external_dependencies['python'] entries are checked via
importlib.metadata as *distribution* names (PEP 508 specs allowed), i.e. they
are pip-installable by definition — so feeding them to pip matches Odoo's own
check semantics exactly.

Usage:
    manifest-pydeps.py ROOT [ROOT...] > reqs.txt

For each ROOT, scans ROOT/*/__manifest__.py (static-vendor layout) and
ROOT/*/*/__manifest__.py (vendor <repo>/<module> layout; OCA `setup/` copies
are deeper and thus never matched). A module is SKIPPED when a
requirements.txt exists in its own dir or any ancestor up to ROOT — the
vendor's pinned file wins; this is a fallback, not an override.

Prints the deduped dep specs one per line (pip -r compatible) on stdout;
per-module attribution and parse warnings go to stderr. Never fails the
build on a broken manifest — Odoo will complain about those on its own.
"""
import ast
import sys
from pathlib import Path


def covered_by_requirements(module_dir: Path, root: Path) -> bool:
    """True if a requirements.txt governs this module (module dir or any
    ancestor up to and including ROOT's direct children)."""
    d = module_dir
    while True:
        if (d / "requirements.txt").is_file():
            return True
        if d == root:
            return False
        d = d.parent


def manifest_pydeps(manifest: Path):
    data = ast.literal_eval(manifest.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError("manifest is not a dict")
    deps = data.get("external_dependencies", {}).get("python", [])
    return [d.strip() for d in deps if isinstance(d, str) and d.strip()]


def main(roots):
    seen = {}  # spec -> first module that wanted it
    for root_arg in roots:
        root = Path(root_arg)
        if not root.is_dir():
            print(f"manifest-pydeps: skipping missing root {root}", file=sys.stderr)
            continue
        manifests = sorted(
            list(root.glob("*/__manifest__.py")) + list(root.glob("*/*/__manifest__.py"))
        )
        for manifest in manifests:
            module_dir = manifest.parent
            if covered_by_requirements(module_dir, root):
                continue
            try:
                deps = manifest_pydeps(manifest)
            except Exception as exc:  # noqa: BLE001 — tolerate vendor junk
                print(f"manifest-pydeps: WARN cannot parse {manifest}: {exc}", file=sys.stderr)
                continue
            for dep in deps:
                if dep not in seen:
                    seen[dep] = module_dir.name
                    print(f"manifest-pydeps: {dep}  (from {module_dir.name})", file=sys.stderr)
    for dep in sorted(seen):
        print(dep)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    main(sys.argv[1:])
