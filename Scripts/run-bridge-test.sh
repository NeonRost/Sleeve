#!/usr/bin/env bash
#
# run-bridge-test.sh — compiles the app's model and engine code together with
# the checks in Scripts/bridge-test/ and runs them against copies of TestFiles/.
#
# Copyright (C) 2026 NeonRost
# SPDX-License-Identifier: GPL-3.0-or-later
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
VENDOR="$ROOT/Vendor/taglib"
CDSHIM="$ROOT/Vendor/cdshim"
OUT="${TMPDIR:-/tmp}/sleeve-bridge-test"

swiftc -g \
  -swift-version 6 \
  -target arm64-apple-macos14.0 \
  -I "$VENDOR" \
  -I "$CDSHIM" \
  -L "$VENDOR/lib" \
  -ltag_c -ltag -lz -lc++ \
  -o "$OUT" \
  "$ROOT/Sleeve/Model/AudioTags.swift" \
  "$ROOT/Sleeve/Model/Artwork.swift" \
  "$ROOT/Sleeve/TagEngine/PropertyKeys.swift" \
  "$ROOT/Sleeve/TagEngine/TagLibBridge.swift" \
  "$ROOT/Sleeve/TagEngine/TagEngine.swift" \
  "$ROOT/Sleeve/Model/TrackFile.swift" \
  "$ROOT/Sleeve/Pattern/PatternToken.swift" \
  "$ROOT/Sleeve/Pattern/PatternRenderer.swift" \
  "$ROOT/Sleeve/Pattern/PatternParser.swift" \
  "$ROOT/Sleeve/Pattern/TextCase.swift" \
  "$ROOT/Sleeve/Pattern/TextReplacement.swift" \
  "$ROOT/Sleeve/Pattern/Numbering.swift" \
  "$ROOT/Sleeve/Model/ArtworkProcessor.swift" \
  "$ROOT/Sleeve/Model/MusicApp.swift" \
  "$ROOT/Sleeve/Convert/AudioFormat.swift" \
  "$ROOT/Sleeve/Convert/ProcessRunner.swift" \
  "$ROOT/Sleeve/Convert/FFmpegLocator.swift" \
  "$ROOT/Sleeve/Convert/ConversionPlanner.swift" \
  "$ROOT/Sleeve/Convert/ConversionQueue.swift" \
  "$ROOT/Sleeve/Rip/DiscTOC.swift" \
  "$ROOT/Sleeve/Rip/CDText.swift" \
  "$ROOT/Sleeve/Rip/RipSettings.swift" \
  "$ROOT/Sleeve/Rip/CDDrive.swift" \
  "$ROOT/Sleeve/Rip/CDReader.swift" \
  "$ROOT/Sleeve/Rip/WAVWriter.swift" \
  "$ROOT/Sleeve/Rip/RipReport.swift" \
  "$ROOT/Sleeve/Rip/DiscImage.swift" \
  "$ROOT/Sleeve/Rip/CueSheet.swift" \
  "$ROOT/Sleeve/Rip/CDBurner.swift" \
  "$ROOT/Sleeve/Split/AudioSplitter.swift" \
  "$ROOT/Sleeve/Split/SplitPreview.swift" \
  "$ROOT/Sleeve/Split/SplitTrack.swift" \
  "$ROOT/Sleeve/Split/TrackListing.swift" \
  "$ROOT/Sleeve/Split/WaveformSampler.swift" \
  "$ROOT/Sleeve/Rip/RipEngine.swift" \
  "$ROOT/Sleeve/Lookup/JSONSanitizer.swift" \
  "$ROOT/Sleeve/Lookup/RateLimiter.swift" \
  "$ROOT/Sleeve/Lookup/LookupModels.swift" \
  "$ROOT/Sleeve/Lookup/DiscogsModels.swift" \
  "$ROOT/Sleeve/Lookup/MusicBrainzClient.swift" \
  "$ROOT/Sleeve/Lookup/DiscogsClient.swift" \
  "$ROOT/Sleeve/Lookup/ReleaseMatcher.swift" \
  "$ROOT/Sleeve/Lookup/KeychainStore.swift" \
  "$ROOT/Sleeve/Lookup/LookupService.swift" \
  "$ROOT/Sleeve/Lookup/ReleaseSearch.swift" \
  "$ROOT/Sleeve/Lookup/LookupSession.swift" \
  "$ROOT/Sleeve/Lookup/DiscLookupSession.swift" \
  "$ROOT/Sleeve/Model/TrackListModel.swift" \
  "$ROOT/Sleeve/App/AppState.swift" \
  "$ROOT/Sleeve/App/AppState+Convert.swift" \
  "$ROOT/Sleeve/App/AppState+Operations.swift" \
  "$ROOT/Sleeve/App/AppState+Rip.swift" \
  "$ROOT/Sleeve/App/AppState+Lookup.swift" \
  "$ROOT/Sleeve/App/AppState+DiscImage.swift" \
  "$ROOT/Sleeve/App/AppState+Burn.swift" \
  "$ROOT/Sleeve/App/AppState+Copy.swift" \
  "$ROOT/Sleeve/App/AppState+Split.swift" \
  "$SCRIPT_DIR/bridge-test/BridgeTests.swift" \
  "$SCRIPT_DIR/bridge-test/AppStateTests.swift" \
  "$SCRIPT_DIR/bridge-test/PatternTests.swift" \
  "$SCRIPT_DIR/bridge-test/ArtworkTests.swift" \
  "$SCRIPT_DIR/bridge-test/ConvertTests.swift" \
  "$SCRIPT_DIR/bridge-test/LookupTests.swift" \
  "$SCRIPT_DIR/bridge-test/RipTests.swift" \
  "$SCRIPT_DIR/bridge-test/BurnTests.swift" \
  "$SCRIPT_DIR/bridge-test/SplitTests.swift" \
  "$SCRIPT_DIR/bridge-test/ListingTests.swift" \
  "$SCRIPT_DIR/bridge-test/main.swift"

cd "$ROOT" && "$OUT"
