//
//  NumberingPopover.swift
//  Sleeve
//

import SwiftUI

/// Nummerierung (Spec §4.2).
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
