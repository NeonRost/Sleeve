//
//  AppState+Operations.swift
//  Sleeve
//
//  Die Stapelverarbeitungen aus der Toolbar: Nummerierung (§4.2),
//  Schreibweise (§4.3), Pattern-Engine in beide Richtungen (§4.4),
//  Coverbilder (§4.5) und Music.app (§4.7).
//
//  Alle arbeiten auf dem **Editor-Zustand**, nie direkt auf der Platte.
//  Geschrieben wird ausschließlich beim Speichern.
//

import AppKit
import Foundation

extension AppState {

    /// Ziel jeder Operation: die Auswahl, oder die ganze Liste, wenn nichts
    /// ausgewählt ist. So verhält sich Tagr auch.
    var operationTargets: [TrackFile] {
        let selected = trackList.selectedTracks
        return selected.isEmpty ? trackList.tracksInDisplayOrder : selected
    }

    /// Dieselben Tracks, aber in der Reihenfolge der Tabelle — für die
    /// Nummerierung entscheidend.
    var operationTargetsInDisplayOrder: [TrackFile] {
        let targets = Set(operationTargets.map(\.id))
        return trackList.tracksInDisplayOrder.filter { targets.contains($0.id) }
    }

    // MARK: - Nummerierung (§4.2)

    func applyNumbering(_ options: NumberingOptions) {
        Numbering.apply(options, to: operationTargetsInDisplayOrder)
    }

    // MARK: - Schreibweise (§4.3)

    func applyCase(_ textCase: TextCase, language: TextCase.Language, fields: Set<TagField>) {
        for track in operationTargets {
            for field in fields {
                guard let value = track.edited.stringValue(for: field), !value.isEmpty else { continue }
                track.set(textCase.apply(to: value, language: language), for: field)
            }
        }
    }

    /// Felder, auf die sich die Schreibweise sinnvoll anwenden lässt.
    /// `nonisolated`, damit die Liste auch aus `AllInOneOptions` erreichbar ist.
    nonisolated static let textFields: [TagField] = [
        .title, .artist, .albumArtist, .album, .composer, .genre, .comment,
    ]

    // MARK: - Tags → Dateiname (§4.4)

    /// Vorschau, bevor etwas passiert. Gibt je Track den vorgeschlagenen
    /// Namen zurück — Kollisionen sind schon aufgelöst.
    func previewFilenames(pattern: String, padsNumbers: Bool = true) -> [(TrackFile, String)] {
        let targets = operationTargetsInDisplayOrder
        guard PatternSyntax.containsToken(pattern) else { return [] }

        var renderer = PatternRenderer()
        renderer.padsNumbers = padsNumbers
        let names = renderer.renderAll(
            pattern,
            for: targets.map { (url: $0.url, tags: $0.edited) }
        )
        return Array(zip(targets, names))
    }

    func applyFilenamePattern(_ pattern: String, padsNumbers: Bool = true) {
        for (track, name) in previewFilenames(pattern: pattern, padsNumbers: padsNumbers) {
            // Gleicht der Vorschlag dem aktuellen Namen, gibt es nichts zu tun.
            track.proposedFilename = name == track.filename ? nil : name
        }
    }

    func clearProposedFilenames() {
        operationTargets.forEach { $0.proposedFilename = nil }
    }

    // MARK: - Dateiname → Tags (§4.4)

    struct ExtractionPreview: Identifiable {
        let id: TrackFile.ID
        let track: TrackFile
        let subject: String
        /// `nil` heißt: passt nicht auf den Pattern, wird übersprungen.
        let values: [TagField: String]?
    }

    func previewExtraction(pattern: String) -> [ExtractionPreview] {
        guard let parser = try? PatternParser(pattern: pattern) else { return [] }
        return operationTargetsInDisplayOrder.map { track in
            ExtractionPreview(
                id: track.id,
                track: track,
                subject: parser.subject(for: track.url),
                values: parser.match(track.url)?.values
            )
        }
    }

