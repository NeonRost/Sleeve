//
//  CasePopover.swift
//  Sleeve
//

import SwiftUI

/// Schreibweise (Spec §4.3).
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

            // Auf alle oder nur auf ausgewählte Felder anwendbar (Spec §4.3).
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
