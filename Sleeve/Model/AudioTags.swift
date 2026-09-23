//
//  AudioTags.swift
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

import Foundation

/// A single tag field. The basis for `TrackFile.touchedFields`: only what is
/// in there gets written — never based on a string comparison. See spec
/// §4.1.
enum TagField: String, CaseIterable, Sendable, Hashable {
    case title
    case artist
    case albumArtist
    case album
    case composer
    case genre
    case year
    case trackNumber
    case trackTotal
    case discNumber
    case discTotal
    case comment
    case lyrics
    case isCompilation
    case artwork
}

struct AudioTags: Equatable, Sendable {
    var title: String?
    var artist: String?
    var albumArtist: String?
    var album: String?
    var composer: String?
    var genre: String?
    var year: Int?
    var trackNumber: Int?
    var trackTotal: Int?
    var discNumber: Int?
    var discTotal: Int?
    var comment: String?
    /// Unsynchronized lyrics. TagLib stores them as `USLT` (MP3), `©lyr` (MP4)
    /// or `LYRICS` (Vorbis).
    var lyrics: String?
    var isCompilation: Bool
    var artwork: [Artwork]

    init(
        title: String? = nil,
        artist: String? = nil,
        albumArtist: String? = nil,
        album: String? = nil,
        composer: String? = nil,
        genre: String? = nil,
        year: Int? = nil,
        trackNumber: Int? = nil,
        trackTotal: Int? = nil,
        discNumber: Int? = nil,
        discTotal: Int? = nil,
        comment: String? = nil,
        lyrics: String? = nil,
        isCompilation: Bool = false,
        artwork: [Artwork] = []
    ) {
        self.title = title
        self.artist = artist
        self.albumArtist = albumArtist
        self.album = album
        self.composer = composer
        self.genre = genre
        self.year = year
        self.trackNumber = trackNumber
        self.trackTotal = trackTotal
        self.discNumber = discNumber
        self.discTotal = discTotal
        self.comment = comment
        self.lyrics = lyrics
        self.isCompilation = isCompilation
        self.artwork = artwork
    }

    /// Text value of a field — for inspector bindings and the
    /// `<Multiple values>` comparison with several tracks selected.
    func stringValue(for field: TagField) -> String? {
        switch field {
        case .title:         title
        case .artist:        artist
        case .albumArtist:   albumArtist
        case .album:         album
        case .composer:      composer
        case .genre:         genre
        case .comment:       comment
        case .lyrics:        lyrics
        case .year:          year.map(String.init)
        case .trackNumber:   trackNumber.map(String.init)
        case .trackTotal:    trackTotal.map(String.init)
        case .discNumber:    discNumber.map(String.init)
        case .discTotal:     discTotal.map(String.init)
        case .isCompilation: isCompilation ? "1" : "0"
        case .artwork:       artwork.isEmpty ? nil : "\(artwork.count)"
        }
    }

    /// Counterpart to `stringValue(for:)`. An empty string means "clear the
    /// field", not "leave it alone" — that distinction is made by
    /// `touchedFields` alone.
    mutating func setStringValue(_ value: String?, for field: TagField) {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = (text?.isEmpty ?? true) ? nil : text
        let number = cleaned.flatMap(Int.init)

        switch field {
        case .title:         title = cleaned
        case .artist:        artist = cleaned
        case .albumArtist:   albumArtist = cleaned
        case .album:         album = cleaned
        case .composer:      composer = cleaned
        case .genre:         genre = cleaned
        case .comment:       comment = cleaned
        case .lyrics:        lyrics = cleaned
        case .year:          year = number
        case .trackNumber:   trackNumber = number
        case .trackTotal:    trackTotal = number
        case .discNumber:    discNumber = number
        case .discTotal:     discTotal = number
        case .isCompilation: isCompilation = (cleaned == "1" || cleaned?.lowercased() == "true")
        case .artwork:       break   // Pictures do not go through text
        }
    }
}

/// Read-only properties of the audio stream. Not part of `AudioTags`,
/// because none of it can be written.
struct AudioProperties: Equatable, Sendable {
    var duration: Duration      // Playing time
    var bitrate: Int            // kbit/s
    var sampleRate: Int         // Hz
    var channels: Int

    static let unknown = AudioProperties(
        duration: .zero, bitrate: 0, sampleRate: 0, channels: 0
    )
}

/// What `TagLibBridge.read` returns.
struct AudioFileInfo: Equatable, Sendable {
    var tags: AudioTags
    var properties: AudioProperties
}
