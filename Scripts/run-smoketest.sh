#!/usr/bin/env bash
#
# run-smoketest.sh — kompiliert und startet den TagLib-Smoketest.
# Prüft, dass der statische TagLib-Build + Module-Map aus Swift heraus tragen.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
VENDOR="$ROOT/Vendor/taglib"
OUT="${TMPDIR:-/tmp}/sleeve-taglib-smoketest"

[ -f "$VENDOR/lib/libtag.a" ] || { echo "libtag.a fehlt — erst Scripts/build-taglib.sh laufen lassen"; exit 1; }

swiftc -O \
  -swift-version 6 \
  -target arm64-apple-macos14.0 \
  -I "$VENDOR" \
  -L "$VENDOR/lib" \
  -ltag_c -ltag -lz -lc++ \
  -o "$OUT" \
  "$SCRIPT_DIR/taglib-smoketest.swift"

"$OUT" "${1:-$ROOT/TestFiles}"
