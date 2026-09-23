#!/usr/bin/env bash
#
# check-strings.sh — vergleicht die vom Compiler extrahierten UI-Texte mit dem
# String-Catalog und meldet, was noch keine Übersetzung hat.
#
# Nach jeder Änderung an sichtbaren Texten laufen lassen. Xcode ergänzt den
# Katalog beim Bauen nur in der IDE, nicht über xcodebuild.
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

print(f"{len(found)} Texte im Code, {len(known)} im Katalog\n")
for title, items in (("Ohne Katalogeintrag", missing),
                     ("Im Katalog, aber nicht mehr im Code", orphans),
                     ("Ohne de/es-Übersetzung", untranslated)):
    if items:
        print(f"{title} ({len(items)}):")
        for key in items:
            print("   ", repr(key))
        print()

sys.exit(1 if (missing or untranslated) else 0)
PY
echo "✓ Katalog ist vollständig."
