//
//  DiscImage.swift
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
//  An image of the whole disc instead of individual tracks (spec §6.9).
//
//  **No ISO.** An audio CD carries no file system: at sector 16, where the
//  ISO 9660 volume descriptor would be, there is music instead of the
//  identifier `CD001`. And of the 2352 bytes of a CDDA sector all 2352 are
//  audio — an ISO container with its 2048 bytes of payload would throw away
//  an eighth.
//
//  The fitting format is one continuous audio stream plus a cue sheet with
//  the track boundaries.
//

import Foundation

enum DiscImageFormat: String, CaseIterable, Identifiable, Sendable {
    /// Raw, 2352 bytes per sector, no header at all. The classic BIN.
    case bin
    /// The same with a 44-byte WAV header — opens in any player.
    case wav
    /// Losslessly compressed, about a third smaller.
    case flac

    var id: String { rawValue }
    var fileExtension: String { rawValue }

    var label: LocalizedStringResource {
        switch self {
        case .bin:  "BIN — raw, as on the disc"
        case .wav:  "WAV — raw with a header"
        case .flac: "FLAC — lossless, smaller"
        }
    }

    /// What the format is good for — and what not.
    ///
    /// Measured with VLC 3.0.23: for `.bin` **and** for `.cue` VLC picks the
    /// `ps` demuxer (MPEG program stream), i.e. it guesses; only the WAV gets
    /// the right one. Without this hint one picks BIN — "raw, as on the CD"
    /// sounds like the most faithful choice — and then wonders why nothing
    /// plays.
    var hint: LocalizedStringResource {
        switch self {
        case .bin:
            "Exact copy for archiving or burning. Most players do not recognise a raw .bin — open the cue sheet instead, in a program that understands one."
        case .wav:
            "Plays in any program. The cue sheet next to it marks the track boundaries."
        case .flac:
            "Like WAV, about a third smaller, and just as lossless."
        }
    }

    /// What follows the file name in the cue sheet. `BINARY` for the raw stream,
    /// `WAVE` for anything with a header — FLAC included, which is how common
    /// players handle it.
    var cueFileType: String {
        self == .bin ? "BINARY" : "WAVE"
    }

    /// FLAC is made from the intermediate WAV and therefore needs ffmpeg.
    var needsFFmpeg: Bool { self == .flac }
}
