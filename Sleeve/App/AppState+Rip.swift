//
//  AppState+Rip.swift
//  Sleeve
//
//  Modus „Rippen" (Spec §6).
//
//  Der Ripper ist ein Eingangsweg für die bestehende Pipeline: Spuren werden
//  als WAV abgelegt, landen in derselben Trackliste wie alle anderen Dateien
//  und werden von dort aus getaggt und umgewandelt. Deshalb steht hier kein
//  eigener Konverter.
//

import AppKit
import SwiftUI
import Foundation

extension AppState {

    // MARK: - Scheibe erkennen

    /// Liest TOC, CD-TEXT und Kennungen der eingelegten Scheibe.
    func refreshDisc() async {
        isInspectingDisc = true
        defer { isInspectingDisc = false }
        do {
            let snapshot = try await ripEngine.inspect()
            disc = snapshot
            discError = nil
            // Alle Audiospuren sind vorausgewählt — das ist der Normalfall.
            selectedRipTracks = Set(snapshot.toc.audioTracks.map(\.number))
            // Ein von Hand gesetzter Ordnername gehörte zur vorigen CD.
            ripFolderName = ""
            applyCDText()
        } catch {
            disc = nil
            discError = Self.describeDiscError(error)
            selectedRipTracks = []
            discTitles = [:]
            discTrackArtists = [:]
        }
    }

    /// Übernimmt, was auf der Scheibe selbst steht. Kostet kein Netz und ist
    /// für Alben, die in keiner Datenbank stehen, oft die einzige Quelle.
    func applyCDText() {
        guard let disc, let text = disc.cdText else { return }
        discAlbum = text.albumTitle ?? ""
        discArtist = text.albumArtist ?? ""
        discComposer = text.albumComposer ?? ""
        for track in disc.toc.audioTracks {
            if let title = text.title(forTrack: track.number) {
                discTitles[track.number] = title
            }
            // Nur eintragen, wo die Spur wirklich einen eigenen Interpreten
            // trägt — sonst stünde bei jedem Track dasselbe.
            if let performer = text.performers[track.number],
               performer != text.albumArtist {
                discTrackArtists[track.number] = performer
            }
        }
        // CD-TEXT kennt weder Jahr noch Genre; beides bleibt, wie es ist.
        discMetadataSource = .cdText
    }

    /// Sucht die Pressung über die Disc ID. Trifft das nicht, bleibt die
    /// Textsuche — und notfalls unbenannt rippen und hinterher taggen.
    func lookupDisc() async {
        guard let disc else { return }
        isLookingUpDisc = true
        discLookupMessage = nil
        defer { isLookingUpDisc = false }

        do {
            // Erst die Disc ID — sie trifft genau diese Pressung.
            var found = try await lookup.musicBrainz.releases(discID: disc.discID)
            if found.isEmpty {
                // Dann die unschärfere Suche über die rohe TOC.
                found = try await lookup.musicBrainz.releases(
                    tocParameter: disc.toc.musicBrainzTOCParameter)
            }
            discLookupCandidates = found

            guard let best = found.first else {
                discLookupMessage = disc.cdText == nil
                    ? String(localized: "Not listed at MusicBrainz. Enter the details yourself.")
                    : String(localized: "Not listed at MusicBrainz — keeping the CD-TEXT.")
                return
            }
            apply(best)
        } catch {
            discLookupMessage = LookupService.describe(error)
        }
    }

    /// Übernimmt eine gefundene Pressung in die Eingabefelder.
    func apply(_ release: LookupRelease) {
        discAlbum = release.title
        discArtist = release.albumArtist ?? discArtist
        if let year = release.year { discYear = String(year) }
        // MusicBrainz führt mehrere Genres; das erste ist das gebräuchlichste.
        if let genre = release.genres.first { discGenre = genre }

        for track in release.tracks {
            guard let number = track.number ?? track.position.flatMap({ Int($0) })
            else { continue }
            if let title = track.title { discTitles[number] = title }
            if let artist = track.artistName, artist != release.albumArtist {
                discTrackArtists[number] = artist
            }
        }
        discMetadataSource = .musicBrainz
    }

    // MARK: - Rippen

