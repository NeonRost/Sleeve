//
//  WAVWriter.swift
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
//  Ripped tracks land as WAV first. From there the existing converter
//  pipeline takes over (spec §5) — the ripper needs to know no codecs.
//
//  CDDA is 16 bit, 44100 Hz, stereo, little-endian. That is exactly what a
//  canonical 44-byte WAV header describes, without any special handling.
//

import Foundation

enum WAVWriter {
    static let sampleRate = 44100
    static let channels = 2
    static let bitsPerSample = 16

    static func header(forPCMByteCount byteCount: Int) -> Data {
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8

        var data = Data(capacity: 44)
        func ascii(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func u32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { data.append(contentsOf: $0) } }

        ascii("RIFF")
        u32(36 + byteCount)
        ascii("WAVE")
        ascii("fmt ")
        u32(16)              // Length of the format chunk
        u16(1)               // 1 = uncompressed PCM
        u16(channels)
        u32(sampleRate)
        u32(byteRate)
        u16(blockAlign)
        u16(bitsPerSample)
        ascii("data")
        u32(byteCount)
        return data
    }

    /// Writes the file in one go. A CD track is rarely larger than 100 MB,
    /// which does not justify writing it piecewise.
    static func write(pcm: Data, to url: URL) throws {
        var file = header(forPCMByteCount: pcm.count)
        file.append(pcm)
        try file.write(to: url, options: .atomic)
    }
}

/// Where the samples of a WAV file lie, and whether they are CD audio.
///
/// Sleeve's own WAVs have the canonical 44-byte header. Other programs do
/// not: ffmpeg puts a `LIST` chunk in front of the samples — 78 bytes
/// without tags, 140 with, measured. A burn that assumes 44 writes the
/// surplus as noise and, when it is not a multiple of four, swaps or
/// garbles the channels. So the chunks are walked.
enum WAVProbe {
    struct Location: Equatable, Sendable {
        var offset: Int
        var byteCount: Int
    }

    enum Problem: Error, Equatable {
        /// No RIFF/WAVE structure, or one without samples.
        case notWAV
        /// A WAV, but not 44.1 kHz, 16 bit, stereo PCM.
        case notCDAudio
    }

    static func locate(_ url: URL) throws -> Location {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw Problem.notWAV }
        defer { try? handle.close() }
        let fileSize = Int((try? handle.seekToEnd()) ?? 0)

        func read(_ count: Int, at offset: Int) -> Data? {
            guard offset + count <= fileSize, (try? handle.seek(toOffset: UInt64(offset))) != nil,
                  let data = try? handle.read(upToCount: count), data.count == count
            else { return nil }
            return data
        }
        func u16(_ data: Data, _ at: Int) -> Int {
            Int(data[data.startIndex + at]) | Int(data[data.startIndex + at + 1]) << 8
        }
        func u32(_ data: Data, _ at: Int) -> Int {
            u16(data, at) | u16(data, at + 2) << 16
        }

        guard let riff = read(12, at: 0),
              riff.prefix(4) == Data("RIFF".utf8), riff.suffix(4) == Data("WAVE".utf8)
        else { throw Problem.notWAV }

        var position = 12
        var isCDAudio: Bool?
        // A sane file has a handful of chunks; the limit only stops a
        // damaged one from being walked forever.
        for _ in 0..<4096 {
            guard let head = read(8, at: position) else { break }
            let id = String(decoding: head.prefix(4), as: UTF8.self)
            let size = u32(head, 4)
            let body = position + 8

            if id == "fmt " {
                guard let format = read(min(size, 40), at: body), format.count >= 16 else {
                    throw Problem.notWAV
                }
                var tag = u16(format, 0)
                // WAVE_FORMAT_EXTENSIBLE carries the real format further back.
                if tag == 0xFFFE, format.count >= 26 { tag = u16(format, 24) }
                isCDAudio = tag == 1
                    && u16(format, 2) == WAVWriter.channels
                    && u32(format, 4) == WAVWriter.sampleRate
                    && u16(format, 14) == WAVWriter.bitsPerSample
            } else if id == "data" {
                guard let isCDAudio else { throw Problem.notWAV }
                guard isCDAudio else { throw Problem.notCDAudio }
                // Written to a pipe, the length is 0 or all ones — then the
                // samples run to the end of the file.
                let rest = fileSize - body
                let count = (size == 0 || size > rest) ? rest : size
                guard count > 0 else { throw Problem.notWAV }
                return Location(offset: body, byteCount: count)
            }
            position = body + size + (size & 1)
        }
        throw Problem.notWAV
    }
}
