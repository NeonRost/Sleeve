//
//  RipEngine.swift
//  Sleeve
//
//  Führt zusammen: Laufwerk finden, Scheibe erkennen, Spuren lesen, als WAV
//  ablegen. Was danach kommt — konvertieren und taggen — macht die bestehende
//  Pipeline.
//
//  Ein Aktor, weil das Laufwerk keine gleichzeitigen Zugriffe verträgt. Der
//  `CDDrive` mit seinem Dateideskriptor verlässt diesen Aktor nie.
//

import Foundation

/// Was von der Scheibe bekannt ist, bevor gerippt wird.
struct DiscSnapshot: Sendable {
    var drive: CDDriveInfo
    var toc: DiscTOC
    var cdText: CDText?
    var mcn: String?
    var currentSpeed: Int?
    /// Ob das Laufwerk C2-Fehlerzeiger wirklich herausgibt. Ausprobiert,
    /// nicht angenommen — siehe `CDDrive.supportsC2`.
    var supportsC2 = false

    var discID: String { toc.musicBrainzDiscID }
}

actor RipEngine {

    enum Event: Sendable {
        case trackStarted(track: Int)
        case trackProgress(track: Int, fraction: Double)
        case trackFinished(RipReport.Entry, url: URL)
        case trackFailed(track: Int, reason: String)
        case finished(RipReport)
    }

    // MARK: - Erkennen

    /// Liest alles, was ohne Rippen über die Scheibe zu erfahren ist.
    func inspect() throws -> DiscSnapshot {
        guard let info = CDDriveFinder.availableDrives().first else {
            throw CDDriveError.noDrive
        }
        guard let raw = info.rawTOC, var toc = DiscTOC(rawTOC: raw) else {
            throw CDDriveError.noDisc
        }

        let drive = try CDDrive(info: info)
        let settings = RipSettings.load()

        let text = drive.readCDText()
        var mcn: String?
        if settings.readsSubchannel {
            mcn = drive.readMCN()
            // ISRCs gleich mitnehmen — später ist die Scheibe vielleicht raus.
            let isrcs = drive.readISRCs(for: toc.tracks)
            for index in toc.tracks.indices {
                toc.tracks[index].isrc = isrcs[toc.tracks[index].number]
            }
        }
        toc.mcn = mcn

        let probeLBA = toc.audioTracks.first?.startLBA ?? 0
        return DiscSnapshot(drive: info, toc: toc, cdText: text,
                            mcn: mcn, currentSpeed: drive.currentSpeed(),
                            supportsC2: drive.supportsC2(probeLBA: probeLBA))
    }

    // MARK: - Rippen

    /// Rippt die angegebenen Spuren in `destination` und meldet den Verlauf.
    /// `names` gibt je Spur den Dateinamen ohne Endung vor. Fehlt einer,
    /// bleibt es bei der zweistelligen Tracknummer.
    nonisolated func rip(tracks numbers: [Int],
                         to destination: URL,
                         names: [Int: String] = [:],
                         settings: RipSettings) -> AsyncStream<Event> {
        AsyncStream { continuation in
            let task = Task {
                await self.perform(tracks: numbers, to: destination, names: names,
                                   settings: settings, continuation: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func perform(tracks numbers: [Int],
                         to destination: URL,
                         names: [Int: String],
                         settings: RipSettings,
                         continuation: AsyncStream<Event>.Continuation) async {
        let started = Date()
        guard let info = CDDriveFinder.availableDrives().first,
              let raw = info.rawTOC, var toc = DiscTOC(rawTOC: raw) else {
            continuation.yield(.trackFailed(track: 0, reason: "no disc"))
            return
        }

        let drive: CDDrive
        do {
            drive = try CDDrive(info: info)
        } catch {
            continuation.yield(.trackFailed(track: 0, reason: "\(error)"))
            return
        }
        drive.setSpeed(multiplier: settings.speedMultiplier)

        // Ohne das stünde im Protokoll keine MCN: hier wird die TOC frisch
        // aus IOKit gelesen und trägt die Kennungen noch nicht.
        if settings.readsSubchannel {
            toc.mcn = drive.readMCN()
            let isrcs = drive.readISRCs(for: toc.tracks)
            for index in toc.tracks.indices {
                toc.tracks[index].isrc = isrcs[toc.tracks[index].number]
            }
        }

        // Lieber ohne C2 lesen als mit einem Laufwerk, das dabei Unsinn
        // liefert. Die Einstellung bleibt stehen, der Durchgang läuft ohne —
        // und das Protokoll sagt es.
        var effective = settings
        if effective.usesC2, !drive.supportsC2(probeLBA: toc.audioTracks.first?.startLBA ?? 0) {
            effective.usesC2 = false
            effective.c2WasRequestedButUnavailable = true
        }

        let reader = CDReader(drive: drive, settings: effective)
        var entries: [RipReport.Entry] = []

        for number in numbers {
            guard !Task.isCancelled else { break }
            guard let track = toc.tracks.first(where: { $0.number == number }),
                  !track.isData else { continue }

            continuation.yield(.trackStarted(track: number))
            do {
                let result = try reader.rip(track: track) { progress in
                    if case let .sector(done, total) = progress, total > 0 {
                        continuation.yield(.trackProgress(
                            track: number, fraction: Double(done) / Double(total)))
                    }
                }
                let base = names[number] ?? String(format: "%02d", number)
                let url = destination.appendingPathComponent("\(base).wav")
                try WAVWriter.write(pcm: result.audio, to: url)

                let entry = RipReport.Entry(result: result)
                entries.append(entry)
                continuation.yield(.trackFinished(entry, url: url))
            } catch {
                continuation.yield(.trackFailed(track: number, reason: "\(error)"))
            }
        }

        // Ist C2 erst unterwegs ausgefallen, gehört das genauso ins
        // Protokoll wie ein Ausfall, den die Vorabprüfung gefunden hat.
        if reader.c2Fellthrough {
            effective.usesC2 = false
            effective.c2WasRequestedButUnavailable = true
        }

        let report = RipReport(drive: info, toc: toc, settings: effective,
                               entries: entries, started: started, ended: Date())
        continuation.yield(.finished(report))
    }

    /// Wirft die Scheibe aus — und zwar wirklich.
    ///
    /// `diskutil eject` allein genügt **nicht**: es gibt das Medium nur
    /// logisch frei. Danach meldet das Laufwerk „No Media Inserted", das
    /// Volume ist aus dem Finder verschwunden — und die Schublade bleibt zu,
    /// die Scheibe liegt weiter drin. Gemessen an einem ASUS BW-16D1X-U über
    /// USB.
    ///
    /// Deshalb zwei Schritte: erst das Volume sauber freigeben, damit macOS
    /// nicht dazwischenfunkt, dann über `drutil` die Lade öffnen.
    ///
    /// `drutil` spricht das voreingestellte Laufwerk an. Bei mehreren
    /// optischen Laufwerken am selben Rechner träfe es womöglich das falsche —
    /// das ist selten genug, um es hier nicht aufzulösen.
    nonisolated func eject(bsdName: String) {
        run("/usr/sbin/diskutil", ["unmount", "/dev/\(bsdName)"])
        run("/usr/bin/drutil", ["tray", "eject"])
    }

    private nonisolated func run(_ path: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        // Auf das Ende warten: sonst öffnet die Lade, bevor das Volume
        // freigegeben ist, und macOS meldet eine unsaubere Entnahme.
        process.waitUntilExit()
    }
}

// MARK: - Abbild der ganzen Scheibe

extension RipEngine {

    enum ImageEvent: Sendable {
        case reading(fraction: Double)
        case converting
        case finished(ImageResult)
        case failed(String)
    }

    struct ImageResult: Sendable {
        var audioURL: URL
        var cueURL: URL
        var byteCount: Int
        var crc: UInt32
        var isClean: Bool
        var c2FellThrough: Bool
    }

    /// Schreibt die ganze Scheibe als ein Stück plus Cue Sheet.
    ///
    /// Gelesen wird identisch zum normalen Rippen — gleicher Modus, gleicher
    /// Versatz, gleiche Wiederholungen. Nur die Verpackung unterscheidet sich.
    /// Eine Trackauswahl gibt es hier bewusst nicht: ein Abbild ist immer die
    /// ganze Scheibe, sonst stimmen die Zeiten im Cue Sheet nicht mehr.
    nonisolated func createImage(in folder: URL,
                                 baseName: String,
                                 format: DiscImageFormat,
                                 settings: RipSettings,
                                 albumTitle: String?,
                                 albumArtist: String?,
                                 trackTitles: [Int: String],
                                 ffmpeg: FFmpegTool?) -> AsyncStream<ImageEvent> {
        AsyncStream { continuation in
            let task = Task {
                await self.performImage(in: folder, baseName: baseName, format: format,
                                        settings: settings, albumTitle: albumTitle,
                                        albumArtist: albumArtist, trackTitles: trackTitles,
                                        ffmpeg: ffmpeg, continuation: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func performImage(in folder: URL,
                              baseName: String,
                              format: DiscImageFormat,
                              settings: RipSettings,
                              albumTitle: String?,
                              albumArtist: String?,
                              trackTitles: [Int: String],
                              ffmpeg: FFmpegTool?,
                              continuation: AsyncStream<ImageEvent>.Continuation) async {
        let started = Date()
        guard let info = CDDriveFinder.availableDrives().first,
              let raw = info.rawTOC, var toc = DiscTOC(rawTOC: raw) else {
            continuation.yield(.failed(String(localized: "No audio CD in the drive.")))
            return
        }
        guard !toc.hasDataTrack else {
            // Eine Datenspur roh mitzuschreiben hieße, sie auszulesen — das
            // ist nicht, wofür dieser Modus da ist (Spec §6.8).
            continuation.yield(.failed(String(localized: "This disc carries a data track. Sleeve images audio discs only.")))
            return
        }

        let drive: CDDrive
        do { drive = try CDDrive(info: info) } catch {
            continuation.yield(.failed("\(error)"))
            return
        }
        drive.setSpeed(multiplier: settings.speedMultiplier)

        var effective = settings
        if effective.usesC2, !drive.supportsC2(probeLBA: 0) {
            effective.usesC2 = false
            effective.c2WasRequestedButUnavailable = true
        }
        if effective.readsSubchannel {
            toc.mcn = drive.readMCN()
            let isrcs = drive.readISRCs(for: toc.tracks)
            for index in toc.tracks.indices { toc.tracks[index].isrc = isrcs[toc.tracks[index].number] }
        }

        // Das WAV ist bei FLAC nur Zwischenstand und verschwindet danach.
        let audioExtension = format == .flac ? "wav" : format.fileExtension
        let audioURL = folder.appendingPathComponent("\(baseName).\(audioExtension)")
        let totalBytes = toc.leadOutLBA * CDGeometry.bytesPerSector

        guard FileManager.default.createFile(atPath: audioURL.path(percentEncoded: false),
                                             contents: nil) else {
            continuation.yield(.failed(String(localized: "Cannot create the destination folder")))
            return
        }
        guard let handle = try? FileHandle(forWritingTo: audioURL) else {
            continuation.yield(.failed(String(localized: "Cannot create the destination folder")))
            return
        }

        let reader = CDReader(drive: drive, settings: effective)
        var summary = CDReader.ReadSummary()
        do {
            // Der WAV-Kopf steht vorn und braucht die Länge — die kennen wir
            // aus der TOC, bevor das erste Byte gelesen ist.
            if format != .bin {
                try handle.write(contentsOf: WAVWriter.header(forPCMByteCount: totalBytes))
            }
            summary = try reader.readContiguous(fromSector: 0, toSector: toc.leadOutLBA) { chunk in
                try handle.write(contentsOf: chunk)
            } onProgress: { progress in
                if case let .sector(done, total) = progress, total > 0 {
                    continuation.yield(.reading(fraction: Double(done) / Double(total)))
                }
            }
            try handle.close()
        } catch is CancellationError {
            try? handle.close()
            try? FileManager.default.removeItem(at: audioURL)
            return
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: audioURL)
            continuation.yield(.failed("\(error)"))
            return
        }

        if reader.c2Fellthrough {
            effective.usesC2 = false
            effective.c2WasRequestedButUnavailable = true
        }

        // Nach FLAC umwandeln, dann das WAV wegräumen.
        var finalURL = audioURL
        if format == .flac {
            continuation.yield(.converting)
            guard let ffmpeg else {
                continuation.yield(.failed(String(localized: "ffmpeg was not found.")))
                return
            }
            var conversion = ConversionSettings()
            conversion.format = .flac
            conversion.compressionLevel = settings.compressionLevel
            conversion.destinationFolder = folder
            conversion.filenamePattern = ""
            conversion.keepsOriginals = false

            var tags = AudioTags()
            tags.album = albumTitle
            tags.artist = albumArtist
            tags.albumArtist = albumArtist

            let planner = ConversionPlanner(tool: ffmpeg, settings: conversion)
            guard let jobs = try? planner.plan([
                ConversionPlanner.Input(trackID: UUID(), url: audioURL, tags: tags)
            ]) else {
                continuation.yield(.failed(String(localized: "ffmpeg was not found.")))
                return
            }
            var converted: URL?
            for await outcome in ConversionQueue(planner: planner,
                                                 artworkOptions: .passthrough).run(jobs) {
                converted = outcome.destination
                if let error = outcome.error {
                    continuation.yield(.failed("\(error)"))
                    return
                }
            }
            guard let converted else {
                continuation.yield(.failed(String(localized: "ffmpeg was not found.")))
                return
            }
            finalURL = converted
        }

        // Cue Sheet mit dem Namen, der wirklich danebenliegt.
        let report = RipReport(drive: info, toc: toc, settings: effective,
                               entries: [], started: started, ended: Date())
        let cue = report.cueSheet(albumTitle: albumTitle, albumArtist: albumArtist,
                                  audioFileName: finalURL.lastPathComponent,
                                  fileType: format.cueFileType,
                                  titles: trackTitles)
        let cueURL = folder.appendingPathComponent("\(baseName).cue")
        do {
            try cue.write(to: cueURL, atomically: true, encoding: .utf8)
        } catch {
            continuation.yield(.failed("\(error)"))
            return
        }

        if settings.writesLog {
            let log = report.logText(albumTitle: albumTitle, albumArtist: albumArtist)
            try? log.write(to: folder.appendingPathComponent("\(baseName).log"),
                           atomically: true, encoding: .utf8)
        }

        continuation.yield(.finished(ImageResult(
            audioURL: finalURL,
            cueURL: cueURL,
            byteCount: totalBytes,
            crc: summary.finishedCRC,
            isClean: summary.isClean,
            c2FellThrough: effective.c2WasRequestedButUnavailable)))
    }
}