    var ripDestinationFolder: URL {
        ripDestination ?? FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// Die Tags, die eine gerippte Spur bekommt. Aus ihnen entsteht auch der
    /// Dateiname — Muster und Tags müssen dieselbe Quelle haben, sonst heißt
    /// die Datei anders, als in ihr steht.
    func tags(forTrack number: Int) -> AudioTags {
        var tags = AudioTags()
        tags.title = discTitles[number]
        tags.album = discAlbum.isEmpty ? nil : discAlbum
        // Der Track-Interpret weicht bei Klassik und Samplern ab; der
        // Album-Interpret bleibt der der Scheibe.
        tags.artist = discTrackArtists[number] ?? (discArtist.isEmpty ? nil : discArtist)
        tags.albumArtist = discArtist.isEmpty ? nil : discArtist
        tags.composer = disc?.cdText?.composer(forTrack: number)
            ?? (discComposer.isEmpty ? nil : discComposer)
        tags.genre = discGenre.isEmpty ? nil : discGenre
        tags.year = Int(discYear)
        tags.trackNumber = number
        tags.trackTotal = disc?.toc.audioTracks.count
        tags.discNumber = discTotal > 1 ? discNumber : nil
        tags.discTotal = discTotal > 1 ? discTotal : nil
        return tags
    }

    /// Wie die Dateien heißen werden. Zeigt der Bereich als Vorschau an.
    func previewFilename(forTrack number: Int) -> String {
        let base = renderedName(forTrack: number)
        return "\(base).\(ripSettings.format.fileExtension)"
    }

    private func renderedName(forTrack number: Int) -> String {
        let renderer = PatternRenderer()
        let pattern = ripSettings.filenamePattern.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return String(format: "%02d", number) }
        let rendered = renderer.render(pattern, tags: tags(forTrack: number))
            .trimmingCharacters(in: .whitespaces)
        // Ohne Titel bleibt vom Muster oft nur ein Trennzeichen übrig.
        return rendered.isEmpty ? String(format: "%02d", number) : rendered
    }

    /// Was das Rippen gerade verhindert — dieselbe Rolle wie
    /// `conversionBlocker` beim Konvertieren.
    var ripBlocker: String? {
        guard disc != nil else { return String(localized: "No audio CD in the drive.") }
        guard !selectedRipTracks.isEmpty else { return String(localized: "No tracks selected.") }
        guard ripSettings.needsFFmpeg else { return nil }
        guard let ffmpeg else {
            return String(localized: "ffmpeg was not found — pick WAV to rip without it.")
        }
        guard ffmpeg.supports(ripSettings.format) else {
            return ripSettings.format.missingEncoderHint
        }
        return nil
    }

    /// Gesamtfortschritt über alle ausgewählten Spuren. Beim Lesen der
    /// Mittelwert, beim Umwandeln der zweite Abschnitt.
    var ripOverallProgress: Double {
        switch ripStage {
        case .idle:       return 0
        case .converting: return ripConversionProgress
        case .reading:
            guard !selectedRipTracks.isEmpty else { return 0 }
            let sum = selectedRipTracks.reduce(0.0) { $0 + (ripProgress[$1] ?? 0) }
            return sum / Double(selectedRipTracks.count)
        }
    }

    /// Was in der Fußzeile steht, solange gerippt wird.
    var ripStatusText: String {
        switch ripStage {
        case .idle: return ""
        case .converting: return String(localized: "Converting…")
        case .reading:
            if let track = ripCurrentTrack {
                return String(localized: "Reading track \(track)…")
            }
            return String(localized: "Reading the disc…")
        }
    }

