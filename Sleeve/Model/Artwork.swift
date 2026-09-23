//
//  Artwork.swift
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

/// Picture type following the ID3v2 APIC convention. TagLib uses the same
/// numbering for all formats and passes it through the complex property API
/// as a plain-text string.
enum PictureType: UInt8, CaseIterable, Sendable, Hashable {
    case other              = 0x00
    case fileIcon           = 0x01
    case otherFileIcon      = 0x02
    case frontCover         = 0x03
    case backCover          = 0x04
    case leafletPage        = 0x05
    case media              = 0x06
    case leadArtist         = 0x07
    case artist             = 0x08
    case conductor          = 0x09
    case band               = 0x0A
    case composer           = 0x0B
    case lyricist           = 0x0C
    case recordingLocation  = 0x0D
    case duringRecording    = 0x0E
    case duringPerformance  = 0x0F
    case movieScreenCapture = 0x10
    case colouredFish       = 0x11
    case illustration       = 0x12
    case bandLogo           = 0x13
    case publisherLogo      = 0x14

    /// Exactly the spelling `TagLib::Utils::pictureTypeToString` produces and
    /// `pictureTypeFromString` accepts again. Do not rephrase — TagLib matches
    /// on equality and otherwise silently falls back to `Other`.
    var taglibName: String {
        switch self {
        case .other:              "Other"
        case .fileIcon:           "File Icon"
        case .otherFileIcon:      "Other File Icon"
        case .frontCover:         "Front Cover"
        case .backCover:          "Back Cover"
        case .leafletPage:        "Leaflet Page"
        case .media:              "Media"
        case .leadArtist:         "Lead Artist"
        case .artist:             "Artist"
        case .conductor:          "Conductor"
        case .band:               "Band"
        case .composer:           "Composer"
        case .lyricist:           "Lyricist"
        case .recordingLocation:  "Recording Location"
        case .duringRecording:    "During Recording"
        case .duringPerformance:  "During Performance"
        case .movieScreenCapture: "Movie Screen Capture"
        case .colouredFish:       "Coloured Fish"
        case .illustration:       "Illustration"
        case .bandLogo:           "Band Logo"
        case .publisherLogo:      "Publisher Logo"
        }
    }

    init(taglibName: String) {
        self = PictureType.allCases.first { $0.taglibName == taglibName } ?? .other
    }

    /// What actually occurs in a music collection. The complete list of 21
    /// entries — "Coloured Fish" included — would only get in the way in a
    /// menu.
    static let commonCases: [PictureType] = [
        .frontCover, .backCover, .leafletPage, .media,
        .artist, .band, .composer, .illustration, .other,
    ]

    var label: LocalizedStringResource {
        switch self {
        case .frontCover:   "Front cover"
        case .backCover:    "Back cover"
        case .leafletPage:  "Booklet page"
        case .media:        "Disc or label"
        case .artist:       "Artist"
        case .band:         "Band"
        case .composer:     "Composer"
        case .illustration: "Illustration"
        default:            "Other"
        }
    }
}

struct Artwork: Equatable, Sendable, Identifiable {
    let id: UUID
    var data: Data
    var mimeType: String              // image/jpeg, image/png
    var pictureType: PictureType      // frontCover, backCover, artist, …
    var description: String?

    init(
        id: UUID = UUID(),
        data: Data,
        mimeType: String,
        pictureType: PictureType = .frontCover,
        description: String? = nil
    ) {
        self.id = id
        self.data = data
        self.mimeType = mimeType
        self.pictureType = pictureType
        self.description = description
    }

    /// Two pictures are equal if their content is equal — the `id` only
    /// identifies them in the list and must not affect the comparison.
    /// Otherwise every cover would count as "different" with several tracks
    /// selected.
    static func == (lhs: Artwork, rhs: Artwork) -> Bool {
        lhs.data == rhs.data
            && lhs.mimeType == rhs.mimeType
            && lhs.pictureType == rhs.pictureType
            && lhs.description == rhs.description
    }

    /// Moves the front cover to the first position.
    ///
    /// Players usually take the **first** embedded picture; only some of
    /// them look at the picture type. Whoever adds a new front cover later
    /// would otherwise get it sorted behind the booklet page — and the
    /// booklet as the cover in the player.
    ///
    /// Everything except the front cover keeps its order: re-sorting booklet
    /// pages by picture type would destroy their sequence.
    static func sortedForEmbedding(_ artwork: [Artwork]) -> [Artwork] {
        artwork.enumerated()
            .sorted { left, right in
                let leftRank = left.element.pictureType == .frontCover ? 0 : 1
                let rightRank = right.element.pictureType == .frontCover ? 0 : 1
                return leftRank == rightRank
                    ? left.offset < right.offset
                    : leftRank < rightRank
            }
            .map(\.element)
    }

    /// Derives the MIME type from the first bytes — more reliable than the
    /// file extension, especially with drag and drop from the browser.
    static func detectMimeType(of data: Data) -> String {
        let prefix = [UInt8](data.prefix(12))
        switch prefix {
        case let p where p.starts(with: [0xFF, 0xD8, 0xFF]):
            return "image/jpeg"
        case let p where p.starts(with: [0x89, 0x50, 0x4E, 0x47]):
            return "image/png"
        case let p where p.starts(with: [0x47, 0x49, 0x46]):
            return "image/gif"
        case let p where p.count >= 12
            && Array(p[0..<4]) == [0x52, 0x49, 0x46, 0x46]
            && Array(p[8..<12]) == [0x57, 0x45, 0x42, 0x50]:
            return "image/webp"
        default:
            return "application/octet-stream"
        }
    }
}
