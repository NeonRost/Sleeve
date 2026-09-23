//
//  NumberingPopover.swift
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

/// Numbering (spec §4.2).
struct NumberingPopover: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var options = NumberingOptions()

    var body: some View {
        PopoverFrame(title: "Numbering") {
            Toggle("Write total (03/12)", isOn: $options.writesTotal)
            Toggle("Leading zeros in file names", isOn: $options.padsNumbers)
            Toggle("Restart numbering on each disc", isOn: $options.restartsPerDisc)

            Divider()

            Text("Numbers \(state.operationTargets.count) tracks in the current sort order.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } actions: {
            Button("Apply") {
                state.applyNumbering(options)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(state.operationTargets.isEmpty)
        }
    }
}
