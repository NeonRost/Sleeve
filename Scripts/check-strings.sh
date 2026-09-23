#!/usr/bin/env bash
#
# check-strings.sh — compares the UI strings extracted by the compiler with the
# string catalog and reports what has no translation yet.
#
# Run after every change to visible text. Xcode only adds to the catalog when
# building in the IDE, not via xcodebuild.
#
# Copyright (C) 2026 NeonRost
# SPDX-License-Identifier: GPL-3.0-or-later
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
CATALOG="$ROOT/Sleeve/Localization/Localizable.xcstrings"

xcodebuild -project "$ROOT/Sleeve.xcodeproj" -scheme Sleeve -configuration Debug build >/dev/null
OBJROOT="$(xcodebuild -project "$ROOT/Sleeve.xcodeproj" -scheme Sleeve \
  -configuration Debug -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ OBJROOT/ {print $2}')"

python3 - "$OBJROOT" "$CATALOG" <<'PY'
import glob, json, os, subprocess, sys

objroot, catalog_path = sys.argv[1], sys.argv[2]

found = set()
for f in glob.glob(os.path.join(objroot, "Sleeve.build/Debug/**/*.stringsdata"), recursive=True):
    out = subprocess.run(["plutil", "-convert", "json", "-o", "-", f], capture_output=True)
    if out.returncode != 0:
        continue
    for entries in json.loads(out.stdout).get("tables", {}).values():
        found.update(e["key"] for e in entries if e.get("key"))

catalog = json.load(open(catalog_path, encoding="utf-8"))
known = catalog.get("strings", {})

missing = sorted(found - set(known))
orphans = sorted(set(known) - found)
untranslated = sorted(
    key for key, entry in known.items()
    if entry.get("shouldTranslate", True)
    and {"de", "es"} - set(entry.get("localizations", {}))
)

print(f"{len(found)} strings in the code, {len(known)} in the catalog\n")
for title, items in (("Missing from the catalog", missing),
                     ("In the catalog but no longer in the code", orphans),
                     ("Without de/es translation", untranslated)):
    if items:
        print(f"{title} ({len(items)}):")
        for key in items:
            print("   ", repr(key))
        print()

sys.exit(1 if (missing or untranslated) else 0)
PY
echo "✓ Catalog is complete."
