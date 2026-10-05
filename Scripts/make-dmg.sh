#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds Sleeve in Release and wraps it in a disk image — open it, drag
# Sleeve onto Applications — plus a .zip of the app, as for MIKE and TOM.
#
# The create-dmg call lives here rather than in someone's shell history: the
# icon positions are tuned to the background (Scripts/make-dmg-background.py),
# so a rebuild from memory would quietly misplace them.
#
#   Scripts/make-dmg.sh      # → Sleeve-<version>-arm64.dmg and .zip in the project folder
#
# Needs create-dmg (brew install create-dmg). It arranges the window through
# the Finder, so the first run asks once for permission to control it.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
BUILD_DIR="$ROOT/.build-release"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

command -v create-dmg >/dev/null || { echo "create-dmg not found — brew install create-dmg" >&2; exit 1; }

echo "==> Building Release"
rm -rf "$BUILD_DIR"
xcodebuild -project Sleeve.xcodeproj -scheme Sleeve -configuration Release \
  -derivedDataPath "$BUILD_DIR" build >/dev/null

APP="$BUILD_DIR/Build/Products/Release/Sleeve.app"
[ -d "$APP" ] || { echo "Build produced no app bundle" >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
ARCH=$(lipo -archs "$APP/Contents/MacOS/Sleeve")
NAME="Sleeve-$VERSION-$ARCH"

# What a successful build does not guarantee, checked on the bundle itself:
# TagLib is arm64-only, and a build without ARCHS = arm64 links without it
# (spec §2.1.1); the license texts are resources the About window shows.
[ "$ARCH" = "arm64" ] || { echo "Expected an arm64 binary, got: $ARCH" >&2; exit 1; }
# (Counted, not grep -q: that stops reading early, nm dies of SIGPIPE, and
# pipefail turns a hit into a failure.)
[ "$(nm "$APP/Contents/MacOS/Sleeve" | grep -c "taglib_")" -gt 0 ] \
  || { echo "TagLib is not linked into the binary" >&2; exit 1; }
[ -n "$(ls "$APP/Contents/Resources" | grep -i -E "lgpl|gpl")" ] \
  || { echo "License texts missing from the bundle" >&2; exit 1; }

echo "==> Drawing the background"
python3 "$ROOT/Scripts/make-dmg-background.py" >/dev/null

echo "==> Packaging $NAME.dmg"
rm -f "$ROOT/$NAME.dmg" "$ROOT/$NAME.zip"
ditto "$APP" "$STAGE/Sleeve.app"

# 160 pt icons at the same places as MIKE's and TOM's; the labels end above
# the disc that rises from the bottom of the background.
create-dmg \
  --volname "Sleeve $VERSION" \
  --volicon "$ROOT/Icon/Sleeve.icns" \
  --background "$ROOT/Scripts/dmg-background.png" \
  --window-pos 200 120 \
  --window-size 660 430 \
  --icon-size 160 \
  --icon "Sleeve.app" 175 165 \
  --hide-extension "Sleeve.app" \
  --app-drop-link 485 165 \
  --no-internet-enable \
  "$ROOT/$NAME.dmg" "$STAGE" >/dev/null

echo "==> Packaging $NAME.zip"
ditto -c -k --keepParent "$STAGE/Sleeve.app" "$ROOT/$NAME.zip"

echo "==> Done:"
echo "    $NAME.dmg ($(du -h "$ROOT/$NAME.dmg" | cut -f1 | tr -d ' '))"
echo "    $NAME.zip ($(du -h "$ROOT/$NAME.zip" | cut -f1 | tr -d ' '))"
echo "    Ad-hoc signed and not notarized, so Gatekeeper refuses it on first"
echo "    launch — the README's 'Open Anyway' step covers that."
