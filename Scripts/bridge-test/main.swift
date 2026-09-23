//
//  main.swift
//
//  Copyright (C) 2026 NeonRost
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <https://www.gnu.org/licenses/>.
//

import Foundation

print("═══ TagLibBridge ═══")
let bridgeResult = try BridgeTests.run()

print("\n═══ Pattern engine ═══")
let patternResult = PatternTests.run()

print("\n═══ Cover art ═══")
let artworkResult = try ArtworkTests.run()

print("\n═══ Convert ═══")
let convertResult = try await ConvertTests.run()

print("\n═══ Lookup ═══")
let lookupResult = try await LookupTests.run()

print("\n═══ Rip ═══")
let ripResult = try RipTests.run()

print("\n═══ Burn ═══")
let burnResult = try BurnTests.run()

print("\n═══ Split ═══")
let splitResult = try await SplitTests.run()

print("\n═══ Track list ═══")
let listingResult = ListingTests.run()

print("\n═══ AppState ═══")
let stateResult = try await AppStateTests.run()

exit([bridgeResult, patternResult, artworkResult, convertResult, lookupResult, ripResult, burnResult, splitResult, listingResult, stateResult].max() ?? 0)
