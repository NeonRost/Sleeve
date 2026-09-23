//
//  RipEngine.swift
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
//  Brings it together: find the drive, identify the disc, read the tracks,
//  store them as WAV. What comes after — converting and tagging — is done
//  by the existing pipeline.
//
//  An actor, because the drive does not tolerate concurrent access. The
//  `CDDrive` with its file descriptor never leaves this actor.
//

import Foundation

/// What is known about the disc before ripping.
struct DiscSnapshot: Sendable {
    var drive: CDDriveInfo
    var toc: DiscTOC
    var cdText: CDText?
    var mcn: String?
    var currentSpeed: Int?
    /// Whether the drive really delivers C2 error pointers. Tried, not
    /// assumed — see `CDDrive.supportsC2`.
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

    // MARK: - Identifying

    /// Reads everything that can be learned about the disc without ripping.
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
            // Take the ISRCs along right away — later the disc may be out.
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

    // MARK: - Ripping

    /// Rips the given tracks into `destination` and reports progress. `names`
    /// gives the file name without extension per track. If one is missing, the
    /// two-digit track number is used.
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

        // Without this the log would show no MCN: here the TOC is read
        // freshly from IOKit and does not carry the identifiers yet.
        if settings.readsSubchannel {
            toc.mcn = drive.readMCN()
            let isrcs = drive.readISRCs(for: toc.tracks)
            for index in toc.tracks.indices {
                toc.tracks[index].isrc = isrcs[toc.tracks[index].number]
            }
        }

        // Better to read without C2 than with a drive that delivers
        // nonsense doing it. The setting stays, the pass runs without —
        // and the log says so.
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

        // If C2 only dropped out along the way, that belongs in the log
        // just like a failure the upfront check found.
        if reader.c2Fellthrough {
            effective.usesC2 = false
            effective.c2WasRequestedButUnavailable = true
        }

        let report = RipReport(drive: info, toc: toc, settings: effective,
                               entries: entries, started: started, ended: Date())
        continuation.yield(.finished(report))
    }

    /// Ejects the disc — for real.
    ///
    /// `diskutil eject` alone is **not** enough: it only releases the medium
    /// logically. Afterwards the drive reports "No Media Inserted", the volume
    /// has disappeared from the Finder — and the tray stays shut, the disc is
    /// still inside. Measured on an ASUS BW-16D1X-U over USB.
    ///
    /// Hence two steps: first release the volume cleanly so that macOS does
    /// not interfere, then open the tray via `drutil`.
    ///
    /// `drutil` addresses the default drive. With several optical drives on
    /// the same machine it might hit the wrong one — rare enough not to be
    /// resolved here.
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
        // Wait for the end: otherwise the tray opens before the volume is
        // released, and macOS reports an improper removal.
        process.waitUntilExit()
    }
}

// MARK: - Image of the whole disc

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

    /// Writes the whole disc as one piece plus a cue sheet.
    ///
    /// Reading is identical to normal ripping — the same mode, the same offset,
    /// the same retries. Only the packaging differs. There is deliberately no
    /// track selection here: an image is always the whole disc, otherwise the
    /// times in the cue sheet are no longer right.
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
            // Writing a data track along raw would mean extracting it — that
            // is not what this mode is for (spec §6.8).
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

        // For FLAC the WAV is only an intermediate and goes away afterwards.
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
            // The WAV header comes first and needs the length — we know it
            // from the TOC before the first byte is read.
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

        // Convert to FLAC, then clean up the WAV.
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

        // Cue sheet with the name that is really next to it.
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
