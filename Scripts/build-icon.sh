#!/usr/bin/env bash
#
# build-icon.sh — baut das komplette App-Icon aus den SVG-Quellen.
#
# Erzeugt:  Icon/*.svg, Icon/layers/, Icon/Sleeve.icon/, Icon/Sleeve.icns,
#           Icon/preview-sizes.png
#
# Voraussetzung: rsvg-convert (brew install librsvg), iconutil (Xcode).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
ICON="$ROOT/Icon"
ICONSET="$ICON/Sleeve.iconset"

command -v rsvg-convert >/dev/null || { echo "rsvg-convert fehlt — 'brew install librsvg'"; exit 1; }

# ── 1. SVG-Quellen erzeugen ─────────────────────────────────────────────────
python3 "$SCRIPT_DIR/make-icon-svg.py"

# ── 2. Klassisches .icns ────────────────────────────────────────────────────
# iconutil erwartet genau diese Dateinamen. 16–512 jeweils @1x und @2x; das
# 1024er ist per Konvention icon_512x512@2x.
echo "iconset:"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for base in 16 32 128 256 512; do
  rsvg-convert -w "$base" -h "$base" "$ICON/sleeve-icon-master.svg" \
    -o "$ICONSET/icon_${base}x${base}.png"
  rsvg-convert -w "$((base * 2))" -h "$((base * 2))" "$ICON/sleeve-icon-master.svg" \
    -o "$ICONSET/icon_${base}x${base}@2x.png"
done
iconutil -c icns "$ICONSET" -o "$ICON/Sleeve.icns"
rm -rf "$ICONSET"
echo "   Icon/Sleeve.icns ($(du -h "$ICON/Sleeve.icns" | cut -f1))"

# ── 3. Kontaktabzug für die Abnahme ─────────────────────────────────────────
echo "Kontaktabzug:"
python3 "$SCRIPT_DIR/make-icon-preview.py"

echo
echo "✓ Fertig."
