#!/usr/bin/env bash
#
# run-smoketest.sh — compiles and runs the TagLib smoke test.
# Checks that the static TagLib build and module map work from Swift.
#
# Copyright (C) 2026 NeonRost
# SPDX-License-Identifier: GPL-3.0-or-later
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
VENDOR="$ROOT/Vendor/taglib"
OUT="${TMPDIR:-/tmp}/sleeve-taglib-smoketest"

[ -f "$VENDOR/lib/libtag.a" ] || { echo "libtag.a is missing — run Scripts/build-taglib.sh first"; exit 1; }

swiftc -O \
  -swift-version 6 \
  -target arm64-apple-macos14.0 \
  -I "$VENDOR" \
  -L "$VENDOR/lib" \
  -ltag_c -ltag -lz -lc++ \
  -o "$OUT" \
  "$SCRIPT_DIR/taglib-smoketest.swift"

"$OUT" "${1:-$ROOT/TestFiles}"