    func startRip() {
        guard let disc, ripBlocker == nil, ripTask == nil else { return }

        let folder = ripDestinationFolder
            .appendingPathComponent(sanitizedAlbumFolderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            discError = String(localized: "Cannot create the destination folder")
            return
        }

        let numbers = selectedRipTracks.sorted()
        let settings = ripSettings
        var names: [Int: String] = [:]
        var wanted: [Int: AudioTags] = [:]
        for number in numbers {
            names[number] = renderedName(forTrack: number)
            wanted[number] = tags(forTrack: number)
        }

        isRipping = true
        ripProgress = [:]
        ripReport = nil
        ripFailures = []
        ripStage = .reading

        ripTask = Task { [ripEngine] in
            var produced: [Int: URL] = [:]
            for await event in ripEngine.rip(tracks: numbers, to: folder,
                                             names: names, settings: settings) {
                switch event {
                case let .trackStarted(track):
                    ripCurrentTrack = track
                case let .trackProgress(track, fraction):
                    ripProgress[track] = fraction
                case let .trackFinished(entry, url):
                    ripProgress[entry.number] = 1
                    produced[entry.number] = url
                case let .trackFailed(track, reason):
                    ripFailures.append(SaveFailure(
                        filename: track > 0 ? String(localized: "Track \(track)") : "Disc",
                        message: reason))
                case let .finished(report):
                    ripReport = report
                    writeSidecars(report, to: folder)
                }
            }
            ripCurrentTrack = nil

            // Umwandeln, wenn ein anderes Format gewünscht ist. Die WAVs sind
            // dabei nur Zwischenstand und verschwinden.
            var finalURLs = numbers.compactMap { produced[$0] }
            if settings.needsFFmpeg, !finalURLs.isEmpty, !Task.isCancelled {
                ripStage = .converting
                finalURLs = await convertRipped(produced, tags: wanted,
                                                to: folder, settings: settings)
            }

            ripStage = .idle
            isRipping = false
            ripTask = nil

            await addFiles(finalURLs)
            applyRippedTags(finalURLs, numbers: numbers, produced: produced, wanted: wanted)

            if settings.ejectsWhenDone, ripFailures.isEmpty {
                ripEngine.eject(bsdName: disc.drive.bsdName)
            }
        }
    }

