//
//  SplitTests.swift
//
//  Track Splitter (§7). Der Durchstich arbeitet mit einer selbst gebauten
//  Datei — drei Töne, dazwischen Stille —, weil dort jede Grenze vorher
//  bekannt ist. An echter Musik wäre „stimmt ungefähr" das Beste, was man
//  prüfen könnte.
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
        check(actual == expected, label, detail: "ist \(actual), erwartet \(expected)")
    }

    static func close(_ actual: Double, _ expected: Double, _ tolerance: Double,
                      _ label: String) {
        check(abs(actual - expected) <= tolerance, label,
              detail: String(format: "ist %.3f, erwartet %.3f ± %.3f", actual, expected, tolerance))
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

        print("\n  \(checks) Prüfungen, \(failures) Fehler")
        return failures == 0 ? 0 : 1
    }

    // MARK: - ffmpegs Ausgabe lesen

    static func parsing() {
        print("\n— ffmpeg-Ausgabe auswerten —")

        let sample = """
        Input #0, mp3, from 'album.mp3':
          Duration: 00:52:29.57, start: 0.025057, bitrate: 320 kb/s
        [silencedetect @ 0x14e704080] silence_start: -0.00478458
        [silencedetect @ 0x14e704080] silence_end: 2.03175 | silence_duration: 2.03654
        [silencedetect @ 0x14e704080] silence_start: 184.729
        [silencedetect @ 0x14e704080] silence_end: 187 | silence_duration: 2.271
        """
        close(AudioSplitter.parseDuration(sample) ?? 0, 3149.57, 0.01, "Dauer aus dem Banner")

        let silences = AudioSplitter.parseSilences(sample)
        equal(silences.count, 2, "zwei Stillen gepaart")
        // ffmpeg meldet gelegentlich einen leicht negativen Start.
        close(silences[0].start, 0, 0.001, "negativer Start wird auf null gezogen")
        close(silences[0].end, 2.03175, 0.001, "Ende mit Nachkommastellen")
        close(silences[1].start, 184.729, 0.001, "zweiter Start")
        // Und manchmal ohne Nachkommastelle — „187", nicht „187.0".
        close(silences[1].end, 187, 0.001, "Ende ohne Nachkommastelle")

        check(AudioSplitter.parseDuration("kein Banner") == nil, "ohne Banner keine Dauer")
        equal(AudioSplitter.parseSilences("nichts").count, 0, "ohne Fundstellen keine Stille")
    }

    // MARK: - Was steckt in der Datei

    static func sourceInfo() {
        print("\n— Quelle erkennen —")

        let video = """
        Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'album.mp4':
          Duration: 00:44:49.30, start: 0.000000, bitrate: 1181 kb/s
          Stream #0:0[0x1](und): Video: h264 (High) (avc1 / 0x31637661), yuv420p, 854x480
          Stream #0:1[0x2](und): Audio: aac (LC) (mp4a / 0x6134706D), 44100 Hz, stereo, fltp, 128 kb/s
        """
        equal(AudioSplitter.parseAudioCodec(video), "aac", "AAC im Video erkannt")
        close(AudioSplitter.parseDuration(video) ?? 0, 2689.3, 0.01, "Dauer des Videos")

        let mp3 = """
        Input #0, mp3, from 'album.mp3':
          Duration: 00:52:29.57, start: 0.025057, bitrate: 320 kb/s
          Stream #0:0: Audio: mp3 (mp3float), 44100 Hz, stereo, fltp, 320 kb/s
        """
        equal(AudioSplitter.parseAudioCodec(mp3), "mp3", "MP3 erkannt")

        let silent = """
        Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'stumm.mp4':
          Duration: 00:00:10.00, start: 0.000000, bitrate: 50 kb/s
          Stream #0:0[0x1](und): Video: h264 (High), yuv420p, 320x180
        """
        check(AudioSplitter.parseAudioCodec(silent) == nil, "Video ohne Ton hat keinen Codec")

        print("\n— Behälter für die Stücke —")
        func ext(_ codec: String) -> String {
            AudioSplitter.SourceInfo(duration: 1, audioCodec: codec, hasVideo: true)
                .outputExtension
        }
        // Aus einem Video wird nie wieder ein Video — gefragt ist die Musik.
        equal(ext("aac"), "m4a", "AAC landet in m4a")
        equal(ext("alac"), "m4a", "ALAC ebenso")
        equal(ext("mp3"), "mp3", "MP3 bleibt MP3")
        equal(ext("opus"), "opus", "Opus bleibt Opus")
        equal(ext("vorbis"), "ogg", "Vorbis kommt in ogg")
        equal(ext("flac"), "flac", "FLAC bleibt FLAC")
        equal(ext("pcm_s16le"), "wav", "rohes PCM kommt in wav")
        equal(ext("irgendwas"), "m4a", "Unbekanntes kommt in m4a")

        check(AudioSplitter.acceptedExtensions.contains("mp4"), "mp4 wird angenommen")
        check(AudioSplitter.acceptedExtensions.contains("webm"), "webm ebenso")
        check(AudioSplitter.acceptedExtensions.contains("mp3"), "mp3 weiterhin")
        check(!AudioSplitter.acceptedExtensions.contains("txt"), "Textdateien nicht")
    }

    // MARK: - Aus Stille werden Grenzen

    static func boundaries() {
        print("\n— Grenzen aus Stille —")

        // Stille am Anfang und Ende ist Leerlauf, keine Grenze.
        let edges = AudioSplitter.trackRanges(
            duration: 100,
            silences: [.init(start: 0, end: 1.5), .init(start: 40, end: 42),
                       .init(start: 99, end: 100)],
            minimumLength: 0)
        equal(edges.count, 2, "Randstille zählt nicht als Grenze")
        close(edges[0].start, 0, 0.001, "erster Track beginnt bei null")
        // Ohne Hüllkurve wird am Ende der Stille geschnitten: die Pause gehört
        // zum vorigen Track, wie bei CD-Rippern.
        close(edges[0].end, 42, 0.001, "die Pause gehört zum Ende des vorigen Tracks")
        close(edges[1].start, 42, 0.001, "der nächste beginnt dort, wo die Musik einsetzt")
        close(edges[1].end, 100, 0.001, "letzter Track reicht bis zum Ende")

        equal(AudioSplitter.trackRanges(duration: 100, silences: []).count, 0,
              "ohne Stille keine Aufteilung")

        print("\n— Nichts geht verloren —")
        // Der erste Anlauf ließ die Pausen weg — und mit ihnen alles, was
        // leiser als die Schwelle war. Am echten Album 66 s in keiner Datei.
        let many = AudioSplitter.trackRanges(
            duration: 600,
            silences: [.init(start: 100, end: 105), .init(start: 250, end: 258),
                       .init(start: 400, end: 401)],
            minimumLength: 10)
        check(zip(many, many.dropFirst()).allSatisfy { abs($0.end - $1.start) < 0.0001 },
              "die Tracks liegen lückenlos aneinander")
        close(many.first!.start, 0, 0.0001, "vom Dateianfang")
        close(many.last!.end, 600, 0.0001, "bis zum Dateiende")
        close(many.reduce(0) { $0 + $1.duration }, 600, 0.0001,
              "zusammen genau so lang wie die Datei")

        print("\n— Die tiefste Stille —")
        // Hüllkurve: 10 s laut, 3 s digitale Null, 4 s leises Intro
        // (−40 dB, unter der Schwelle), dann laut. Die Schwellen-Stille reicht
        // bis 17 s — geschnitten werden muss aber bei 13 s, sonst bekommt der
        // vorige Track das Intro.
        var peaks = [Float](repeating: 0.8, count: 1000)       // 100 je Sekunde
        for i in 1000..<1300 { peaks.append(0) }               // 10–13 s
        for _ in 1300..<1700 { peaks.append(0.01) }            // 13–17 s, −40 dB
        for _ in 1700..<3000 { peaks.append(0.8) }             // 17–30 s
        let levels = WaveformSampler.Waveform(peaks: peaks, duration: 30)
        let region = SilenceInterval(start: 10, end: 17)
        close(AudioSplitter.cutPosition(in: region, levels: levels), 13, 0.02,
              "geschnitten wird am Ende der digitalen Null, nicht der Schwelle")
        close(AudioSplitter.cutPosition(in: region, levels: nil), 17, 0.001,
              "ohne Hüllkurve am Ende der Stille")

        // Ohne digitale Null — Rauschen einer Kassette, −55 dB — zählt alles
        // unter −60 dB bzw. knapp über dem Tiefsten als Boden.
        var hiss = [Float](repeating: 0.8, count: 500)
        hiss += [Float](repeating: 0.0018, count: 300)          // 5–8 s Rauschen
        hiss += [Float](repeating: 0.02, count: 200)            // 8–10 s leises Intro
        hiss += [Float](repeating: 0.8, count: 500)
        close(AudioSplitter.cutPosition(in: .init(start: 5, end: 10),
                                        levels: WaveformSampler.Waveform(peaks: hiss, duration: 15)),
              8, 0.02, "auch bei Rauschen statt Null am Ende des Tiefsten")

        print("\n— Kurze Stücke zwischen zwei Tracks —")
        // Der Fall vom Album: vor „LUV" eine lange Pause, dann drei kurze
        // Klangstücke mit kleinen Pausen — das Intro. Es gehört zum nächsten
        // Track, nicht zum vorigen.
        let intro = AudioSplitter.trackRanges(
            duration: 1500,
            silences: [.init(start: 1132.5, end: 1136.7),       // lange Pause
                       .init(start: 1139.0, end: 1140.0),
                       .init(start: 1143.7, end: 1145.0),
                       .init(start: 1148.2, end: 1149.9)],
            minimumLength: 10)
        equal(intro.count, 2, "das Intro wird kein eigener Track")
        close(intro[1].start, 1136.7, 0.001, "sondern beginnt den nächsten, nach der langen Pause")

        // Applaus nach einem Live-Stück: kurze Lücke, dann die lange Pause.
        let applause = AudioSplitter.trackRanges(
            duration: 300,
            silences: [.init(start: 92.5, end: 93.0), .init(start: 97.0, end: 101.0)],
            minimumLength: 10)
        equal(applause.count, 2, "Applaus wird kein eigener Track")
        close(applause[0].end, 101.0, 0.001, "sondern bleibt beim Stück davor")

        // Ein Knacken in der Pause trennt sie nicht.
        let click = AudioSplitter.bridge(
            [.init(start: 92.5, end: 96.9), .init(start: 97.1, end: 97.6)], within: 1.0)
        equal(click.count, 1, "zwei Stillen mit einem Knacken dazwischen sind eine")
        close(click[0].end, 97.6, 0.001, "und reichen bis zum Ende der zweiten")

        // Am Dateianfang gibt es keinen Vorgänger — kurze Stücke gehen nach hinten.
        let opener = AudioSplitter.thin(
            [.init(position: 3, strength: 1), .init(position: 100, strength: 4)],
            duration: 300, minimumLength: 10)
        equal(opener.count, 1, "ein zu kurzes erstes Stück hat nur einen Nachbarn")
        close(opener[0].position, 100, 0.001, "und geht in ihn auf")

        let tail = AudioSplitter.thin(
            [.init(position: 100, strength: 4), .init(position: 295, strength: 1)],
            duration: 300, minimumLength: 10)
        close(tail.last!.position, 100, 0.001, "ein zu kurzes letztes Stück ebenso")

        equal(AudioSplitter.thin(
            [.init(position: 1, strength: 1), .init(position: 2, strength: 1)],
            duration: 300, minimumLength: 0).count, 2,
              "abgeschaltete Mindestlänge dünnt nichts aus")
    }

    // MARK: - Zeitangaben

    static func timecodes() {
        print("\n— Zeitangaben —")
        equal(Timecode.format(0), "00:00.0", "null")
        equal(Timecode.format(61.26), "01:01.3", "eine Minute und etwas")
        // Genau .x5 ist binär ein Gleichstand; `%.1f` rundet dann zur geraden
        // Ziffer. Festgehalten, damit es niemand für einen Fehler hält.
        equal(Timecode.format(61.25), "01:01.2", "Gleichstand rundet zur geraden Ziffer")
        equal(Timecode.short(300.3), "5:00", "Vergleichstabellen: ganze Sekunden")
        equal(Timecode.short(993.6), "16:34", "gerundet")
        equal(Timecode.short(3723), "1:02:03", "mit Stunden")
        equal(Timecode.format(3599.9), "59:59.9", "knapp eine Stunde")

        close(Timecode.parse("01:01.3") ?? 0, 61.3, 0.001, "zurückgelesen")
        close(Timecode.parse("90") ?? 0, 90, 0.001, "blanke Sekunden")
        close(Timecode.parse("1:02:03") ?? 0, 3723, 0.001, "mit Stunden")
        close(Timecode.parse("01:01,3") ?? 0, 61.3, 0.001, "Komma statt Punkt")
        check(Timecode.parse("") == nil, "leer ergibt nichts")
        check(Timecode.parse("Unsinn") == nil, "Unsinn ergibt nichts")
        check(Timecode.parse("1:2:3:4") == nil, "vier Teile ergeben nichts")

        // Rundlauf über viele Werte — hier fällt ein Rundungsfehler auf.
        var roundTripOK = true
        for tenths in stride(from: 0, through: 6000, by: 7) {
            let seconds = Double(tenths) / 10
            guard let back = Timecode.parse(Timecode.format(seconds)),
                  abs(back - seconds) < 0.06 else { roundTripOK = false; break }
        }
        check(roundTripOK, "Rundlauf über 860 Werte")
    }

    // MARK: - Zielformat

    static func targetFormat() {
        print("\n— Zielformat —")
        check(!SplitOutput.keepSource.reencodes, "wie die Quelle kodiert nicht neu")
        check(SplitOutput.convert(.mp3).reencodes, "MP3 kodiert neu")
        check(SplitOutput.convert(.flac).reencodes,
              "auch FLAC kodiert neu — verlustfrei heißt nicht unverändert")
        check(SplitOutput.keepSource != SplitOutput.convert(.mp3), "beide unterscheidbar")
    }

    // MARK: - Hineinhören

    @MainActor
    static func preview() async {
        print("\n— Hineinhören —")
        // Das Fenster liegt um die Grenze, nicht dahinter.
        let player = SplitPreview()
        player.length = 12
        func window(trackStart: Double, fileDuration: Double) -> (Double, Double) {
            let from = max(0, trackStart - player.lead)
            return (from, min(fileDuration, from + player.length))
        }
        var w = window(trackStart: 100, fileDuration: 600)
        close(w.0, 96, 0.001, "beginnt ein Drittel der Probe vor dem Track")
        close(w.1, 108, 0.001, "und läuft die volle Länge")

        w = window(trackStart: 0, fileDuration: 600)
        close(w.0, 0, 0.001, "bei Track 1 nicht vor den Dateianfang")
        close(w.1, 12, 0.001, "und dann die volle Länge")

        w = window(trackStart: 598, fileDuration: 600)
        close(w.1, 600, 0.001, "am Dateiende wird abgeschnitten")
        check(w.1 > w.0, "das Fenster bleibt sinnvoll")

        // Und an echten Dateien: AVFoundation muss sie annehmen.
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
            check(preview.unplayableReason == nil, "\(ext) lässt sich abspielen")
        }
    }

    // MARK: - Grenzen bearbeiten

    @MainActor
    static func editing() {
        print("\n— Grenzen eines Tracks —")
        let track = SplitTrack(range: TrackRange(start: 100, end: 220))
        check(!track.isAdjusted, "frisch erkannt heißt unverändert")

        track.assign(start: 97.5)
        close(track.range.start, 97.5, 0.001, "Anfang wird gespeichert")
        equal(track.startText, "01:37.5", "das Zeitfeld zieht mit")
        check(track.isAdjusted, "die Zeile gilt als verändert")

        track.assign(start: 100)
        check(!track.isAdjusted, "zurück auf die Erkennung heißt unverändert")

        // Nach Teilen oder Zusammenlegen ist der neue Stand der Ausgangspunkt.
        track.assign(end: 150)
        track.detected = track.range
        check(!track.isAdjusted, "ein neuer Ausgangspunkt gilt als unverändert")
    }

    /// Marke, Auswahl, Teilen und Zusammenlegen — so, wie das Fenster sie
    /// benutzt: über den Zustand der App, nicht über Einzelteile.
    @MainActor
    static func windowModel() {
        print("\n— Marke und Auswahl —")
        let state = AppState()
        state.splitSourceInfo = AudioSplitter.SourceInfo(duration: 300, audioCodec: "aac",
                                                         hasVideo: false)
        state.splitTracks = [
            SplitTrack(range: TrackRange(start: 0, end: 92.5)),
            SplitTrack(range: TrackRange(start: 97.6, end: 200)),
            SplitTrack(range: TrackRange(start: 203, end: 300)),
        ]
        state.splitPreview.length = 15   // Vorlauf also 5 s
        state.selectSplitTrack(state.splitTracks[1].id)

        // Ohne eigene Setzung steht die Marke am Trackanfang — wer einen Track
        // abspielt, erwartet ihn ab seinem Anfang, nicht vier Sekunden davor.
        close(state.splitMarkPosition, 97.6, 0.001, "Marke steht am Anfang des Tracks")
        close(state.splitCurrentPosition, 97.6, 0.001, "ohne Wiedergabe gilt die Marke")

        // Über die Grenze hinweg hören ist ein eigener Knopf.
        state.jumpToStartBoundary()
        state.splitPreview.stop()
        close(state.splitMarkPosition, 92.6, 0.001, "⏮ setzt die Marke um den Vorlauf davor")
        state.selectSplitTrack(state.splitTracks[2].id)
        state.selectSplitTrack(state.splitTracks[1].id)

        state.setSplitMark(150)
        close(state.splitMarkPosition, 150, 0.001, "Marke lässt sich setzen")
        state.setSplitMark(-10)
        close(state.splitMarkPosition, 0, 0.001, "nicht vor den Dateianfang")
        state.setSplitMark(9999)
        close(state.splitMarkPosition, 300, 0.001, "nicht hinter das Dateiende")

        // Eine andere Zeile wählen setzt die Marke zurück an deren Anfang.
        state.selectSplitTrack(state.splitTracks[2].id)
        close(state.splitMarkPosition, 203, 0.001, "neue Zeile, neue Marke an ihrem Anfang")

        print("\n— Gemeinsame Grenzen —")
        // Grenze 1 ist das Ende von Track 0 und der Anfang von Track 1. Wer sie
        // verschiebt, verschiebt beides — sonst entstünde eine Lücke, und was
        // darin liegt, stünde in keiner Datei.
        state.splitTracks = [
            SplitTrack(range: TrackRange(start: 0, end: 97.6)),
            SplitTrack(range: TrackRange(start: 97.6, end: 203)),
            SplitTrack(range: TrackRange(start: 203, end: 300)),
        ]
        state.selectSplitTrack(state.splitTracks[1].id)
        state.setSplitMark(99)
        state.setSelectedStartHere()
        close(state.splitTracks[1].range.start, 99, 0.001, "„Anfang hierher“ nimmt die Marke")
        close(state.splitTracks[0].range.end, 99, 0.001, "und der vorige Track endet mit")

        state.setSplitMark(195)
        state.setSelectedEndHere()
        close(state.splitTracks[1].range.end, 195, 0.001, "„Ende hierher“ ebenso")
        close(state.splitTracks[2].range.start, 195, 0.001, "und der nächste beginnt mit")

        func contiguous() -> Bool {
            zip(state.splitTracks, state.splitTracks.dropFirst())
                .allSatisfy { abs($0.range.end - $1.range.start) < 0.0001 }
        }
        check(contiguous(), "keine Lücke nach dem Verschieben")

        // Eine Grenze kann nicht über den Nachbarn hinausgeschoben werden.
        state.moveSelectedStart(to: -50)
        check(state.splitTracks[0].range.duration >= SplitTrack.minimumLength - 0.0001,
              "der vorige Track verschwindet nicht")
        check(contiguous(), "und es bleibt lückenlos")

        // Zurücksetzen nimmt die Nachbarn mit.
        state.selectSplitTrack(state.splitTracks[1].id)
        state.resetSelectedBoundaries()
        close(state.splitTracks[1].range.start, 97.6, 0.001, "Zurücksetzen stellt den Anfang her")
        close(state.splitTracks[0].range.end, 97.6, 0.001, "samt Ende des vorigen")
        check(contiguous(), "lückenlos")

        // Nur an den Dateirändern lässt sich etwas abschneiden.
        state.selectSplitTrack(state.splitTracks[0].id)
        state.moveSelectedStart(to: 4)
        close(state.splitTracks[0].range.start, 4, 0.001,
              "am Dateianfang lässt sich eine Ansage abschneiden")
        close(state.splitTracks[0].range.end, 97.6, 0.001, "ohne dass sich sonst etwas bewegt")
        state.moveSelectedStart(to: 0)
        state.selectSplitTrack(state.splitTracks[1].id)


        print("\n— Teilen und Zusammenlegen —")
        state.setSplitMark(150)
        check(state.canSplitHere, "mitten im Track lässt sich teilen")
        state.splitHere()
        equal(state.splitTracks.count, 4, "aus drei Tracks werden vier")
        close(state.splitTracks[1].range.end, 150, 0.001, "der erste Teil endet an der Marke")
        close(state.splitTracks[2].range.start, 150, 0.001, "der zweite beginnt dort")
        equal(state.splitSelectionID, state.splitTracks[2].id, "der neue Teil ist gewählt")
        check(contiguous(), "lückenlos")

        // Nach dem Teilen führt Zurücksetzen nicht mehr an die alte Grenze —
        // die gibt es nicht mehr.
        state.selectSplitTrack(state.splitTracks[1].id)
        state.resetSelectedBoundaries()
        close(state.splitTracks[1].range.end, 150, 0.001,
              "Zurücksetzen nach dem Teilen hält die neue Grenze")

        state.selectSplitTrack(state.splitTracks[2].id)
        state.mergeSelectedWithPrevious()
        equal(state.splitTracks.count, 3, "Zusammenlegen macht es rückgängig")
        equal(state.splitSelectionID, state.splitTracks[1].id, "der Vorgänger ist nun gewählt")
        check(contiguous(), "lückenlos")

        state.selectSplitTrack(state.splitTracks[0].id)
        state.mergeSelectedWithPrevious()
        equal(state.splitTracks.count, 3, "der erste Track hat keinen Vorgänger")
    }

    /// Eine Trackliste übernehmen — so, wie das Blatt es tut.
    @MainActor
    static func applyingListing() async {
        print("\n— Trackliste übernehmen —")
        let state = AppState()
        state.splitSource = URL(fileURLWithPath:
            "/x/BEAST - IMagination∞lenS (Full Album) (486p_30fps_H264-128kbit_AAC).mp4")
        state.splitSourceInfo = AudioSplitter.SourceInfo(duration: 1370, audioCodec: "aac",
                                                         hasVideo: true)

        // Vorschlag für die Suche aus dem Dateinamen, ohne die Klammern, die
        // Uploader anhängen.
        let guess = state.suggestedSplitSearch
        equal(guess.artist, "BEAST", "Interpret aus dem Dateinamen")
        equal(guess.album, "IMagination∞lenS", "Album ohne „(Full Album)“ und Auflösung")

        // Erkennung wie am echten Album: die Pause in „48k" ist eine Grenze,
        // Lynch fehlt.
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

        // Nur Titel: die Grenzen bleiben, wie sie sind.
        state.applyListing(listing, alignBoundaries: false)
        equal(state.splitTracks.count, 7, "ohne Ausrichten bleiben sieben Tracks")
        equal(state.splitTracks[5].title, "Lynch", "Titel der Reihe nach")
        close(state.splitTracks[5].range.start, 886.4, 0.001, "die Grenze bleibt, wo sie war")

        // Mit Ausrichten: die Liste setzt die Grenzen.
        state.applyListing(listing, alignBoundaries: true)
        equal(state.splitTracks.count, 7, "sieben Tracks aus sieben Einträgen")
        close(state.splitTracks[4].range.start, 848.1, 0.001, "14:07 rastet an der Stille ein")
        close(state.splitTracks[5].range.start, 993, 0.001, "Lynch bei 16:33 — ohne Stille gilt die Liste")
        close(state.splitTracks[4].range.duration, 144.9, 0.01,
              "„48k“ ist wieder ein Track, die Pause darin trennt nicht mehr")
        equal(state.splitTracks[5].title, "Lynch", "und heißt richtig")
        check(zip(state.splitTracks, state.splitTracks.dropFirst())
                .allSatisfy { abs($0.range.end - $1.range.start) < 0.0001 }, "lückenlos")
        equal(state.splitSelectionID, state.splitTracks.first?.id, "der erste Track ist gewählt")
        check(!state.splitTracks[5].isAdjusted,
              "die ausgerichteten Grenzen gelten als Ausgangspunkt")
        check(state.splitMetadata == nil, "eine eingefügte Liste liefert kein Album")

        // Aus MusicBrainz kommen Album, Interpret und Jahr mit.
        let release = LookupRelease(provider: .musicBrainz, id: "x", title: "IMagination∞lenS",
                                    albumArtist: "BEAST", year: 2022,
                                    tracks: [LookupTrack(position: "1", title: "Beast City",
                                                         duration: "1:36")])
        let fromRelease = TrackListing(release: release)
        close(fromRelease.entries[0].duration ?? 0, 96, 0.001, "Länge aus MusicBrainz gelesen")
        state.applyListing(fromRelease, alignBoundaries: false)
        equal(state.splitMetadata?.album, "IMagination∞lenS", "Album wird gemerkt")
        equal(state.splitMetadata?.artist, "BEAST", "Interpret ebenso")
        equal(state.splitMetadata?.year, 2022, "und das Jahr")

        // Übernommen wird nur, was angehakt ist — wie beim Taggen.
        let mitGenre = LookupRelease(provider: .discogs, id: "y", title: "Anderes Album",
                                     albumArtist: "Jemand", year: 1999,
                                     genres: ["Electronic"], styles: ["Breakbeat"],
                                     tracks: [LookupTrack(position: "A1", title: "Neu",
                                                          duration: "1:36")])
        let genreListe = TrackListing(release: mitGenre)
        equal(genreListe.genre, "Breakbeat", "Genre nach der Genre-Wahl — Style voreingestellt")
        equal(TrackListing(release: mitGenre, genreSource: .genre).genre, "Electronic",
              "oder das Genre, wenn so gewählt")
        equal(genreListe.availableFields, [.title, .artist, .album, .year, .genre],
              "Ein Album liefert alle fünf Felder")
        equal(listing.availableFields, [.title], "Eine eingefügte Liste nur Titel")
        let titelVorher = state.splitTracks[0].title
        state.applyListing(genreListe, fields: [.album, .genre], alignBoundaries: false)
        equal(state.splitTracks[0].title, titelVorher, "Titel nicht angehakt: bleibt")
        equal(state.splitMetadata?.album, "Anderes Album", "Album angehakt: übernommen")
        equal(state.splitMetadata?.genre, "Breakbeat", "Genre ebenso")
        equal(state.splitMetadata?.artist, "BEAST", "Interpret nicht angehakt: bleibt, wie er war")
        equal(state.splitMetadata?.year, 2022, "Jahr ebenso")
        state.applyListing(genreListe, fields: [], alignBoundaries: false)
        equal(state.splitMetadata?.album, "Anderes Album", "Nichts angehakt ändert nichts")

        // Und live: liefert MusicBrainz wirklich Längen?
        do {
            let live = try await MusicBrainzClient()
                .release(id: "f922ec87-4758-421d-a839-3193455345ff")
            let listing = TrackListing(release: live)
            check(listing.entries.count >= 12, "echtes Release: alle Tracks",
                  detail: "\(listing.entries.count)")
            check(listing.hasDurations, "mit Längen für jeden Track")
            check((listing.entries.first?.duration ?? 0) > 290,
                  "„Smells Like Teen Spirit“ ist rund fünf Minuten lang")
        } catch {
            print("  … Live-Abfrage übersprungen: \(error)")
        }
    }

    /// Läuft der Abspielkopf wirklich mit? Ein Balken, der sich nicht bewegt,
    /// sieht aus wie ein hängendes Programm.
    @MainActor
    static func playhead() async {
        print("\n— Abspielkopf —")
        guard let ffmpeg = await FFmpegLocator().locate() else {
            print("  … übersprungen, kein ffmpeg")
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
            check(false, "Probe abspielbar"); return
        }
        preview.length = 12
        let id = UUID()
        preview.playFrom(id: id, url: file, position: 5, fileDuration: 30)

        var samples: [Double] = []
        for _ in 0..<6 {
            try? await Task.sleep(for: .milliseconds(400))
            if let position = preview.position { samples.append(position) }
        }
        check(samples.count >= 4, "der Kopf meldet sich regelmäßig",
              detail: "\(samples.count) Meldungen")
        let moved = (samples.last ?? 0) - (samples.first ?? 0)
        check(moved > 1.2, "und wandert in Echtzeit",
              detail: String(format: "%.2f s in rund 2 s", moved))
        check((samples.first ?? 0) >= 4.9, "beginnt an der gesetzten Stelle",
              detail: String(format: "%.2f", samples.first ?? 0))

        preview.stop()
        check(preview.position == nil, "nach dem Anhalten kein Kopf mehr")
        check(preview.playingID == nil, "und keine spielende Zeile")
    }

    @MainActor
    static func previewLength() {
        print("\n— Länge der Hörprobe —")
        let preview = SplitPreview()
        preview.length = 15
        close(preview.lead, 5, 0.001, "ein Drittel liegt vor der Grenze")
        close(preview.tail, 10, 0.001, "zwei Drittel danach")
        close(preview.lead + preview.tail, preview.length, 0.001, "zusammen die volle Länge")

        preview.length = 30
        close(preview.lead, 10, 0.001, "wächst mit")
    }

    // MARK: - Hüllkurve

    static func waveform() async {
        print("\n— Hüllkurve —")

        // Spitzenwert je Eimer, nicht Mittelwert: der Mittelwert zöge kurze
        // laute Stellen glatt, und genau die will man sehen.
        var samples = [Int16](repeating: 0, count: 1000)
        samples[500] = 20000
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let peaks = WaveformSampler.reduce(data, into: 10)
        equal(peaks.count, 10, "zehn Eimer")
        check(peaks[5] > 0.5, "der laute Ausschlag bleibt sichtbar")
        check(peaks[0] == 0, "stille Eimer bleiben still")
        equal(WaveformSampler.reduce(Data(), into: 10).count, 0, "leere Daten ergeben nichts")

        // Normiert wird auf den lautesten Punkt der **ganzen Datei**, auch in
        // einer Lupe. Normierte jede Lupe auf sich selbst, sähe ein leises
        // Ausklingen so laut aus wie der Refrain.
        let quiet = WaveformSampler.Waveform(peaks: [0.02, 0.10, 0.05, 0.00], duration: 4)
        let whole = quiet.envelope(from: 0, to: 4, columns: 4)
        close(Double(whole[1]), 1.0, 0.001, "der lauteste Punkt füllt die Höhe")
        close(Double(whole[0]), 0.2, 0.001, "die übrigen im Verhältnis dazu")
        close(Double(whole[3]), 0, 0.001, "Stille bleibt Stille")
        let lens = quiet.envelope(from: 0, to: 1, columns: 1)
        close(Double(lens[0]), 0.2, 0.001, "auch im Ausschnitt bezogen auf die ganze Datei")

        let silent = WaveformSampler.Waveform(peaks: [0, 0, 0], duration: 3)
        check(silent.envelope(from: 0, to: 3, columns: 3).allSatisfy { $0 == 0 },
              "eine stille Datei ergibt keine Division durch null")

        // Mehr Spalten als Werte: jede Spalte bekommt trotzdem ihren Wert.
        let fine = quiet.envelope(from: 1, to: 2, columns: 8)
        equal(fine.count, 8, "eine Lupe darf feiner auflösen als die Werte")
        check(fine.allSatisfy { abs($0 - 1.0) < 0.001 }, "und zeigt dabei den richtigen Wert")

        // Und an einer echten Datei.
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
            check(false, "Hüllkurve einer echten Datei"); return
        }
        // Feste Auflösung: hundert Werte je Sekunde, also 10 ms je Wert.
        close(Double(shape.peaks.count), 1600, 30, "hundert Werte je Sekunde")
        let view = shape.envelope(from: 0, to: 16, columns: 16)
        check(view[1] > 0.7, "die erste Hälfte ist laut")
        check(view[8] < 0.1, "die Stille dazwischen ist erkennbar",
              detail: String(format: "%.3f", view[8]))
        check(view[13] > 0.7, "danach wird es wieder laut")

        // Die Lupe trifft die Stille auf eine Zehntelsekunde genau — dafür
        // ist die feine Auflösung da.
        let edge = shape.envelope(from: 5.5, to: 6.5, columns: 10)
        check(edge[0] > 0.5, "0,5 s vor der Stille ist es laut")
        check(edge[9] < 0.1, "0,5 s danach still")
    }

    // MARK: - Durchstich mit einem Album-Video

    /// Ein heruntergeladenes „ganzes Album" ist oft ein Video. Geprüft wird,
    /// dass die Tonspur **unverändert** herauskommt — nicht neu kodiert.
    static func videoEndToEnd(ffmpeg: FFmpegTool, folder: URL) async throws {
        print("\n— Album als Video —")
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
            check(false, "Album-Video gebaut", detail: build.standardError.prefix(120).description)
            return
        }

        let info = try await AudioSplitter.probe(file: video, ffmpeg: ffmpeg)
        check(info.hasVideo, "Bildspur erkannt")
        equal(info.audioCodec, "aac", "Tonspur ist AAC")
        equal(info.outputExtension, "m4a", "Stücke werden m4a, nicht mp4")
        close(info.duration, 27, 0.3, "Dauer erkannt")

        let analysis = try await AudioSplitter.analyze(
            file: video, thresholdDB: -30, minDuration: 0.5, ffmpeg: ffmpeg)
        let ranges = AudioSplitter.trackRanges(
            duration: analysis.duration, silences: analysis.silences, minimumLength: 10)
        equal(ranges.count, 2, "zwei Tracks im Video gefunden")

        let piece = folder.appendingPathComponent("aus-video.m4a")
        try await AudioSplitter.cut(source: video, range: ranges[0], to: piece,
                                    audioOnly: true, ffmpeg: ffmpeg)

        // Im Ergebnis darf kein Bild mehr stecken.
        let probe = try await ProcessRunner.run(ffmpeg.url, arguments: [
            "-hide_banner", "-i", piece.path(percentEncoded: false), "-f", "null", "-",
        ])
        check(!probe.standardError.contains("Video:"), "im Stück steckt kein Bild mehr")
        equal(AudioSplitter.parseAudioCodec(probe.standardError), "aac",
              "und der Ton ist unverändert AAC")

        // Der eigentliche Beweis: die ganze Tonspur herausgezogen muss mit der
        // im Video bitgleich sein.
        let whole = folder.appendingPathComponent("ganz.m4a")
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
              "herausgezogene Tonspur ist bitgleich mit der im Video")

        // Und derselbe Schnitt mit Umwandlung: aus AAC wird MP3.
        let asMP3 = folder.appendingPathComponent("umgewandelt.mp3")
        try await AudioSplitter.cut(source: video, range: ranges[0], to: asMP3,
                                    audioOnly: true, output: .convert(.mp3),
                                    bitrate: 192, ffmpeg: ffmpeg)
        let mp3Probe = try await ProcessRunner.run(ffmpeg.url, arguments: [
            "-hide_banner", "-i", asMP3.path(percentEncoded: false), "-f", "null", "-",
        ])
        equal(AudioSplitter.parseAudioCodec(mp3Probe.standardError), "mp3",
              "umgewandeltes Stück ist MP3")
        close(AudioSplitter.parseDuration(mp3Probe.standardError) ?? 0,
              ranges[0].duration, 0.35, "und hat die richtige Länge")
    }

    // MARK: - Durchstich

    static func endToEnd() async throws {
        print("\n— Durchstich mit einer gebauten Datei —")
        guard let ffmpeg = await FFmpegLocator().locate() else {
            print("  … übersprungen, kein ffmpeg")
            return
        }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("sleeve-split-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // Drei Töne zu 12 s, dazwischen 3 s Stille. Gesamt 42 s.
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
            check(false, "Testdatei gebaut", detail: build.standardError.prefix(120).description)
            return
        }
        check(true, "Testdatei gebaut: drei Töne zu 12 s, dazwischen 3 s Stille")

        let analysis = try await AudioSplitter.analyze(
            file: source, thresholdDB: -30, minDuration: 0.5, ffmpeg: ffmpeg)
        close(analysis.duration, 42, 0.2, "Dauer erkannt")
        equal(analysis.silences.count, 2, "zwei Stillen gefunden")

        let ranges = AudioSplitter.trackRanges(
            duration: analysis.duration, silences: analysis.silences, minimumLength: 10)
        equal(ranges.count, 3, "drei Tracks")
        close(ranges[0].start, 0, 0.2, "Track 1 beginnt bei 0 s")
        // Die Pause gehört zum Ende des vorigen Tracks — nichts wird verworfen.
        close(ranges[0].end, 15, 0.3, "Track 1 endet, wo Ton 2 einsetzt")
        close(ranges[1].start, 15, 0.3, "Track 2 beginnt bei 15 s")
        close(ranges[1].end, 30, 0.3, "Track 2 endet, wo Ton 3 einsetzt")
        close(ranges[2].start, 30, 0.3, "Track 3 beginnt bei 30 s")
        close(ranges[2].end, 42, 0.2, "Track 3 endet am Dateiende")

        // Und wirklich schneiden.
        for (index, range) in ranges.enumerated() {
            let target = folder.appendingPathComponent(String(format: "%02d.mp3", index + 1))
            try await AudioSplitter.cut(source: source, range: range,
                                        to: target, audioOnly: false, ffmpeg: ffmpeg)
            let exists = FileManager.default.fileExists(atPath: target.path(percentEncoded: false))
            check(exists, "Track \(index + 1) geschrieben")
            guard exists else { continue }

            // Die geschnittene Datei muss die erwartete Länge haben.
            let probe = try await ProcessRunner.run(ffmpeg.url, arguments: [
                "-hide_banner", "-i", target.path(percentEncoded: false),
                "-f", "null", "-",
            ])
            let cutDuration = AudioSplitter.parseDuration(probe.standardError) ?? 0
            close(cutDuration, range.duration, 0.35,
                  "Track \(index + 1) ist \(String(format: "%.1f", range.duration)) s lang")
        }

        try await videoEndToEnd(ffmpeg: ffmpeg, folder: folder)

        // Und die Tags: `-c copy` erbt sie von der Quelle, deshalb muss der
        // Titel nachträglich gesetzt werden.
        let first = folder.appendingPathComponent("01.mp3")
        var tags = AudioTags()
        tags.title = "Erster Ton"
        tags.trackNumber = 1
        try TagLibBridge.write(tags, fields: [.title, .trackNumber], to: first)
        let readBack = try TagLibBridge.read(from: first)
        equal(readBack.tags.title, "Erster Ton", "Titel steht im geschnittenen Stück")
        equal(readBack.tags.trackNumber, 1, "Tracknummer ebenso")
    }
}
