//
//  main.swift
//

import Foundation

print("═══ TagLibBridge ═══")
let bridgeResult = try BridgeTests.run()

print("\n═══ Pattern-Engine ═══")
let patternResult = PatternTests.run()

print("\n═══ Coverbilder ═══")
let artworkResult = try ArtworkTests.run()

print("\n═══ Konvertieren ═══")
let convertResult = try await ConvertTests.run()

print("\n═══ Discogs-Lookup ═══")
let lookupResult = try await LookupTests.run()

print("\n═══ Rippen ═══")
let ripResult = try RipTests.run()

print("\n═══ Brennen ═══")
let burnResult = try BurnTests.run()

print("\n═══ Aufteilen ═══")
let splitResult = try await SplitTests.run()

print("\n═══ Trackliste ═══")
let listingResult = ListingTests.run()

print("\n═══ AppState ═══")
let stateResult = try await AppStateTests.run()

exit([bridgeResult, patternResult, artworkResult, convertResult, lookupResult, ripResult, burnResult, splitResult, listingResult, stateResult].max() ?? 0)
