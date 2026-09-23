//
//  TrackFile.swift
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

import Foundation
import SwiftUI

/// State of a file in the list. Drives the status column.
enum TrackStatus: Sendable {
    case unchanged
    case changed
    case failed
}

/// `@unchecked Sendable` with a clear promise: every access to `TrackFile`
/// happens on the main thread. The class is **never** handed to
/// `TagEngine` — only `AudioTags`, `URL` and `Set<TagField>` go there, all
/// Sendable value types.
///
/// `@MainActor` would be the clean guarantee but does not work here:
/// SwiftUI's `Table` sorts via `KeyPathComparator`, and a key path to an
/// actor-isolated property cannot be formed. Sortable columns are a spec
/// requirement (§4.1), so the isolation has to go.
@Observable
final class TrackFile: Identifiable, @unchecked Sendable {
    let id = UUID()

    /// Mutable: renaming (§4.4) and later conversion change the path.
    var url: URL

    /// State on disk. The basis for "Discard" and for the undo step after
    /// saving.
    private(set) var original: AudioTags

    /// Working state in the editor.
    var edited: AudioTags

    /// **The single most important point of the spec (§4.1).** Only what is in
    /// here gets written. Never decide by comparing values — a field that looks
    /// empty may have to stay unwritten.
    var touchedFields: Set<TagField> = []

    var proposedFilename: String?
    var lastError: TagError?

    /// Comes from the audio stream. Not editable, but changes when the file
    /// has been converted.
    private(set) var properties: AudioProperties

    /// Size on disk. Cached instead of queried on every redraw — otherwise
    /// the table would make a thousand file system calls per frame for a
    /// thousand rows.
    private(set) var fileSize: Int64

    init(url: URL, info: AudioFileInfo) {
        self.url = url
        self.original = info.tags
        self.edited = info.tags
        self.properties = info.properties
        self.fileSize = Self.sizeOnDisk(of: url)
    }

    static func sizeOnDisk(of url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap(Int64.init) ?? 0
    }

    func refreshFileSize() {
        fileSize = Self.sizeOnDisk(of: url)
    }

    var isDirty: Bool { !touchedFields.isEmpty || proposedFilename != nil }

    var status: TrackStatus {
        if lastError != nil { return .failed }
        return isDirty ? .changed : .unchanged
    }

    var filename: String { url.lastPathComponent }

    // MARK: - Editing

    /// Sets a field **and** marks it as touched. The only way the UI may
    /// change tags.
    ///
    /// If the call does not change the value, nothing happens. SwiftUI calls
    /// a `TextField`'s setter with the unchanged text even on a mere focus
    /// change — without this check, one click into the field would be enough
    /// to have it written on the next save.
    ///
    /// This is **not** a relapse into "decide by comparing values what gets
    /// written" (spec §4.1): the comparison is against the current editor
    /// state, not against what is on disk. Whoever deliberately empties a
    /// field changes its value and gets it marked.
    func set(_ value: String?, for field: TagField) {
        let before = edited.stringValue(for: field)
        edited.setStringValue(value, for: field)
        guard edited.stringValue(for: field) != before else { return }

        touchedFields.insert(field)
        lastError = nil
    }

    func setArtwork(_ artwork: [Artwork]) {
        // The only way pictures are set — so the order is fixed here, not at
        // every call site separately.
        edited.artwork = Artwork.sortedForEmbedding(artwork)
        touchedFields.insert(.artwork)
        lastError = nil
    }

    /// After a successful write: the editor state is now the state on disk.
    /// The file has grown or shrunk in the process — through a cover, say.
    func commit() {
        original = edited
        touchedFields.removeAll()
        proposedFilename = nil
        lastError = nil
        refreshFileSize()
    }

    /// Discards unsaved changes.
    func revert() {
        edited = original
        touchedFields.removeAll()
        proposedFilename = nil
        lastError = nil
    }

    /// After conversion: the file is a different one, the track the same.
    /// `id`, and with it the selection, stays.
    func replaceFile(url newURL: URL, info: AudioFileInfo) {
        url = newURL
        original = info.tags
        edited = info.tags
        properties = info.properties
        touchedFields.removeAll()
        proposedFilename = nil
        lastError = nil
        refreshFileSize()
    }

    /// Puts back an earlier state to undo a write. Afterwards every field
    /// counts as touched, so that all of them get written again.
    func restore(_ snapshot: AudioTags, fields: Set<TagField>) {
        edited = snapshot
        touchedFields = fields
        lastError = nil
    }

    // MARK: - Sort keys for the table

    /// `Table` sorts via `Comparable` key paths — `String?` is not one.
    var titleText: String { edited.title ?? "" }
    var artistText: String { edited.artist ?? "" }
    var albumText: String { edited.album ?? "" }
    var yearValue: Int { edited.year ?? 0 }
    var trackValue: Int { edited.trackNumber ?? 0 }
}

// MARK: - Bindings for the UI

extension TrackFile {
    /// A `Binding` whose setter marks the field as touched. Every text input
    /// in table and inspector goes through here — that is the only way
    /// `touchedFields` stays the single truth about what gets written.
    func textBinding(for field: TagField) -> Binding<String> {
        Binding(
            get: { self.edited.stringValue(for: field) ?? "" },
            set: { self.set($0, for: field) }
        )
    }
}

extension TrackFile {
    /// Sort keys for the duration and status columns.
    var durationSeconds: Int { Int(properties.duration.components.seconds) }

    /// Values for the optional columns.
    var albumArtistText: String { edited.albumArtist ?? "" }
    var genreText: String { edited.genre ?? "" }
    var composerText: String { edited.composer ?? "" }
    var commentText: String { edited.comment ?? "" }
    var discValue: Int { edited.discNumber ?? 0 }
    var formatText: String { url.pathExtension.uppercased() }
    var folderText: String { url.deletingLastPathComponent().lastPathComponent }

    var statusSortKey: Int {
        switch status {
        case .unchanged: 0
        case .changed:   1
        case .failed:    2
        }
    }
}
