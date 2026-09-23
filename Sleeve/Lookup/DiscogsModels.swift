//
//  DiscogsModels.swift
//  Sleeve
//
//  Die Antwortstrukturen von api.discogs.com, plus die Aufbereitung ihrer
//  Eigenheiten (Spec §4.6).
//

import Foundation

// MARK: - Künstler

struct DiscogsArtist: Decodable, Sendable, Hashable {
    var name: String
    /// „Artist Name Variation" — die Schreibweise auf genau dieser Pressung.
    var anv: String?
    /// Verbindet diesen Künstler mit dem **nächsten**: "&", "Feat.", "," …
    var join: String?

    var displayName: String {
        let raw = (anv?.isEmpty == false ? anv! : name)
        // Discogs hängt an mehrfach vergebene Künstlernamen eine laufende
        // Nummer: `Nirvana (2)`. Die gehört nicht ins Tag.
        //
        // Das Literal steht bewusst hier und nicht als statische Konstante:
        // `Regex` ist nicht `Sendable` und als `static let` unter Swift 6
        // nicht erlaubt.
        return raw.replacing(/\s\(\d+\)$/, with: "")
    }

    /// Setzt mehrere Künstler nach den `join`-Feldern zusammen. Nur den ersten
    /// zu nehmen wäre bei Kollaborationen schlicht falsch (Spec §4.6).
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
    /// "track", "heading", "index" — nur das erste ist ein echtes Stück.
    var type_: String?
    var title: String?
    var duration: String?
    var artists: [DiscogsArtist]?

    /// Tracklisten enthalten Überschriften und Index-Einträge ohne Position.
    /// Die müssen vor dem Zuordnen raus (Spec §4.6).
    var isPlayable: Bool {
        let hasPosition = !(position ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        let kind = (type_ ?? "track").lowercased()
        return kind == "track" && hasPosition
    }

    var artistName: String? { DiscogsArtist.combined(artists) }
}

/// Zerlegt Positionsangaben in Disc und Nummer.
///
/// Discogs kennt viele Schreibweisen: "7", "A1" (Vinylseite), "1-3" und
/// "CD2-4" (Mehrfachtonträger), "2.4". Vinylseiten ergeben keine Discnummer —
/// dort zählt die Reihenfolge.
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
        // Reine Zahl
        if let match = text.firstMatch(of: /^(\d+)$/) {
            return TrackPosition(disc: nil, number: Int(match.1))
        }
        // Vinylseite wie "A", "B2", "AA"
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

    /// Nur die echten Stücke, in Reihenfolge.
    var playableTracks: [DiscogsTrack] { (tracklist ?? []).filter(\.isPlayable) }

    var labelSummary: String? {
        guard let label = labels?.first else { return nil }
        return [label.name, label.catno].compactMap { $0 }.joined(separator: " · ")
    }

    var formatSummary: String? { formats?.first?.summary }

    /// Wie viele Tonträger die Tracklist erkennen lässt.
    var discCount: Int {
        let discs = playableTracks.compactMap { TrackPosition.parse($0.position).disc }
        return Set(discs).count
    }
}

// MARK: - Suche

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

// MARK: - Übersetzung ins gemeinsame Modell

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
