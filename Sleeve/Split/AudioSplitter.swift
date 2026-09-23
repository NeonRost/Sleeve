//
//  AudioSplitter.swift
//  Sleeve
//
//  Eine lange Aufnahme in einzelne Tracks zerlegen (Spec §7).
//
//  Der Kern heißt bewusst „schneide diese Datei an dieser Liste von
//  Positionen" und nicht „finde Stille". Woher die Grenzen kommen, ist
//  austauschbar: heute aus der Stille zwischen den Stücken, später aus einem
//  Cue Sheet (§9.1). Sonst stünde das Cue-Einlesen irgendwann als zweites
//  Werkzeug daneben statt als weitere Quelle davor.
//
//  Die Stille-Erkennung und der Randpuffer stammen aus dem Track Splitter in
//  NeonRosts Werkzeugkoffer und sind dort über längere Zeit erprobt worden.
//

import Foundation

struct SilenceInterval: Equatable, Sendable {
    var start: Double
    var end: Double
}

struct SilenceAnalysis: Sendable {
    var duration: Double
    /// Alles, was ffmpeg gemeldet hat, samt Randartefakten. Was davon
    /// tatsächlich geschnitten wird, entscheidet `trackRanges`.
    var silences: [SilenceInterval]
}

struct TrackRange: Identifiable, Equatable, Sendable {
    var id = UUID()
    var start: Double
    var end: Double

    var duration: Double { max(0, end - start) }
}

