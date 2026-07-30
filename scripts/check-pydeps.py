#!/usr/bin/env python3
"""Fail the build when a module that WILL be loaded misses a python dep.

Odoo checks external_dependencies at install time, but a module that is
already installed in a database is imported at registry load before anything
checks anything: a missing dep then takes the whole server down with a bare
ModuleNotFoundError, in production, on every boot (see the llm_tool/pydantic
incident). The image, not the running server, is where that has to fail.

Usage:
    check-pydeps.py ROOT [ROOT...]

Scans ROOT/*/__manifest__.py (module per dir, e.g. custom_addons and the
_selected symlink farm) and resolves every external_dependencies['python']
entry through importlib.metadata, exactly like Odoo does. Prints what is
missing and exits 1; exits 0 when everything resolves.
"""
import ast
import re
import sys
from importlib.metadata import PackageNotFoundError, distribution
from pathlib import Path

# "pydantic>=2.0.0", "pillow[extra]", "foo ; python_version>'3'" -> "pydantic"
_NAME = re.compile(r"^[A-Za-z0-9._-]+")


def dist_name(spec):
    match = _NAME.match(spec.strip())
    return match.group(0) if match else ""


def manifest_pydeps(manifest):
    data = ast.literal_eval(manifest.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        return []
    deps = data.get("external_dependencies", {}).get("python", [])
    return [d.strip() for d in deps if isinstance(d, str) and d.strip()]


def main(roots):
    missing = {}  # dist name -> modules that need it
    checked = 0
    for root_arg in roots:
        root = Path(root_arg)
        if not root.is_dir():
            print(f"check-pydeps: skipping missing root {root}", file=sys.stderr)
            continue
        for manifest in sorted(root.glob("*/__manifest__.py")):
            try:
                deps = manifest_pydeps(manifest)
            except Exception as exc:  # noqa: BLE001 - tolerate vendor junk
                print(f"check-pydeps: WARN cannot parse {manifest}: {exc}",
                      file=sys.stderr)
                continue
            checked += 1
            for dep in deps:
                name = dist_name(dep)
                if not name:
                    continue
                try:
                    distribution(name)
                except PackageNotFoundError:
                    missing.setdefault(name, []).append(manifest.parent.name)
    if missing:
        print("", file=sys.stderr)
        print("ERROR: python dependencies of selected modules are not installed:",
              file=sys.stderr)
        for name in sorted(missing):
            print(f"  - {name}  (needed by {', '.join(sorted(set(missing[name])))})",
                  file=sys.stderr)
        print("", file=sys.stderr)
        print("       These modules would import-crash the server at registry", file=sys.stderr)
        print("       load. Either install the dep (vendor requirements.txt or", file=sys.stderr)
        print("       the product's requirements.txt) or drop the module from", file=sys.stderr)
        print("       third_party_addons/selection.txt.", file=sys.stderr)
        print("       INSTALL_VENDOR_REQS=0 skips every vendor requirements.txt", file=sys.stderr)
        print("       - a slim build has to curate deps by hand.", file=sys.stderr)
        return 1
    print(f"[build] python deps of {checked} modules all resolve")
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1:]))
