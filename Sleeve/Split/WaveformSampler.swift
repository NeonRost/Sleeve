//
//  WaveformSampler.swift
//  Sleeve
//
//  Die Hüllkurve einer Datei berechnen (Spec §7.7).
//
//  Berechnet wird einmal in fester, feiner Auflösung — hundert Werte je
//  Sekunde. Daraus schöpfen beide Ansichten: die Übersicht über die ganze
//  Datei fasst viele Werte je Bildpunkt zusammen, die Lupen auf eine Grenze
//  nur wenige. Eine feste *Anzahl* Werte (der erste Anlauf nahm 2000) taugte
//  nur für die Übersicht: bei 45 Minuten sind das 1,35 s je Wert, zu grob, um
//  einen Schnitt zu setzen.
//
//  Je Bildpunkt wird der **lauteste** Wert gezeichnet, nicht der Mittelwert —
//  der zöge kurze laute Stellen glatt, und genau die will man sehen.
//

import Foundation

enum WaveformSampler {

    /// Proben je Sekunde beim Dekodieren. Gegen die volle Auflösung gemessen
    /// weicht die Hüllkurve bei 4000 Hz um 0,002 ab, bei 2000 Hz um 0,023.
    static let workingRate = 4000

    /// Werte je Sekunde in der fertigen Hüllkurve — 10 ms je Wert.
    static let peaksPerSecond = 100

    struct Waveform: Sendable, Identifiable {
        let id = UUID()
        /// Ein Spitzenwert je 1/`peaksPerSecond` Sekunde, 0…1 bezogen auf
        /// Vollaussteuerung.
        var peaks: [Float]
        var duration: Double
        /// Der lauteste Wert der ganzen Datei — Bezug für die Normierung.
        var loudest: Float

        init(peaks: [Float], duration: Double) {
            self.peaks = peaks
            self.duration = duration
            self.loudest = peaks.max() ?? 0
        }

        var isEmpty: Bool { peaks.isEmpty }

        /// Auf den lautesten Punkt der **ganzen Datei** bezogen, auch in einer
        /// Lupe. Würde jede Lupe auf sich selbst normieren, sähe ein leises
        /// Ausklingen genauso laut aus wie der Refrain — und man setzte die
        /// Grenze an die falsche Stelle.
        ///
        /// Ohne Normierung wiederum wird eine leise Aufnahme zur flachen
        /// Linie: ffmpegs eigener `sine`-Generator liefert nur −18 dBFS.
        func envelope(from start: Double, to end: Double, columns: Int) -> [Float] {
            guard columns > 0, end > start, !peaks.isEmpty else { return [] }
            let scale: Float = loudest > 0.0001 ? 1 / loudest : 0
            let rate = Double(peaks.count) / max(duration, 0.001)

            var result = [Float](repeating: 0, count: columns)
            let span = end - start
            for column in 0..<columns {
                let t0 = start + span * Double(column) / Double(columns)
                let t1 = start + span * Double(column + 1) / Double(columns)
                var from = Int((t0 * rate).rounded(.down))
                var to = Int((t1 * rate).rounded(.up))
                from = min(max(from, 0), peaks.count)
                to = min(max(to, from + 1), peaks.count)
                guard from < to else { continue }
                var value: Float = 0
                for index in from..<to where peaks[index] > value { value = peaks[index] }
                result[column] = min(1, value * scale)
            }
            return result
        }
    }

    /// Rechnet die Datei einmal durch.
    static func load(_ url: URL, duration: Double, ffmpeg: FFmpegTool) async throws -> Waveform {
        guard duration > 0 else { throw SplitError.analysisFailed }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("sleeve-wave-\(UUID().uuidString).raw")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let result = try await ProcessRunner.run(ffmpeg.url, arguments: [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            "-i", url.path(percentEncoded: false),
            // Kein Bild, ein Kanal, grob abgetastet — es geht um die Form,
            // nicht um den Klang.
            "-vn", "-ac", "1", "-ar", "\(workingRate)",
            "-f", "s16le", scratch.path(percentEncoded: false),
        ])
        guard result.succeeded else { throw SplitError.analysisFailed }

        let data = try Data(contentsOf: scratch, options: .mappedIfSafe)
        let samples = data.count / 2
        let buckets = max(1, samples * peaksPerSecond / workingRate)
        return Waveform(peaks: reduce(data, into: buckets), duration: duration)
    }

    /// Fasst rohe 16-Bit-Proben zu Spitzenwerten zusammen.
    static func reduce(_ data: Data, into buckets: Int) -> [Float] {
        let sampleCount = data.count / 2
        guard sampleCount > 0, buckets > 0 else { return [] }

        var peaks = [Float](repeating: 0, count: buckets)
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for bucket in 0..<buckets {
                let start = sampleCount * bucket / buckets
                let end = max(start + 1, sampleCount * (bucket + 1) / buckets)
                var loudest: Int32 = 0
                var index = start
                while index < end, index < sampleCount {
                    let value = Int32(samples[index].magnitude)
                    if value > loudest { loudest = value }
                    index += 1
                }
                peaks[bucket] = Float(loudest) / Float(Int16.max)
            }
        }
        return peaks
    }
}
