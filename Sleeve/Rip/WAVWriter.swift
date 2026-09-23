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
