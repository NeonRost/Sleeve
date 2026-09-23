//
//  FilenamePopover.swift
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
//  Tags → file name (spec §4.4). Live preview before anything happens.
//

import SwiftUI

struct FilenamePopover: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @AppStorage("pattern.filename") private var pattern = "%track% - %artist% - %title%"
    @State private var padsNumbers = true

    private var preview: [(TrackFile, String)] {
        state.previewFilenames(pattern: pattern, padsNumbers: padsNumbers)
    }

    var body: some View {
        PopoverFrame(title: "File naming") {
            HStack(spacing: 6) {
                TextField("Pattern", text: $pattern)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                TokenMenu(pattern: $pattern)
                presetMenu
            }

            Toggle("Leading zeros", isOn: $padsNumbers)

            if !PatternSyntax.containsToken(pattern) {
                Label("The pattern has no placeholder — every file would get the same name.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Divider()

            Text("Preview")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Preview before anything happens (spec §4.4).
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(preview.prefix(12), id: \.0.id) { track, name in
                        HStack(spacing: 6) {
                            Text(track.filename)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Image(systemName: "arrow.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .font(.caption)
                    }
                    if preview.count > 12 {
                        Text("… and \(preview.count - 12) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 150)
        } actions: {
            Button("Clear proposals") {
                state.clearProposedFilenames()
                dismiss()
            }
            Button("Apply") {
                state.applyFilenamePattern(pattern, padsNumbers: padsNumbers)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(preview.isEmpty)
        }
        .frame(width: 460)
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
