//
//  DiscTOC.swift
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
//  The disc's table of contents and everything that follows from it alone:
//  track lengths, MusicBrainz disc ID, FreeDB ID, cue sheet.
//
//  Pure computation without device access — hence fully testable without a
//  disc in the drive.
//

import CryptoKit
import Foundation

/// A sector of an audio CD holds 588 stereo samples of 4 bytes each.
enum CDGeometry {
    static let bytesPerSector = 2352
    static let samplesPerSector = 588
    static let bytesPerSample = 4
    static let sectorsPerSecond = 75
    /// CDs count from 00:02:00, not from zero. The offset of 150 sectors is
    /// part of every address conversion.
    static let leadInSectors = 150
}

struct DiscTrack: Equatable, Sendable, Identifiable {
    var number: Int
    /// Start sector, counted from track 1 = 0 (i.e. without the 150 lead-in
    /// sectors).
    var startLBA: Int
    var sectorCount: Int
    var isData: Bool
    /// Read from the subchannel, if present.
    var isrc: String?

    var id: Int { number }
    var endLBA: Int { startLBA + sectorCount }
    var duration: Duration {
        .seconds(Double(sectorCount) / Double(CDGeometry.sectorsPerSecond))
    }
    var byteCount: Int { sectorCount * CDGeometry.bytesPerSector }
}

struct DiscTOC: Equatable, Sendable {
    var firstTrack: Int
    var lastTrack: Int
    /// Start sector of the lead-out, i.e. the end of the last track.
    var leadOutLBA: Int
    var tracks: [DiscTrack]
    var mcn: String?

    var audioTracks: [DiscTrack] { tracks.filter { !$0.isData } }
    var hasDataTrack: Bool { tracks.contains(where: \.isData) }

    var totalDuration: Duration {
        .seconds(Double(leadOutLBA) / Double(CDGeometry.sectorsPerSecond))
    }

    // MARK: - Parsing the raw TOC from IOKit

    /// Parses the `TOC` property of an `IOCDMedia` object. That is a `CDTOC`:
    /// four bytes of header, then 11-byte descriptors.
    ///
    /// Of interest are the special points 0xA0 (first track), 0xA1 (last) and
    /// 0xA2 (lead-out), plus points 1…99 for the tracks themselves.
    init?(rawTOC data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }

        // The length field counts from behind itself.
        let declared = (Int(bytes[0]) << 8 | Int(bytes[1])) + 2
        let limit = min(declared, bytes.count)

        var first = 0, last = 0, leadOut = -1
        var starts: [Int: (lba: Int, isData: Bool)] = [:]

        var i = 4
        while i + 11 <= limit {
            let d = Array(bytes[i..<(i + 11)])
            i += 11

            let control = d[1] & 0x0F
            let point = d[3]
            // The P address is stored as minute/second/frame in the last
            // three bytes of the descriptor.
            let pLBA = (Int(d[8]) * 60 + Int(d[9])) * CDGeometry.sectorsPerSecond
                + Int(d[10]) - CDGeometry.leadInSectors

            switch point {
            case 0xA0: first = Int(d[8])
            case 0xA1: last = Int(d[8])
            case 0xA2: leadOut = pLBA
            case 1...99:
                // Bit 2 of the control nibble tells data from audio.
                starts[Int(point)] = (pLBA, control & 0x04 != 0)
            default: break
            }
        }

        guard first > 0, last >= first, leadOut > 0, !starts.isEmpty else { return nil }

        // A track's length only follows from the start of the next one.
        var built: [DiscTrack] = []
        for number in first...last {
            guard let entry = starts[number] else { continue }
            let next = starts[number + 1]?.lba ?? leadOut
            built.append(DiscTrack(number: number,
                                   startLBA: entry.lba,
                                   sectorCount: max(0, next - entry.lba),
                                   isData: entry.isData))
        }
        guard !built.isEmpty else { return nil }

        self.firstTrack = first
        self.lastTrack = last
        self.leadOutLBA = leadOut
        self.tracks = built
        self.mcn = nil
    }

    /// Direct route for tests.
    init(firstTrack: Int, lastTrack: Int, leadOutLBA: Int,
         tracks: [DiscTrack], mcn: String? = nil) {
        self.firstTrack = firstTrack
        self.lastTrack = lastTrack
        self.leadOutLBA = leadOutLBA
        self.tracks = tracks
        self.mcn = mcn
    }

    // MARK: - Identifiers

    /// MusicBrainz disc ID: SHA-1 over first and last track number, the
    /// lead-out and 99 track offsets, all as uppercase hex. The result is
    /// Base64-encoded, with `+/=` replaced by `._-` so that the identifier
    /// fits into a URL.
    ///
    /// Checked against the worked example in the MusicBrainz documentation.
    var musicBrainzDiscID: String {
        var input = String(format: "%02X%02X", firstTrack, lastTrack)
        input += String(format: "%08X", leadOutLBA + CDGeometry.leadInSectors)

        var offsets = [Int](repeating: 0, count: 100)
        for track in tracks where (1...99).contains(track.number) {
            offsets[track.number] = track.startLBA + CDGeometry.leadInSectors
        }
        for number in 1...99 {
            input += String(format: "%08X", number <= lastTrack ? offsets[number] : 0)
        }

        let digest = Data(Insecure.SHA1.hash(data: Data(input.utf8)))
        return digest.base64EncodedString()
            .replacingOccurrences(of: "+", with: ".")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "-")
    }

    /// The old FreeDB identifier. MusicBrainz accepts it as a second way to
    /// search, and XLD lists it in its log.
    var freeDBID: String {
        var checksum = 0
        for track in tracks {
            var seconds = (track.startLBA + CDGeometry.leadInSectors) / CDGeometry.sectorsPerSecond
            while seconds > 0 {
                checksum += seconds % 10
                seconds /= 10
            }
        }
        let firstStart = tracks.first?.startLBA ?? 0
        let total = (leadOutLBA + CDGeometry.leadInSectors) / CDGeometry.sectorsPerSecond
            - (firstStart + CDGeometry.leadInSectors) / CDGeometry.sectorsPerSecond
        let value = (UInt32(checksum % 255) << 24) | (UInt32(total) << 8) | UInt32(lastTrack & 0xFF)
        return String(format: "%08x", value)
    }

    /// For the MusicBrainz search when the disc ID is not registered:
    /// `first last leadout offset1 offset2 …`
    var musicBrainzTOCParameter: String {
        var parts = [String(firstTrack), String(lastTrack),
                     String(leadOutLBA + CDGeometry.leadInSectors)]
        parts += tracks.map { String($0.startLBA + CDGeometry.leadInSectors) }
        return parts.joined(separator: "+")
    }
}
