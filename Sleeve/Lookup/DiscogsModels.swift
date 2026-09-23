//
//  DiscogsModels.swift
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
//  The response structures of api.discogs.com, plus the handling of their
//  quirks (spec §4.6).
//

import Foundation

// MARK: - Artists

struct DiscogsArtist: Decodable, Sendable, Hashable {
    var name: String
    /// "Artist Name Variation" — the spelling on exactly this pressing.
    var anv: String?
    /// Joins this artist to the **next** one: "&", "Feat.", "," …
    var join: String?

    var displayName: String {
        let raw = (anv?.isEmpty == false ? anv! : name)
        // Discogs appends a running number to artist names used more than
        // once: `Nirvana (2)`. It does not belong in the tag.
        //
        // The literal stands here on purpose and not as a static constant:
        // `Regex` is not `Sendable` and not allowed as a `static let` under
        // Swift 6.
        return raw.replacing(/\s\(\d+\)$/, with: "")
    }

    /// Joins several artists according to the `join` fields. Taking only the
    /// first would simply be wrong for collaborations (spec §4.6).
    static func combined(_ artists: [DiscogsArtist]?) -> String? {
        guard let artists, !artists.isEmpty else { return nil }

        var result = ""
        for (index, artist) in artists.enumerated() {
            result += artist.displayName
            guard index < artists.count - 1 else { continue }

            let join = (artist.join ?? "").trimmingCharacters(in: .whitespaces)
            switch join {
            case "":  result += ", "
            case ",": result += ", "
            default:  result += " \(join) "
            }
        }
        return result.isEmpty ? nil : result
    }
}

// MARK: - Track

struct DiscogsTrack: Decodable, Sendable, Hashable {
    var position: String?
    /// "track", "heading", "index" — only the first is a real piece.
    var type_: String?
    var title: String?
    var duration: String?
    var artists: [DiscogsArtist]?

    /// Track lists contain headings and index entries without a position.
    /// Those have to go before matching (spec §4.6).
    var isPlayable: Bool {
        let hasPosition = !(position ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        let kind = (type_ ?? "track").lowercased()
        return kind == "track" && hasPosition
    }

    var artistName: String? { DiscogsArtist.combined(artists) }
}

/// Splits position strings into disc and number.
///
/// Discogs knows many spellings: "7", "A1" (vinyl side), "1-3" and
/// "CD2-4" (multiple media), "2.4". Vinyl sides yield no disc number —
/// there the order is what counts.
struct TrackPosition: Equatable, Sendable {
    var disc: Int?
    var number: Int?

    static func parse(_ raw: String?) -> TrackPosition {
        let text = (raw ?? "").trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return TrackPosition() }

        // "1-3", "CD2-4", "2.4"
        if let match = text.firstMatch(of: /^(?:[A-Za-z]*)(\d+)[-.](\d+)$/) {
            return TrackPosition(disc: Int(match.1), number: Int(match.2))
        }
        // Plain number
        if let match = text.firstMatch(of: /^(\d+)$/) {
            return TrackPosition(disc: nil, number: Int(match.1))
        }
        // Vinyl side such as "A", "B2", "AA"
        return TrackPosition()
    }
}

// MARK: - Release

struct DiscogsLabel: Decodable, Sendable, Hashable {
    var name: String?
    var catno: String?
}

struct DiscogsFormat: Decodable, Sendable, Hashable {
    var name: String?
    var qty: String?
    var descriptions: [String]?

    var summary: String {
        let extra = (descriptions ?? []).joined(separator: ", ")
        guard let name else { return extra }
        return extra.isEmpty ? name : "\(name), \(extra)"
    }
}

struct DiscogsRelease: Decodable, Sendable {
    var id: Int
    var title: String
    var year: Int?
    var country: String?
    var genres: [String]?
    var styles: [String]?
    var artists: [DiscogsArtist]?
    var labels: [DiscogsLabel]?
    var formats: [DiscogsFormat]?
    var tracklist: [DiscogsTrack]?
    var thumb: String?

    var albumArtist: String? { DiscogsArtist.combined(artists) }

    /// Only the real pieces, in order.
    var playableTracks: [DiscogsTrack] { (tracklist ?? []).filter(\.isPlayable) }

    var labelSummary: String? {
        guard let label = labels?.first else { return nil }
        return [label.name, label.catno].compactMap { $0 }.joined(separator: " · ")
    }

    var formatSummary: String? { formats?.first?.summary }

    /// How many media the track list reveals.
    var discCount: Int {
        let discs = playableTracks.compactMap { TrackPosition.parse($0.position).disc }
        return Set(discs).count
    }
}

// MARK: - Search

struct DiscogsSearchResponse: Decodable, Sendable {
    var results: [DiscogsSearchResult]?
}

struct DiscogsSearchResult: Decodable, Sendable, Identifiable, Hashable {
    var id: Int
    var title: String?
    var year: String?
    var country: String?
    var thumb: String?
    var label: [String]?
    var format: [String]?
    var catno: String?
    var type: String?

    var isRelease: Bool { (type ?? "release") == "release" }

    var subtitle: String {
        [year, country, label?.first, format?.joined(separator: ", "), catno]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " · ")
    }
}

// MARK: - Translation into the common model

extension DiscogsTrack {
    func asLookupTrack() -> LookupTrack {
        let parsed = TrackPosition.parse(position)
        return LookupTrack(
            position: position,
            title: title,
            artistName: artistName,
            duration: duration,
            disc: parsed.disc,
            number: parsed.number
        )
    }
}

extension DiscogsRelease {
    func asLookupRelease() -> LookupRelease {
        LookupRelease(
            provider: .discogs,
            id: String(id),
            title: title,
            albumArtist: albumArtist,
            year: (year ?? 0) > 0 ? year : nil,
            country: country,
            labelSummary: labelSummary,
            formatSummary: formatSummary,
            genres: genres ?? [],
            styles: styles ?? [],
            thumbnailURL: thumb.flatMap(URL.init(string:)),
            tracks: playableTracks.map { $0.asLookupTrack() }
        )
    }
}

extension DiscogsSearchResult {
    func asLookupSearchResult() -> LookupSearchResult {
        LookupSearchResult(
            provider: .discogs,
            id: String(id),
            title: title ?? "—",
            subtitle: subtitle,
            thumbnailURL: thumb.flatMap(URL.init(string:))
        )
    }
}
