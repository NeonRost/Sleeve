//
//  CDText.swift
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
//  CD-TEXT lives on the disc itself. For albums that are in no database it
//  is often the only source — and it costs no network and no waiting.
//
//  Layout: packs of 18 bytes. Four bytes of header (type, track number,
//  sequence number, block info), twelve bytes of text, two bytes of CRC. A
//  text field runs across any number of packs and ends with a null byte;
//  the packs of one type together form a chain of fields in which entry 0
//  belongs to the album and 1…n to the tracks.
//

import Foundation

struct CDText: Equatable, Sendable {
    /// Index 0 is the album, 1…n are the tracks.
    var titles: [Int: String] = [:]
    var performers: [Int: String] = [:]
    var songwriters: [Int: String] = [:]
    var composers: [Int: String] = [:]
    var arrangers: [Int: String] = [:]

    var albumTitle: String? { titles[0] }
    var albumArtist: String? { performers[0] }
    var albumComposer: String? { composers[0] }

    var isEmpty: Bool {
        titles.isEmpty && performers.isEmpty && songwriters.isEmpty
            && composers.isEmpty && arrangers.isEmpty
    }

    func title(forTrack number: Int) -> String? { titles[number] }
    func performer(forTrack number: Int) -> String? { performers[number] ?? performers[0] }
    func composer(forTrack number: Int) -> String? { composers[number] ?? composers[0] }

    // MARK: - Parsing

    private enum PackType: UInt8 {
        case title = 0x80, performer = 0x81, songwriter = 0x82
        case composer = 0x83, arranger = 0x84
        case sizeInfo = 0x8F
    }

    /// `payload` is the body of the TOC response in format 5, i.e. without the
    /// four-byte header.
    init(packets payload: [UInt8]) {
        // The character set is in the size info pack. 0x00 is Latin-1, 0x80
        // is MS-JIS. Without it, Latin-1 applies — read as UTF-8, umlauts
        // fall apart into replacement characters, which is exactly what
        // happened on the first attempt.
        var encoding = String.Encoding.isoLatin1
        var index = 0
        while index + 18 <= payload.count {
            if payload[index] == PackType.sizeInfo.rawValue, payload[index + 2] == 0 {
                if payload[index + 4] == 0x80 { encoding = .shiftJIS }
                break
            }
            index += 18
        }

        // First concatenate all text bytes per type, then split at the null
        // bytes — a field may run across pack boundaries.
        var streams: [UInt8: [UInt8]] = [:]
        var startTrack: [UInt8: Int] = [:]
        index = 0
        while index + 18 <= payload.count {
            let type = payload[index]
            let track = Int(payload[index + 1] & 0x7F)
            if PackType(rawValue: type) != nil, type != PackType.sizeInfo.rawValue {
                if streams[type] == nil { startTrack[type] = track }
                streams[type, default: []].append(contentsOf: payload[(index + 4)..<(index + 16)])
            }
            index += 18
        }

        for (type, bytes) in streams {
            var fields = bytes.split(separator: 0, omittingEmptySubsequences: false)
            // After the last null byte there is only padding.
            if !fields.isEmpty { fields.removeLast() }

            var entries: [Int: String] = [:]
            let base = startTrack[type] ?? 0
            for (position, field) in fields.enumerated() {
                guard !field.isEmpty,
                      let text = String(bytes: field, encoding: encoding)?
                          .trimmingCharacters(in: .whitespaces),
                      !text.isEmpty
                else { continue }
                entries[base + position] = text
            }

            switch PackType(rawValue: type) {
            case .title:      titles = entries
            case .performer:  performers = entries
            case .songwriter: songwriters = entries
            case .composer:   composers = entries
            case .arranger:   arrangers = entries
            default: break
            }
        }
    }

    init() {}
}
