//
//  AppState+Operations.swift
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
//  The batch operations from the toolbar: numbering (§4.2), capitalization
//  (§4.3), the pattern engine in both directions (§4.4), cover pictures
//  (§4.5) and the Music app (§4.7).
//
//  All of them work on the **editor state**, never directly on disk.
//  Nothing is written until the user saves.
//

import AppKit
import Foundation

extension AppState {

    /// Target of every operation: the selection, or the whole list when
    /// nothing is selected. Tagr behaves the same way.
    var operationTargets: [TrackFile] {
        let selected = trackList.selectedTracks
        return selected.isEmpty ? trackList.tracksInDisplayOrder : selected
    }

    /// The same tracks, but in table order — decisive for numbering.
    var operationTargetsInDisplayOrder: [TrackFile] {
        let targets = Set(operationTargets.map(\.id))
        return trackList.tracksInDisplayOrder.filter { targets.contains($0.id) }
    }

    // MARK: - Numbering (§4.2)

    func applyNumbering(_ options: NumberingOptions) {
        Numbering.apply(options, to: operationTargetsInDisplayOrder)
    }

    // MARK: - Capitalization (§4.3)

    func applyCase(_ textCase: TextCase, language: TextCase.Language, fields: Set<TagField>) {
        for track in operationTargets {
            for field in fields {
                guard let value = track.edited.stringValue(for: field), !value.isEmpty else { continue }
                track.set(textCase.apply(to: value, language: language), for: field)
            }
        }
    }

    /// Fields capitalization can sensibly be applied to. `nonisolated`, so
    /// that `AllInOneOptions` can reach the list too.
    nonisolated static let textFields: [TagField] = [
        .title, .artist, .albumArtist, .album, .composer, .genre, .comment,
    ]

    // MARK: - Find and replace (§4.3.1)

    /// One change a replacement would make — for the preview.
    struct ReplacementChange: Identifiable, Equatable {
        var id: String { "\(trackID)-\(field.rawValue)" }
        let trackID: TrackFile.ID
        let filename: String
        let field: TagField
        let old: String
        let new: String
    }

    /// Every change the replacement would make on the targets, in table
    /// order. Throws for an invalid regular expression.
    func replacementPreview(_ replacement: TextReplacement,
                            fields: Set<TagField>) throws -> [ReplacementChange] {
        var changes: [ReplacementChange] = []
        for track in operationTargetsInDisplayOrder {
            for field in Self.textFields where fields.contains(field) {
                guard let old = track.edited.stringValue(for: field), !old.isEmpty,
                      let new = try replacement.apply(to: old), new != old else { continue }
                changes.append(ReplacementChange(trackID: track.id, filename: track.filename,
                                                 field: field, old: old, new: new))
            }
        }
        return changes
    }

    /// Applies exactly what the preview shows. Only changed fields are
    /// marked as touched — a field the pattern does not match stays
    /// untouched (spec §4.1). A field replaced down to nothing is cleared.
    @discardableResult
    func applyReplacement(_ replacement: TextReplacement, fields: Set<TagField>) throws -> Int {
        let changes = try replacementPreview(replacement, fields: fields)
        for change in changes {
            trackList.track(id: change.trackID)?.set(change.new, for: change.field)
        }
        return changes.count
    }

    // MARK: - Tags → file name (§4.4)

    /// Preview before anything happens. Returns the proposed name per track —
    /// collisions are already resolved.
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
            // If the proposal equals the current name, there is nothing to do.
            track.proposedFilename = name == track.filename ? nil : name
        }
    }

    func clearProposedFilenames() {
        operationTargets.forEach { $0.proposedFilename = nil }
    }

    // MARK: - File name → tags (§4.4)

    struct ExtractionPreview: Identifiable {
        let id: TrackFile.ID
        let track: TrackFile
        let subject: String
        /// `nil` means: does not fit the pattern, skipped.
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

    /// Takes over only the lines that match. Non-matching ones stay untouched
    /// (spec §4.4).
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

    // MARK: - Cover pictures (§4.5)

    /// Sets the picture on **all** target tracks — the most common case.
    ///
    /// Scaling and encoding no longer happen here but in the import dialog: a
    /// global preset never gets it right for every picture anyway.
    func applyArtwork(_ artwork: Artwork, replacing: Bool = true) {
        for track in operationTargets {
            // When appending, do not keep the same picture type twice — two
            // "Front Cover" pictures in one file are a mistake, not a booklet.
            let existing = replacing
                ? []
                : track.edited.artwork.filter { $0.pictureType != artwork.pictureType }
            track.setArtwork(existing + [artwork])
        }
    }

    /// Removes all pictures.
    func removeArtwork() {
        operationTargets.forEach { $0.setArtwork([]) }
    }

    /// Removes exactly one picture. Only useful when the selection carries
    /// the same pictures — otherwise the well shows nothing anyway.
    func removeArtwork(at index: Int) {
        for track in operationTargets {
            var images = track.edited.artwork
            guard images.indices.contains(index) else { continue }
            images.remove(at: index)
            track.setArtwork(images)
        }
    }

    /// Exports the cover of the first target track as a file (§4.5).
    func exportArtwork(to url: URL) throws {
        guard let artwork = operationTargets.first?.edited.artwork.first else { return }
        try artwork.data.write(to: url)
    }

    // MARK: - Music app (§4.7)

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

    /// Pure chaining, no logic of its own: numbering → capitalization →
    /// renaming → saving.
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
