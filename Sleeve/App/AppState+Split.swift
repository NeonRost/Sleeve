//
//  AppState+Split.swift
//  Sleeve
//
//  Track Splitter (Spec §7).
//
//  Was nach dem Schneiden passiert, unterscheidet Sleeve von einem reinen
//  Splitter: die Stücke landen in der Trackliste. Deshalb gibt es hier
//  **keinen eigenen Tag-Block** für Interpret, Album, Jahr und Cover — das
//  kann der Tag-Bereich längst besser, mit Mehrfachauswahl und Nachschlagen.
//  Geschrieben werden hier nur Titel und Tracknummer, weil die beim Schneiden
//  ohnehin feststehen.
//
//  Wichtig: `-c copy` **erbt die Tags der Quelldatei**. Ohne Korrektur trüge
//  jedes Stück den Titel des ganzen Albums.
//

import AppKit
import Foundation
import SwiftUI

/// Woher die Titel kommen: eine der beiden Quellen von „Album nachschlagen"
/// oder eine eingefügte Trackliste.
enum SplitLookupMode: String, CaseIterable, Identifiable, Sendable {
    case musicBrainz, discogs, pasted
    var id: String { rawValue }

    var provider: LookupProvider? {
        switch self {
        case .musicBrainz: .musicBrainz
        case .discogs:     .discogs
        case .pasted:      nil
        }
    }

    init(_ provider: LookupProvider) {
        switch provider {
        case .musicBrainz: self = .musicBrainz
        case .discogs:     self = .discogs
        }
    }
}

struct SplitResult: Sendable {
    var count: Int
    var folder: URL
    var files: [URL]
}

enum SplitStage: Sendable, Equatable {
    case idle
    case analyzing
    case cutting(done: Int, total: Int)
}

extension AppState {

    // MARK: - Quelle

    /// Vor dem Öffnen des Fensters aufräumen — ein Fehler vom letzten Mal
    /// soll nicht als Erstes zu sehen sein.
    func prepareSplit() {
        splitError = nil
        splitFailures = []
        splitStage = .idle
    }

