//
//  MusicBrainzClient.swift
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
//  The lookup source without a token (spec §4.6, §6.2).
//
//  MusicBrainz requires no account and no key — only a meaningful
//  User-Agent and **at most one request per second**. Whoever asks faster
//  gets 503.
//

import Foundation

// MARK: - Response structures

struct MBArtistCredit: Decodable, Sendable {
    struct Artist: Decodable, Sendable { var name: String? }
    /// The spelling credited for this release.
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

/// At MusicBrainz, genres hardly ever hang off the individual release
/// but off the release group. Measured: even "Nevermind" has none on the
/// release and seven on the group. Without this detour the genre field
/// would almost always stay empty.
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

/// Which pictures the Cover Art Archive holds for a release.
struct MBCoverArtArchive: Decodable, Sendable {
    var front: Bool?
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
    var coverArtArchive: MBCoverArtArchive?

    enum CodingKeys: String, CodingKey {
        case id, title, date, country, media, genres, disambiguation
        case artistCredit = "artist-credit"
        case releaseGroup = "release-group"
        case labelInfo = "label-info"
        case coverArtArchive = "cover-art-archive"
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

    /// The Cover Art Archive is open and needs no key either.
    var coverURL: URL? {
        URL(string: "https://coverartarchive.org/release/\(id)/front-250")
    }

    /// The largest ready-made size of the Cover Art Archive. The original can
    /// be several megabytes — too much for every track of an album. Only
    /// where the release says it has a front cover; search results do not
    /// say, the full release does.
    var largeCoverURL: URL? {
        guard coverArtArchive?.front == true else { return nil }
        return URL(string: "https://coverartarchive.org/release/\(id)/front-1200")
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
            // Look at the release first, then at the group — that is where they
            // usually are.
            genres: {
                let own = (genres ?? []).compactMap(\.name)
                return own.isEmpty ? (releaseGroup?.genres ?? []).compactMap(\.name) : own
            }(),
            styles: [],
            thumbnailURL: coverArtArchive?.front == false ? nil : coverURL,
            coverURL: largeCoverURL,
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

/// Response of the disc ID query.
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

    /// MusicBrainz requires the application name, version and a way to get
    /// in touch. A generic User-Agent gets blocked.
    static let userAgent = "Sleeve/1.0 ( https://github.com/NeonRost/Sleeve )"

    private static let baseURL = URL(string: "https://musicbrainz.org/ws/2")!

    private let session: URLSession
    /// One request per second — that is the documented limit.
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

    /// Searches via the disc ID. That is the exact route: the identifier
    /// follows from the TOC and thus hits **this** pressing, not just an album
    /// of the same name. An empty result means: not registered.
    func releases(discID: String) async throws -> [LookupRelease] {
        do {
            let response: MBDiscResponse = try await get("/discid/\(discID)", items: [
                URLQueryItem(name: "inc", value: "recordings+artist-credits+labels+genres+release-groups"),
                URLQueryItem(name: "fmt", value: "json"),
            ])
            return (response.releases ?? []).map { $0.asLookupRelease() }
        } catch ClientError.notFound {
            // For a disc ID, "unknown" is an answer, not an error.
            return []
        }
    }

    /// Fallback when the disc ID is not registered: MusicBrainz can also
    /// search by the raw TOC. That is less exact — pressings with slightly
    /// different track lengths come along — and therefore returns several
    /// candidates to choose from.
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

    // MARK: - Internal

    /// Escape Lucene special characters, or a title like "Best of (Live)"
    /// breaks the query apart.
    private func escape(_ text: String) -> String {
        var escaped = ""
        for character in text {
            if #"+-&|!(){}[]^"~*?:\/"#.contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    /// Downloads a cover from the Cover Art Archive. That is a service of its
    /// own with its own limits, so the one-request-per-second rule of the
    /// MusicBrainz API does not apply; redirects to archive.org are followed
    /// by URLSession.
    func imageData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ClientError.transport(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw http.statusCode == 404 ? ClientError.notFound : ClientError.server(http.statusCode)
        }
        return data
    }

    /// When overloaded, MusicBrainz answers with 503 and expects the caller
    /// to try again right away. A single 503 is therefore not an error but a
    /// request for patience.
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
            case 503:       throw ClientError.busy   // asked too fast
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
