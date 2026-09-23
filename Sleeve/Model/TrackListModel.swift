//
//  TrackListModel.swift
//  Sleeve
//

import Foundation
import SwiftUI

/// Die Dateiliste — **modusübergreifend**. Sie ist das gemeinsame Objekt, an
/// dem Taggen, Konvertieren und Rippen arbeiten, und überlebt jeden
/// Moduswechsel (Spec §1.1).
@Observable
final class TrackListModel {
    var tracks: [TrackFile] = []
    var selection: Set<TrackFile.ID> = []

    /// Von der `Table` gesetzte Sortierung. Liegt im Modell und nicht als
    /// `@State` in der View, weil die Nummerierung sie braucht — §4.2 sagt
    /// „nach aktueller Sortierung durchnummerieren".
    var sortOrder: [KeyPathComparator<TrackFile>] = [
        KeyPathComparator(\TrackFile.trackValue)
    ]

    /// Die Liste so, wie sie gerade auf dem Schirm steht.
    var tracksInDisplayOrder: [TrackFile] { tracks.sorted(using: sortOrder) }

    // MARK: - Spalten

    /// Welche Spalten sichtbar sind und in welcher Reihenfolge. macOS pflegt
    /// das selbst; wir sichern es nur über den Programmstart hinweg.
    var columnLayout = TableColumnCustomization<TrackFile>() {
        didSet { persistColumnLayout() }
    }

    /// Kennungen der zuschaltbaren Spalten, in Menü-Reihenfolge. Nur die
    /// Kennungen — die Beschriftungen gehören in die View, schon weil
    /// `LocalizedStringKey` nicht `Sendable` ist.
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
        // In der Reihenfolge der Liste, nicht in der des Sets.
        tracks.filter { selection.contains($0.id) }
    }

    var dirtyTracks: [TrackFile] { tracks.filter(\.isDirty) }

    var changedCount: Int { dirtyTracks.count }

    var hasErrors: Bool { tracks.contains { $0.lastError != nil } }

    // MARK: - Bestand ändern

    /// Hängt an und überspringt Pfade, die schon in der Liste stehen.
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
