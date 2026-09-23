//
//  TagInspector.swift
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

struct TagInspector: View {
    @Environment(AppState.self) private var state

    private var tracks: [TrackFile] {
        let selected = state.trackList.selectedTracks
        return selected.isEmpty ? [] : selected
    }

    var body: some View {
        Group {
            if tracks.isEmpty {
                ContentUnavailableView(
                    "No selection",
                    systemImage: "sidebar.left",
                    description: Text("Select one or more tracks to edit their tags.")
                )
            } else {
                Form {
                    Section {
                        field(.title, "Title")
                        field(.artist, "Artist")
                        field(.album, "Album")
                        field(.albumArtist, "Album artist")
                    }

                    Section {
                        field(.composer, "Composer")
                        field(.genre, "Genre")
                        field(.year, "Year", width: 70)
                        compilationToggle
                    }

                    Section {
                        numberPair(.trackNumber, .trackTotal, "Track")
                        numberPair(.discNumber, .discTotal, "Disc")
                    }

                    Section {
                        // Both grow while typing, instead of taking up half the
                        // screen from the start.
                        field(.comment, "Comment", axis: .vertical)
                        field(.lyrics, "Lyrics", axis: .vertical)
                    }

                    Section("Artwork") {
                        ArtworkWell(tracks: tracks)
                    }
                }
                .formStyle(.grouped)
                .safeAreaInset(edge: .top, spacing: 0) {
                    SelectionHeader(count: tracks.count)
                }
            }
        }
    }

    // MARK: - Fields

    @ViewBuilder
    private func field(
        _ tagField: TagField,
        _ label: LocalizedStringKey,
        width: CGFloat? = nil,
        axis: Axis = .horizontal
    ) -> some View {
        LabeledContent {
            HStack(spacing: 6) {
                TextField(
                    label,
                    text: binding(for: tagField),
                    prompt: prompt(for: tagField),
                    axis: axis
                )
                .labelsHidden()
                // Without a border, the form does not show that the row is
                // an input field.
                .textFieldStyle(.roundedBorder)
                .frame(width: width, alignment: .leading)
                .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)

                ClearButton(isEnabled: hasValue(tagField)) { clear(tagField) }
                TouchedDot(isTouched: isTouched(tagField))
            }
        } label: {
            Text(label)
        }
    }

    /// `TRACKNUMBER` and `DISCNUMBER` are one value in the tag ("3/12"), two
    /// fields in the editor.
    @ViewBuilder
    private func numberPair(
        _ number: TagField,
        _ total: TagField,
        _ label: LocalizedStringKey
    ) -> some View {
        LabeledContent {
            HStack(spacing: 6) {
                TextField(label, text: binding(for: number), prompt: prompt(for: number))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 58)
                Text("of").foregroundStyle(.secondary)
                TextField(label, text: binding(for: total), prompt: prompt(for: total))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 58)
                ClearButton(isEnabled: hasValue(number) || hasValue(total)) {
                    clear(number)
                    clear(total)
                }
                TouchedDot(isTouched: isTouched(number) || isTouched(total))
                Spacer()
            }
        } label: {
            Text(label)
        }
    }

    @ViewBuilder
    private var compilationToggle: some View {
        LabeledContent {
            HStack(spacing: 6) {
                Toggle("Compilation", isOn: Binding(
                    get: { tracks.allSatisfy(\.edited.isCompilation) },
                    set: { newValue in
                        tracks.forEach { $0.set(newValue ? "1" : "0", for: .isCompilation) }
                    }
                ))
                .labelsHidden()
                TouchedDot(isTouched: isTouched(.isCompilation))
                Spacer()
            }
        } label: {
            Text("Compilation")
        }
    }

    // MARK: - Multiple selection

    /// The common value of the selection, or `nil` if the values differ.
    private func commonValue(_ field: TagField) -> String?? {
        guard let first = tracks.first else { return .some(nil) }
        let value = first.edited.stringValue(for: field)
        let allEqual = tracks.allSatisfy { $0.edited.stringValue(for: field) == value }
        return allEqual ? .some(value) : nil
    }

    private func isMixed(_ field: TagField) -> Bool {
        commonValue(field) == nil
    }

    /// With differing values the field stays empty and shows
    /// `<Multiple values>` as placeholder — **not** simply empty, or it
    /// looks like "no value" (spec §4.1).
    private func prompt(for field: TagField) -> Text? {
        isMixed(field) ? Text("<Multiple values>") : nil
    }

    private func binding(for field: TagField) -> Binding<String> {
        Binding(
            get: {
                guard let common = commonValue(field) else { return "" }
                return common ?? ""
            },
            set: { newValue in
                // Writes to all selected tracks and marks the field as touched on
                // each of them.
                tracks.forEach { $0.set(newValue, for: field) }
            }
        )
    }

    private func isTouched(_ field: TagField) -> Bool {
        tracks.contains { $0.touchedFields.contains(field) }
    }

    /// Does any of the selected tracks have something here at all?
    private func hasValue(_ field: TagField) -> Bool {
        tracks.contains { ($0.edited.stringValue(for: field)?.isEmpty == false) }
    }

    /// Clears the field on **all** selected tracks.
    ///
    /// This is explicitly a change, not doing nothing: afterwards the field
    /// counts as touched and is cleared on save. That is exactly what the
    /// button is for — for the advertising address in the comment of
    /// downloaded MP3s, say.
    private func clear(_ field: TagField) {
        tracks.forEach { $0.set(nil, for: field) }
    }
}

// MARK: - Header row

private struct SelectionHeader: View {
    let count: Int

    var body: some View {
        HStack {
            Text(count == 1 ? "1 track selected" : "\(count) tracks selected")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// Clears a field across the whole selection. Small and unobtrusive, but
/// always in the same place — when greyed out there is nothing to clear.
private struct ClearButton: View {
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(isHovering && isEnabled ? AnyShapeStyle(.secondary)
                                                         : AnyShapeStyle(.tertiary))
        }
        .buttonStyle(.borderless)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { isHovering = $0 }
        .help("Clear this field on all selected tracks")
    }
}

/// Makes visible what will actually be written. Without this dot the user
/// cannot tell whether an empty field means "untouched" or "deliberately
/// cleared".
private struct TouchedDot: View {
    let isTouched: Bool

    var body: some View {
        Circle()
            .fill(isTouched ? Color.accentColor : .clear)
            .frame(width: 6, height: 6)
            .help(isTouched
                  ? "Edited — this field will be written"
                  : "Untouched — this field stays as it is on disk")
    }
}
