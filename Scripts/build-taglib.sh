#!/usr/bin/env bash
#
# build-taglib.sh — builds TagLib as a static arm64 library for Sleeve.
#
# Run once (or after changing the TagLib version).
# Result:
#   Vendor/taglib/lib/libtag.a
#   Vendor/taglib/include/taglib/*.h
#
# Copyright (C) 2026 NeonRost
# SPDX-License-Identifier: GPL-3.0-or-later
#
set -euo pipefail

TAGLIB_VERSION="v2.3.2"
DEPLOYMENT_TARGET="14.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
VENDOR="$ROOT/Vendor/taglib"
SRC="$ROOT/Vendor/src/taglib"
BUILD="$SRC/build-arm64"
PREFIX="$SRC/install-arm64"

command -v cmake >/dev/null 2>&1 || { echo "cmake is missing — 'brew install cmake'"; exit 1; }

# ── Fetch sources ────────────────────────────────────────────────────────────
if [ ! -d "$SRC/.git" ]; then
  echo "→ Cloning TagLib $TAGLIB_VERSION"
  mkdir -p "$(dirname "$SRC")"
  git clone --branch "$TAGLIB_VERSION" --depth 1 --recurse-submodules \
    https://github.com/taglib/taglib.git "$SRC"
else
  echo "→ TagLib sources present, updating to $TAGLIB_VERSION"
  git -C "$SRC" fetch --depth 1 origin tag "$TAGLIB_VERSION" --no-tags
  git -C "$SRC" checkout --force "$TAGLIB_VERSION"
  git -C "$SRC" submodule update --init --recursive --depth 1
fi

# ── Configure ────────────────────────────────────────────────────────────────
echo "→ Configuring (arm64, deployment target $DEPLOYMENT_TARGET)"
rm -rf "$BUILD" "$PREFIX"
cmake -S "$SRC" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
  -DBUILD_SHARED_LIBS=OFF \
  -DVISIBILITY_HIDDEN=ON \
  -DBUILD_TESTING=OFF \
  -DBUILD_EXAMPLES=OFF \
  -DBUILD_BINDINGS=ON \
  -DWITH_ZLIB=ON

# ── Build & install ──────────────────────────────────────────────────────────
echo "→ Building"
cmake --build "$BUILD" --config Release --parallel "$(sysctl -n hw.ncpu)"
cmake --install "$BUILD" --config Release

# ── Copy artefacts to Vendor/taglib ──────────────────────────────────────────
echo "→ Copying to Vendor/taglib"
rm -rf "$VENDOR/include" "$VENDOR/lib"
mkdir -p "$VENDOR/include" "$VENDOR/lib"
cp -R "$PREFIX/include/taglib" "$VENDOR/include/"
cp "$PREFIX/lib/libtag.a"    "$VENDOR/lib/"
# TagLib 2.x puts the C API into a library of its own (libtag_c.a).
if [ -f "$PREFIX/lib/libtag_c.a" ]; then
  cp "$PREFIX/lib/libtag_c.a" "$VENDOR/lib/"
fi

# ── Take the license texts along ─────────────────────────────────────────────
cp "$SRC/COPYING.LGPL" "$ROOT/LICENSES/taglib-LGPL-2.1.txt" 2>/dev/null || true
cp "$SRC/COPYING.MPL"  "$ROOT/LICENSES/taglib-MPL-1.1.txt"  2>/dev/null || true

echo
echo "✓ Done."
lipo -info "$VENDOR/lib/"*.a
ls "$VENDOR/include/taglib" | wc -l | xargs echo "  Headers:"
