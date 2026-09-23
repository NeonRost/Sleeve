//
//  WaveformSampler.swift
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
//  Computes the envelope of a file (spec §7.7).
//
//  It is computed once, at a fixed fine resolution — a hundred values per
//  second. Both views draw from it: the overview of the whole file combines
//  many values per pixel, the magnifiers on a boundary only a few. A fixed
//  *number* of values (the first attempt used 2000) only worked for the
//  overview: at 45 minutes that is 1.35 s per value, too coarse to place a
//  cut.
//
//  Each pixel shows the **loudest** value, not the mean — the mean would
//  smooth out short loud spots, and those are exactly what one wants to see.
//

import Foundation

enum WaveformSampler {

    /// Samples per second while decoding. Measured against full resolution,
    /// the envelope deviates by 0.002 at 4000 Hz and by 0.023 at 2000 Hz.
    static let workingRate = 4000

    /// Values per second in the finished envelope — 10 ms per value.
    static let peaksPerSecond = 100

    struct Waveform: Sendable, Identifiable {
        let id = UUID()
        /// One peak value per 1/`peaksPerSecond` second, 0…1 relative to full
        /// scale.
        var peaks: [Float]
        var duration: Double
        /// The loudest value of the whole file — the reference for normalization.
        var loudest: Float

        init(peaks: [Float], duration: Double) {
            self.peaks = peaks
            self.duration = duration
            self.loudest = peaks.max() ?? 0
        }

        var isEmpty: Bool { peaks.isEmpty }

        /// Relative to the loudest point of the **whole file**, even in a
        /// magnifier. If every magnifier normalized to itself, a quiet fade-out
        /// would look as loud as the chorus — and one would put the boundary in
        /// the wrong place.
        ///
        /// Without normalization, on the other hand, a quiet recording becomes a
        /// flat line: ffmpeg's own `sine` generator only delivers −18 dBFS.
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

    /// Runs through the file once.
    static func load(_ url: URL, duration: Double, ffmpeg: FFmpegTool) async throws -> Waveform {
        guard duration > 0 else { throw SplitError.analysisFailed }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("sleeve-wave-\(UUID().uuidString).raw")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let result = try await ProcessRunner.run(ffmpeg.url, arguments: [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            "-i", url.path(percentEncoded: false),
            // No picture, one channel, coarsely sampled — this is about the
            // shape, not the sound.
            "-vn", "-ac", "1", "-ar", "\(workingRate)",
            "-f", "s16le", scratch.path(percentEncoded: false),
        ])
        guard result.succeeded else { throw SplitError.analysisFailed }

        let data = try Data(contentsOf: scratch, options: .mappedIfSafe)
        let samples = data.count / 2
        let buckets = max(1, samples * peaksPerSecond / workingRate)
        return Waveform(peaks: reduce(data, into: buckets), duration: duration)
    }

    /// Combines raw 16-bit samples into peak values.
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
