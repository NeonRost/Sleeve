//
//  TrackTableView.swift
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
//  Shared by all modes — the same list in every mode (spec §1.1).
//

import SwiftUI

struct TrackTableView: View {
    @Environment(AppState.self) private var state

    @State private var isTargetedByDrop = false

    var body: some View {
        @Bindable var list = state.trackList

        Table(list.tracksInDisplayOrder,
              selection: $list.selection,
              sortOrder: $list.sortOrder,
              columnCustomization: $list.columnLayout) {
            columns
        }
        .textFieldStyle(.plain)
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .onAppear { EditableCellClick.install(list: state.trackList) }
        // Drag and drop of files and folders, resolved recursively (spec §4.1).
        .dropDestination(for: URL.self) { urls, _ in
            Task { await state.addFiles(urls) }
            return true
        } isTargeted: { isTargetedByDrop = $0 }
        .overlay { overlays }
        // `TableColumn` only takes text as its header, no custom view. The
        // menu therefore sits above the header, flush right — where one
        // looks for it. macOS additionally offers the right-click on the
        // header anyway.
        .overlay(alignment: .topTrailing) {
            ColumnMenu()
                .padding(.trailing, 7)
                .padding(.top, 3)
        }
    }

    /// A property of its own with an explicit result type — as a literal
    /// in the `Table` call the type checker takes unreasonably long.
    @TableColumnBuilder<TrackFile, KeyPathComparator<TrackFile>>
    private var columns: some TableColumnContent<TrackFile, KeyPathComparator<TrackFile>> {
        defaultColumns
        optionalColumns
        statusColumn
    }

    // MARK: - Always visible

    @TableColumnBuilder<TrackFile, KeyPathComparator<TrackFile>>
    private var defaultColumns: some TableColumnContent<TrackFile, KeyPathComparator<TrackFile>> {
        TableColumn("#", value: \TrackFile.trackValue) { track in
            EditableCell(track: track, field: .trackNumber, alignment: .trailing)
        }
        .width(44)
        .customizationID("track")

        TableColumn("Title", value: \TrackFile.titleText) { track in
            EditableCell(track: track, field: .title)
        }
        .width(min: 140, ideal: 220)
        .customizationID("title")

        TableColumn("Artist", value: \TrackFile.artistText) { track in
            EditableCell(track: track, field: .artist)
        }
        .width(min: 120, ideal: 180)
        .customizationID("artist")

        TableColumn("Album", value: \TrackFile.albumText) { track in
            EditableCell(track: track, field: .album)
        }
        .width(min: 120, ideal: 180)
        .customizationID("album")

        TableColumn("Year", value: \TrackFile.yearValue) { track in
            EditableCell(track: track, field: .year, alignment: .trailing)
        }
        .width(56)
        .customizationID("year")

        TableColumn("Length", value: \TrackFile.durationSeconds) { track in
            PlainCell(text: track.properties.duration.formatted(
                .time(pattern: .minuteSecond)), alignment: .trailing)
        }
        .width(64)
        .customizationID("length")

        TableColumn("File name", value: \TrackFile.filename) { track in
            FilenameCell(track: track)
        }
        .width(min: 120, ideal: 200)
        .customizationID("filename")
    }

    // MARK: - Optional
    //
    // Hidden by default. Shown and hidden via the menu at the right of the
    // header — or via the right-click macOS offers by itself. The choice
    // survives a relaunch.

