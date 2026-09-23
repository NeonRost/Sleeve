//
//  MusicBrainzClient.swift
//  Sleeve
//
//  Die tokenfreie Nachschlagequelle (Spec §4.6, §6.2).
//
//  MusicBrainz verlangt kein Konto und keinen Schlüssel — nur einen
//  aussagekräftigen User-Agent und **höchstens eine Anfrage pro Sekunde**.
//  Wer schneller fragt, bekommt 503.
//

import Foundation

// MARK: - Antwortstrukturen

struct MBArtistCredit: Decodable, Sendable {
    struct Artist: Decodable, Sendable { var name: String? }
    /// Die für diese Veröffentlichung gutgeschriebene Schreibweise.
    var name: String?
    var joinphrase: String?
    var artist: Artist?

    var displayName: String? { name ?? artist?.name }

    static func combined(_ credits: [MBArtistCredit]?) -> String? {
        guard let credits, !credits.isEmpty else { return nil }
        var result = ""
        for credit in credits {
            result += credit.displayName ?? ""
            result += credit.joinphrase ?? ""
        }
        let trimmed = result.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct MBLabelInfo: Decodable, Sendable {
    struct Label: Decodable, Sendable { var name: String? }
    var label: Label?
    var catalogNumber: String?

    enum CodingKeys: String, CodingKey {
        case label
        case catalogNumber = "catalog-number"
    }
}

struct MBGenre: Decodable, Sendable { var name: String? }

/// Genres hängen bei MusicBrainz fast nie am einzelnen Release, sondern an
/// der Release-Group. Nachgemessen: selbst „Nevermind" hat am Release keine,
/// an der Gruppe sieben. Ohne diesen Umweg bliebe das Genrefeld fast immer
/// leer.
struct MBReleaseGroup: Decodable, Sendable {
    var id: String?
    var primaryType: String?
    var genres: [MBGenre]?

    enum CodingKeys: String, CodingKey {
        case id
        case primaryType = "primary-type"
        case genres
    }
}

struct MBTrack: Decodable, Sendable {
    var position: Int?
    var number: String?
    var title: String?
    var length: Int?
    var artistCredit: [MBArtistCredit]?

    enum CodingKeys: String, CodingKey {
        case position, number, title, length
        case artistCredit = "artist-credit"
    }

    var durationText: String? {
        guard let length, length > 0 else { return nil }
        let seconds = length / 1000
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct MBMedium: Decodable, Sendable {
    var position: Int?
    var format: String?
    var trackCount: Int?
    var tracks: [MBTrack]?

    enum CodingKeys: String, CodingKey {
        case position, format, tracks
        case trackCount = "track-count"
    }
}

struct MBRelease: Decodable, Sendable {
    var id: String
    var title: String?
    var date: String?
    var country: String?
    var artistCredit: [MBArtistCredit]?
    var labelInfo: [MBLabelInfo]?
    var media: [MBMedium]?
    var genres: [MBGenre]?
    var releaseGroup: MBReleaseGroup?
    var disambiguation: String?

    enum CodingKeys: String, CodingKey {
        case id, title, date, country, media, genres, disambiguation
        case artistCredit = "artist-credit"
        case releaseGroup = "release-group"
        case labelInfo = "label-info"
    }

    var labelSummary: String? {
        guard let info = labelInfo?.first else { return nil }
        return [info.label?.name, info.catalogNumber].compactMap { $0 }.joined(separator: " · ")
    }

    var formatSummary: String? {
        guard let media, !media.isEmpty else { return nil }
        let formats = media.compactMap(\.format)
        guard !formats.isEmpty else { return nil }
        return media.count > 1 ? "\(media.count)× \(formats[0])" : formats[0]
    }

    /// Das Cover Art Archive ist offen und braucht ebenfalls keinen Schlüssel.
    var coverURL: URL? {
        URL(string: "https://coverartarchive.org/release/\(id)/front-250")
    }

    func asLookupRelease() -> LookupRelease {
        var tracks: [LookupTrack] = []
        let multipleDiscs = (media?.count ?? 0) > 1

        for medium in media ?? [] {
            for track in medium.tracks ?? [] {
                tracks.append(LookupTrack(
                    position: multipleDiscs
                        ? "\(medium.position ?? 1)-\(track.number ?? "")"
                        : track.number,
                    title: track.title,
                    artistName: MBArtistCredit.combined(track.artistCredit),
                    duration: track.durationText,
                    disc: multipleDiscs ? medium.position : nil,
                    number: track.position ?? Int(track.number ?? "")
                ))
            }
        }

        return LookupRelease(
            provider: .musicBrainz,
            id: id,
            title: title ?? "—",
            albumArtist: MBArtistCredit.combined(artistCredit),
            year: date?.leadingYearValue,
            country: country,
            labelSummary: labelSummary,
            formatSummary: formatSummary,
            // Erst am Release nachsehen, dann an der Gruppe — dort stehen sie
            // in aller Regel.
            genres: {
                let own = (genres ?? []).compactMap(\.name)
                return own.isEmpty ? (releaseGroup?.genres ?? []).compactMap(\.name) : own
            }(),
            styles: [],
            thumbnailURL: coverURL,
            tracks: tracks
        )
    }

    func asLookupSearchResult() -> LookupSearchResult {
        let subtitle = [
            MBArtistCredit.combined(artistCredit),
            date, country, labelSummary, formatSummary, disambiguation,
        ]
        .compactMap { $0?.isEmpty == false ? $0 : nil }
        .joined(separator: " · ")

        return LookupSearchResult(
            provider: .musicBrainz, id: id, title: title ?? "—",
            subtitle: subtitle, thumbnailURL: coverURL
        )
    }
}

/// Antwort der Disc-ID-Abfrage.
struct MBDiscResponse: Decodable, Sendable {
    var releases: [MBRelease]?
}

struct MBSearchResponse: Decodable, Sendable {
    var count: Int?
    var releases: [MBRelease]?
}

// MARK: - Client

actor MusicBrainzClient {

    enum ClientError: Error, Equatable, Sendable {
        case notFound
        case busy
        case server(Int)
        case decoding
        case transport(String)

        var readableDescription: String {
            switch self {
            case .notFound: String(localized: "Not found on MusicBrainz.")
            case .busy:     String(localized: "MusicBrainz is busy — try again in a moment.")
            case .server(let code): String(localized: "MusicBrainz returned an error (\(code)).")
            case .decoding: String(localized: "The MusicBrainz response could not be read.")
            case .transport(let message): message
            }
        }
    }

    /// MusicBrainz verlangt Anwendungsname, Version und eine Kontaktmöglichkeit.
    /// Ein allgemeiner User-Agent wird geblockt.
    static let userAgent = "Sleeve/1.0 ( https://github.com/NeonRost/Sleeve )"

    private static let baseURL = URL(string: "https://musicbrainz.org/ws/2")!

    private let session: URLSession
    /// Eine Anfrage pro Sekunde — das ist die dokumentierte Obergrenze.
    private let limiter = RateLimiter(limit: 1, per: .seconds(1))

    init(session: URLSession = .shared) {
        self.session = session
    }

    func search(_ query: DiscogsClient.SearchQuery, limit: Int = 25) async throws -> [LookupSearchResult] {
        var terms: [String] = []
        func add(_ field: String, _ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            terms.append("\(field):\(escape(trimmed))")
        }
        add("artist", query.artist)
        add("release", query.releaseTitle)
        add("date", query.year)
        add("catno", query.catalogNumber)
        guard !terms.isEmpty else { return [] }

        let response: MBSearchResponse = try await get("/release/", items: [
            URLQueryItem(name: "query", value: terms.joined(separator: " AND ")),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "fmt", value: "json"),
        ])
        return (response.releases ?? []).map { $0.asLookupSearchResult() }
    }

    /// Sucht über die Disc ID. Das ist der genaue Weg: die Kennung fällt aus
    /// der TOC und trifft damit **diese** Pressung, nicht bloß ein Album
    /// gleichen Namens. Leeres Ergebnis heißt: nicht eingetragen.
    func releases(discID: String) async throws -> [LookupRelease] {
        do {
            let response: MBDiscResponse = try await get("/discid/\(discID)", items: [
                URLQueryItem(name: "inc", value: "recordings+artist-credits+labels+genres+release-groups"),
                URLQueryItem(name: "fmt", value: "json"),
            ])
            return (response.releases ?? []).map { $0.asLookupRelease() }
        } catch ClientError.notFound {
            // Für eine Disc ID ist „unbekannt" eine Antwort, kein Fehler.
            return []
        }
    }

    /// Ersatzweg, wenn die Disc ID nicht eingetragen ist: MusicBrainz kann
    /// auch über die rohe TOC suchen. Das trifft unschärfer — Pressungen mit
    /// geringfügig anderen Spurlängen kommen mit — und liefert deshalb
    /// mehrere Treffer zur Auswahl.
    func releases(tocParameter: String) async throws -> [LookupRelease] {
        do {
            let response: MBDiscResponse = try await get("/discid/-", items: [
                URLQueryItem(name: "toc", value: tocParameter),
                URLQueryItem(name: "inc", value: "recordings+artist-credits+labels+genres+release-groups"),
                URLQueryItem(name: "fmt", value: "json"),
            ])
            return (response.releases ?? []).map { $0.asLookupRelease() }
        } catch ClientError.notFound {
            return []
        }
    }

    func release(id: String) async throws -> LookupRelease {
        let release: MBRelease = try await get("/release/\(id)", items: [
            URLQueryItem(name: "inc", value: "recordings+artist-credits+labels+genres+release-groups"),
            URLQueryItem(name: "fmt", value: "json"),
        ])
        return release.asLookupRelease()
    }

    // MARK: - Intern

    /// Lucene-Sonderzeichen maskieren, sonst zerlegt ein Titel wie
    /// „Best of (Live)" die Abfrage.
    private func escape(_ text: String) -> String {
        var escaped = ""
        for character in text {
            if #"+-&|!(){}[]^"~*?:\/"#.contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    /// MusicBrainz antwortet bei Überlast mit 503 und erwartet, dass der
    /// Aufrufer es gleich noch einmal versucht. Ein einzelner 503 ist also
    /// kein Fehler, sondern eine Bitte um Geduld.
    private func get<T: Decodable>(_ path: String, items: [URLQueryItem],
                                   attempt: Int = 1) async throws -> T {
        do {
            return try await perform(path, items: items)
        } catch MusicBrainzClient.ClientError.busy where attempt < 3 {
            try? await Task.sleep(for: .seconds(attempt))
            return try await get(path, items: items, attempt: attempt + 1)
        }
    }

    private func perform<T: Decodable>(_ path: String, items: [URLQueryItem]) async throws -> T {
        await limiter.acquire()

        var components = URLComponents(
            url: Self.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = items

        var request = URLRequest(url: components.url!)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ClientError.transport(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200..<300: break
            case 404:       throw ClientError.notFound
            case 503:       throw ClientError.busy   // zu schnell gefragt
            default:        throw ClientError.server(http.statusCode)
            }
        }

        do {
            return try JSONDecoder().decode(
                T.self, from: JSONSanitizer.escapingControlCharactersInStrings(data))
        } catch {
            throw ClientError.decoding
        }
    }
}
