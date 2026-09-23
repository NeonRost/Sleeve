//
//  SplitTests.swift
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
//  Track Splitter (§7). The end-to-end run works with a self-built file —
//  three tones with silence in between — because there every boundary is
//  known beforehand. With real music "roughly right" would be the best one
//  could check.
//

import Foundation

enum SplitTests {

    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var checks = 0

    static func check(_ condition: Bool, _ label: String,
                      detail: @autoclosure () -> String = "") {
        checks += 1
        if condition { print("  ✓ \(label)") }
        else {
            failures += 1
            let extra = detail()
            print("  ✗ \(label)\(extra.isEmpty ? "" : " — \(extra)")")
        }
    }

    static func equal<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
        check(actual == expected, label, detail: "is \(actual), expected \(expected)")
    }

    static func close(_ actual: Double, _ expected: Double, _ tolerance: Double,
                      _ label: String) {
        check(abs(actual - expected) <= tolerance, label,
              detail: String(format: "is %.3f, expected %.3f ± %.3f", actual, expected, tolerance))
    }

    static func run() async throws -> Int32 {
        parsing()
        sourceInfo()
        targetFormat()
        boundaries()
        timecodes()
        try await endToEnd()
        await preview()
        await editing()
        await windowModel()
        await previewLength()
        await playhead()
        await applyingListing()
        await waveform()

        print("\n  \(checks) checks, \(failures) failures")
        return failures == 0 ? 0 : 1
    }

    // MARK: - Reading ffmpeg's output

    static func parsing() {
        print("\n— Parsing ffmpeg output —")

        let sample = """
        Input #0, mp3, from 'album.mp3':
          Duration: 00:52:29.57, start: 0.025057, bitrate: 320 kb/s
        [silencedetect @ 0x14e704080] silence_start: -0.00478458
        [silencedetect @ 0x14e704080] silence_end: 2.03175 | silence_duration: 2.03654
        [silencedetect @ 0x14e704080] silence_start: 184.729
        [silencedetect @ 0x14e704080] silence_end: 187 | silence_duration: 2.271
        """
        close(AudioSplitter.parseDuration(sample) ?? 0, 3149.57, 0.01, "duration from the banner")

        let silences = AudioSplitter.parseSilences(sample)
        equal(silences.count, 2, "two silences paired")
        // ffmpeg occasionally reports a slightly negative start.
        close(silences[0].start, 0, 0.001, "a negative start is pulled to zero")
        close(silences[0].end, 2.03175, 0.001, "end with decimals")
        close(silences[1].start, 184.729, 0.001, "second start")
        // And sometimes without decimals — "187", not "187.0".
        close(silences[1].end, 187, 0.001, "end without decimals")

        check(AudioSplitter.parseDuration("no banner") == nil, "no banner, no duration")
        equal(AudioSplitter.parseSilences("nothing").count, 0, "no findings, no silence")
    }

    // MARK: - What is in the file

    static func sourceInfo() {
        print("\n— Recognizing the source —")

        let video = """
        Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'album.mp4':
          Duration: 00:44:49.30, start: 0.000000, bitrate: 1181 kb/s
          Stream #0:0[0x1](und): Video: h264 (High) (avc1 / 0x31637661), yuv420p, 854x480
          Stream #0:1[0x2](und): Audio: aac (LC) (mp4a / 0x6134706D), 44100 Hz, stereo, fltp, 128 kb/s
        """
        equal(AudioSplitter.parseAudioCodec(video), "aac", "AAC in the video recognized")
        close(AudioSplitter.parseDuration(video) ?? 0, 2689.3, 0.01, "duration of the video")

        let mp3 = """
        Input #0, mp3, from 'album.mp3':
          Duration: 00:52:29.57, start: 0.025057, bitrate: 320 kb/s
          Stream #0:0: Audio: mp3 (mp3float), 44100 Hz, stereo, fltp, 320 kb/s
        """
        equal(AudioSplitter.parseAudioCodec(mp3), "mp3", "MP3 recognized")

        let silent = """
        Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'silent.mp4':
          Duration: 00:00:10.00, start: 0.000000, bitrate: 50 kb/s
          Stream #0:0[0x1](und): Video: h264 (High), yuv420p, 320x180
        """
        check(AudioSplitter.parseAudioCodec(silent) == nil, "a video without sound has no codec")

        print("\n— Containers for the pieces —")
        func ext(_ codec: String) -> String {
            AudioSplitter.SourceInfo(duration: 1, audioCodec: codec, hasVideo: true)
                .outputExtension
        }
        // A video never becomes a video again — the music is what is wanted.
        equal(ext("aac"), "m4a", "AAC ends up in m4a")
        equal(ext("alac"), "m4a", "ALAC likewise")
        equal(ext("mp3"), "mp3", "MP3 stays MP3")
        equal(ext("opus"), "opus", "Opus stays Opus")
        equal(ext("vorbis"), "ogg", "Vorbis goes into ogg")
        equal(ext("flac"), "flac", "FLAC stays FLAC")
        equal(ext("pcm_s16le"), "wav", "raw PCM goes into wav")
        equal(ext("whatever"), "m4a", "anything unknown goes into m4a")

        check(AudioSplitter.acceptedExtensions.contains("mp4"), "mp4 is accepted")
        check(AudioSplitter.acceptedExtensions.contains("webm"), "webm likewise")
        check(AudioSplitter.acceptedExtensions.contains("mp3"), "mp3 still")
        check(!AudioSplitter.acceptedExtensions.contains("txt"), "text files not")
    }

    // MARK: - Silence becomes boundaries

    static func boundaries() {
        print("\n— Boundaries from silence —")

        // Silence at the start and end is dead air, not a boundary.
        let edges = AudioSplitter.trackRanges(
            duration: 100,
            silences: [.init(start: 0, end: 1.5), .init(start: 40, end: 42),
                       .init(start: 99, end: 100)],
            minimumLength: 0)
        equal(edges.count, 2, "edge silence does not count as a boundary")
        close(edges[0].start, 0, 0.001, "the first track starts at zero")
        // Without an envelope the cut goes at the end of the silence: the
        // pause belongs to the previous track, as with CD rippers.
        close(edges[0].end, 42, 0.001, "the pause belongs to the end of the previous track")
        close(edges[1].start, 42, 0.001, "the next one starts where the music sets in")
        close(edges[1].end, 100, 0.001, "the last track reaches to the end")

        equal(AudioSplitter.trackRanges(duration: 100, silences: []).count, 0,
              "no silence, no splitting")

        print("\n— Nothing gets lost —")
        // The first attempt left out the pauses — and with them everything
        // quieter than the threshold. On the real album 66 s in no file.
        let many = AudioSplitter.trackRanges(
            duration: 600,
            silences: [.init(start: 100, end: 105), .init(start: 250, end: 258),
                       .init(start: 400, end: 401)],
            minimumLength: 10)
        check(zip(many, many.dropFirst()).allSatisfy { abs($0.end - $1.start) < 0.0001 },
              "the tracks lie against each other without gaps")
        close(many.first!.start, 0, 0.0001, "from the start of the file")
        close(many.last!.end, 600, 0.0001, "to the end of the file")
        close(many.reduce(0) { $0 + $1.duration }, 600, 0.0001,
              "together exactly as long as the file")

        print("\n— The deepest silence —")
        // Envelope: 10 s loud, 3 s digital zero, 4 s quiet intro (−40 dB,
        // below the threshold), then loud. The threshold silence reaches to
        // 17 s — but the cut has to go at 13 s, or the previous track gets
        // the intro.
        var peaks = [Float](repeating: 0.8, count: 1000)       // 100 per second
        for i in 1000..<1300 { peaks.append(0) }               // 10–13 s
        for _ in 1300..<1700 { peaks.append(0.01) }            // 13–17 s, −40 dB
        for _ in 1700..<3000 { peaks.append(0.8) }             // 17–30 s
        let levels = WaveformSampler.Waveform(peaks: peaks, duration: 30)
        let region = SilenceInterval(start: 10, end: 17)
        close(AudioSplitter.cutPosition(in: region, levels: levels), 13, 0.02,
              "the cut goes at the end of the digital zero, not of the threshold")
        close(AudioSplitter.cutPosition(in: region, levels: nil), 17, 0.001,
              "without an envelope at the end of the silence")

        // Without digital zero — a cassette's hiss, −55 dB — everything below
        // −60 dB or just above the deepest point counts as floor.
        var hiss = [Float](repeating: 0.8, count: 500)
        hiss += [Float](repeating: 0.0018, count: 300)          // 5–8 s hiss
        hiss += [Float](repeating: 0.02, count: 200)            // 8–10 s quiet intro
        hiss += [Float](repeating: 0.8, count: 500)
        close(AudioSplitter.cutPosition(in: .init(start: 5, end: 10),
                                        levels: WaveformSampler.Waveform(peaks: hiss, duration: 15)),
              8, 0.02, "with hiss instead of zero too, at the end of the deepest stretch")

        print("\n— Short pieces between two tracks —")
        // The case from the album: before "LUV" a long pause, then three short
        // bits of sound with small pauses — the intro. It belongs to the next
        // track, not to the previous one.
        let intro = AudioSplitter.trackRanges(
            duration: 1500,
            silences: [.init(start: 1132.5, end: 1136.7),       // long pause
                       .init(start: 1139.0, end: 1140.0),
                       .init(start: 1143.7, end: 1145.0),
                       .init(start: 1148.2, end: 1149.9)],
            minimumLength: 10)
        equal(intro.count, 2, "the intro does not become a track of its own")
        close(intro[1].start, 1136.7, 0.001, "but starts the next one, after the long pause")

        // Applause after a live piece: a short gap, then the long pause.
        let applause = AudioSplitter.trackRanges(
            duration: 300,
            silences: [.init(start: 92.5, end: 93.0), .init(start: 97.0, end: 101.0)],
            minimumLength: 10)
        equal(applause.count, 2, "applause does not become a track of its own")
        close(applause[0].end, 101.0, 0.001, "but stays with the piece before")

        // A click in the pause does not split it.
        let click = AudioSplitter.bridge(
            [.init(start: 92.5, end: 96.9), .init(start: 97.1, end: 97.6)], within: 1.0)
        equal(click.count, 1, "two silences with a click between them are one")
        close(click[0].end, 97.6, 0.001, "and reach to the end of the second")

        // At the start of the file there is no predecessor — short pieces go
        // backwards.
        let opener = AudioSplitter.thin(
            [.init(position: 3, strength: 1), .init(position: 100, strength: 4)],
            duration: 300, minimumLength: 10)
        equal(opener.count, 1, "a too-short first piece has only one neighbour")
        close(opener[0].position, 100, 0.001, "and merges into it")

        let tail = AudioSplitter.thin(
            [.init(position: 100, strength: 4), .init(position: 295, strength: 1)],
            duration: 300, minimumLength: 10)
        close(tail.last!.position, 100, 0.001, "a too-short last piece likewise")

        equal(AudioSplitter.thin(
            [.init(position: 1, strength: 1), .init(position: 2, strength: 1)],
            duration: 300, minimumLength: 0).count, 2,
              "a switched-off minimum length thins out nothing")
    }

    // MARK: - Time values

    static func timecodes() {
        print("\n— Time values —")
        equal(Timecode.format(0), "00:00.0", "zero")
        equal(Timecode.format(61.26), "01:01.3", "a minute and a bit")
        // Exactly .x5 is a tie in binary; `%.1f` then rounds to the even
        // digit. Recorded so that nobody takes it for a bug.
        equal(Timecode.format(61.25), "01:01.2", "a tie rounds to the even digit")
        equal(Timecode.short(300.3), "5:00", "comparison tables: whole seconds")
        equal(Timecode.short(993.6), "16:34", "rounded")
        equal(Timecode.short(3723), "1:02:03", "with hours")
        equal(Timecode.format(3599.9), "59:59.9", "just under an hour")

        close(Timecode.parse("01:01.3") ?? 0, 61.3, 0.001, "read back")
        close(Timecode.parse("90") ?? 0, 90, 0.001, "bare seconds")
        close(Timecode.parse("1:02:03") ?? 0, 3723, 0.001, "with hours")
        close(Timecode.parse("01:01,3") ?? 0, 61.3, 0.001, "comma instead of point")
        check(Timecode.parse("") == nil, "empty yields nothing")
        check(Timecode.parse("nonsense") == nil, "nonsense yields nothing")
        check(Timecode.parse("1:2:3:4") == nil, "four parts yield nothing")

        // A round trip over many values — this is where a rounding error shows.
        var roundTripOK = true
        for tenths in stride(from: 0, through: 6000, by: 7) {
            let seconds = Double(tenths) / 10
            guard let back = Timecode.parse(Timecode.format(seconds)),
                  abs(back - seconds) < 0.06 else { roundTripOK = false; break }
        }
        check(roundTripOK, "round trip over 860 values")
    }

    // MARK: - Target format

    static func targetFormat() {
        print("\n— Target format —")
        check(!SplitOutput.keepSource.reencodes, "same as source does not re-encode")
        check(SplitOutput.convert(.mp3).reencodes, "MP3 re-encodes")
        check(SplitOutput.convert(.flac).reencodes,
              "FLAC re-encodes too — lossless does not mean unchanged")
        check(SplitOutput.keepSource != SplitOutput.convert(.mp3), "both distinguishable")
    }

    // MARK: - Listening

    @MainActor
    static func preview() async {
        print("\n— Listening —")
        // The window lies around the boundary, not behind it.
        let player = SplitPreview()
        player.length = 12
        func window(trackStart: Double, fileDuration: Double) -> (Double, Double) {
            let from = max(0, trackStart - player.lead)
            return (from, min(fileDuration, from + player.length))
        }
        var w = window(trackStart: 100, fileDuration: 600)
        close(w.0, 96, 0.001, "starts a third of the preview before the track")
        close(w.1, 108, 0.001, "and runs the full length")

        w = window(trackStart: 0, fileDuration: 600)
        close(w.0, 0, 0.001, "for track 1 not before the start of the file")
        close(w.1, 12, 0.001, "and then the full length")

        w = window(trackStart: 598, fileDuration: 600)
        close(w.1, 600, 0.001, "cut off at the end of the file")
        check(w.1 > w.0, "the window stays sensible")

        // And on real files: AVFoundation has to accept them.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("sleeve-preview-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        guard let ffmpeg = await FFmpegLocator().locate() else { return }

        for (ext, encoder) in [("mp3", "libmp3lame"), ("m4a", "aac"),
                               ("flac", "flac"), ("wav", "pcm_s16le")] {
            let file = folder.appendingPathComponent("probe.\(ext)")
            _ = try? await ProcessRunner.run(ffmpeg.url, arguments: [
                "-hide_banner", "-loglevel", "error", "-y",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=3",
                "-c:a", encoder, file.path(percentEncoded: false),
            ])
            let preview = SplitPreview()
            await preview.check(file)
            check(preview.unplayableReason == nil, "\(ext) can be played")
        }
    }

    // MARK: - Editing boundaries

    @MainActor
    static func editing() {
        print("\n— A track's boundaries —")
        let track = SplitTrack(range: TrackRange(start: 100, end: 220))
        check(!track.isAdjusted, "freshly detected means unchanged")

        track.assign(start: 97.5)
        close(track.range.start, 97.5, 0.001, "the start is stored")
        equal(track.startText, "01:37.5", "the time field follows")
        check(track.isAdjusted, "the row counts as changed")

        track.assign(start: 100)
        check(!track.isAdjusted, "back to the detection means unchanged")

        // After splitting or merging, the new state is the starting point.
        track.assign(end: 150)
        track.detected = track.range
        check(!track.isAdjusted, "a new starting point counts as unchanged")
    }

    /// Mark, selection, splitting and merging — the way the window uses them:
    /// through the app's state, not through individual parts.
    @MainActor
    static func windowModel() {
        print("\n— Mark and selection —")
        let state = AppState()
        state.splitSourceInfo = AudioSplitter.SourceInfo(duration: 300, audioCodec: "aac",
                                                         hasVideo: false)
        state.splitTracks = [
            SplitTrack(range: TrackRange(start: 0, end: 92.5)),
            SplitTrack(range: TrackRange(start: 97.6, end: 200)),
            SplitTrack(range: TrackRange(start: 203, end: 300)),
        ]
        state.splitPreview.length = 15   // so the lead-in is 5 s
        state.selectSplitTrack(state.splitTracks[1].id)

        // Unless set by hand, the mark sits at the start of the track — whoever
        // plays a track expects it from its start, not four seconds before.
        close(state.splitMarkPosition, 97.6, 0.001, "the mark sits at the start of the track")
        close(state.splitCurrentPosition, 97.6, 0.001, "without playback the mark applies")

        // Playing across the boundary is a button of its own.
        state.jumpToStartBoundary()
        state.splitPreview.stop()
        close(state.splitMarkPosition, 92.6, 0.001, "⏮ puts the mark the lead-in before")
        state.selectSplitTrack(state.splitTracks[2].id)
        state.selectSplitTrack(state.splitTracks[1].id)

        state.setSplitMark(150)
        close(state.splitMarkPosition, 150, 0.001, "the mark can be set")
        state.setSplitMark(-10)
        close(state.splitMarkPosition, 0, 0.001, "not before the start of the file")
        state.setSplitMark(9999)
        close(state.splitMarkPosition, 300, 0.001, "not beyond the end of the file")

        // Selecting another row puts the mark back at its start.
        state.selectSplitTrack(state.splitTracks[2].id)
        close(state.splitMarkPosition, 203, 0.001, "new row, new mark at its start")

        print("\n— Shared boundaries —")
        // Boundary 1 is the end of track 0 and the start of track 1. Whoever
        // moves it moves both — otherwise a gap would open, and whatever lies
        // in it would end up in no file.
        state.splitTracks = [
            SplitTrack(range: TrackRange(start: 0, end: 97.6)),
            SplitTrack(range: TrackRange(start: 97.6, end: 203)),
            SplitTrack(range: TrackRange(start: 203, end: 300)),
        ]
        state.selectSplitTrack(state.splitTracks[1].id)
        state.setSplitMark(99)
        state.setSelectedStartHere()
        close(state.splitTracks[1].range.start, 99, 0.001, "\"Start Here\" takes the mark")
        close(state.splitTracks[0].range.end, 99, 0.001, "and the previous track ends with it")

        state.setSplitMark(195)
        state.setSelectedEndHere()
        close(state.splitTracks[1].range.end, 195, 0.001, "\"End Here\" likewise")
        close(state.splitTracks[2].range.start, 195, 0.001, "and the next one starts with it")

        func contiguous() -> Bool {
            zip(state.splitTracks, state.splitTracks.dropFirst())
                .allSatisfy { abs($0.range.end - $1.range.start) < 0.0001 }
        }
        check(contiguous(), "no gap after moving")

        // A boundary cannot be pushed beyond the neighbour.
        state.moveSelectedStart(to: -50)
        check(state.splitTracks[0].range.duration >= SplitTrack.minimumLength - 0.0001,
              "the previous track does not disappear")
        check(contiguous(), "and it stays gapless")

        // Resetting takes the neighbours along.
        state.selectSplitTrack(state.splitTracks[1].id)
        state.resetSelectedBoundaries()
        close(state.splitTracks[1].range.start, 97.6, 0.001, "reset restores the start")
        close(state.splitTracks[0].range.end, 97.6, 0.001, "including the end of the previous one")
        check(contiguous(), "gapless")

        // Only at the edges of the file can something be cut off.
        state.selectSplitTrack(state.splitTracks[0].id)
        state.moveSelectedStart(to: 4)
        close(state.splitTracks[0].range.start, 4, 0.001,
              "at the start of the file an announcement can be cut off")
        close(state.splitTracks[0].range.end, 97.6, 0.001, "without anything else moving")
        state.moveSelectedStart(to: 0)
        state.selectSplitTrack(state.splitTracks[1].id)

        print("\n— Splitting and merging —")
        state.setSplitMark(150)
        check(state.canSplitHere, "the middle of a track can be split")
        state.splitHere()
        equal(state.splitTracks.count, 4, "three tracks become four")
        close(state.splitTracks[1].range.end, 150, 0.001, "the first part ends at the mark")
        close(state.splitTracks[2].range.start, 150, 0.001, "the second starts there")
        equal(state.splitSelectionID, state.splitTracks[2].id, "the new part is selected")
        check(contiguous(), "gapless")

        // After splitting, reset no longer leads to the old boundary — it no
        // longer exists.
        state.selectSplitTrack(state.splitTracks[1].id)
        state.resetSelectedBoundaries()
        close(state.splitTracks[1].range.end, 150, 0.001,
              "reset after splitting keeps the new boundary")

        state.selectSplitTrack(state.splitTracks[2].id)
        state.mergeSelectedWithPrevious()
        equal(state.splitTracks.count, 3, "merging undoes it")
        equal(state.splitSelectionID, state.splitTracks[1].id, "the predecessor is selected now")
        check(contiguous(), "gapless")

        state.selectSplitTrack(state.splitTracks[0].id)
        state.mergeSelectedWithPrevious()
        equal(state.splitTracks.count, 3, "the first track has no predecessor")
    }

    /// Applying a track list — the way the sheet does it.
    @MainActor
    static func applyingListing() async {
        print("\n— Applying a track list —")
        let state = AppState()
        state.splitSource = URL(fileURLWithPath:
            "/x/BEAST - IMagination∞lenS (Full Album) (486p_30fps_H264-128kbit_AAC).mp4")
        state.splitSourceInfo = AudioSplitter.SourceInfo(duration: 1370, audioCodec: "aac",
                                                         hasVideo: true)

        // Search suggestion from the file name, without the parentheses
        // uploaders append.
        let guess = state.suggestedSplitSearch
        equal(guess.artist, "BEAST", "artist from the file name")
        equal(guess.album, "IMagination∞lenS", "album without \"(Full Album)\" and resolution")

        // Detection as on the real album: the pause in "48k" is a boundary,
        // Lynch is missing.
        state.splitAnalysis = SilenceAnalysis(duration: 1370, silences: [
            .init(start: 92.5, end: 95.8), .init(start: 312.0, end: 316.5),
            .init(start: 568.0, end: 573.0), .init(start: 837.0, end: 848.1),
            .init(start: 885.1, end: 886.4), .init(start: 1132.5, end: 1136.7),
        ])
        state.splitTracks = [0, 95.8, 316.5, 573.0, 848.1, 886.4, 1136.7].enumerated().map { i, start in
            let ends: [Double] = [95.8, 316.5, 573.0, 848.1, 886.4, 1136.7, 1370]
            return SplitTrack(range: TrackRange(start: start, end: ends[i]))
        }
        let listing = TrackListing(pasted: """
            Beast City 0:00
            Vision 1:35
            Chemical 5:16
            Spiral Cave 9:32
            48k Rate Change 14:07
            Lynch 16:33
            LUV 18:55
            """)

        // Titles only: the boundaries stay as they are.
        state.applyListing(listing, alignBoundaries: false)
        equal(state.splitTracks.count, 7, "without aligning, seven tracks remain")
        equal(state.splitTracks[5].title, "Lynch", "titles in order")
        close(state.splitTracks[5].range.start, 886.4, 0.001, "the boundary stays where it was")

        // With aligning: the list sets the boundaries.
        state.applyListing(listing, alignBoundaries: true)
        equal(state.splitTracks.count, 7, "seven tracks from seven entries")
        close(state.splitTracks[4].range.start, 848.1, 0.001, "14:07 snaps to the silence")
        close(state.splitTracks[5].range.start, 993, 0.001, "Lynch at 16:33 — without silence the list applies")
        close(state.splitTracks[4].range.duration, 144.9, 0.01,
              "\"48k\" is one track again, the pause in it no longer splits")
        equal(state.splitTracks[5].title, "Lynch", "and is named correctly")
        check(zip(state.splitTracks, state.splitTracks.dropFirst())
                .allSatisfy { abs($0.range.end - $1.range.start) < 0.0001 }, "gapless")
        equal(state.splitSelectionID, state.splitTracks.first?.id, "the first track is selected")
        check(!state.splitTracks[5].isAdjusted,
              "the aligned boundaries count as the starting point")
        check(state.splitMetadata == nil, "a pasted list provides no album")

        // From MusicBrainz, album, artist and year come along.
        let release = LookupRelease(provider: .musicBrainz, id: "x", title: "IMagination∞lenS",
                                    albumArtist: "BEAST", year: 2022,
                                    tracks: [LookupTrack(position: "1", title: "Beast City",
                                                         duration: "1:36")])
        let fromRelease = TrackListing(release: release)
        close(fromRelease.entries[0].duration ?? 0, 96, 0.001, "length read from MusicBrainz")
        state.applyListing(fromRelease, alignBoundaries: false)
        equal(state.splitMetadata?.album, "IMagination∞lenS", "the album is kept")
        equal(state.splitMetadata?.artist, "BEAST", "the artist likewise")
        equal(state.splitMetadata?.year, 2022, "and the year")

        // Only what is ticked is taken over — as when tagging.
        let withGenre = LookupRelease(provider: .discogs, id: "y", title: "Another Album",
                                      albumArtist: "Someone", year: 1999,
                                      genres: ["Electronic"], styles: ["Breakbeat"],
                                      tracks: [LookupTrack(position: "A1", title: "New",
                                                           duration: "1:36")])
        let genreListing = TrackListing(release: withGenre)
        equal(genreListing.genre, "Breakbeat", "genre by the genre choice — style is the default")
        equal(TrackListing(release: withGenre, genreSource: .genre).genre, "Electronic",
              "or the genre, if so chosen")
        equal(genreListing.availableFields, [.title, .artist, .album, .year, .genre],
              "an album provides all five fields")
        equal(listing.availableFields, [.title], "a pasted list only titles")
        let titleBefore = state.splitTracks[0].title
        state.applyListing(genreListing, fields: [.album, .genre], alignBoundaries: false)
        equal(state.splitTracks[0].title, titleBefore, "title not ticked: stays")
        equal(state.splitMetadata?.album, "Another Album", "album ticked: taken over")
        equal(state.splitMetadata?.genre, "Breakbeat", "genre likewise")
        equal(state.splitMetadata?.artist, "BEAST", "artist not ticked: stays as it was")
        equal(state.splitMetadata?.year, 2022, "year likewise")
        state.applyListing(genreListing, fields: [], alignBoundaries: false)
        equal(state.splitMetadata?.album, "Another Album", "nothing ticked changes nothing")

        // And live: does MusicBrainz really deliver lengths?
        do {
            let live = try await MusicBrainzClient()
                .release(id: "f922ec87-4758-421d-a839-3193455345ff")
            let listing = TrackListing(release: live)
            check(listing.entries.count >= 12, "real release: all tracks",
                  detail: "\(listing.entries.count)")
            check(listing.hasDurations, "with lengths for every track")
            check((listing.entries.first?.duration ?? 0) > 290,
                  "\"Smells Like Teen Spirit\" is about five minutes long")
        } catch {
            print("  … live query skipped: \(error)")
        }
    }

    /// Does the playhead really move along? A bar that does not move looks
    /// like a hanging program.
    @MainActor
    static func playhead() async {
        print("\n— Playhead —")
        guard let ffmpeg = await FFmpegLocator().locate() else {
            print("  … skipped, no ffmpeg")
            return
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("sleeve-head-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let file = folder.appendingPathComponent("probe.mp3")
        _ = try? await ProcessRunner.run(ffmpeg.url, arguments: [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=30",
            "-c:a", "libmp3lame", file.path(percentEncoded: false),
        ])

        let preview = SplitPreview()
        await preview.check(file)
        guard preview.unplayableReason == nil else {
            check(false, "probe playable"); return
        }
        preview.length = 12
        let id = UUID()
        preview.playFrom(id: id, url: file, position: 5, fileDuration: 30)

        var samples: [Double] = []
        for _ in 0..<6 {
            try? await Task.sleep(for: .milliseconds(400))
            if let position = preview.position { samples.append(position) }
        }
        check(samples.count >= 4, "the head reports regularly",
              detail: "\(samples.count) reports")
        let moved = (samples.last ?? 0) - (samples.first ?? 0)
        check(moved > 1.2, "and moves in real time",
              detail: String(format: "%.2f s in about 2 s", moved))
        check((samples.first ?? 0) >= 4.9, "starts at the set position",
              detail: String(format: "%.2f", samples.first ?? 0))

        preview.stop()
        check(preview.position == nil, "after stopping no head any more")
        check(preview.playingID == nil, "and no playing row")
    }

    @MainActor
    static func previewLength() {
        print("\n— Length of the preview —")
        let preview = SplitPreview()
        preview.length = 15
        close(preview.lead, 5, 0.001, "a third lies before the boundary")
        close(preview.tail, 10, 0.001, "two thirds after it")
        close(preview.lead + preview.tail, preview.length, 0.001, "together the full length")

        preview.length = 30
        close(preview.lead, 10, 0.001, "grows along")
    }

    // MARK: - Envelope

    static func waveform() async {
        print("\n— Envelope —")

        // Peak per bucket, not the mean: the mean would smooth out short loud
        // spots, and those are exactly what one wants to see.
        var samples = [Int16](repeating: 0, count: 1000)
        samples[500] = 20000
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let peaks = WaveformSampler.reduce(data, into: 10)
        equal(peaks.count, 10, "ten buckets")
        check(peaks[5] > 0.5, "the loud spike stays visible")
        check(peaks[0] == 0, "silent buckets stay silent")
        equal(WaveformSampler.reduce(Data(), into: 10).count, 0, "empty data yields nothing")

        // Normalized to the loudest point of the **whole file**, even in a
        // magnifier. If every magnifier normalized to itself, a quiet fade-out
        // would look as loud as the chorus.
        let quiet = WaveformSampler.Waveform(peaks: [0.02, 0.10, 0.05, 0.00], duration: 4)
        let whole = quiet.envelope(from: 0, to: 4, columns: 4)
        close(Double(whole[1]), 1.0, 0.001, "the loudest point fills the height")
        close(Double(whole[0]), 0.2, 0.001, "the others in proportion to it")
        close(Double(whole[3]), 0, 0.001, "silence stays silence")
        let lens = quiet.envelope(from: 0, to: 1, columns: 1)
        close(Double(lens[0]), 0.2, 0.001, "in a detail, too, relative to the whole file")

        let silent = WaveformSampler.Waveform(peaks: [0, 0, 0], duration: 3)
        check(silent.envelope(from: 0, to: 3, columns: 3).allSatisfy { $0 == 0 },
              "a silent file causes no division by zero")

        // More columns than values: every column still gets its value.
        let fine = quiet.envelope(from: 1, to: 2, columns: 8)
        equal(fine.count, 8, "a magnifier may resolve finer than the values")
        check(fine.allSatisfy { abs($0 - 1.0) < 0.001 }, "and shows the right value doing so")

        // And on a real file.
        guard let ffmpeg = await FFmpegLocator().locate() else { return }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("sleeve-wave-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let file = folder.appendingPathComponent("probe.mp3")
        _ = try? await ProcessRunner.run(ffmpeg.url, arguments: [
            "-hide_banner", "-loglevel", "error", "-y", "-filter_complex",
            "sine=frequency=440:duration=6[a];aevalsrc=0:d=4[b];"
            + "sine=frequency=880:duration=6[c];[a][b][c]concat=n=3:v=0:a=1[out]",
            "-map", "[out]", "-c:a", "libmp3lame", file.path(percentEncoded: false),
        ])
        guard let shape = try? await WaveformSampler.load(file, duration: 16, ffmpeg: ffmpeg) else {
            check(false, "envelope of a real file"); return
        }
        // Fixed resolution: a hundred values per second, i.e. 10 ms per value.
        close(Double(shape.peaks.count), 1600, 30, "a hundred values per second")
        let view = shape.envelope(from: 0, to: 16, columns: 16)
        check(view[1] > 0.7, "the first half is loud")
        check(view[8] < 0.1, "the silence in between is recognizable",
              detail: String(format: "%.3f", view[8]))
        check(view[13] > 0.7, "then it gets loud again")

        // The magnifier hits the silence to a tenth of a second — that is what
        // the fine resolution is for.
        let edge = shape.envelope(from: 5.5, to: 6.5, columns: 10)
        check(edge[0] > 0.5, "0.5 s before the silence it is loud")
        check(edge[9] < 0.1, "0.5 s after it silent")
    }

    // MARK: - End to end with an album video

    /// A downloaded "full album" is often a video. What is checked is that the
    /// audio stream comes out **unchanged** — not re-encoded.
    static func videoEndToEnd(ffmpeg: FFmpegTool, folder: URL) async throws {
        print("\n— Album as a video —")
        let video = folder.appendingPathComponent("album.mp4")
        let build = try await ProcessRunner.run(ffmpeg.url, arguments: [
            "-hide_banner", "-loglevel", "error", "-y",
            "-filter_complex",
            "color=c=navy:s=320x180:d=27[v];"
            + "sine=frequency=440:duration=12[a1];aevalsrc=0:d=3[s];"
            + "sine=frequency=660:duration=12[a2];[a1][s][a2]concat=n=3:v=0:a=1[a]",
            "-map", "[v]", "-map", "[a]",
            "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "128k",
            video.path(percentEncoded: false),
        ])
        guard build.succeeded else {
            check(false, "album video built", detail: build.standardError.prefix(120).description)
            return
        }

        let info = try await AudioSplitter.probe(file: video, ffmpeg: ffmpeg)
        check(info.hasVideo, "picture stream recognized")
        equal(info.audioCodec, "aac", "the audio stream is AAC")
        equal(info.outputExtension, "m4a", "pieces become m4a, not mp4")
        close(info.duration, 27, 0.3, "duration recognized")

        let analysis = try await AudioSplitter.analyze(
            file: video, thresholdDB: -30, minDuration: 0.5, ffmpeg: ffmpeg)
        let ranges = AudioSplitter.trackRanges(
            duration: analysis.duration, silences: analysis.silences, minimumLength: 10)
        equal(ranges.count, 2, "two tracks found in the video")

        let piece = folder.appendingPathComponent("from-video.m4a")
        try await AudioSplitter.cut(source: video, range: ranges[0], to: piece,
                                    audioOnly: true, ffmpeg: ffmpeg)

        // No picture may be left in the result.
        let probe = try await ProcessRunner.run(ffmpeg.url, arguments: [
            "-hide_banner", "-i", piece.path(percentEncoded: false), "-f", "null", "-",
        ])
        check(!probe.standardError.contains("Video:"), "no picture left in the piece")
        equal(AudioSplitter.parseAudioCodec(probe.standardError), "aac",
              "and the sound is unchanged AAC")

        // The actual proof: the whole audio stream extracted has to be
        // bit-identical to the one in the video.
        let whole = folder.appendingPathComponent("whole.m4a")
        _ = try await ProcessRunner.run(ffmpeg.url, arguments: [
            "-hide_banner", "-loglevel", "error", "-y",
            "-i", video.path(percentEncoded: false),
            "-map", "0:a:0", "-c:a", "copy", whole.path(percentEncoded: false),
        ])
        func samples(_ url: URL, mapAudio: Bool) async throws -> Data {
            var args = ["-v", "error", "-i", url.path(percentEncoded: false)]
            if mapAudio { args += ["-map", "0:a:0"] }
            args += ["-f", "s16le", "-"]
            let raw = try await ProcessRunner.run(ffmpeg.url, arguments: args)
            return Data(raw.standardOutput.utf8)
        }
        let fromVideo = try await samples(video, mapAudio: true)
        let fromFile = try await samples(whole, mapAudio: false)
        check(!fromVideo.isEmpty && fromVideo == fromFile,
              "the extracted audio stream is bit-identical to the one in the video")

        // And the same cut with conversion: AAC becomes MP3.
        let asMP3 = folder.appendingPathComponent("converted.mp3")
        try await AudioSplitter.cut(source: video, range: ranges[0], to: asMP3,
                                    audioOnly: true, output: .convert(.mp3),
                                    bitrate: 192, ffmpeg: ffmpeg)
        let mp3Probe = try await ProcessRunner.run(ffmpeg.url, arguments: [
            "-hide_banner", "-i", asMP3.path(percentEncoded: false), "-f", "null", "-",
        ])
        equal(AudioSplitter.parseAudioCodec(mp3Probe.standardError), "mp3",
              "the converted piece is MP3")
        close(AudioSplitter.parseDuration(mp3Probe.standardError) ?? 0,
              ranges[0].duration, 0.35, "and has the right length")
    }

    // MARK: - End to end

    static func endToEnd() async throws {
        print("\n— End to end with a built file —")
        guard let ffmpeg = await FFmpegLocator().locate() else {
            print("  … skipped, no ffmpeg")
            return
        }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("sleeve-split-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // Three tones of 12 s, 3 s of silence between them. 42 s in total.
        let source = folder.appendingPathComponent("probe.mp3")
        let filter = "sine=frequency=440:duration=12,"
            + "adelay=0|0[a];"
            + "aevalsrc=0:d=3[s1];"
            + "sine=frequency=660:duration=12[b];"
            + "aevalsrc=0:d=3[s2];"
            + "sine=frequency=880:duration=12[c];"
            + "[a][s1][b][s2][c]concat=n=5:v=0:a=1[out]"
        let build = try await ProcessRunner.run(ffmpeg.url, arguments: [
            "-hide_banner", "-loglevel", "error", "-y",
            "-filter_complex", filter, "-map", "[out]",
            "-b:a", "128k", source.path(percentEncoded: false),
        ])
        guard build.succeeded else {
            check(false, "test file built", detail: build.standardError.prefix(120).description)
            return
        }
        check(true, "test file built: three tones of 12 s, 3 s of silence between them")

        let analysis = try await AudioSplitter.analyze(
            file: source, thresholdDB: -30, minDuration: 0.5, ffmpeg: ffmpeg)
        close(analysis.duration, 42, 0.2, "duration recognized")
        equal(analysis.silences.count, 2, "two silences found")

        let ranges = AudioSplitter.trackRanges(
            duration: analysis.duration, silences: analysis.silences, minimumLength: 10)
        equal(ranges.count, 3, "three tracks")
        close(ranges[0].start, 0, 0.2, "track 1 starts at 0 s")
        // The pause belongs to the end of the previous track — nothing is
        // discarded.
        close(ranges[0].end, 15, 0.3, "track 1 ends where tone 2 sets in")
        close(ranges[1].start, 15, 0.3, "track 2 starts at 15 s")
        close(ranges[1].end, 30, 0.3, "track 2 ends where tone 3 sets in")
        close(ranges[2].start, 30, 0.3, "track 3 starts at 30 s")
        close(ranges[2].end, 42, 0.2, "track 3 ends at the end of the file")

        // And really cut.
        for (index, range) in ranges.enumerated() {
            let target = folder.appendingPathComponent(String(format: "%02d.mp3", index + 1))
            try await AudioSplitter.cut(source: source, range: range,
                                        to: target, audioOnly: false, ffmpeg: ffmpeg)
            let exists = FileManager.default.fileExists(atPath: target.path(percentEncoded: false))
            check(exists, "track \(index + 1) written")
            guard exists else { continue }

            // The cut file has to have the expected length.
            let probe = try await ProcessRunner.run(ffmpeg.url, arguments: [
                "-hide_banner", "-i", target.path(percentEncoded: false),
                "-f", "null", "-",
            ])
            let cutDuration = AudioSplitter.parseDuration(probe.standardError) ?? 0
            close(cutDuration, range.duration, 0.35,
                  "track \(index + 1) is \(String(format: "%.1f", range.duration)) s long")
        }

        try await videoEndToEnd(ffmpeg: ffmpeg, folder: folder)

        // And the tags: `-c copy` inherits them from the source, which is why
        // the title has to be set afterwards.
        let first = folder.appendingPathComponent("01.mp3")
        var tags = AudioTags()
        tags.title = "First Tone"
        tags.trackNumber = 1
        try TagLibBridge.write(tags, fields: [.title, .trackNumber], to: first)
        let readBack = try TagLibBridge.read(from: first)
        equal(readBack.tags.title, "First Tone", "the title is in the cut piece")
        equal(readBack.tags.trackNumber, 1, "the track number likewise")
    }
}
