#!/usr/bin/env bash
#
# build-icon.sh — builds the complete app icon from the SVG sources.
#
# Produces: Icon/*.svg, Icon/layers/, Icon/Sleeve.icon/, Icon/Sleeve.icns,
#           Icon/preview-sizes.png
#
# Requires: rsvg-convert (brew install librsvg), iconutil (Xcode).
#
# Copyright (C) 2026 NeonRost
# SPDX-License-Identifier: GPL-3.0-or-later
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
ICON="$ROOT/Icon"
ICONSET="$ICON/Sleeve.iconset"

command -v rsvg-convert >/dev/null || { echo "rsvg-convert is missing — 'brew install librsvg'"; exit 1; }

# ── 1. Generate the SVG sources ─────────────────────────────────────────────
python3 "$SCRIPT_DIR/make-icon-svg.py"

# ── 2. Classic .icns ────────────────────────────────────────────────────────
# iconutil expects exactly these file names. 16–512 each @1x and @2x; the
# 1024 one is icon_512x512@2x by convention.
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

# ── 3. Contact sheet for review ─────────────────────────────────────────────
echo "contact sheet:"
python3 "$SCRIPT_DIR/make-icon-preview.py"

echo
echo "✓ Done."
