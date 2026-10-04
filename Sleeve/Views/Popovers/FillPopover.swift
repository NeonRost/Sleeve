//
//  FillPopover.swift
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
//  Fill one field from a pattern (spec §4.3.2). Like every batch operation
//  it shows what will happen before anything happens.
//

import SwiftUI

struct FillPopover: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @AppStorage("fill.field") private var fieldName = TagField.title.rawValue
    @AppStorage("fill.pattern") private var pattern = "%filename%"
    @State private var padsNumbers = false

    private static let previewRows = 6

    /// Ready-made patterns for the usual cases.
    private static let presets = [
        "%filename%",
        "%artist%",
        "%track% %title%",
        "%artist% - %title%",
        "%folder%",
    ]

    private var field: TagField { TagField(rawValue: fieldName) ?? .title }

    private var format: FieldFormat {
        FieldFormat(pattern: pattern, padsNumbers: padsNumbers)
    }

    var body: some View {
        let changes = state.formatPreview(format, field: field)
        PopoverFrame(title: "Fill a field") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("Field").fixedSize().gridColumnAlignment(.trailing)
                    Picker("Field", selection: $fieldName) {
                        ForEach(AppState.textFields, id: \.self) { field in
                            Text(field.takeOverLabel).tag(field.rawValue)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    Text("Pattern").fixedSize()
                    HStack(spacing: 6) {
                        TextField("Pattern", text: $pattern)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 180)
                        placeholderMenu
                        presetMenu
                    }
                }
            }

            Text("%filename% is the file name without extension, %folder% the folder it is in.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Leading zeros", isOn: $padsNumbers)

            if !pattern.isEmpty, !format.containsToken {
                Label("The pattern has no placeholder — every track would get the same text.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            if changes.isEmpty {
                Text(format.containsToken
                     ? "Nothing would change."
                     : "Enter a pattern with a placeholder.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Changes: \(changes.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(changes.prefix(Self.previewRows)) { change in
                        ChangeRow(change: change)
                    }
                    if changes.count > Self.previewRows {
                        Text("and \(changes.count - Self.previewRows) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } actions: {
            Button("Apply") {
                state.applyFormat(format, field: field)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(changes.isEmpty)
        }
        .frame(width: 380)
    }

    /// The tag placeholders and the two about the file.
    private var placeholderMenu: some View {
        Menu {
            ForEach(PatternToken.allCases) { token in
                Button(token.placeholder) { pattern += token.placeholder }
            }
            Divider()
            ForEach(FieldFormat.FileToken.allCases, id: \.self) { token in
                Button(token.placeholder) { pattern += token.placeholder }
            }
        } label: {
            Image(systemName: "curlybraces")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Insert a placeholder")
    }

    private var presetMenu: some View {
        Menu {
            ForEach(Self.presets, id: \.self) { preset in
                Button(preset) { pattern = preset }
            }
        } label: {
            Image(systemName: "list.bullet")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Presets")
    }
}
