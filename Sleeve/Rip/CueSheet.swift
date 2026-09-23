//
//  CueSheet.swift
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
//  Reading a cue sheet — the opposite direction of `RipReport.cueSheet`.
//
//  Burning needs it: the image itself does not say where a track starts.
//  The same parsing will later carry opening an image into the track list
//  (spec §9.1) — which is why it stands on its own here and not inside the
//  burner.
//

import Foundation

struct CueSheet: Equatable, Sendable {

    struct Track: Equatable, Sendable, Identifiable {
        var number: Int
        /// Start sector from the beginning of the file, from `INDEX 01`.
        var startLBA: Int
        var title: String?
        var performer: String?
        var isrc: String?

        init(number: Int, startLBA: Int, title: String? = nil,
             performer: String? = nil, isrc: String? = nil) {
            self.number = number
            self.startLBA = startLBA
            self.title = title
            self.performer = performer
            self.isrc = isrc
        }

        var id: Int { number }
    }

    var audioFileName: String
    /// `BINARY` for the raw stream, `WAVE` for anything with a header.
    var fileType: String
    var albumTitle: String?
    var albumPerformer: String?
    var catalog: String?
    var tracks: [Track]

    // MARK: - Parsing

    init?(text: String) {
        var fileName: String?
        var type = "WAVE"
        var title: String?
        var performer: String?
        var catalog: String?
        var parsed: [Track] = []
        /// Before the first `TRACK` line, TITLE and PERFORMER belong to the
        /// album, after it to the respective track.
        var current: Track?

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let (keyword, rest) = Self.split(line)

            switch keyword {
            case "FILE":
                // FILE "name with spaces.bin" BINARY
                if let quoted = Self.quoted(rest) {
                    fileName = quoted.value
                    let tail = quoted.remainder.trimmingCharacters(in: .whitespaces)
                    if !tail.isEmpty { type = tail.uppercased() }
                } else {
                    let parts = rest.split(separator: " ", maxSplits: 1)
                    fileName = parts.first.map(String.init)
                    if parts.count > 1 { type = String(parts[1]).uppercased() }
                }

            case "TRACK":
                if let track = current { parsed.append(track) }
                let parts = rest.split(separator: " ")
                let number = parts.first.flatMap { Int($0) } ?? (parsed.count + 1)
                // Data tracks appear in the cue, but they are not burned here.
                let mode = parts.count > 1 ? String(parts[1]).uppercased() : "AUDIO"
                current = mode == "AUDIO" ? Track(number: number, startLBA: 0) : nil

            case "TITLE":
                let value = Self.quoted(rest)?.value ?? rest
                if current != nil { current?.title = value } else { title = value }

            case "PERFORMER":
                let value = Self.quoted(rest)?.value ?? rest
                if current != nil { current?.performer = value } else { performer = value }

            case "ISRC":
                current?.isrc = rest

            case "CATALOG":
                catalog = rest

            case "INDEX":
                // Only INDEX 01 is the start of the audible track; INDEX 00
                // marks the pause before it and still belongs to the previous one.
                let parts = rest.split(separator: " ")
                guard parts.count >= 2, parts[0] == "01",
                      let lba = Self.lba(fromMSF: String(parts[1])) else { break }
                current?.startLBA = lba

            default:
                break
            }
        }
        if let track = current { parsed.append(track) }

        guard let fileName, !parsed.isEmpty else { return nil }
        self.audioFileName = fileName
        self.fileType = type
        self.albumTitle = title
        self.albumPerformer = performer
        self.catalog = catalog
        self.tracks = parsed.sorted { $0.number < $1.number }
    }

    /// How many sectors each track spans — only follows from the start of the
    /// next one; the last one runs to the end of the file.
    func sectorCounts(totalSectors: Int) -> [Int: Int] {
        var counts: [Int: Int] = [:]
        for (index, track) in tracks.enumerated() {
            let next = index + 1 < tracks.count ? tracks[index + 1].startLBA : totalSectors
            counts[track.number] = max(0, next - track.startLBA)
        }
        return counts
    }

    // MARK: - Helpers

    private static func split(_ line: String) -> (String, String) {
        guard let space = line.firstIndex(of: " ") else { return (line.uppercased(), "") }
        return (String(line[line.startIndex..<space]).uppercased(),
                String(line[line.index(after: space)...]).trimmingCharacters(in: .whitespaces))
    }

    /// Extracts the content of the first quotation marks and returns what
    /// comes after them.
    private static func quoted(_ text: String) -> (value: String, remainder: String)? {
        guard let open = text.firstIndex(of: "\""),
              let close = text[text.index(after: open)...].firstIndex(of: "\"")
        else { return nil }
        return (String(text[text.index(after: open)..<close]),
                String(text[text.index(after: close)...]))
    }

    /// `mm:ss:ff` — minutes, seconds, frames of 1/75 second.
    static func lba(fromMSF text: String) -> Int? {
        let parts = text.split(separator: ":")
        guard parts.count == 3,
              let minutes = Int(parts[0]), let seconds = Int(parts[1]), let frames = Int(parts[2]),
              seconds < 60, frames < 75
        else { return nil }
        return (minutes * 60 + seconds) * CDGeometry.sectorsPerSecond + frames
    }
}
