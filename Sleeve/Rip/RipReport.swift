//
//  RipReport.swift
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
//  The log of one pass — and the cue sheet.
//
//  A rip log is no accessory: it is the only record of the conditions under
//  which reading happened and whether something did not arrive cleanly.
//  That is why it also states what was *not* checked.
//

import Foundation

struct RipReport: Sendable {
    struct Entry: Sendable {
        var number: Int
        var crc: UInt32
        var verificationCRC: UInt32?
        var suspiciousSectors: [Int]
        var c2ErrorSectors: [Int]
        var retryCount: Int
        var isrc: String?

        var isAccurate: Bool {
            suspiciousSectors.isEmpty && c2ErrorSectors.isEmpty
                && (verificationCRC == nil || verificationCRC == crc)
        }

        init(result: TrackRipResult) {
            self.number = result.track.number
            self.crc = result.crc
            self.verificationCRC = result.verificationCRC
            self.suspiciousSectors = result.suspiciousSectors
            self.c2ErrorSectors = result.c2ErrorSectors
            self.retryCount = result.retryCount
            self.isrc = result.track.isrc
        }
    }

    var drive: CDDriveInfo
    var toc: DiscTOC
    var settings: RipSettings
    var entries: [Entry]
    var started: Date
    var ended: Date

    var allAccurate: Bool { entries.allSatisfy(\.isAccurate) }

    // MARK: - Log

    func logText(albumTitle: String? = nil, albumArtist: String? = nil) -> String {
        var lines: [String] = []
        let stamp = started.formatted(date: .numeric, time: .shortened)

        lines.append("Sleeve — CD rip log")
        lines.append(stamp)
        lines.append("")
        if let albumArtist { lines.append("Artist:      \(albumArtist)") }
        if let albumTitle { lines.append("Album:       \(albumTitle)") }
        lines.append("Drive:       \(drive.displayName) \(drive.revision)")
        lines.append("")
        lines.append("Mode:        \(settings.mode == .secure ? "Secure" : "Burst")")
        lines.append("Read offset: \(settings.readOffset) samples")
        if settings.c2WasRequestedButUnavailable {
            lines.append("C2:          requested, not delivered by the drive")
        } else {
            lines.append("C2:          \(settings.usesC2 ? "used" : "not used")")
        }
        lines.append("Speed:       \(settings.speedMultiplier.map { "\($0)×" } ?? "automatic")")
        lines.append("Second pass: \(settings.testBeforeCopy ? "yes" : "no")")
        lines.append("")
        lines.append("Disc ID:     \(toc.musicBrainzDiscID)")
        lines.append("FreeDB:      \(toc.freeDBID)")
        if let mcn = toc.mcn { lines.append("MCN:         \(mcn)") }
        lines.append("")

        for entry in entries.sorted(by: { $0.number < $1.number }) {
            lines.append("Track \(String(format: "%2d", entry.number))")
            lines.append("    CRC32            \(String(format: "%08X", entry.crc))")
            if let verification = entry.verificationCRC {
                let verdict = verification == entry.crc
                    ? "matches" : "DIFFERS"
                lines.append("    Second pass      \(String(format: "%08X", verification))  \(verdict)")
            }
            if let isrc = entry.isrc { lines.append("    ISRC             \(isrc)") }
            if entry.retryCount > 0 {
                lines.append("    Retries          \(entry.retryCount)")
            }
            if !entry.c2ErrorSectors.isEmpty {
                lines.append("    C2 errors        \(entry.c2ErrorSectors.count) sectors")
            }
            if !entry.suspiciousSectors.isEmpty {
                lines.append("    UNRESOLVED       \(entry.suspiciousSectors.count) sectors from "
                    + "\(entry.suspiciousSectors[0])")
            }
            lines.append("    \(entry.isAccurate ? "no problems" : "NOT READ CLEANLY")")
            lines.append("")
        }

        lines.append(allAccurate
            ? "All tracks read without problems."
            : "At least one track could not be read reliably.")
        lines.append("")
        // Stay honest: without comparing against other people's rips this
        // is a statement about repeatability, not about correctness.
        lines.append("Note: Sleeve does not compare against an external database.")
        lines.append("What was checked is whether the same disc reads reproducibly")
        lines.append("in this drive — not whether the read offset is correct.")

        return lines.joined(separator: "\n")
    }

    // MARK: - Cue sheet

    /// `fileType` is `WAVE` for anything with a header and `BINARY` for the
    /// raw stream of a BIN image — if it is wrong, the player finds the track
    /// boundaries shifted by 44 bytes.
    ///
    /// Known limitation: only `INDEX 01` is written. The pauses between the
    /// tracks are in the image, but where exactly a pause begins (`INDEX 00`)
    /// the TOC does not say — that would need the subchannel, which the test
    /// drive does not deliver reliably (§6.1.1). INDEX 01 is enough for the
    /// usual purposes; it stays gapless anyway, because nothing is cut out.
    func cueSheet(albumTitle: String?, albumArtist: String?,
                  audioFileName: String, fileType: String = "WAVE",
                  titles: [Int: String] = [:]) -> String {
        var lines: [String] = []
        if let mcn = toc.mcn { lines.append("CATALOG \(mcn)") }
        if let albumArtist { lines.append("PERFORMER \"\(escape(albumArtist))\"") }
        if let albumTitle { lines.append("TITLE \"\(escape(albumTitle))\"") }
        lines.append("FILE \"\(escape(audioFileName))\" \(fileType)")

        for track in toc.tracks where !track.isData {
            lines.append("  TRACK \(String(format: "%02d", track.number)) AUDIO")
            if let title = titles[track.number], !title.isEmpty {
                lines.append("    TITLE \"\(escape(title))\"")
            }
            if let isrc = track.isrc { lines.append("    ISRC \(isrc)") }
            lines.append("    INDEX 01 \(Self.msf(track.startLBA))")
        }
        return lines.joined(separator: "\n")
    }

    private func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: "'")
    }

    /// Cue sheets count in minutes:seconds:frames from track 1.
    static func msf(_ lba: Int) -> String {
        let frames = max(0, lba)
        return String(format: "%02d:%02d:%02d",
                      frames / (75 * 60),
                      (frames / 75) % 60,
                      frames % 75)
    }
}
