//
//  ExtractPopover.swift
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
//  File name → tags (spec §4.4). The same pattern read backwards.
//

import SwiftUI

struct ExtractPopover: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @AppStorage("pattern.extract") private var pattern = "%track% - %title%"

    private var rows: [AppState.ExtractionPreview] {
        state.previewExtraction(pattern: pattern)
    }

    private var matchCount: Int {
        rows.count { $0.values != nil }
    }

    var body: some View {
        PopoverFrame(title: "Extract tags from file names") {
            HStack(spacing: 6) {
                TextField("Pattern", text: $pattern)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                TokenMenu(pattern: $pattern)
                presetMenu
            }

            Text("A pattern with slashes also matches folder names, e.g. %artist%/%album%/%track% - %title%")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Divider()

            HStack {
                Text("Preview")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(matchCount) of \(rows.count) match")
                    .font(.caption)
                    .foregroundStyle(matchCount == rows.count ? Color.secondary : Color.orange)
            }

            // Non-matching lines in red and skipped (spec §4.4).
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(rows.prefix(14)) { row in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: row.values == nil
                                  ? "xmark.circle.fill" : "checkmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(row.values == nil ? .red : .green)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.subject)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundStyle(row.values == nil ? Color.red : Color.primary)
                                if let values = row.values {
                                    Text(describe(values))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .font(.caption)
                    }
                    if rows.count > 14 {
                        Text("… and \(rows.count - 14) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 170)
        } actions: {
            Button("Apply") {
                state.applyExtraction(pattern)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(matchCount == 0)
        }
        .frame(width: 460)
    }

    private func describe(_ values: [TagField: String]) -> String {
        PatternToken.allCases
            .compactMap { token in
                values[token.field].map { "\(token.rawValue): \($0)" }
            }
            .joined(separator: " · ")
    }

    private var presetMenu: some View {
        Menu {
            ForEach(PatternParser.presets, id: \.self) { preset in
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
