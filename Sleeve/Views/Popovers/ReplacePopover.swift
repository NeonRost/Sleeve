//
//  ReplacePopover.swift
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
//  Find and replace (spec §4.3.1). Like every batch operation it shows what
//  will happen before anything happens.
//

import SwiftUI

struct ReplacePopover: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var replacement = TextReplacement()
    @State private var fields: Set<TagField> = [.title, .artist, .albumArtist, .album]

    /// How many example rows the preview shows before summing up.
    private static let previewRows = 6

    private var preview: Result<[AppState.ReplacementChange], TextReplacement.Problem> {
        do {
            return .success(try state.replacementPreview(replacement, fields: fields))
        } catch let problem as TextReplacement.Problem {
            return .failure(problem)
        } catch {
            return .failure(.invalidPattern(error.localizedDescription))
        }
    }

    var body: some View {
        let preview = preview
        PopoverFrame(title: "Replace") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("Find").gridColumnAlignment(.trailing)
                    TextField("", text: $replacement.find)
                }
                GridRow {
                    Text("Replace with")
                    TextField("", text: $replacement.replacement, prompt: Text("nothing — remove"))
                }
            }
            .textFieldStyle(.roundedBorder)

            Toggle("Match case", isOn: $replacement.matchesCase)
            Toggle("Regular expression", isOn: $replacement.usesRegularExpression)
                .help("In the replacement, $1 inserts what the first group in parentheses matched.")

            Divider()

            Text("Apply to")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(AppState.textFields, id: \.self) { field in
                Toggle(field.takeOverLabel, isOn: Binding(
                    get: { fields.contains(field) },
                    set: { isOn in
                        if isOn { fields.insert(field) } else { fields.remove(field) }
                    }
                ))
            }

            if !replacement.isEmpty {
                Divider()
                previewSection(preview)
            }
        } actions: {
            Button("Apply") {
                _ = try? state.applyReplacement(replacement, fields: fields)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled((try? preview.get())?.isEmpty ?? true)
        }
        .frame(width: 360)
        #if DEBUG
        .onAppear {
            // -SleeveDebugReplaceFind "text" fills in the search, for a screenshot.
            if let find = UserDefaults.standard.string(forKey: "SleeveDebugReplaceFind") {
                replacement.find = find
            }
        }
        #endif
    }

    @ViewBuilder
    private func previewSection(
        _ preview: Result<[AppState.ReplacementChange], TextReplacement.Problem>
    ) -> some View {
        switch preview {
        case .failure:
            Label("This is not a valid regular expression.",
                  systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
        case .success(let changes) where changes.isEmpty:
            Text("Nothing matches in the selected fields.")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .success(let changes):
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
    }
}

/// The old value struck through, the new one below it. An empty result says
/// that the field will be cleared; the field's name is in the tooltip.
private struct ChangeRow: View {
    let change: AppState.ReplacementChange

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: change.old)
                .foregroundStyle(.secondary)
                .strikethrough()
                .lineLimit(1)
            HStack(spacing: 4) {
                Image(systemName: "arrow.turn.down.right")
                    .foregroundStyle(.tertiary)
                if change.new.isEmpty {
                    Text("cleared").italic().foregroundStyle(.orange)
                } else {
                    Text(verbatim: change.new).lineLimit(1)
                }
            }
        }
        .font(.callout)
        .help(Text(change.field.takeOverLabel))
    }
}
