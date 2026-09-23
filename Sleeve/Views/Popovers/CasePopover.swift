//
//  CasePopover.swift
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

/// Capitalization (spec §4.3).
struct CasePopover: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var textCase: TextCase = .titleCase
    @State private var language: TextCase.Language = .english
    @State private var fields: Set<TagField> = [.title, .artist, .album, .albumArtist]

    var body: some View {
        PopoverFrame(title: "Capitalization") {
            Picker("Style", selection: $textCase) {
                ForEach(TextCase.allCases) { style in
                    Text(style.label).tag(style)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            if textCase == .titleCase {
                Picker("Language", selection: $language) {
                    ForEach(TextCase.Language.allCases) { value in
                        Text(value.label).tag(value)
                    }
                }
                .help("Decides which short words stay lowercase")
            }

            Divider()

            Text("Apply to")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Applies to all fields or only to chosen ones (spec §4.3).
            ForEach(AppState.textFields, id: \.self) { field in
                Toggle(label(for: field), isOn: Binding(
                    get: { fields.contains(field) },
                    set: { isOn in
                        if isOn { fields.insert(field) } else { fields.remove(field) }
                    }
                ))
            }
        } actions: {
            Button("Apply") {
                state.applyCase(textCase, language: language, fields: fields)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(fields.isEmpty || state.operationTargets.isEmpty)
        }
    }

    private func label(for field: TagField) -> LocalizedStringKey {
        switch field {
        case .title:       "Title"
        case .artist:      "Artist"
        case .albumArtist: "Album artist"
        case .album:       "Album"
        case .composer:    "Composer"
        case .genre:       "Genre"
        case .comment:     "Comment"
        default:           "—"
        }
    }
}