    /// Übernimmt nur die Zeilen, die matchen. Nicht-matchende bleiben
    /// unangetastet (Spec §4.4).
    @discardableResult
    func applyExtraction(_ pattern: String) -> Int {
        var applied = 0
        for row in previewExtraction(pattern: pattern) {
            guard let values = row.values else { continue }
            for (field, value) in values {
                row.track.set(value, for: field)
            }
            applied += 1
        }
        return applied
    }

    // MARK: - Coverbilder (§4.5)

    /// Setzt das Bild auf **alle** Zieltracks — der häufigste Fall.
    ///
    /// Skaliert und kodiert wird nicht mehr hier, sondern im Einfüge-Dialog:
    /// eine globale Voreinstellung trifft es je Bild ohnehin nie.
    func applyArtwork(_ artwork: Artwork, replacing: Bool = true) {
        for track in operationTargets {
            // Beim Anhängen denselben Bildtyp nicht doppelt führen — zwei
            // „Front Cover" in einer Datei sind ein Fehler, kein Booklet.
            let existing = replacing
                ? []
                : track.edited.artwork.filter { $0.pictureType != artwork.pictureType }
            track.setArtwork(existing + [artwork])
        }
    }

    /// Entfernt alle Bilder.
    func removeArtwork() {
        operationTargets.forEach { $0.setArtwork([]) }
    }

    /// Entfernt genau ein Bild. Sinnvoll nur, wenn die Auswahl dieselben
    /// Bilder trägt — sonst zeigt das Feld ohnehin nichts an.
    func removeArtwork(at index: Int) {
        for track in operationTargets {
            var images = track.edited.artwork
            guard images.indices.contains(index) else { continue }
            images.remove(at: index)
            track.setArtwork(images)
        }
    }

    /// Exportiert das Cover des ersten Zieltracks als Datei (§4.5).
    func exportArtwork(to url: URL) throws {
        guard let artwork = operationTargets.first?.edited.artwork.first else { return }
        try artwork.data.write(to: url)
    }

    // MARK: - Music.app (§4.7)

    func addToMusic() {
        let urls = operationTargets.map(\.url)
        do {
            try MusicApp.add(urls)
        } catch {
            failures.append(SaveFailure(
                filename: String(localized: "Music"),
                message: error.localizedDescription
            ))
            isShowingFailureSheet = true
        }
    }

    // MARK: - All in One (§4.4)

    /// Reine Verkettung, keine eigene Logik: Nummerierung → Schreibweise →
    /// Dateibenennung → Speichern.
    struct AllInOneOptions: Sendable {
        var numbering: NumberingOptions? = NumberingOptions()
        var textCase: TextCase? = .titleCase
        var language: TextCase.Language = .english
        var caseFields: Set<TagField>
        var filenamePattern: String? = "%track% - %artist% - %title%"
        var savesAfterwards = true

        init(
            numbering: NumberingOptions? = NumberingOptions(),
            textCase: TextCase? = .titleCase,
            language: TextCase.Language = .english,
            caseFields: Set<TagField>? = nil,
            filenamePattern: String? = "%track% - %artist% - %title%",
            savesAfterwards: Bool = true
        ) {
            self.numbering = numbering
            self.textCase = textCase
            self.language = language
            self.caseFields = caseFields ?? Set(AppState.textFields)
            self.filenamePattern = filenamePattern
            self.savesAfterwards = savesAfterwards
        }
    }

    func applyAllInOne(_ options: AllInOneOptions) async {
        if let numbering = options.numbering {
            applyNumbering(numbering)
        }
        if let textCase = options.textCase {
            applyCase(textCase, language: options.language, fields: options.caseFields)
        }
        if let pattern = options.filenamePattern, !pattern.isEmpty {
            applyFilenamePattern(pattern, padsNumbers: options.numbering?.padsNumbers ?? true)
        }
        if options.savesAfterwards {
            await save()
        }
    }
}