    /// Schickt die gerippten WAVs durch dieselbe Pipeline wie der
    /// Konvertieren-Bereich. Kein zweiter Konverter, keine zweite Fehlerquelle.
    private func convertRipped(_ produced: [Int: URL],
                               tags wanted: [Int: AudioTags],
                               to folder: URL,
                               settings: RipSettings) async -> [URL] {
        guard let ffmpeg else { return Array(produced.values) }

        var conversion = ConversionSettings()
        conversion.format = settings.format
        conversion.bitrate = settings.bitrate
        conversion.compressionLevel = settings.compressionLevel
        conversion.destinationFolder = folder
        // Der Name steht schon am WAV; das Muster hier noch einmal anzuwenden
        // hieße, es doppelt zu rendern.
        conversion.filenamePattern = ""
        // Das WAV ist Zwischenstand, kein Original.
        conversion.keepsOriginals = false

        let planner = ConversionPlanner(tool: ffmpeg, settings: conversion)
        let inputs = produced.sorted { $0.key < $1.key }.map { number, url in
            ConversionPlanner.Input(trackID: UUID(), url: url,
                                    tags: wanted[number] ?? AudioTags())
        }
        guard let jobs = try? planner.plan(inputs) else {
            ripFailures.append(SaveFailure(
                filename: String(localized: "Conversion"),
                message: settings.format.missingEncoderHint))
            return Array(produced.values)
        }

        var results: [URL] = []
        var done = 0
        for await outcome in ConversionQueue(planner: planner,
                                             artworkOptions: .passthrough).run(jobs) {
            if let destination = outcome.destination {
                results.append(destination)
            } else {
                ripFailures.append(SaveFailure(
                    filename: outcome.source.lastPathComponent,
                    message: Self.describeConversion(outcome.error)))
            }
            done += 1
            ripConversionProgress = Double(done) / Double(max(1, jobs.count))
            if Task.isCancelled { break }
        }
        return results.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func describeConversion(_ error: ConversionQueue.ConversionError?) -> String {
        switch error {
        case .ffmpegFailed(let message): message
        case .ffmpegMissing:             String(localized: "ffmpeg was not found.")
        case .taggingFailed:             String(localized: "The tags could not be written.")
        case .moveFailed:                String(localized: "The file could not be moved.")
        case nil:                        ""
        }
    }

    func cancelRip() {
        ripTask?.cancel()
        ripTask = nil
        isRipping = false
        ripCurrentTrack = nil
    }

    // MARK: - Nachbereiten

    /// Protokoll und Cue Sheet neben die Dateien legen.
    private func writeSidecars(_ report: RipReport, to folder: URL) {
        let album = discAlbum, artist = discArtist
        let name = sanitizedAlbumFolderName
        if ripSettings.writesLog {
            let text = report.logText(albumTitle: album.isEmpty ? nil : album,
                                      albumArtist: artist.isEmpty ? nil : artist)
            try? text.write(to: folder.appendingPathComponent("\(name).log"),
                            atomically: true, encoding: .utf8)
        }
        if ripSettings.writesCueSheet {
            let cue = report.cueSheet(albumTitle: album.isEmpty ? nil : album,
                                      albumArtist: artist.isEmpty ? nil : artist,
                                      audioFileName: "\(name).wav")
            try? cue.write(to: folder.appendingPathComponent("\(name).cue"),
                           atomically: true, encoding: .utf8)
        }
    }

    /// Trägt die Angaben in die Liste ein. Beim Umwandeln hat ffmpeg sie
    /// schon geschrieben; hier geht es darum, dass sie auch in der Ansicht
    /// stehen.
    private func applyRippedTags(_ urls: [URL], numbers: [Int],
                                 produced: [Int: URL], wanted: [Int: AudioTags]) {
        // Zuordnung über die Reihenfolge — nach dem Umwandeln heißen die
        // Dateien anders, als sie gerippt wurden.
        let ordered = numbers.filter { produced[$0] != nil }
        for (index, url) in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            .enumerated() {
            guard index < ordered.count,
                  let track = trackList.tracks.first(where: { $0.url == url }),
                  let tags = wanted[ordered[index]] else { continue }
            for field in TagField.allCases where field != .artwork {
                if let value = tags.stringValue(for: field) {
                    track.set(value, for: field)
                }
            }
        }
    }

    /// Wie der Ordner heißt, wenn nichts eingetragen ist — zugleich der
    /// Platzhaltertext im Feld.
    var suggestedAlbumFolderName: String {
        let raw = [discArtist, discAlbum].filter { !$0.isEmpty }.joined(separator: " - ")
        return PatternRenderer().sanitize(raw.isEmpty ? "Audio CD" : raw)
    }

    /// Der Name, der wirklich angelegt wird. Ein eigener Eintrag sticht den
    /// Vorschlag; leer heißt, es bleibt beim Vorschlag.
    var sanitizedAlbumFolderName: String {
        let custom = ripFolderName.trimmingCharacters(in: .whitespaces)
        return custom.isEmpty ? suggestedAlbumFolderName
                              : PatternRenderer().sanitize(custom)
    }

    // MARK: - Fehlertexte

    static func describeDiscError(_ error: Error) -> String {
        switch error {
        case CDDriveError.noDrive:
            String(localized: "No optical drive found.")
        case CDDriveError.noDisc:
            String(localized: "No audio CD in the drive.")
        case let CDDriveError.cannotOpen(reason):
            String(localized: "Cannot open the drive: \(reason)")
        default:
            String(localized: "The disc could not be read.")
        }
    }
}

// MARK: - Scheibenwechsel bemerken

/// Beobachtet, ob eine Audio-CD eingelegt oder ausgeworfen wird.
///
/// `NSWorkspace` meldet das Einbinden des CDDA-Volumes — das genügt, denn
/// genau dann steht auch die TOC bereit.
@MainActor
final class DiscWatcher {
    /// Die Beobachter liegen in einer eigenen kleinen Box, damit `deinit` —
    /// das außerhalb des Hauptaktors läuft — sie noch abmelden darf. Sie
    /// werden ausschließlich beim Anmelden angefasst, deshalb ist das sicher.
    private final class Storage: @unchecked Sendable {
        let center: NotificationCenter
        var observers: [NSObjectProtocol] = []
        init(center: NotificationCenter) { self.center = center }
    }

    private let storage = Storage(center: NSWorkspace.shared.notificationCenter)

    func start(onChange: @escaping @MainActor () -> Void) {
        guard storage.observers.isEmpty else { return }
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            storage.observers.append(
                storage.center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { onChange() }
                })
        }
    }

    deinit {
        for observer in storage.observers { storage.center.removeObserver(observer) }
    }
}

/// Woher die angezeigten Metadaten stammen. Der Nutzer soll sehen, ob er
/// Angaben von der Scheibe selbst oder aus dem Netz vor sich hat.
enum DiscMetadataSource: Sendable {
    case cdText
    case musicBrainz

    var label: LocalizedStringKey {
        switch self {
        case .cdText:      "from CD-TEXT"
        case .musicBrainz: "from MusicBrainz"
        }
    }
}

/// Woran der Ripper gerade arbeitet. Der Fortschritt steht in der Fußzeile,
/// nicht im Formular — dort scrollt er weg, genau wenn man ihn braucht.
enum RipStage: Sendable, Equatable {
    case idle
    case reading
    case converting

    var label: LocalizedStringKey {
        switch self {
        case .idle:       ""
        case .reading:    "Reading the disc…"
        case .converting: "Converting…"
        }
    }
}
