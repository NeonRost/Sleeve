//
//  TrackListModel.swift
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

/// The file list — **shared by all modes**. It is the common object that
/// tagging, converting and ripping work on, and it survives every mode
/// switch (spec §1.1).
@Observable
final class TrackListModel {
    var tracks: [TrackFile] = []
    var selection: Set<TrackFile.ID> = []

    /// Sort order set by the `Table`. Lives in the model rather than as
    /// `@State` in the view because numbering needs it — §4.2 says "number
    /// in the current sort order".
    var sortOrder: [KeyPathComparator<TrackFile>] = [
        KeyPathComparator(\TrackFile.trackValue)
    ]

    /// The list as it currently appears on screen.
    var tracksInDisplayOrder: [TrackFile] { tracks.sorted(using: sortOrder) }

    // MARK: - Columns

    /// Which columns are visible and in which order. macOS maintains this
    /// itself; we only preserve it across launches.
    var columnLayout = TableColumnCustomization<TrackFile>() {
        didSet { persistColumnLayout() }
    }

    /// Identifiers of the optional columns, in menu order. Identifiers only —
    /// the labels belong to the view, not least because `LocalizedStringKey`
    /// is not `Sendable`.
    static let optionalColumnIDs = [
        "bitrate", "size", "format", "samplerate",
        "albumartist", "genre", "composer", "disc", "comment", "folder",
    ]

    func resetColumns() {
        columnLayout = TableColumnCustomization<TrackFile>()
    }

    private static let layoutKey = "table.columnLayout"

    private func persistColumnLayout() {
        guard let data = try? JSONEncoder().encode(columnLayout) else { return }
        UserDefaults.standard.set(data, forKey: Self.layoutKey)
    }

    func restoreColumnLayout() {
        guard let data = UserDefaults.standard.data(forKey: Self.layoutKey),
              let restored = try? JSONDecoder().decode(
                TableColumnCustomization<TrackFile>.self, from: data)
        else { return }
        columnLayout = restored
    }

    var selectedTracks: [TrackFile] {
        // In list order, not in set order.
        tracks.filter { selection.contains($0.id) }
    }

    var dirtyTracks: [TrackFile] { tracks.filter(\.isDirty) }

    var changedCount: Int { dirtyTracks.count }

    var hasErrors: Bool { tracks.contains { $0.lastError != nil } }

    // MARK: - Changing the contents

    /// Appends, skipping paths that are already in the list.
    func append(contentsOf newTracks: [TrackFile]) {
        let known = Set(tracks.map(\.url.standardizedFileURL))
        tracks.append(contentsOf: newTracks.filter { !known.contains($0.url.standardizedFileURL) })
    }

    func contains(url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        return tracks.contains { $0.url.standardizedFileURL == standardized }
    }

    func removeSelected() {
        tracks.removeAll { selection.contains($0.id) }
        selection.removeAll()
    }

    func removeAll() {
        tracks.removeAll()
        selection.removeAll()
    }

    func track(id: TrackFile.ID) -> TrackFile? {
        tracks.first { $0.id == id }
    }
}