    @TableColumnBuilder<TrackFile, KeyPathComparator<TrackFile>>
    private var optionalColumns: some TableColumnContent<TrackFile, KeyPathComparator<TrackFile>> {
        TableColumn("Bitrate", value: \TrackFile.properties.bitrate) { track in
            PlainCell(text: track.properties.bitrate > 0
                      ? "\(track.properties.bitrate) kbit/s" : "—",
                      alignment: .trailing)
        }
        .width(88)
        .customizationID("bitrate")
        .defaultVisibility(.hidden)

        TableColumn("Size", value: \TrackFile.fileSize) { track in
            PlainCell(text: track.fileSize > 0
                      ? track.fileSize.formatted(.byteCount(style: .file)) : "—",
                      alignment: .trailing)
        }
        .width(80)
        .customizationID("size")
        .defaultVisibility(.hidden)

        TableColumn("Format", value: \TrackFile.formatText) { track in
            PlainCell(text: track.formatText)
        }
        .width(64)
        .customizationID("format")
        .defaultVisibility(.hidden)

        TableColumn("Sample rate", value: \TrackFile.properties.sampleRate) { track in
            PlainCell(text: track.properties.sampleRate > 0
                      ? "\(track.properties.sampleRate) Hz" : "—",
                      alignment: .trailing)
        }
        .width(92)
        .customizationID("samplerate")
        .defaultVisibility(.hidden)

        TableColumn("Album artist", value: \TrackFile.albumArtistText) { track in
            EditableCell(track: track, field: .albumArtist)
        }
        .width(min: 100, ideal: 160)
        .customizationID("albumartist")
        .defaultVisibility(.hidden)

        TableColumn("Genre", value: \TrackFile.genreText) { track in
            EditableCell(track: track, field: .genre)
        }
        .width(min: 90, ideal: 130)
        .customizationID("genre")
        .defaultVisibility(.hidden)

        TableColumn("Composer", value: \TrackFile.composerText) { track in
            EditableCell(track: track, field: .composer)
        }
        .width(min: 90, ideal: 140)
        .customizationID("composer")
        .defaultVisibility(.hidden)

        TableColumn("Disc", value: \TrackFile.discValue) { track in
            EditableCell(track: track, field: .discNumber, alignment: .trailing)
        }
        .width(50)
        .customizationID("disc")
        .defaultVisibility(.hidden)

        TableColumn("Comment", value: \TrackFile.commentText) { track in
            EditableCell(track: track, field: .comment)
        }
        .width(min: 100, ideal: 180)
        .customizationID("comment")
        .defaultVisibility(.hidden)

        TableColumn("Folder", value: \TrackFile.folderText) { track in
            PlainCell(text: track.folderText)
        }
        .width(min: 100, ideal: 160)
        .customizationID("folder")
        .defaultVisibility(.hidden)
    }

    // MARK: - Status column with the column menu

    @TableColumnBuilder<TrackFile, KeyPathComparator<TrackFile>>
    private var statusColumn: some TableColumnContent<TrackFile, KeyPathComparator<TrackFile>> {
        TableColumn("", value: \TrackFile.statusSortKey) { track in
            StatusIndicator(track: track)
        }
        // A bit wider than necessary: the column menu sits above it on the right.
        .width(46)
        .customizationID("status")
        .disabledCustomizationBehavior(.visibility)
    }

