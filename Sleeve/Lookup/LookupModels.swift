//
//  LookupModels.swift
//  Sleeve
//
//  Gemeinsame Sprache für alle Nachschlagequellen. Discogs und MusicBrainz
//  antworten völlig verschieden; die Zuordnungs-Oberfläche und der
//  `ReleaseMatcher` sollen davon nichts merken.
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

    /// Discogs sperrt seine Suche hinter einen Token. MusicBrainz nicht —
    /// dort genügt ein aussagekräftiger User-Agent.
    var needsToken: Bool { self == .discogs }

    /// Vorgabe beider Nachschlage-Blätter: Discogs, sobald ein Token
    /// hinterlegt ist — bessere Cover, feinere Styles. Sonst MusicBrainz, das
    /// ohne auskommt.
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
    /// Wie die Quelle es schreibt: "3", "A1", "1-3".
    var position: String?
    var title: String?
    var artistName: String?
    var duration: String?
    /// Schon aufgelöst, wo die Quelle es hergibt.
    var disc: Int?
    var number: Int?
}

struct LookupSearchResult: Sendable, Identifiable, Hashable {
    var provider: LookupProvider
    /// Bei Discogs eine Zahl, bei MusicBrainz eine UUID — deshalb Text.
    var id: String
    var title: String
    var subtitle: String
    var thumbnailURL: URL?
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
    /// MusicBrainz kennt nur Genres, Discogs trennt Genre und Style.
    var genres: [String] = []
    var styles: [String] = []
    var thumbnailURL: URL?
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

/// Discogs trennt `genre` („Rock") und `style` („Melodic Death Metal").
/// Gewünscht ist meist der Style (Spec §4.6). MusicBrainz liefert nur Genres —
/// dort fällt die Wahl automatisch darauf zurück.
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

/// Aus "1987-04-01" oder "1987" die Jahreszahl.
extension String {
    var leadingYearValue: Int? {
        let digits = prefix { $0.isNumber }
        guard digits.count == 4 else { return nil }
        return Int(digits)
    }
}

/// Wie genau eine Länge aus der Quelle zur eigenen passen muss — gilt beim
/// Taggen wie im Track Splitter.
enum LookupComparison {
    /// Ab wann eine Abweichung orange wird. Uploader runden auf ganze
    /// Sekunden, Pressungen unterscheiden sich um Bruchteile — drei Sekunden
    /// fangen beides ab und lassen echte Fehlgriffe durch.
    static let tolerance: Double = 3

    static func deviates(_ mine: Double?, from theirs: Double?) -> Bool {
        guard let mine, let theirs else { return false }
        return abs(mine - theirs) > tolerance
    }
}
