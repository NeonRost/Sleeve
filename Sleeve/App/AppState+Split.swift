//
//  AppState+Split.swift
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
//  Track Splitter (spec §7).
//
//  What happens after cutting sets Sleeve apart from a mere splitter: the
//  pieces land in the track list. That is why there is **no tag block of
//  its own** here for artist, album, year and cover — the Tag section has
//  long done that better, with multiple selection and lookup. Written here
//  are only title and track number, which are settled by the cut anyway,
//  plus whatever an applied track list provides.
//
//  Important: `-c copy` **inherits the source file's tags**. Without a
//  correction every piece would carry the title of the whole album.
//

import AppKit
import Foundation
import SwiftUI

/// Where the titles come from: one of the two sources of "Look Up Album"
/// or a pasted track list.
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

    // MARK: - Source

    /// Clean up before the window opens — an error from last time should
    /// not be the first thing to see.
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

        // Look right away at what is inside: it decides which extension the
        // pieces get — and whether there is sound at all.
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

    /// Computes the envelope once. With a long recording that takes
    /// noticeably long, hence in the background and with an indicator.
    private func loadWaveform(_ url: URL, duration: Double, ffmpeg tool: FFmpegTool) async {
        guard duration > 0 else { return }
        isLoadingWaveform = true
        defer { isLoadingWaveform = false }
        splitWaveform = try? await WaveformSampler.load(url, duration: duration, ffmpeg: tool)
    }

    /// Sets a new boundary at this position — the counterpart to merging.
    ///
    /// Before, boundaries could only disappear, never appear. Whoever saw in
    /// the envelope that two pieces had been combined could not separate them.
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

    /// Which extension the cut pieces get.
    var splitOutputExtension: String {
        if case let .convert(format) = splitOutput { return format.fileExtension }
        return splitSourceInfo?.outputExtension
            ?? splitSource?.pathExtension.lowercased()
            ?? "mp3"
    }

    /// What the target format is called in the picker. For "same as source"
    /// the actual extension belongs with it — otherwise one guesses.
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

    // MARK: - Analysis

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

    // MARK: - Selection and mark

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
        // A new row means: the mark goes back to its start.
        splitMark = nil
        if splitPreview.playingID != nil { splitPreview.stop() }
    }

    /// Where the mark is. Unless set by hand: **at the start** of the selected
    /// track, on the green line.
    ///
    /// The first version put it a little before, so that "Play from Mark"
    /// would play across the boundary by itself. Nobody could guess that —
    /// whoever plays a track expects it from its start. Playing across the
    /// boundary is what ⏮ and the button in the track list do.
    var splitMarkPosition: Double {
        if let splitMark { return splitMark }
        return selectedSplitTrack?.range.start ?? 0
    }

    /// The position that currently applies: while playing the moving head,
    /// otherwise the mark. "Start Here", "End Here" and "Split Here" refer to
    /// it — one presses what one hears.
    var splitCurrentPosition: Double {
        splitPreview.position ?? splitMarkPosition
    }

    func setSplitMark(_ seconds: Double) {
        splitMark = min(max(0, seconds), splitDuration)
        // If something is already playing, playback jumps along — otherwise one
        // hears a different spot than the one just clicked.
        if splitPreview.playingID != nil { playSplitFromMark() }
    }

    // MARK: - Playback

    var isSplitPlaying: Bool { splitPreview.playingID != nil }

    func playSplitFromMark() {
        guard let source = splitSource else { return }
        splitPreview.playFrom(id: splitSelectionID ?? UUID(), url: source,
                              position: splitMarkPosition, fileDuration: splitDuration)
    }

    /// Whoever presses stop while listening means **this** spot: the mark
    /// takes over the head. If the preview runs out by itself, however, the
    /// mark stays where it was — otherwise it would march on a bit with
    /// every playback.
    func toggleSplitPlayback() {
        if isSplitPlaying {
            if let live = splitPreview.position { splitMark = live }
            splitPreview.stop()
        } else {
            playSplitFromMark()
        }
    }

    /// The button in a row: select it and hear the front boundary.
    func playAcrossStart(of track: SplitTrack) {
        if splitPreview.playingID == track.id { splitPreview.stop(); return }
        splitSelectionID = track.id
        jumpToStartBoundary()
    }

    /// Plays **across** the start: a third of the preview before it — end of
    /// the previous track, pause, entry.
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

    // MARK: - Boundaries

    /// Moves a boundary. Boundary `b` is the start of track `b` and at the
    /// same time the end of track `b − 1` — the tracks lie against each other
    /// without gaps, and editing has to keep it that way. Moving only one side
    /// would open a gap, and whatever lies in it would end up in no file.
    ///
    /// Only at the start of the file (`b == 0`) and at its end (`b == count`)
    /// can something be cut off — an announcement before the first piece, say.
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

    /// Both boundaries of the selected track back — the neighbours move along.
    func resetSelectedBoundaries() {
        guard let track = selectedSplitTrack else { return }
        moveSelectedStart(to: track.detected.start)
        moveSelectedEnd(to: track.detected.end)
    }

    /// Can a new boundary be created at the current position?
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

    /// Merges the selected track with the previous one.
    func mergeSelectedWithPrevious() {
        guard let index = selectedSplitIndex, index > 0 else { return }
        let previous = splitTracks[index - 1]
        mergeSplitTrack(splitTracks[index])
        splitSelectionID = previous.id
        splitMark = nil
    }

    /// Removes a boundary: the track moves into its predecessor.
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

    // MARK: - Track list from outside (§7.12)

    /// A suggestion for the search, from the file name: "Artist - Album",
    /// without the parentheses uploaders append — "(Full Album)", "(486p…)".
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

    /// Lays a track list onto the tracks found.
    ///
    /// With `alignBoundaries` the boundaries are set anew — from start times
    /// or lengths, snapped to detected silences nearby. That also finds
    /// transitions without a pause, which no silence detection sees. Without
    /// it the boundaries stay, and the titles are taken over in order.
    ///
    /// `fields` says what of it should go into the tags — the same choice as
    /// when tagging. Whatever is not chosen stays as it was.
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

    // MARK: - Cutting

    var splitCanRun: Bool {
        !splitTracks.isEmpty && splitBlocker == nil
            && splitBlockerForFormat == nil && splitTask == nil
    }

    /// The file name of a piece — the same pattern as when ripping.
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

    /// Which fields are written when cutting. Title, number and comment
    /// always (§7.2); album, artist, year and genre only if a track list
    /// provided them — otherwise what the source carried stays.
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
                    // `-c copy` drags the source's tags along. Whatever describes
                    // the whole recording — artist, year, genre — may stay.
                    // Whatever describes the *source file* may not:
                    //
                    // - the title, or every piece would be named like the whole album;
                    // - the comment, which for downloads is almost always the
                    //   URL it came from. Measured on a real album video: all
                    //   13 pieces carried the YouTube address.
                    //
                    // `comment` is therefore in the list with an empty value —
                    // that deletes it.
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
                // Report visibly where the pieces ended up — without it the
                // process ends silently, and one goes looking for the files.
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

    /// Never overwrite an existing file — the same rule as when
    /// converting.
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