    @ViewBuilder
    private var overlays: some View {
        if state.trackList.tracks.isEmpty {
            EmptyListHint(isTargeted: isTargetedByDrop)
        } else if isTargetedByDrop {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .padding(4)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Column menu

private struct ColumnMenu: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var list = state.trackList

        Menu {
            Section("Columns") {
                ForEach(TrackListModel.optionalColumnIDs, id: \.self) { id in
                    Toggle(Self.label(for: id), isOn: Binding(
                        get: { list.columnLayout[visibility: id] == .visible },
                        set: { list.columnLayout[visibility: id] = $0 ? .visible : .hidden }
                    ))
                }
            }
            Divider()
            Button("Reset Columns") { list.resetColumns() }
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .help("Show or hide columns")
    }

    static func label(for id: String) -> LocalizedStringKey {
        switch id {
        case "bitrate":     "Bitrate"
        case "size":        "Size"
        case "format":      "Format"
        case "samplerate":  "Sample rate"
        case "albumartist": "Album artist"
        case "genre":       "Genre"
        case "composer":    "Composer"
        case "disc":        "Disc"
        case "comment":     "Comment"
        case "folder":      "Folder"
        default:            "—"
        }
    }
}

// MARK: - Cells

/// Editable inline. The setter goes through `TrackFile.set` and thus marks
/// the field as touched — typing in the table and typing in the inspector
/// are the same operation.
///
/// As in the Finder: the first click selects the row, a click into a cell
/// of a row that is already selected starts editing. With a text field in
/// every cell, the first click used to start editing right away — a row
/// could only be selected by aiming at the length, the file name or the
/// size. A double click on an unselected row does both, one after the
/// other. With ⌘ or ⇧ held the click only changes the selection.
///
/// The cell under the mouse pointer stands out on a selected row, so that
/// it shows where a click would start editing.
private struct EditableCell: View {
    @Environment(AppState.self) private var state

    let track: TrackFile
    let field: TagField
    var alignment: TextAlignment = .leading

    @State private var isHovering = false
    @State private var isEditing = false
    @FocusState private var isFocused: Bool

    private var isRowSelected: Bool {
        state.trackList.selection.contains(track.id)
    }

    var body: some View {
        Group {
            if isEditing {
                TextField("", text: track.textBinding(for: field), prompt: Text("—"))
                    .multilineTextAlignment(alignment)
                    .focused($isFocused)
                    .onSubmit { isEditing = false }
                    .onExitCommand { isEditing = false }
                    .onAppear { isFocused = true }
                    .onChange(of: isFocused) { _, focused in
                        if !focused { isEditing = false }
                    }
            } else {
                let value = track.edited.stringValue(for: field) ?? ""
                Text(verbatim: value.isEmpty ? "—" : value)
                    .foregroundStyle(value.isEmpty ? .tertiary : .primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity,
                           alignment: alignment == .trailing ? .trailing : .leading)
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded { startEditing() })
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background {
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary.opacity(isHovering && isRowSelected && !isEditing ? 1 : 0))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.accentColor, lineWidth: isEditing && isFocused ? 2 : 0)
        }
        .padding(.horizontal, -5)
        .onHover { isHovering = $0 }
    }

    /// Only on a row that was already selected before this click, and not
    /// while the click extends or shrinks the selection.
    private func startEditing() {
        let modifiers = NSEvent.modifierFlags.intersection([.command, .shift])
        guard modifiers.isEmpty, wasSelectedBeforeClick else { return }
        isEditing = true
    }

    /// The table updates the selection on the same click. Whether the row
    /// was selected *before* is what decides — remembered on mouse down.
    private var wasSelectedBeforeClick: Bool {
        EditableCellClick.selectionBeforeClick?.contains(track.id) ?? isRowSelected
    }
}

/// Remembers the selection as it was when the mouse went down, before the
/// table changes it on that very click. A local event monitor sees the
/// event before SwiftUI does.
@MainActor
enum EditableCellClick {
    static var selectionBeforeClick: Set<TrackFile.ID>?
    private static var monitor: Any?

    static func install(list: TrackListModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            MainActor.assumeIsolated { selectionBeforeClick = list.selection }
            return event
        }
    }
}

/// Read-only values such as duration, bitrate or file size.
private struct PlainCell: View {
    let text: String
    var alignment: Alignment = .leading

    var body: some View {
        Text(text)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: alignment)
    }
}

private struct FilenameCell: View {
    let track: TrackFile

    var body: some View {
        Text(track.proposedFilename ?? track.filename)
            .foregroundStyle(track.proposedFilename == nil ? Color.primary : Color.accentColor)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

private struct StatusIndicator: View {
    let track: TrackFile

    var body: some View {
        switch track.status {
        case .unchanged:
            Color.clear.frame(width: 1)
        case .changed:
            Image(systemName: "pencil.circle.fill")
                .foregroundStyle(.tint)
                .help("Changed — not written yet")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help("Writing this file failed")
        }
    }
}

// MARK: - Empty list

private struct EmptyListHint: View {
    let isTargeted: Bool

    var body: some View {
        ContentUnavailableView {
            Label("No tracks", systemImage: "music.note.list")
        } description: {
            Text("Drop audio files or folders here. Folders are scanned recursively.")
        }
        .background(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
    }
}
