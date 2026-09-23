//
//  LookupTests.swift
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
//  Lookup (§4.6). Checked against real API responses stored in the
//  `fixtures/` folder — no network during the test run. The German titles in
//  the made-up Discogs fixture are deliberate: umlauts break matching first.
//

import Foundation

enum LookupTests {

    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var checks = 0

    static func check(_ condition: Bool, _ label: String, detail: @autoclosure () -> String = "") {
        checks += 1
        if condition {
            print("  ✓ \(label)")
        } else {
            failures += 1
            let extra = detail()
            print("  ✗ \(label)\(extra.isEmpty ? "" : " — \(extra)")")
        }
    }

    static func equal<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
        check(actual == expected, label, detail: "is \(actual), expected \(expected)")
    }

    static func section(_ title: String) { print("\n━━ \(title)") }

    static func fixture(_ name: String) throws -> Data {
        let path = FileManager.default.currentDirectoryPath
            + "/Scripts/bridge-test/fixtures/\(name).json"
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    static func run() async throws -> Int32 {

        // MARK: - Control characters

        section("Control characters in the response")
        let raw = try fixture("release-control-chars")
        check(raw.filter { $0 < 0x20 }.count > 0, "the response contains raw control characters",
              detail: "\(raw.filter { $0 < 0x20 }.count) of them")

        // JSONDecoder checks lazily: it only trips over the control character
        // if a declared field actually reads it. So whether the same response
        // gets through depends on the model — which is exactly why the bytes
        // are straightened.
        struct WithNotes: Decodable { let id: Int; let notes: String? }
        struct WithoutNotes: Decodable { let id: Int }
        check((try? JSONDecoder().decode(WithoutNotes.self, from: raw)) != nil,
              "a model without the affected field reads the raw data without complaint")
        check((try? JSONDecoder().decode(WithNotes.self, from: raw)) == nil,
              "as soon as the field is declared, the same response fails")
        check((try? JSONDecoder().decode(
                WithNotes.self,
                from: JSONSanitizer.escapingControlCharactersInStrings(raw))) != nil,
              "after straightening, that works too")

        let straightened = JSONSanitizer.escapingControlCharactersInStrings(raw)
        let release = try JSONDecoder().decode(DiscogsRelease.self, from: straightened)
        check(true, "readable after straightening: \(release.title)")
        equal(release.id, 82730, "the ID is right")
        check(!release.playableTracks.isEmpty, "tracks read",
              detail: "\(release.playableTracks.count)")

        // The sanitizer must not touch anything else.
        let alreadyEscaped = Data(#"{"a":"Line\nBreak","b":"Backslash\\","c":"Quote\""}"#.utf8)
        equal(JSONSanitizer.escapingControlCharactersInStrings(alreadyEscaped), alreadyEscaped,
              "correct JSON stays unchanged")

        let withWhitespace = Data("{\n  \"a\" : \"x\"\n}".utf8)
        equal(JSONSanitizer.escapingControlCharactersInStrings(withWhitespace), withWhitespace,
              "control characters outside of strings stay")

        struct Probe: Decodable { let a: String }
        let broken = Data("{\"a\":\"before\rafter\"}".utf8)
        check((try? JSONDecoder().decode(Probe.self, from: broken)) == nil,
              "a raw \\r fails without the sanitizer")
        let repaired = try JSONDecoder().decode(
            Probe.self, from: JSONSanitizer.escapingControlCharactersInStrings(broken))
        equal(repaired.a, "before\rafter", "readable with the sanitizer, content preserved")

        // MARK: - A real release

        section("Reading a real response")
        let simple = try JSONDecoder().decode(
            DiscogsRelease.self,
            from: JSONSanitizer.escapingControlCharactersInStrings(try fixture("release-simple")))
        equal(simple.title, "Never Gonna Give You Up", "title")
        equal(simple.albumArtist, "Rick Astley", "album artist")
        equal(simple.year, 1987, "year")
        equal(simple.playableTracks.count, 2, "two pieces")
        equal(simple.labelSummary, "RCA · PB 41447", "label and catalog number")
        let simpleNeutral = simple.asLookupRelease()
        equal(GenreSource.style.value(from: simpleNeutral), "Euro-Disco", "style preferred")
        equal(GenreSource.genre.value(from: simpleNeutral), "Electronic; Pop", "genre on request")
        equal(GenreSource.both.value(from: simpleNeutral), "Electronic; Pop; Euro-Disco",
              "both combined")

        // MARK: - Quirks

        section("Discogs quirks")
        let tricky = try JSONDecoder().decode(DiscogsRelease.self, from: try fixture("release-tricky"))

        equal(tricky.tracklist?.count, 6, "six entries in the track list")
        equal(tricky.playableTracks.count, 4, "heading and index entry are out")
        check(!tricky.playableTracks.contains { $0.title == "Medley" },
              "index entry without a position skipped")

        let remotePreview = tricky.asLookupRelease().tracks
        equal(tricky.albumArtist, "Nirvana & Die Ärzte, Queen Featuring",
              "several artists joined, suffix \"(2)\" removed")
        equal(remotePreview[1].artistName, "Böhse Mädelz Feat. NeonRost",
              "the track's own artists with join")

        equal(TrackPosition.parse("1-3"), TrackPosition(disc: 1, number: 3), "position \"1-3\"")
        equal(TrackPosition.parse("CD2-4"), TrackPosition(disc: 2, number: 4), "position \"CD2-4\"")
        equal(TrackPosition.parse("2.5"), TrackPosition(disc: 2, number: 5), "position \"2.5\"")
        equal(TrackPosition.parse("12"), TrackPosition(disc: nil, number: 12), "plain number")
        equal(TrackPosition.parse("B2"), TrackPosition(disc: nil, number: nil), "vinyl side")
        equal(TrackPosition.parse(nil), TrackPosition(), "without a value")
        equal(tricky.discCount, 2, "double CD recognized")

        // MARK: - Matching

        section("Matching")
        func localTracks(_ titles: [String?]) -> [ReleaseMatcher.LocalTrack] {
            titles.enumerated().map {
                ReleaseMatcher.LocalTrack(id: UUID(), title: $0.element,
                                          filename: "\($0.offset + 1).mp3")
            }
        }

        let trickyNeutral = tricky.asLookupRelease()
        let remote = trickyNeutral.tracks
        let four = localTracks(["Erstes Stück", "Zweites Stück", "Drittes Stück", "Viertes Stück"])
        equal(ReleaseMatcher.suggest(local: four, remote: remote),
              [0, 1, 2, 3], "same count, same order")

        let noTitles = localTracks([nil, nil, nil, nil])
        equal(ReleaseMatcher.suggest(local: noTitles, remote: remote),
              [0, 1, 2, 3], "without titles the order applies")

        // A bonus track at the end: the four known ones still have to fit.
        let withBonus = localTracks(["Erstes Stück", "Zweites Stück", "Drittes Stück",
                                     "Viertes Stück", "Bonus from the radio show"])
        let bonusPairing = ReleaseMatcher.suggest(local: withBonus, remote: remote)
        equal(Array(bonusPairing.prefix(4)), [0, 1, 2, 3], "known pieces fit")
        equal(bonusPairing[4], nil, "the bonus track stays without a counterpart")

        // Swapped order — here the title match has to take effect.
        let swapped = localTracks(["Viertes Stück", "Erstes Stück", "Drittes Stück", "Zweites Stück"])
        equal(ReleaseMatcher.suggest(local: swapped, remote: remote),
              [3, 0, 2, 1], "swapped files are matched by title")

        equal(ReleaseMatcher.normalize("03 - Haut bloß ab!"), "haut bloß ab",
              "normalization removes track number and punctuation")
        check(ReleaseMatcher.similarity("Erstes Stück", "erstes stueck") < 1.0,
              "similarity is no blind equality test")
        check(ReleaseMatcher.similarity("Erstes Stück", "Erstes Stück") == 1.0, "equal is 1.0")
        check(ReleaseMatcher.similarity("Erstes Stück", "Something else entirely") < 0.4,
              "different stays low")

        // MARK: - Proposed fields

        section("Proposed fields")
        let proposals = ReleaseMatcher.proposals(
            release: trickyNeutral, local: four,
            pairing: [0, 1, 2, 3], genreSource: .style)
        equal(proposals.count, 4, "one proposal per file")

        let first = proposals[0].values
        equal(first[.title], "Erstes Stück", "title")
        equal(first[.album], "Die Hüllen - Sampler", "album")
        equal(first[.albumArtist], "Nirvana & Die Ärzte, Queen Featuring", "album artist")
        equal(first[.year], "1994", "year")
        equal(first[.genre], "Melodic Death Metal; Doom Metal", "style instead of genre")
        equal(first[.trackNumber], "1", "track number from the position")
        equal(first[.discNumber], "1", "disc number from the position")
        equal(first[.discTotal], "2", "two media")
        equal(first[.trackTotal], "2", "two pieces on this disc")

        let second = proposals[1].values
        equal(second[.artist], "Böhse Mädelz Feat. NeonRost",
              "the track's own artist beats the album artist")
        let third = proposals[2].values
        equal(third[.discNumber], "2", "second disc")
        equal(third[.trackNumber], "1", "back at 1 on disc 2")

        // MARK: - MusicBrainz

        section("MusicBrainz — without a token")
        let mbRelease = try JSONDecoder().decode(
            MBRelease.self,
            from: JSONSanitizer.escapingControlCharactersInStrings(
                try fixture("musicbrainz-release")))
        let mbNeutral = mbRelease.asLookupRelease()
        equal(mbNeutral.title, "Whenever You Need Somebody", "title")
        equal(mbNeutral.albumArtist, "Rick Astley", "artist from artist-credit")
        equal(mbNeutral.year, 1987, "year from the date")
        equal(mbNeutral.country, "US", "country")
        equal(mbNeutral.tracks.count, 10, "ten pieces across all media")
        equal(mbNeutral.tracks.first?.title, "Never Gonna Give You Up", "first piece")
        equal(mbNeutral.tracks.first?.number, 1, "track number")
        equal(mbNeutral.tracks.first?.duration, "3:37", "duration from milliseconds")
        equal(mbNeutral.provider, .musicBrainz, "source noted")
        check(mbNeutral.labelSummary?.contains("BMG") == true, "label read",
              detail: mbNeutral.labelSummary ?? "—")
        check(mbNeutral.thumbnailURL?.absoluteString.contains("coverartarchive.org") == true,
              "the cover comes from the open Cover Art Archive")

        // MusicBrainz knows no styles — the choice still has to deliver something.
        equal(GenreSource.style.value(from: mbNeutral), GenreSource.genre.value(from: mbNeutral),
              "without styles the style choice falls back to genres")

        let mbSearch = try JSONDecoder().decode(
            MBSearchResponse.self, from: try fixture("musicbrainz-search"))
        let results = (mbSearch.releases ?? []).map { $0.asLookupSearchResult() }
        check(!results.isEmpty, "search results read", detail: "\(results.count)")
        check(results.first?.subtitle.contains("Rick Astley") == true,
              "the subtitle names the artist", detail: results.first?.subtitle ?? "—")
        equal(results.first?.provider, .musicBrainz, "source noted on the result")

        equal(MusicBrainzClient.userAgent, "Sleeve/1.0 ( https://github.com/NeonRost/Sleeve )",
              "the User-Agent names application and contact")
        check(!LookupProvider.musicBrainz.needsToken, "MusicBrainz needs no token")
        check(LookupProvider.discogs.needsToken, "Discogs does")

        // Both sources through the same matcher.
        let mbLocal = localTracks(mbNeutral.tracks.map(\.title))
        equal(ReleaseMatcher.suggest(local: mbLocal, remote: mbNeutral.tracks),
              Array(0..<mbNeutral.tracks.count), "the same matcher serves both sources")

        // MARK: - Rate limit

        section("Rate limit")
        let limiter = RateLimiter(limit: 3, per: .milliseconds(400))
        let start = ContinuousClock().now
        for _ in 0..<3 { await limiter.acquire() }
        let afterThree = ContinuousClock().now - start
        check(afterThree < .milliseconds(100), "the first three go through right away",
              detail: "\(afterThree)")

        await limiter.acquire()   // the fourth has to wait
        let afterFour = ContinuousClock().now - start
        check(afterFour >= .milliseconds(380), "the fourth waits for the window",
              detail: "\(afterFour)")

        let discogs = RateLimiter.forDiscogs(authenticated: true)
        check(await discogs.currentLoad == 0, "a fresh limiter is empty")

        // MARK: - Client without a token

        section("Client")
        let client = DiscogsClient(token: nil)
        check(!(await client.hasToken), "recognized as having no token")
        do {
            _ = try await client.search(.init(artist: "whatever"))
            check(false, "search without a token throws")
        } catch let error as DiscogsClient.ClientError {
            equal(error, .missingToken, "search without a token reports the missing token")
        }
        await client.updateToken("  ")
        check(!(await client.hasToken), "whitespace does not count as a token")
        await client.updateToken("abc123")
        check(await client.hasToken, "a real token is taken over")
        equal(DiscogsClient.userAgent, "Sleeve/1.0 +https://github.com/NeonRost/Sleeve",
              "User-Agent as in the spec")

        await sharedSearch()

        print("\n\(checks - failures)/\(checks) checks passed")
        if failures > 0 {
            print("✗ \(failures) failed")
            return 1
        }
        print("✓ All green.")
        return 0
    }

    // MARK: - Shared search

    /// "Look Up Album" and "Look Up Titles" share the search. Checked without
    /// network: the responses come from `fixtures/`.
    @MainActor
    static func sharedSearch() async {
        section("Search shared by both sheets")
        equal(LookupProvider.preferred(hasDiscogsToken: false), .musicBrainz,
              "without a token MusicBrainz is the default")
        equal(LookupProvider.preferred(hasDiscogsToken: true), .discogs,
              "with a token Discogs — in both sheets")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        let service = LookupService(
            discogs: DiscogsClient(token: nil),
            musicBrainz: MusicBrainzClient(session: URLSession(configuration: config)))
        FixtureProtocol.requests = 0

        var query = DiscogsClient.SearchQuery()
        query.artist = "Rick Astley"
        let search = ReleaseSearch(service: service, provider: .musicBrainz, query: query,
                                   hasDiscogsToken: false)
        check(search.canSearch, "with a search term and no lock, searching is allowed")
        await search.search()
        check(!search.results.isEmpty, "results from the search", detail: "\(search.results.count)")
        check(search.message == nil, "no message when something was found")

        // The files: the album's titles, one of them ten seconds too long.
        guard let data = try? fixture("musicbrainz-release"),
              let album = try? JSONDecoder().decode(
                MBRelease.self, from: JSONSanitizer.escapingControlCharactersInStrings(data))
                .asLookupRelease()
        else { check(false, "fixture readable"); return }
        let files = album.tracks.enumerated().map { index, track in
            ReleaseMatcher.LocalTrack(
                id: UUID(), title: track.title, filename: "\(index + 1).mp3",
                duration: (track.duration.flatMap(Timecode.parse) ?? 0) + (index == 3 ? 10 : 0.4))
        }
        let session = LookupSession(search: search, local: files, genreSource: .style)
        equal(session.matchedCount, 0, "without a selected album nothing is matched")

        await search.select(search.results[0].id)
        check(search.release != nil, "result selected, album loaded")
        equal(search.selectedID, search.results[0].id, "the result stays selected")
        equal(session.matchedCount, files.count, "the matching follows the loaded album")
        equal(session.remoteDuration(for: 0), 217, "length of the assigned track in seconds")
        equal(session.deviationCount, 1,
              "exactly the file ten seconds off stands out — 0.4 s does not")
        check(!session.proposals().isEmpty, "proposals to take over")

        session.assign(remoteIndex: nil, toLocal: 3)
        equal(session.matchedCount, files.count - 1, "unassigned by hand")
        equal(session.deviationCount, 0, "no assignment, no deviation")

        await search.select(nil)
        check(search.release == nil, "selection cleared, album gone")
        equal(session.matchedCount, 0, "…and with it the matching")

        let requestsSoFar = FixtureProtocol.requests
        await search.switchProvider(to: .discogs)
        equal(search.provider, .discogs, "source switched")
        check(search.results.isEmpty, "the other source's results are gone")
        check(search.providerBlocker != nil, "without a token: a hint instead of a search")
        check(!search.canSearch, "searching locked")
        equal(FixtureProtocol.requests, requestsSoFar, "and no request went out")

        await search.switchProvider(to: .musicBrainz)
        check(!search.results.isEmpty, "back at MusicBrainz a new search starts right away")

        search.query = DiscogsClient.SearchQuery()
        check(!search.canSearch, "no search term, no search")

        check(!LookupComparison.deviates(200, from: 203), "3 s still count as matching")
        check(LookupComparison.deviates(200, from: 203.5), "above that not")
        check(!LookupComparison.deviates(nil, from: 200), "without a length of one's own, no deviation")
    }
}

/// Answers MusicBrainz requests from `fixtures/`: the search with the stored
/// result list, every album request with the stored album.
final class FixtureProtocol: URLProtocol {
    nonisolated(unsafe) static var requests = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests += 1
        let path = request.url?.path ?? ""
        let name = path.hasSuffix("/release") || path.hasSuffix("/release/")
            ? "musicbrainz-search" : "musicbrainz-release"
        let data = (try? LookupTests.fixture(name)) ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
