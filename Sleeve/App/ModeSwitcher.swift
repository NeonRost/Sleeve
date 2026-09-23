//
//  ModeSwitcher.swift
//  Sleeve
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

import SwiftUI

/// The persistent switcher in the toolbar (Resolve model, spec §1.1). No
/// start window forcing a decision up front — the file list stays put when
/// the mode changes.
struct ModeSwitcher: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        Picker("Mode", selection: $state.activeMode) {
            ForEach(AppMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        // No fixed width: the segments differ in length in every language, and
        // every surplus point is missing from the buttons on the right.
        .fixedSize()
        // Unavailable modes stay visible but cannot be chosen.
        .overlay { DisabledModeOverlay() }
    }
}

/// SwiftUI's `Picker` cannot disable a single segment. The explanation
/// therefore comes as a tooltip over the switcher, and the selection is
/// reset should a locked mode get chosen anyway.
private struct DisabledModeOverlay: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .onChange(of: state.activeMode) { previous, new in
                if case .unavailable = state.availability(of: new) {
                    state.activeMode = previous
                }
            }
            .help(tooltip)
    }

    private var tooltip: String {
        let locked = AppMode.allCases.filter { !state.availability(of: $0).isAvailable }
        guard !locked.isEmpty else { return "" }
        return String(localized: "Converting and ripping arrive in later versions.")
    }
}
