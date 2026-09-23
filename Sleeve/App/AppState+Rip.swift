//
//  AppState+Rip.swift
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
//  The Rip mode (spec §6).
//
//  The ripper is one more way into the existing pipeline: tracks are stored
//  as WAV, land in the same track list as all other files, and are tagged
//  and converted from there. That is why there is no converter of its own
//  here.
//

import AppKit
import SwiftUI
import Foundation

extension AppState {

    // MARK: - Identifying the disc

    /// Reads TOC, CD-TEXT and identifiers of the inserted disc.
    func refreshDisc() async {
        isInspectingDisc = true
        defer { isInspectingDisc = false }
        do {
            let snapshot = try await ripEngine.inspect()
            disc = snapshot
            discError = nil
            // All audio tracks are preselected — that is the normal case.
            selectedRipTracks = Set(snapshot.toc.audioTracks.map(\.number))
            // A folder name set by hand belonged to the previous CD.
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

    /// Takes over what is on the disc itself. Costs no network and is often the
    /// only source for albums that are in no database.
    func applyCDText() {
        guard let disc, let text = disc.cdText else { return }
        discAlbum = text.albumTitle ?? ""
        discArtist = text.albumArtist ?? ""
        discComposer = text.albumComposer ?? ""
        for track in disc.toc.audioTracks {
            if let title = text.title(forTrack: track.number) {
                discTitles[track.number] = title
            }
            // Only fill in where the track really carries an artist of its
            // own — otherwise every track would show the same.
            if let performer = text.performers[track.number],
               performer != text.albumArtist {
                discTrackArtists[track.number] = performer
            }
        }
        // CD-TEXT knows neither year nor genre; both stay as they are.
        discMetadataSource = .cdText
    }

    /// Looks up the pressing via the disc ID. If that misses, the text search
    /// remains — and, if need be, ripping unnamed and tagging afterwards.
    func lookupDisc() async {
        guard let disc else { return }
        isLookingUpDisc = true
        discLookupMessage = nil
        defer { isLookingUpDisc = false }

        do {
            // The disc ID first — it hits exactly this pressing.
            var found = try await lookup.musicBrainz.releases(discID: disc.discID)
            if found.isEmpty {
                // Then the less exact search via the raw TOC.
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

    /// Takes a found pressing over into the input fields.
    func apply(_ release: LookupRelease) {
        discAlbum = release.title
        discArtist = release.albumArtist ?? discArtist
        if let year = release.year { discYear = String(year) }
        // MusicBrainz lists several genres; the first is the most common.
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

    // MARK: - Ripping

    var ripDestinationFolder: URL {
        ripDestination ?? FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// The tags a ripped track gets. The file name is made from them too —
    /// pattern and tags must have the same source, or the file is named
    /// differently from what it contains.
    func tags(forTrack number: Int) -> AudioTags {
        var tags = AudioTags()
        tags.title = discTitles[number]
        tags.album = discAlbum.isEmpty ? nil : discAlbum
        // The track artist differs for classical music and compilations;
        // the album artist stays that of the disc.
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

    /// What the files will be called. The section shows it as a preview.
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
        // Without a title, often only a separator is left of the pattern.
        return rendered.isEmpty ? String(format: "%02d", number) : rendered
    }

    /// What currently prevents ripping — the same role as
    /// `conversionBlocker` for converting.
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

    /// Overall progress across all selected tracks. The mean while reading,
    /// the second stage while converting.
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

    /// What the footer says while ripping.
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

            // Convert, if another format is wanted. The WAVs are only
            // intermediates then and go away.
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

    /// Sends the ripped WAVs through the same pipeline as the Convert
    /// section. No second converter, no second source of errors.
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
        // The name is already on the WAV; applying the pattern here again
        // would render it twice.
        conversion.filenamePattern = ""
        // The WAV is an intermediate, not an original.
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

    // MARK: - Finishing

    /// Put log and cue sheet next to the files.
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

    /// Enters the details into the list. When converting, ffmpeg has already
    /// written them; this is about showing them in the view as well.
    private func applyRippedTags(_ urls: [URL], numbers: [Int],
                                 produced: [Int: URL], wanted: [Int: AudioTags]) {
        // Matching by order — after conversion the files are named
        // differently from how they were ripped.
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

    /// What the folder is called when nothing is entered — also the
    /// placeholder text in the field.
    var suggestedAlbumFolderName: String {
        let raw = [discArtist, discAlbum].filter { !$0.isEmpty }.joined(separator: " - ")
        return PatternRenderer().sanitize(raw.isEmpty ? "Audio CD" : raw)
    }

    /// The name that is really created. An entry of one's own beats the
    /// suggestion; empty means the suggestion stays.
    var sanitizedAlbumFolderName: String {
        let custom = ripFolderName.trimmingCharacters(in: .whitespaces)
        return custom.isEmpty ? suggestedAlbumFolderName
                              : PatternRenderer().sanitize(custom)
    }

    // MARK: - Error messages

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

// MARK: - Noticing disc changes

/// Observes whether an audio CD is inserted or ejected.
///
/// `NSWorkspace` reports the mounting of the CDDA volume — that is enough,
/// because that is exactly when the TOC is ready too.
@MainActor
final class DiscWatcher {
    /// The observers live in a small box of their own so that `deinit` —
    /// which runs outside the main actor — may still unregister them. They
    /// are only touched when registering, which is why this is safe.
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

/// Where the displayed metadata comes from. The user should see whether
/// the details come from the disc itself or from the network.
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

/// What the ripper is working on right now. Progress sits in the footer,
/// not in the form — there it scrolls away exactly when one needs it.
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
