//
//  LookupModels.swift
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
//  A common language for all lookup sources. Discogs and MusicBrainz answer
//  completely differently; the matching UI and `ReleaseMatcher` should not
//  notice.
//

import Foundation

enum LookupProvider: String, CaseIterable, Identifiable, Sendable {
    case musicBrainz, discogs

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .musicBrainz: "MusicBrainz"
        case .discogs:     "Discogs"
        }
    }

    /// Discogs locks its search behind a token. MusicBrainz does not — a
    /// meaningful User-Agent is enough there.
    var needsToken: Bool { self == .discogs }

    /// Default for both lookup sheets: Discogs as soon as a token is stored —
    /// better covers, finer styles. Otherwise MusicBrainz, which needs none.
    static func preferred(hasDiscogsToken: Bool) -> LookupProvider {
        hasDiscogsToken ? .discogs : .musicBrainz
    }

    var note: LocalizedStringResource {
        switch self {
        case .musicBrainz:
            "Free and open, no account needed. Fewer cover images."
        case .discogs:
            "Better cover art and finer style information. Needs a token."
        }
    }
}

struct LookupTrack: Sendable, Hashable {
    /// As the source writes it: "3", "A1", "1-3".
    var position: String?
    var title: String?
    var artistName: String?
    var duration: String?
    /// Already resolved, where the source provides it.
    var disc: Int?
    var number: Int?
}

struct LookupSearchResult: Sendable, Identifiable, Hashable {
    var provider: LookupProvider
    /// A number at Discogs, a UUID at MusicBrainz — hence text.
    var id: String
    var title: String
    var subtitle: String
    var thumbnailURL: URL?
    /// A short mark in the result list — "Disc ID" for an exact hit on the
    /// inserted CD.
    var badge: String? = nil
}

struct LookupRelease: Sendable {
    var provider: LookupProvider
    var id: String
    var title: String
    var albumArtist: String?
    var year: Int?
    var country: String?
    var labelSummary: String?
    var formatSummary: String?
    /// MusicBrainz only knows genres, Discogs separates genre and style.
    var genres: [String] = []
    var styles: [String] = []
    var thumbnailURL: URL?
    /// The cover in a size worth putting into the tag — `nil` when the
    /// source has none.
    var coverURL: URL?
    var tracks: [LookupTrack] = []

    var discCount: Int {
        let discs = tracks.compactMap(\.disc)
        return Set(discs).count
    }

    var summary: String {
        [albumArtist, year.map(String.init), country, labelSummary, formatSummary]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

/// Discogs separates `genre` ("Rock") and `style` ("Melodic Death Metal").
/// The style is usually what one wants (spec §4.6). MusicBrainz only
/// delivers genres — there the choice falls back to them automatically.
enum GenreSource: String, CaseIterable, Identifiable, Sendable {
    case style, genre, both

    var id: String { rawValue }

    var label: LocalizedStringResource {
        switch self {
        case .style: "Style (Melodic Death Metal)"
        case .genre: "Genre (Rock)"
        case .both:  "Both, combined"
        }
    }

    func value(from release: LookupRelease) -> String? {
        let chosen: [String] = switch self {
        case .style: release.styles.isEmpty ? release.genres : release.styles
        case .genre: release.genres.isEmpty ? release.styles : release.genres
        case .both:  release.genres + release.styles
        }
        return chosen.isEmpty ? nil : chosen.joined(separator: "; ")
    }
}

/// The year from "1987-04-01" or "1987".
extension String {
    var leadingYearValue: Int? {
        let digits = prefix { $0.isNumber }
        guard digits.count == 4 else { return nil }
        return Int(digits)
    }
}

/// How closely a length from the source has to match one's own — the same
/// when tagging and in the Track Splitter.
enum LookupComparison {
    /// From when on a deviation turns orange. Uploaders round to whole
    /// seconds, pressings differ by fractions — three seconds absorb both and
    /// still let real mismatches through.
    static let tolerance: Double = 3

    static func deviates(_ mine: Double?, from theirs: Double?) -> Bool {
        guard let mine, let theirs else { return false }
        return abs(mine - theirs) > tolerance
    }
}
