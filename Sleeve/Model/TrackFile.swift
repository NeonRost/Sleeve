//
//  TrackFile.swift
//  Sleeve
//

import Foundation
import SwiftUI

/// Zustand einer Datei in der Liste. Bestimmt die Statusspalte.
enum TrackStatus: Sendable {
    case unchanged
    case changed
    case failed
}

/// `@unchecked Sendable` mit klarer Zusage: Jeder Zugriff auf `TrackFile`
/// passiert auf dem Main-Thread. Die Klasse wird **nie** an `TagEngine`
/// gereicht — dorthin gehen ausschließlich `AudioTags`, `URL` und
/// `Set<TagField>`, alles Sendable-Werttypen.
///
/// `@MainActor` wäre die saubere Zusicherung, geht hier aber nicht: SwiftUIs
/// `Table` sortiert über `KeyPathComparator`, und ein KeyPath auf eine
/// aktor-isolierte Property lässt sich nicht bilden. Sortierbare Spalten sind
/// Spec-Anforderung (§4.1), also fällt die Isolation.
@Observable
final class TrackFile: Identifiable, @unchecked Sendable {
    let id = UUID()

    /// Veränderlich: Umbenennung (§4.4) und später Konvertierung ändern den Pfad.
    var url: URL

    /// Stand auf der Platte. Grundlage für „Verwerfen" und für den
    /// Undo-Schritt nach dem Speichern.
    private(set) var original: AudioTags

    /// Arbeitsstand im Editor.
    var edited: AudioTags

    /// **Der wichtigste Einzelpunkt der Spec (§4.1).** Nur was hier drinsteht,
    /// wird geschrieben. Nie über einen Wertvergleich entscheiden — ein Feld,
    /// das leer aussieht, kann ungeschrieben bleiben müssen.
    var touchedFields: Set<TagField> = []

    var proposedFilename: String?
    var lastError: TagError?

    /// Kommt aus dem Audiostream. Nicht bearbeitbar, ändert sich aber, wenn
    /// die Datei konvertiert wurde.
    private(set) var properties: AudioProperties

    /// Größe auf der Platte. Zwischengespeichert statt bei jedem Neuzeichnen
    /// erfragt — die Tabelle rendert sonst bei tausend Zeilen tausend
    /// Dateisystemzugriffe pro Bildaufbau.
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

    // MARK: - Bearbeiten

    /// Setzt ein Feld **und** merkt es als berührt vor. Der einzige Weg, über
    /// den die UI Tags ändern darf.
    ///
    /// Ändert der Aufruf den Wert nicht, passiert nichts. SwiftUI ruft den
    /// Setter eines `TextField` auch beim bloßen Fokuswechsel mit dem
    /// unveränderten Text auf — ohne diese Prüfung würde ein Klick ins Feld
    /// genügen, um es beim nächsten Speichern zu schreiben.
    ///
    /// Das ist **kein** Rückfall in „per Wertvergleich entscheiden, was
    /// geschrieben wird" (Spec §4.1): verglichen wird gegen den aktuellen
    /// Editor-Stand, nicht gegen den Plattenstand. Wer ein Feld absichtlich
    /// leert, ändert seinen Wert und wird vorgemerkt.
    func set(_ value: String?, for field: TagField) {
        let before = edited.stringValue(for: field)
        edited.setStringValue(value, for: field)
        guard edited.stringValue(for: field) != before else { return }

        touchedFields.insert(field)
        lastError = nil
    }

    func setArtwork(_ artwork: [Artwork]) {
        // Einziger Weg, über den Bilder gesetzt werden — deshalb wird hier
        // die Reihenfolge festgelegt, nicht an jeder Aufrufstelle einzeln.
        edited.artwork = Artwork.sortedForEmbedding(artwork)
        touchedFields.insert(.artwork)
        lastError = nil
    }

    /// Nach erfolgreichem Schreiben: der Editor-Stand ist jetzt der Plattenstand.
    /// Die Datei ist dabei gewachsen oder geschrumpft — etwa durch ein Cover.
    func commit() {
        original = edited
        touchedFields.removeAll()
        proposedFilename = nil
        lastError = nil
        refreshFileSize()
    }

    /// Verwirft ungespeicherte Änderungen.
    func revert() {
        edited = original
        touchedFields.removeAll()
        proposedFilename = nil
        lastError = nil
    }

    /// Nach der Konvertierung: Die Datei ist eine andere, der Track derselbe.
    /// `id` und damit die Auswahl bleiben erhalten.
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

    /// Setzt einen früheren Stand zur Rücknahme eines Schreibvorgangs ein.
    /// Alle Felder gelten danach als berührt, damit sie wieder geschrieben werden.
    func restore(_ snapshot: AudioTags, fields: Set<TagField>) {
        edited = snapshot
        touchedFields = fields
        lastError = nil
    }

    // MARK: - Sortierschlüssel für die Table

    /// `Table` sortiert über `Comparable`-KeyPaths — `String?` ist das nicht.
    var titleText: String { edited.title ?? "" }
    var artistText: String { edited.artist ?? "" }
    var albumText: String { edited.album ?? "" }
    var yearValue: Int { edited.year ?? 0 }
    var trackValue: Int { edited.trackNumber ?? 0 }
}

// MARK: - Bindings für die UI

extension TrackFile {
    /// Ein `Binding`, dessen Setter das Feld als berührt vormerkt. Jede
    /// Texteingabe in Tabelle und Inspector läuft hierüber — nur so bleibt
    /// `touchedFields` die einzige Wahrheit darüber, was geschrieben wird.
    func textBinding(for field: TagField) -> Binding<String> {
        Binding(
            get: { self.edited.stringValue(for: field) ?? "" },
            set: { self.set($0, for: field) }
        )
    }
}

extension TrackFile {
    /// Sortierschlüssel für die Dauer- und Statusspalte.
    var durationSeconds: Int { Int(properties.duration.components.seconds) }

    /// Werte für die zuschaltbaren Spalten.
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
