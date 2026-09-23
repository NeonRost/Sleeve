//
//  AudioSplitter.swift
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
//  Splitting a long recording into individual tracks (spec §7).
//
//  The core is deliberately called "cut this file at this list of
//  positions" and not "find silence". Where the boundaries come from is
//  interchangeable: today from the silence between the pieces, later from a
//  cue sheet (§9.1). Otherwise reading cue sheets would one day stand next
//  to it as a second tool instead of being one more source in front of it.
//
//  Silence detection and the edge buffer come from the Track Splitter in
//  NeonRost's toolbox and have been proven there over a long time.
//

import Foundation

struct SilenceInterval: Equatable, Sendable {
    var start: Double
    var end: Double
}

struct SilenceAnalysis: Sendable {
    var duration: Double
    /// Everything ffmpeg reported, edge artefacts included. What actually
    /// gets cut is decided by `trackRanges`.
    var silences: [SilenceInterval]
}

struct TrackRange: Identifiable, Equatable, Sendable {
    var id = UUID()
    var start: Double
    var end: Double

    var duration: Double { max(0, end - start) }
}

/// What the pieces should become.
///
/// `keepSource` only cuts (`-c copy`) and leaves the audio stream untouched.
/// Everything else **re-encodes** — with a lossy source that means lossy a
/// second time. Sometimes that is wanted (an MP3 for the car radio stick),
/// but it is never free, which is why the UI says so.
enum SplitOutput: Hashable, Sendable {
    case keepSource
    case convert(AudioFormat)

    var reencodes: Bool { self != .keepSource }
}

enum SplitError: Error, Equatable, Sendable {
    case ffmpegMissing
    case analysisFailed
    case noAudioTrack
    case missingEncoder(AudioFormat)
    case cutFailed(String)
}

enum AudioSplitter {

    static let audioExtensions: Set<String> = [
        "mp3", "flac", "m4a", "aac", "ogg", "opus", "wav", "aiff", "aif", "wma", "alac",
    ]