/// Was aus den Stücken werden soll.
///
/// `keepSource` schneidet nur (`-c copy`) und lässt die Tonspur unangetastet.
/// Alles andere **kodiert neu** — bei einer verlustbehafteten Quelle heißt das
/// ein zweites Mal verlustbehaftet. Das ist manchmal gewollt (eine MP3 für den
/// Autoradio-Stick), aber nie gratis, und die Oberfläche sagt es deshalb.
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

    /// Ein heruntergeladenes Album ist oft ein Video — YouTube liefert Bild
    /// und Ton zusammen, und wer „ganzes Album" sucht, bekommt genau das.
    /// Die Tonspur lässt sich verlustfrei herausziehen, also gibt es keinen
    /// Grund, solche Dateien abzuweisen.
    static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "webm", "avi", "flv", "wmv", "ts", "mpg", "mpeg",
    ]

    static var acceptedExtensions: Set<String> { audioExtensions.union(videoExtensions) }

    /// Stille in den ersten oder letzten zwei Sekunden gilt als übliche
    /// Leerlaufzeit einer Plattenseite oder Kassette, nicht als Trackgrenze.
    /// Fester Wert, kein Regler: die beiden, auf die es ankommt — Schwelle und
    /// Mindestdauer — sind genug Knöpfe für einen Bildschirm.
    static let edgeBuffer: Double = 2.0

    /// Voreinstellung für die kürzeste Länge, die ein Track haben darf.
    ///
    /// Ohne diese Schranke entstehen aus Applaus, Übergängen und Ansagen
    /// Bruchstücke von Sekundenbruchteilen. An einem echten Mitschnitt
    /// gemessen: von 22 gefundenen Abschnitten waren **neun kürzer als vier
    /// Sekunden**, vier davon unter einer halben, einer exakt null Sekunden
    /// lang — ein Schnitt der Länge null ergibt eine unbrauchbare Datei.
    static let defaultMinimumTrackLength: Double = 10.0

    // MARK: - Was ist das für eine Datei?

    struct SourceInfo: Equatable, Sendable {
        var duration: Double
        /// Der Codec der Tonspur, wie ffmpeg ihn nennt — `aac`, `mp3`, …
        var audioCodec: String
        var hasVideo: Bool

        /// Die Endung, die das geschnittene Stück bekommt.
        ///
        /// Aus einem Video wird nie wieder ein Video: gefragt ist die Musik.
        /// Der Behälter richtet sich nach dem Tonformat, damit nichts neu
        /// kodiert werden muss.
        var outputExtension: String {
            switch audioCodec {
            case "aac", "alac":            "m4a"
            case "mp3":                    "mp3"
            case "flac":                   "flac"
            case "opus":                   "opus"
            case "vorbis":                 "ogg"
            case "ac3":                    "ac3"
            case let codec where codec.hasPrefix("pcm_"): "wav"
            // Unbekanntes in einen Behälter zu zwingen, der es nicht nimmt,
            // scheitert erst beim Schneiden. m4a nimmt am meisten.
            default:                       "m4a"
            }
        }
    }

    /// Fragt ffmpeg, was in der Datei steckt. Liefert zugleich die Dauer, die
    /// sonst ein zweiter Aufruf kosten würde.
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

    /// `Stream #0:1[0x2](und): Audio: aac (LC) …` — der Name hinter „Audio:".
    static func parseAudioCodec(_ text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            guard line.contains("Stream #"), let range = line.range(of: "Audio: ") else { continue }
            let rest = line[range.upperBound...]
            let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if !name.isEmpty { return String(name).lowercased() }
        }
        return nil
    }

    // MARK: - Untersuchen

    /// Lässt ffmpeg die Stille suchen und liest Dauer und Fundstellen aus.
    static func analyze(file: URL,
                        thresholdDB: Double,
                        minDuration: Double,
                        ffmpeg: FFmpegTool) async throws -> SilenceAnalysis {
        let result: ProcessRunner.Result
        do {
            result = try await ProcessRunner.run(ffmpeg.url, arguments: [
                "-hide_banner",
                "-i", file.path(percentEncoded: false),
                // Kein Bild dekodieren — bei einem Album-Video spart das den
                // Löwenanteil der Zeit, und gesucht wird ohnehin im Ton.
                "-vn",
                "-af", "silencedetect=noise=\(thresholdDB)dB:d=\(minDuration)",
                "-f", "null", "-",
            ])
        } catch {
            throw SplitError.analysisFailed
        }

        // ffmpeg schreibt Banner *und* Filterausgabe nach stderr.
        let text = result.standardError
        guard let duration = parseDuration(text) else { throw SplitError.analysisFailed }
        return SilenceAnalysis(duration: duration, silences: parseSilences(text))
    }

    /// `Duration: 00:52:29.57, …` aus ffmpegs Kopfzeilen.
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

    /// Paart `silence_start:` mit `silence_end:`.
    ///
    /// Die Werte kommen manchmal ohne Nachkommastelle (`silence_start: 0`),
    /// deshalb ist der Nachkommateil im Muster optional. Und sie können
    /// negativ sein — ffmpeg meldet gelegentlich `-0.00478...`.
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

    // MARK: - Grenzen

    /// Stillen, die weniger als das auseinanderliegen, gelten als eine — was
    /// dazwischen klingt, ist ein Knacken oder ein Atmer in der Pause.
    static let noiseLength: Double = 1.0

    /// Unterhalb davon gilt ein Wert beim Suchen der tiefsten Stille als
    /// Boden, auch wenn die Datei nirgends ganz still ist (−60 dBFS).
    static let floorLevel: Float = 0.001

    /// Ein möglicher Schnitt: wo, und wie überzeugend. Je länger die Stille,
    /// desto wahrscheinlicher liegt dort wirklich eine Trackgrenze.
    struct Cut: Equatable, Sendable {
        var position: Double
        var strength: Double
    }

    /// Macht aus gefundener Stille lückenlos aneinanderliegende Tracks.
    ///
    /// **Nichts wird verworfen.** Der erste Anlauf ließ die Pausen zwischen den
    /// Tracks weg — und mit ihnen alles, was leiser als die Schwelle war. Am
    /// echten Album gemessen: 66 s in keiner Datei, darunter das leise Intro
    /// von „Slider" (−35 bis −49 dB, sechs Sekunden). Jetzt gehört eine Pause
    /// zum Ende des vorigen Tracks, wie bei CD-Rippern üblich.
    ///
    /// `levels` ist die Hüllkurve der Datei. Mit ihr wird am Ende der
    /// **tiefsten** Stille geschnitten statt am Ende der Schwellen-Stille — das
    /// ist der Unterschied zwischen einem Intro, das zum richtigen Track gehört,
    /// und einem, das der vorige bekommt. Ohne Hüllkurve wird am Ende der
    /// Stille geschnitten.
    static func trackRanges(duration: Double,
                            silences: [SilenceInterval],
                            minimumLength: Double = defaultMinimumTrackLength,
                            levels: WaveformSampler.Waveform? = nil) -> [TrackRange] {
        let regions = bridge(silences.sorted { $0.start < $1.start }, within: noiseLength)
            // Stille ganz am Anfang oder Ende ist Leerlauf, keine Grenze.
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

    /// Fasst Stillen zusammen, zwischen denen nur ein kurzes Geräusch liegt.
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

    /// Wo in einer Stille geschnitten wird: am Ende ihres **tiefsten**
    /// Abschnitts.
    ///
    /// Die Schwelle allein reicht nicht. Ein leises Intro liegt unter ihr und
    /// gehört trotzdem zum nächsten Stück; ein Ausklang ebenso zum vorigen.
    /// Der tiefste Abschnitt — oft digitale Null — ist die eigentliche Fuge.
    /// Gibt es mehrere, zählt der längste.
    static func cutPosition(in region: SilenceInterval, levels: WaveformSampler.Waveform?) -> Double {
        guard let levels, !levels.peaks.isEmpty, levels.duration > 0 else { return region.end }
        let rate = Double(levels.peaks.count) / levels.duration
        let from = max(0, Int((region.start * rate).rounded(.down)))
        let to = min(levels.peaks.count, Int((region.end * rate).rounded(.up)))
        guard from < to else { return region.end }

        let window = levels.peaks[from..<to]
        let quietest = window.min() ?? 0
        let floor = max(quietest * 2, floorLevel)   // etwa +6 dB über dem Tiefsten

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

    /// Dünnt die Schnitte aus, bis kein Track kürzer ist als die Mindestlänge.
    ///
    /// Liegen zwischen zwei langen Tracks mehrere zu kurze Stücke, bleibt von
    /// den Schnitten dort **genau einer**: der an der längsten Stille. Was
    /// davor liegt, gehört zum vorigen Track, was danach liegt, zum nächsten.
    ///
    /// So landet Applaus direkt nach einem Live-Stück beim Stück — die lange
    /// Pause kommt erst danach — und ein zerklüftetes Intro nach einer langen
    /// Pause beim nächsten Stück. Die erste Fassung hängte alles an den
    /// Vorgänger; am echten Album gehörte so das Intro von „LUV" plötzlich zum
    /// Track davor, 15 s daneben.
    static func thin(_ cuts: [Cut], duration: Double, minimumLength: Double) -> [Cut] {
        guard minimumLength > 0, !cuts.isEmpty else { return cuts }

        // Stücke i = 0…n; Schnitt j trennt Stück j−1 von Stück j (j = 1…n).
        let bounds = [0.0] + cuts.map(\.position) + [duration]
        let pieceCount = cuts.count + 1
        let short = (0..<pieceCount).map { bounds[$0 + 1] - bounds[$0] < minimumLength }
        var keep = [Bool](repeating: true, count: cuts.count + 1)   // Index 1…n

        var piece = 0
        while piece < pieceCount {
            guard short[piece] else { piece += 1; continue }
            var last = piece
            while last + 1 < pieceCount, short[last + 1] { last += 1 }

            let candidates = (piece...(last + 1)).filter { $0 >= 1 && $0 <= cuts.count }
            if piece == 0 && last == pieceCount - 1 {
                candidates.forEach { keep[$0] = false }          // alles zu kurz
            } else if piece == 0 || last == pieceCount - 1 {
                candidates.forEach { keep[$0] = false }          // nur ein Nachbar
            } else {
                // Bei Gleichstand der spätere — kurze Stücke bleiben dann beim
                // Vorgänger.
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

    // MARK: - Schneiden

    /// Schneidet einen Abschnitt heraus, ohne neu zu kodieren.
    ///
    /// `-ss`/`-to` vor `-c copy` landet bei komprimierten Formaten auf der
    /// nächsten Frame-Grenze statt auf dem Sample genau — an einer echten MP3
    /// gemessen im Bereich einiger Millisekunden, nicht hörbar. Das ist so und
    /// kein Fehler, dem man nachjagen sollte.
    /// Steckt ein Bild in der Quelle, wandert nur die Tonspur mit
    /// (`-map 0:a:0`). Nachgemessen: die so herausgezogene Spur ist mit der
    /// im Video **bitgleich** — es wird nichts neu kodiert.
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
            // Ein Coverbild ist ein Videostream; `-vn` wirft es mit heraus.
            // Getaggt wird hinterher über TagLib, wie überall in Sleeve.
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
            // Abgebrochen: die halbfertige Datei muss weg, anders als die
            // vorher fertig gewordenen.
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

// MARK: - Zeitangaben

/// `mm:ss.s` lesen und schreiben — für die Felder, in denen sich Grenzen von
/// Hand nachjustieren lassen.
enum Timecode {

    static func format(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let minutes = Int(total) / 60
        let rest = total - Double(minutes * 60)
        return String(format: "%02d:%04.1f", minutes, rest)
    }

    /// Ganze Sekunden, wie Tracklisten sie schreiben: „5:00", „1:02:03".
    /// Für Vergleiche mit einer Quelle — die Zehntel stehen dort in der
    /// Abweichung.
    static func short(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        let hours = total / 3600, minutes = total / 60 % 60, rest = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }

    /// Nimmt `mm:ss.s`, `h:mm:ss.s` und blanke Sekunden entgegen.
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