    func chooseSplitSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadSplitSource(url)
    }

    func loadSplitSource(_ url: URL) {
        guard AudioSplitter.acceptedExtensions.contains(url.pathExtension.lowercased()) else {
            splitError = String(localized: "Sleeve cannot read this file type.")
            return
        }
        splitSource = url
        splitDestination = url.deletingLastPathComponent()
        splitTracks = []
        splitAnalysis = nil
        splitSourceInfo = nil
        splitWaveform = nil
        splitError = nil
        splitStage = .idle
        splitSelectionID = nil
        splitMark = nil
        splitCompleted = nil
        splitMetadata = nil
        splitPasteText = ""
        splitSearch = nil
        splitPreview.stop()

        // Gleich nachsehen, was drinsteckt: davon hängt ab, welche Endung die
        // Stücke bekommen — und ob überhaupt Ton dabei ist.
        guard let tool = ffmpeg else { return }
        Task {
            await splitPreview.check(url)
            do {
                splitSourceInfo = try await AudioSplitter.probe(file: url, ffmpeg: tool)
                await loadWaveform(url, duration: splitSourceInfo?.duration ?? 0, ffmpeg: tool)
            } catch SplitError.noAudioTrack {
                splitError = String(localized: "This file has no audio track.")
                splitSource = nil
            } catch {
                splitError = String(localized: "The file could not be analyzed.")
                splitSource = nil
            }
        }
    }

    /// Rechnet die Hüllkurve einmal durch. Das dauert bei einem langen
    /// Mitschnitt spürbar, deshalb im Hintergrund und mit Anzeige.
    private func loadWaveform(_ url: URL, duration: Double, ffmpeg tool: FFmpegTool) async {
        guard duration > 0 else { return }
        isLoadingWaveform = true
        defer { isLoadingWaveform = false }
        splitWaveform = try? await WaveformSampler.load(url, duration: duration, ffmpeg: tool)
    }

    /// Setzt an dieser Stelle eine neue Grenze — das Gegenstück zum
    /// Verschmelzen.
    ///
    /// Bisher konnten Grenzen nur verschwinden, nie entstehen. Wer in der
    /// Hüllkurve sieht, dass zwei Stücke zusammengefasst wurden, konnte sie
    /// nicht trennen.
    @discardableResult
    func splitTrack(at seconds: Double) -> UUID? {
        guard let index = splitTracks.firstIndex(where: {
            seconds > $0.range.start + SplitTrack.minimumLength
                && seconds < $0.range.end - SplitTrack.minimumLength
        }) else { return nil }

        let existing = splitTracks[index]
        let tail = SplitTrack(range: TrackRange(start: seconds, end: existing.range.end))
        existing.assign(end: seconds)
        existing.detected = existing.range
        splitTracks.insert(tail, at: index + 1)
        return tail.id
    }

    /// Welche Endung die geschnittenen Stücke bekommen.
    var splitOutputExtension: String {
        if case let .convert(format) = splitOutput { return format.fileExtension }
        return splitSourceInfo?.outputExtension
            ?? splitSource?.pathExtension.lowercased()
            ?? "mp3"
    }

    /// Wie das Zielformat in der Auswahl heißt. Bei „wie die Quelle" gehört
    /// die tatsächliche Endung dazu — sonst rät man.
    var splitKeepSourceLabel: String {
        let ext = (splitSourceInfo?.outputExtension ?? "").uppercased()
        return ext.isEmpty
            ? String(localized: "Same as the source")
            : String(localized: "Same as the source (\(ext))")
    }

    var splitBlockerForFormat: String? {
        guard case let .convert(format) = splitOutput else { return nil }
        guard let tool = ffmpeg else { return String(localized: "ffmpeg was not found.") }
        return tool.supports(format) ? nil : format.missingEncoderHint
    }

    // MARK: - Untersuchen

    var splitBlocker: String? {
        guard splitSource != nil else { return String(localized: "Pick an audio file first.") }
        guard ffmpeg != nil else { return String(localized: "ffmpeg was not found.") }
        return nil
    }

    func analyzeSplit() {
        guard let source = splitSource, let tool = ffmpeg, splitTask == nil else { return }
        let threshold = splitThresholdDB
        let minSilence = splitMinimumSilence
        let minTrack = splitMinimumTrackLength

        splitError = nil
        splitStage = .analyzing

        splitTask = Task {
            defer { splitTask = nil; splitStage = .idle }
            do {
                let analysis = try await AudioSplitter.analyze(
                    file: source, thresholdDB: threshold,
                    minDuration: minSilence, ffmpeg: tool)
                splitAnalysis = analysis
                splitPreview.stop()
                splitTracks = AudioSplitter.trackRanges(
                    duration: analysis.duration, silences: analysis.silences,
                    minimumLength: minTrack, levels: splitWaveform
                ).map(SplitTrack.init)
                splitMark = nil
                splitSelectionID = splitTracks.first?.id
                if splitTracks.isEmpty {
                    splitError = String(localized: "No silence found with these settings. Try a higher threshold or a shorter minimum duration.")
                }
            } catch {
                splitError = String(localized: "The file could not be analyzed.")
            }
        }
    }

    // MARK: - Auswahl und Marke

    var selectedSplitTrack: SplitTrack? {
        splitTracks.first { $0.id == splitSelectionID }
    }

    var selectedSplitIndex: Int? {
        splitTracks.firstIndex { $0.id == splitSelectionID }
    }

    var splitDuration: Double { splitSourceInfo?.duration ?? splitAnalysis?.duration ?? 0 }

    func selectSplitTrack(_ id: UUID?) {
        guard id != splitSelectionID else { return }
        splitSelectionID = id
        // Eine neue Zeile heißt: die Marke gehört wieder an ihren Anfang.
        splitMark = nil
        if splitPreview.playingID != nil { splitPreview.stop() }
    }

    /// Wo die Marke steht. Ohne eigene Setzung: **am Anfang** des gewählten
    /// Tracks, auf der grünen Linie.
    ///
    /// Die erste Fassung setzte sie ein Stück davor, damit „Ab Marke
    /// abspielen" von selbst über die Grenze hinweg hörte. Das war nicht zu
    /// erraten — wer einen Track abspielt, erwartet ihn ab seinem Anfang. Über
    /// die Grenze hinweg hören ⏮ und der Knopf in der Trackliste.
    var splitMarkPosition: Double {
        if let splitMark { return splitMark }
        return selectedSplitTrack?.range.start ?? 0
    }

    /// Die Stelle, die gerade gilt: beim Abspielen der laufende Kopf, sonst
    /// die Marke. Darauf beziehen sich „Anfang hierher", „Ende hierher" und
    /// „Hier teilen" — man drückt, was man hört.
    var splitCurrentPosition: Double {
        splitPreview.position ?? splitMarkPosition
    }

    func setSplitMark(_ seconds: Double) {
        splitMark = min(max(0, seconds), splitDuration)
        // Läuft schon etwas, springt die Wiedergabe mit — sonst hört man eine
        // andere Stelle als die, die man gerade angeklickt hat.
        if splitPreview.playingID != nil { playSplitFromMark() }
    }

    // MARK: - Abspielen

    var isSplitPlaying: Bool { splitPreview.playingID != nil }

    func playSplitFromMark() {
        guard let source = splitSource else { return }
        splitPreview.playFrom(id: splitSelectionID ?? UUID(), url: source,
                              position: splitMarkPosition, fileDuration: splitDuration)
    }

    /// Wer beim Hören auf Stopp drückt, meint **diese** Stelle: die Marke
    /// übernimmt den Kopf. Läuft die Hörprobe dagegen von allein aus, bleibt
    /// die Marke, wo sie war — sonst marschierte sie bei jedem Abspielen ein
    /// Stück weiter.
    func toggleSplitPlayback() {
        if isSplitPlaying {
            if let live = splitPreview.position { splitMark = live }
            splitPreview.stop()
        } else {
            playSplitFromMark()
        }
    }

    /// Den Knopf in einer Zeile: auswählen und die vordere Grenze hören.
    func playAcrossStart(of track: SplitTrack) {
        if splitPreview.playingID == track.id { splitPreview.stop(); return }
        splitSelectionID = track.id
        jumpToStartBoundary()
    }

    /// Hört **über** den Anfang hinweg: ein Drittel der Hörprobe davor — Ende
    /// des vorigen Tracks, Pause, Einsatz.
    func jumpToStartBoundary() {
        guard let track = selectedSplitTrack else { return }
        splitMark = max(0, track.range.start - splitPreview.lead)
        playSplitFromMark()
    }

    func jumpToEndBoundary() {
        guard let track = selectedSplitTrack else { return }
        splitMark = max(0, track.range.end - splitPreview.lead)
        playSplitFromMark()
    }

    // MARK: - Grenzen

    /// Verschiebt eine Grenze. Grenze `b` ist der Anfang von Track `b` und
    /// zugleich das Ende von Track `b − 1` — die Tracks liegen lückenlos
    /// aneinander, und das muss beim Bearbeiten so bleiben. Verschöbe man nur
    /// eine Seite, entstünde eine Lücke, und was darin liegt, stünde in keiner
    /// Datei.
    ///
    /// Nur am Anfang der Datei (`b == 0`) und an ihrem Ende (`b == Anzahl`)
    /// lässt sich etwas abschneiden — etwa eine Ansage vor dem ersten Stück.
    func moveBoundary(_ boundary: Int, to seconds: Double) {
        let count = splitTracks.count
        guard count > 0, boundary >= 0, boundary <= count else { return }
        let minimum = SplitTrack.minimumLength

        if boundary == 0 {
            let track = splitTracks[0]
            track.assign(start: min(max(0, seconds), track.range.end - minimum))
        } else if boundary == count {
            let track = splitTracks[count - 1]
            track.assign(end: max(min(seconds, splitDuration), track.range.start + minimum))
        } else {
            let before = splitTracks[boundary - 1], after = splitTracks[boundary]
            let lower = before.range.start + minimum
            let upper = after.range.end - minimum
            guard lower <= upper else { return }
            let position = min(max(seconds, lower), upper)
            before.assign(end: position)
            after.assign(start: position)
        }
    }

    func moveSelectedStart(to seconds: Double) {
        guard let index = selectedSplitIndex else { return }
        moveBoundary(index, to: seconds)
    }

    func moveSelectedEnd(to seconds: Double) {
        guard let index = selectedSplitIndex else { return }
        moveBoundary(index + 1, to: seconds)
    }

    func setSelectedStartHere() { moveSelectedStart(to: splitCurrentPosition) }
    func setSelectedEndHere() { moveSelectedEnd(to: splitCurrentPosition) }

    /// Beide Grenzen des gewählten Tracks zurück — die Nachbarn gehen mit.
    func resetSelectedBoundaries() {
        guard let track = selectedSplitTrack else { return }
        moveSelectedStart(to: track.detected.start)
        moveSelectedEnd(to: track.detected.end)
    }

    /// Kann an der aktuellen Stelle eine neue Grenze entstehen?
    var canSplitHere: Bool {
        let at = splitCurrentPosition
        return splitTracks.contains {
            at > $0.range.start + SplitTrack.minimumLength
                && at < $0.range.end - SplitTrack.minimumLength
        }
    }

    func splitHere() {
        let at = splitCurrentPosition
        if let tail = splitTrack(at: at) {
            splitSelectionID = tail
            splitMark = nil
        }
    }

    /// Den gewählten Track mit dem vorigen zusammenlegen.
    func mergeSelectedWithPrevious() {
        guard let index = selectedSplitIndex, index > 0 else { return }
        let previous = splitTracks[index - 1]
        mergeSplitTrack(splitTracks[index])
        splitSelectionID = previous.id
        splitMark = nil
    }

    /// Eine Grenze entfernen: der Track wandert in seinen Vorgänger.
    func mergeSplitTrack(_ track: SplitTrack) {
        guard let index = splitTracks.firstIndex(where: { $0.id == track.id }) else { return }
        if index > 0 {
            let previous = splitTracks[index - 1]
            previous.assign(end: track.range.end)
            previous.detected = previous.range
        } else if splitTracks.count > 1 {
            let next = splitTracks[1]
            next.assign(start: track.range.start)
            next.detected = next.range
        }
        splitTracks.remove(at: index)
    }

    // MARK: - Trackliste von außen (§7.12)

    /// Ein Vorschlag für die Suche, aus dem Dateinamen: „Interpret - Album",
    /// ohne die Klammern, die Uploader anhängen — „(Full Album)", „(486p…)".
    var suggestedSplitSearch: (artist: String, album: String) {
        guard let source = splitSource else { return ("", "") }
        var name = source.deletingPathExtension().lastPathComponent
        while let range = name.range(of: #"\s*[\(\[][^\(\)\[\]]*[\)\]]\s*$"#,
                                     options: .regularExpression) {
            name.removeSubrange(range)
        }
        let parts = name.components(separatedBy: " - ")
        guard parts.count >= 2 else { return ("", name.trimmingCharacters(in: .whitespaces)) }
        return (parts[0].trimmingCharacters(in: .whitespaces),
                parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces))
    }

    /// Legt eine Trackliste auf die gefundenen Tracks.
    ///
    /// Mit `alignBoundaries` werden die Grenzen neu gesetzt — aus Startzeiten
    /// oder Längen, eingerastet an erkannten Stillen in der Nähe. Das findet
    /// auch Übergänge ohne Pause, die keine Stille-Erkennung sieht. Ohne
    /// bleiben die Grenzen, und die Titel werden der Reihe nach übernommen.
    ///
    /// `fields` sagt, was davon in die Tags soll — dieselbe Auswahl wie beim
    /// Taggen. Was nicht gewählt ist, bleibt, wie es war.
    func applyListing(_ listing: TrackListing,
                      fields: Set<TagField> = Set(TrackListing.takeOverFields),
                      alignBoundaries: Bool) {
        splitPreview.stop()
        if alignBoundaries, let analysis = splitAnalysis {
            let candidates = AudioSplitter.candidateCuts(
                silences: analysis.silences, duration: splitDuration, levels: splitWaveform)
            let ranges: [TrackRange]
            if listing.hasStarts {
                ranges = AudioSplitter.alignedRanges(
                    starts: listing.entries.compactMap(\.start),
                    duration: splitDuration, candidates: candidates)
            } else if listing.hasDurations {
                ranges = AudioSplitter.alignedRanges(
                    durations: listing.entries.compactMap(\.duration),
                    duration: splitDuration, candidates: candidates)
            } else {
                ranges = []
            }
            if !ranges.isEmpty {
                splitTracks = ranges.map(SplitTrack.init)
            }
        }
        if fields.contains(.title) {
            for (track, entry) in zip(splitTracks, listing.entries) {
                track.title = entry.title
            }
        }
        var metadata = splitMetadata ?? TrackListing(entries: [])
        if fields.contains(.album), let album = listing.album { metadata.album = album }
        if fields.contains(.artist), let artist = listing.artist { metadata.artist = artist }
        if fields.contains(.year), let year = listing.year { metadata.year = year }
        if fields.contains(.genre), let genre = listing.genre { metadata.genre = genre }
        let hasMetadata = metadata.album != nil || metadata.artist != nil
            || metadata.year != nil || metadata.genre != nil
        splitMetadata = hasMetadata ? metadata : nil
        splitSelectionID = splitTracks.first?.id
        splitMark = nil
    }

    // MARK: - Schneiden

    var splitCanRun: Bool {
        !splitTracks.isEmpty && splitBlocker == nil
            && splitBlockerForFormat == nil && splitTask == nil
    }

    /// Der Dateiname eines Stücks — dasselbe Muster wie beim Rippen.
    func splitFilename(at index: Int) -> String {
        guard splitTracks.indices.contains(index), let source = splitSource else { return "" }
        let base = renderedSplitName(at: index)
        _ = source
        return "\(base).\(splitOutputExtension)"
    }

    private func renderedSplitName(at index: Int) -> String {
        let fallback = String(format: "%02d", index + 1)
        let pattern = splitPattern.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return fallback }
        let rendered = PatternRenderer()
            .render(pattern, tags: splitTags(at: index))
            .trimmingCharacters(in: .whitespaces)
        return rendered.isEmpty ? fallback : rendered
    }

    private func splitTags(at index: Int) -> AudioTags {
        var tags = AudioTags()
        let title = splitTracks[index].title.trimmingCharacters(in: .whitespaces)
        tags.title = title.isEmpty ? nil : title
        tags.trackNumber = index + 1
        tags.trackTotal = splitTracks.count
        tags.album = splitMetadata?.album
        tags.artist = splitMetadata?.artist
        tags.albumArtist = splitMetadata?.artist
        tags.year = splitMetadata?.year
        tags.genre = splitMetadata?.genre
        return tags
    }

    /// Welche Felder beim Schneiden geschrieben werden. Titel, Nummer und
    /// Kommentar immer (§7.2); Album, Interpret, Jahr und Genre nur, wenn eine
    /// Trackliste sie geliefert hat — sonst bleibt, was die Quelle trug.
    private var splitWrittenFields: Set<TagField> {
        var fields: Set<TagField> = [.title, .trackNumber, .comment]
        if splitMetadata?.album != nil { fields.insert(.album) }
        if splitMetadata?.artist != nil { fields.formUnion([.artist, .albumArtist]) }
        if splitMetadata?.year != nil { fields.insert(.year) }
        if splitMetadata?.genre != nil { fields.insert(.genre) }
        return fields
    }

    func startSplit() {
        guard splitCanRun, let source = splitSource, let tool = ffmpeg else { return }
        splitPreview.stop()
        let folder = splitDestination ?? source.deletingLastPathComponent()
        let jobs = splitTracks.indices.map {
            (range: splitTracks[$0].range, name: renderedSplitName(at: $0), tags: splitTags(at: $0))
        }
        let fields = splitWrittenFields
        let audioOnly = splitSourceInfo?.hasVideo ?? false
        let ext = splitOutputExtension
        let output = splitOutput
        let rate = splitBitrate
        let level = splitCompressionLevel

        splitError = nil
        splitCompleted = nil
        splitStage = .cutting(done: 0, total: jobs.count)

        splitTask = Task {
            var produced: [URL] = []
            var failures: [SaveFailure] = []

            for (index, job) in jobs.enumerated() {
                if Task.isCancelled { break }
                splitStage = .cutting(done: index, total: jobs.count)

                let destination = Self.freeURL(in: folder, name: job.name, extension: ext)
                do {
                    try await AudioSplitter.cut(source: source, range: job.range,
                                                to: destination, audioOnly: audioOnly,
                                                output: output, bitrate: rate,
                                                compressionLevel: level, ffmpeg: tool)
                    // `-c copy` schleppt die Tags der Quelle mit. Was die ganze
                    // Aufnahme beschreibt — Interpret, Jahr, Genre —, darf
                    // bleiben. Was die *Quelldatei* beschreibt, nicht:
                    //
                    // - der Titel, sonst hieße jedes Stück wie das ganze Album;
                    // - der Kommentar, der bei Downloads fast immer die
                    //   Herkunfts-URL ist. An einem echten Album-Video
                    //   gemessen: alle 13 Stücke trugen die YouTube-Adresse.
                    //
                    // `comment` steht deshalb mit leerem Wert in der Liste —
                    // das löscht ihn.
                    try? await engine.write(TagEngine.WriteRequest(
                        url: destination, tags: job.tags, fields: fields))
                    produced.append(destination)
                } catch {
                    failures.append(SaveFailure(filename: destination.lastPathComponent,
                                                message: Self.describeSplit(error)))
                }
            }

            splitStage = .idle
            splitTask = nil
            splitFailures = failures
            if !produced.isEmpty {
                // Sichtbar melden, wo die Stücke gelandet sind — ohne das
                // endet der Vorgang stumm, und man sucht die Dateien.
                splitCompleted = SplitResult(count: produced.count, folder: folder,
                                             files: produced)
                await addFiles(produced)
            }
        }
    }

    func cancelSplit() {
        splitTask?.cancel()
        splitTask = nil
        splitStage = .idle
    }

    /// Nie eine vorhandene Datei überschreiben — dieselbe Regel wie beim
    /// Konvertieren.
    private static func freeURL(in folder: URL, name: String, extension ext: String) -> URL {
        let candidate = folder.appendingPathComponent("\(name).\(ext)")
        guard FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false))
        else { return candidate }
        var counter = 2
        while true {
            let next = folder.appendingPathComponent("\(name) (\(counter)).\(ext)")
            if !FileManager.default.fileExists(atPath: next.path(percentEncoded: false)) {
                return next
            }
            counter += 1
        }
    }

    private static func describeSplit(_ error: Error) -> String {
        switch error {
        case SplitError.cutFailed(let detail) where !detail.isEmpty: detail
        case SplitError.analysisFailed: String(localized: "The file could not be analyzed.")
        case SplitError.noAudioTrack: String(localized: "This file has no audio track.")
        case SplitError.missingEncoder(let format): format.missingEncoderHint
        case is CancellationError: String(localized: "Cancelled.")
        default: String(localized: "ffmpeg could not cut this track.")
        }
    }
}