    /// A downloaded album is often a video — YouTube delivers picture and
    /// sound together, and whoever searches for a "full album" gets exactly
    /// that. The audio stream can be extracted losslessly, so there is no
    /// reason to reject such files.
    static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "webm", "avi", "flv", "wmv", "ts", "mpg", "mpeg",
    ]

    static var acceptedExtensions: Set<String> { audioExtensions.union(videoExtensions) }

    /// Silence in the first or last two seconds counts as the usual dead air
    /// of a record side or cassette, not as a track boundary. A fixed value,
    /// not a slider: the two that matter — threshold and minimum duration —
    /// are enough controls for one screen.
    static let edgeBuffer: Double = 2.0

    /// Default for the shortest length a track may have.
    ///
    /// Without this limit, applause, transitions and announcements produce
    /// fragments of fractions of a second. Measured on a real recording: of 22
    /// sections found, **nine were shorter than four seconds**, four of them
    /// under half a second, one exactly zero seconds long — a cut of length
    /// zero yields an unusable file.
    static let defaultMinimumTrackLength: Double = 10.0

    // MARK: - What kind of file is this?

    struct SourceInfo: Equatable, Sendable {
        var duration: Double
        /// The codec of the audio stream as ffmpeg names it — `aac`, `mp3`, …
        var audioCodec: String
        var hasVideo: Bool

        /// The extension the cut piece gets.
        ///
        /// A video never becomes a video again: the music is what is wanted. The
        /// container follows the audio format, so that nothing needs re-encoding.
        var outputExtension: String {
            switch audioCodec {
            case "aac", "alac":            "m4a"
            case "mp3":                    "mp3"
            case "flac":                   "flac"
            case "opus":                   "opus"
            case "vorbis":                 "ogg"
            case "ac3":                    "ac3"
            case let codec where codec.hasPrefix("pcm_"): "wav"
            // Forcing something unknown into a container that does not take it
            // only fails when cutting. m4a takes the most.
            default:                       "m4a"
            }
        }
    }

    /// Asks ffmpeg what is in the file. Also returns the duration, which
    /// would otherwise cost a second call.
    static func probe(file: URL, ffmpeg: FFmpegTool) async throws -> SourceInfo {
        let result: ProcessRunner.Result
        do {
            result = try await ProcessRunner.run(ffmpeg.url, arguments: [
                "-hide_banner", "-i", file.path(percentEncoded: false), "-f", "null", "-",
            ])
        } catch {
            throw SplitError.analysisFailed
        }
        let text = result.standardError
        guard let duration = parseDuration(text) else { throw SplitError.analysisFailed }
        guard let codec = parseAudioCodec(text) else { throw SplitError.noAudioTrack }
        return SourceInfo(duration: duration, audioCodec: codec,
                          hasVideo: text.contains("Stream #") && text.contains("Video:"))
    }

    /// `Stream #0:1[0x2](und): Audio: aac (LC) …` — the name after "Audio:".
    static func parseAudioCodec(_ text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            guard line.contains("Stream #"), let range = line.range(of: "Audio: ") else { continue }
            let rest = line[range.upperBound...]
            let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if !name.isEmpty { return String(name).lowercased() }
        }
        return nil
    }

    // MARK: - Analysis

    /// Lets ffmpeg look for silence and reads the duration and the findings.
    static func analyze(file: URL,
                        thresholdDB: Double,
                        minDuration: Double,
                        ffmpeg: FFmpegTool) async throws -> SilenceAnalysis {
        let result: ProcessRunner.Result
        do {
            result = try await ProcessRunner.run(ffmpeg.url, arguments: [
                "-hide_banner",
                "-i", file.path(percentEncoded: false),
                // Decode no picture — for an album video that saves the lion's
                // share of the time, and the search happens in the audio anyway.
                "-vn",
                "-af", "silencedetect=noise=\(thresholdDB)dB:d=\(minDuration)",
                "-f", "null", "-",
            ])
        } catch {
            throw SplitError.analysisFailed
        }

        // ffmpeg writes banner *and* filter output to stderr.
        let text = result.standardError
        guard let duration = parseDuration(text) else { throw SplitError.analysisFailed }
        return SilenceAnalysis(duration: duration, silences: parseSilences(text))
    }

    /// `Duration: 00:52:29.57, …` from ffmpeg's header lines.
    static func parseDuration(_ text: String) -> Double? {
        guard let match = text.range(of: #"Duration: (\d+):(\d+):(\d+\.\d+)"#,
                                     options: .regularExpression) else { return nil }
        let parts = text[match]
            .replacingOccurrences(of: "Duration: ", with: "")
            .split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2])
        else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }

    /// Pairs `silence_start:` with `silence_end:`.
    ///
    /// The values sometimes come without decimals (`silence_start: 0`), so the
    /// decimal part in the pattern is optional. And they can be negative —
    /// ffmpeg occasionally reports `-0.00478...`.
    static func parseSilences(_ text: String) -> [SilenceInterval] {
        var starts: [Double] = []
        var ends: [Double] = []
        for line in text.split(whereSeparator: \.isNewline) {
            if let value = firstNumber(in: line, after: "silence_start:") {
                starts.append(max(0, value))
            } else if let value = firstNumber(in: line, after: "silence_end:") {
                ends.append(max(0, value))
            }
        }
        return zip(starts, ends).map { SilenceInterval(start: $0, end: $1) }
    }

    private static func firstNumber(in line: Substring, after marker: String) -> Double? {
        guard let markerRange = line.range(of: marker),
              let numberRange = line.range(of: #"-?[0-9]+(\.[0-9]+)?"#,
                                           options: .regularExpression,
                                           range: markerRange.upperBound..<line.endIndex)
        else { return nil }
        return Double(line[numberRange])
    }

    // MARK: - Boundaries

    /// Silences less than this far apart count as one — whatever sounds in
    /// between is a click or a breath in the pause.
    static let noiseLength: Double = 1.0

    /// Below this, a value counts as floor when searching for the deepest
    /// silence, even if the file is nowhere completely silent (−60 dBFS).
    static let floorLevel: Float = 0.001

    /// A possible cut: where, and how convincing. The longer the silence, the
    /// more likely there really is a track boundary there.
    struct Cut: Equatable, Sendable {
        var position: Double
        var strength: Double
    }

    /// Turns the silence found into tracks that lie against each other without
    /// gaps.
    ///
    /// **Nothing is discarded.** The first attempt left out the pauses between
    /// the tracks — and with them everything quieter than the threshold.
    /// Measured on the real album: 66 s in no file, including the quiet intro
    /// of "Slider" (−35 to −49 dB, six seconds). Now a pause belongs to the end
    /// of the previous track, as is usual with CD rippers.
    ///
    /// `levels` is the envelope of the file. With it, the cut goes at the end
    /// of the **deepest** silence instead of at the end of the threshold
    /// silence — that is the difference between an intro that belongs to the
    /// right track and one the previous track gets. Without an envelope the
    /// cut goes at the end of the silence.
    static func trackRanges(duration: Double,
                            silences: [SilenceInterval],
                            minimumLength: Double = defaultMinimumTrackLength,
                            levels: WaveformSampler.Waveform? = nil) -> [TrackRange] {
        let regions = bridge(silences.sorted { $0.start < $1.start }, within: noiseLength)
            // Silence right at the start or end is dead air, not a boundary.
            .filter { $0.start >= edgeBuffer && $0.end <= duration - edgeBuffer }
        guard !regions.isEmpty else { return [] }

        let cuts = regions.map {
            Cut(position: cutPosition(in: $0, levels: levels), strength: $0.end - $0.start)
        }
        let kept = thin(cuts, duration: duration, minimumLength: minimumLength)
        guard !kept.isEmpty else { return [] }

        var ranges: [TrackRange] = []
        var cursor = 0.0
        for cut in kept {
            ranges.append(TrackRange(start: cursor, end: cut.position))
            cursor = cut.position
        }
        ranges.append(TrackRange(start: cursor, end: duration))
        return ranges
    }

    /// Merges silences with only a short noise between them.
    static func bridge(_ silences: [SilenceInterval], within gap: Double) -> [SilenceInterval] {
        var result: [SilenceInterval] = []
        for silence in silences {
            if var last = result.last, silence.start - last.end < gap {
                last.end = max(last.end, silence.end)
                result[result.count - 1] = last
            } else {
                result.append(silence)
            }
        }
        return result
    }

    /// Where a silence is cut: at the end of its **deepest** stretch.
    ///
    /// The threshold alone is not enough. A quiet intro lies below it and still
    /// belongs to the next piece; a fade-out likewise to the previous one. The
    /// deepest stretch — often digital zero — is the actual seam. If there are
    /// several, the longest counts.
    static func cutPosition(in region: SilenceInterval, levels: WaveformSampler.Waveform?) -> Double {
        guard let levels, !levels.peaks.isEmpty, levels.duration > 0 else { return region.end }
        let rate = Double(levels.peaks.count) / levels.duration
        let from = max(0, Int((region.start * rate).rounded(.down)))
        let to = min(levels.peaks.count, Int((region.end * rate).rounded(.up)))
        guard from < to else { return region.end }

        let window = levels.peaks[from..<to]
        let quietest = window.min() ?? 0
        let floor = max(quietest * 2, floorLevel)   // about +6 dB above the deepest point

        var bestEnd = to, bestLength = 0
        var runStart: Int?
        for index in from...to {
            let isFloor = index < to && levels.peaks[index] <= floor
            if isFloor {
                if runStart == nil { runStart = index }
            } else if let started = runStart {
                if index - started > bestLength { bestLength = index - started; bestEnd = index }
                runStart = nil
            }
        }
        guard bestLength > 0 else { return region.end }
        return min(max(Double(bestEnd) / rate, region.start), region.end)
    }

    /// Thins out the cuts until no track is shorter than the minimum length.
    ///
    /// If there are several pieces that are too short between two long tracks,
    /// **exactly one** of the cuts there remains: the one at the longest
    /// silence. Whatever lies before it belongs to the previous track, whatever
    /// lies after it to the next.
    ///
    /// That way applause right after a live piece stays with the piece — the
    /// long pause only comes afterwards — and a jagged intro after a long pause
    /// goes to the next piece. The first version attached everything to the
    /// predecessor; on the real album the intro of "LUV" suddenly belonged to
    /// the track before, 15 s off.
    static func thin(_ cuts: [Cut], duration: Double, minimumLength: Double) -> [Cut] {
        guard minimumLength > 0, !cuts.isEmpty else { return cuts }

        // Pieces i = 0…n; cut j separates piece j−1 from piece j (j = 1…n).
        let bounds = [0.0] + cuts.map(\.position) + [duration]
        let pieceCount = cuts.count + 1
        let short = (0..<pieceCount).map { bounds[$0 + 1] - bounds[$0] < minimumLength }
        var keep = [Bool](repeating: true, count: cuts.count + 1)   // index 1…n

        var piece = 0
        while piece < pieceCount {
            guard short[piece] else { piece += 1; continue }
            var last = piece
            while last + 1 < pieceCount, short[last + 1] { last += 1 }

            let candidates = (piece...(last + 1)).filter { $0 >= 1 && $0 <= cuts.count }
            if piece == 0 && last == pieceCount - 1 {
                candidates.forEach { keep[$0] = false }          // everything too short
            } else if piece == 0 || last == pieceCount - 1 {
                candidates.forEach { keep[$0] = false }          // only one neighbour
            } else {
                // On a tie the later one — short pieces then stay with the
                // predecessor.
                let strongest = candidates.max {
                    let a = cuts[$0 - 1].strength, b = cuts[$1 - 1].strength
                    return a == b ? $0 < $1 : a < b
                }
                candidates.forEach { keep[$0] = $0 == strongest }
            }
            piece = last + 1
        }
        return cuts.indices.filter { keep[$0 + 1] }.map { cuts[$0] }
    }

    // MARK: - Cutting

    /// Cuts out a section without re-encoding.
    ///
    /// With compressed formats, `-ss`/`-to` before `-c copy` lands on the next
    /// frame boundary rather than on the exact sample — measured on a real MP3
    /// in the range of a few milliseconds, not audible. That is how it is and
    /// not a bug to chase.
    ///
    /// If the source contains a picture, only the audio stream comes along
    /// (`-map 0:a:0`). Verified: the stream extracted this way is
    /// **bit-identical** to the one in the video — nothing is re-encoded.
    static func cut(source: URL,
                    range: TrackRange,
                    to destination: URL,
                    audioOnly: Bool,
                    output: SplitOutput = .keepSource,
                    bitrate: Int = 256,
                    compressionLevel: Int = 5,
                    ffmpeg: FFmpegTool) async throws {
        var arguments = [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            "-ss", String(format: "%.3f", range.start),
            "-to", String(format: "%.3f", range.end),
            "-i", source.path(percentEncoded: false),
        ]

        switch output {
        case .keepSource:
            if audioOnly {
                arguments += ["-map", "0:a:0", "-c:a", "copy"]
            } else {
                arguments += ["-c", "copy"]
            }
        case .convert(let format):
            guard let encoder = ffmpeg.encoder(for: format) else {
                throw SplitError.missingEncoder(format)
            }
            // A cover picture is a video stream; `-vn` throws it out as well.
            // Tagging happens afterwards via TagLib, as everywhere in Sleeve.
            arguments += ["-vn", "-map_metadata", "-1", "-c:a", encoder]
            if AudioFormat.experimentalEncoders.contains(encoder) {
                arguments += ["-strict", "-2"]
            }
            if format.supportsBitrate { arguments += ["-b:a", "\(bitrate)k"] }
            if format.supportsCompressionLevel {
                arguments += ["-compression_level", "\(compressionLevel)"]
            }
        }
        arguments.append(destination.path(percentEncoded: false))

        let result: ProcessRunner.Result
        do {
            result = try await ProcessRunner.run(ffmpeg.url, arguments: arguments)
        } catch {
            // Cancelled: the half-finished file has to go, unlike the ones
            // finished before it.
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        guard result.succeeded else {
            try? FileManager.default.removeItem(at: destination)
            let detail = result.standardError
                .split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            throw SplitError.cutFailed(detail)
        }
    }
}

// MARK: - Time values

/// Reading and writing `mm:ss.s` — for the fields in which boundaries can be
/// adjusted by hand.
enum Timecode {

    static func format(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let minutes = Int(total) / 60
        let rest = total - Double(minutes * 60)
        return String(format: "%02d:%04.1f", minutes, rest)
    }

    /// Whole seconds, as track lists write them: "5:00", "1:02:03". For
    /// comparisons with a source — the tenths show in the deviation there.
    static func short(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        let hours = total / 3600, minutes = total / 60 % 60, rest = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }

    /// Accepts `mm:ss.s`, `h:mm:ss.s` and bare seconds.
    static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 3 else { return nil }

        var seconds = 0.0
        for part in parts {
            guard let value = Double(part.replacingOccurrences(of: ",", with: ".")),
                  value >= 0 else { return nil }
            seconds = seconds * 60 + value
        }
        return seconds
    }
}
