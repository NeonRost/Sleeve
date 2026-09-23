//
//  AllInOnePopover.swift
//  Sleeve
//
//  Makro über Nummerierung → Schreibweise → Dateibenennung → Speichern.
//  Reine Verkettung, keine eigene Logik (Spec §4.4).
//

import SwiftUI

struct AllInOnePopover: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var doesNumbering = true
    @State private var doesCase = true
    @State private var doesRenaming = true
    @State private var saves = true

    @State private var textCase: TextCase = .titleCase
    @State private var language: TextCase.Language = .english
    @AppStorage("pattern.filename") private var pattern = "%track% - %artist% - %title%"

    var body: some View {
        PopoverFrame(title: "All in One") {
            Toggle("Renumber tracks", isOn: $doesNumbering)

            Toggle("Fix capitalization", isOn: $doesCase)
            if doesCase {
                HStack {
                    Picker("", selection: $textCase) {
                        ForEach(TextCase.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .labelsHidden()
                    if textCase == .titleCase {
                        Picker("", selection: $language) {
                            ForEach(TextCase.Language.allCases) { value in
                                Text(value.label).tag(value)
                            }
                        }
                        .labelsHidden()
                    }
                }
                .padding(.leading, 18)
            }

            Toggle("Rename files", isOn: $doesRenaming)
            if doesRenaming {
                TextField("Pattern", text: $pattern)
                    .textFieldStyle(.roundedBorder)
                    .padding(.leading, 18)
            }

            Divider()
            Toggle("Write to disk afterwards", isOn: $saves)

            Text("Runs on \(state.operationTargets.count) tracks.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } actions: {
            Button("Run") {
                let options = AppState.AllInOneOptions(
                    numbering: doesNumbering ? NumberingOptions() : nil,
                    textCase: doesCase ? textCase : nil,
                    language: language,
                    caseFields: Set(AppState.textFields),
                    filenamePattern: doesRenaming ? pattern : nil,
                    savesAfterwards: saves
                )
                dismiss()
                Task { await state.applyAllInOne(options) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(state.operationTargets.isEmpty)
        }
        .frame(width: 380)
    }
}
