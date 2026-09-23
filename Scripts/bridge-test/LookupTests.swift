//
//  LookupTests.swift
//
//  Discogs-Lookup (§4.6). Geprüft wird gegen echte API-Antworten, die im
//  Ordner `fixtures/` liegen — kein Netz im Testlauf.
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
        check(actual == expected, label, detail: "ist \(actual), erwartet \(expected)")
    }

    static func section(_ title: String) { print("\n━━ \(title)") }

    static func fixture(_ name: String) throws -> Data {
        let path = FileManager.default.currentDirectoryPath
            + "/Scripts/bridge-test/fixtures/\(name).json"
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    static func run() async throws -> Int32 {

        // MARK: - Steuerzeichen

        section("Steuerzeichen in der Antwort")
        let roh = try fixture("release-control-chars")
        check(roh.filter { $0 < 0x20 }.count > 0, "Antwort enthält rohe Steuerzeichen",
              detail: "\(roh.filter { $0 < 0x20 }.count) Stück")

        // JSONDecoder prüft faul: er stolpert nur über das Steuerzeichen, wenn
        // ein deklariertes Feld es tatsächlich liest. Damit hängt es vom Modell
        // ab, ob dieselbe Antwort durchgeht — genau deshalb wird begradigt.
        struct MitNotes: Decodable { let id: Int; let notes: String? }
        struct OhneNotes: Decodable { let id: Int }
        check((try? JSONDecoder().decode(OhneNotes.self, from: roh)) != nil,
              "Modell ohne das betroffene Feld liest die Rohdaten klaglos")
        check((try? JSONDecoder().decode(MitNotes.self, from: roh)) == nil,
              "Sobald das Feld deklariert ist, scheitert dieselbe Antwort")
        check((try? JSONDecoder().decode(
                MitNotes.self,
                from: JSONSanitizer.escapingControlCharactersInStrings(roh))) != nil,
              "Nach dem Begradigen geht auch das")

        let begradigt = JSONSanitizer.escapingControlCharactersInStrings(roh)
        let release = try JSONDecoder().decode(DiscogsRelease.self, from: begradigt)
        check(true, "Nach dem Begradigen lesbar: \(release.title)")
        equal(release.id, 82730, "ID stimmt")
        check(!release.playableTracks.isEmpty, "Tracks gelesen",
              detail: "\(release.playableTracks.count)")

        // Der Sanitizer darf nichts anderes anfassen.
        let bereitsEscaped = Data(#"{"a":"Zeile\nUmbruch","b":"Backslash\\","c":"Quote\""}"#.utf8)
        equal(JSONSanitizer.escapingControlCharactersInStrings(bereitsEscaped), bereitsEscaped,
              "Korrektes JSON bleibt unverändert")

        let mitLeerraum = Data("{\n  \"a\" : \"x\"\n}".utf8)
        equal(JSONSanitizer.escapingControlCharactersInStrings(mitLeerraum), mitLeerraum,
              "Steuerzeichen außerhalb von Zeichenketten bleiben stehen")

        struct Probe: Decodable { let a: String }
        let kaputt = Data("{\"a\":\"vor\rnach\"}".utf8)
        check((try? JSONDecoder().decode(Probe.self, from: kaputt)) == nil,
              "Rohes \\r scheitert ohne Sanitizer")
        let repariert = try JSONDecoder().decode(
            Probe.self, from: JSONSanitizer.escapingControlCharactersInStrings(kaputt))
        equal(repariert.a, "vor\rnach", "Mit Sanitizer lesbar, Inhalt erhalten")

        // MARK: - Echtes Release

        section("Echte Antwort lesen")
        let simple = try JSONDecoder().decode(
            DiscogsRelease.self,
            from: JSONSanitizer.escapingControlCharactersInStrings(try fixture("release-simple")))
        equal(simple.title, "Never Gonna Give You Up", "Titel")
        equal(simple.albumArtist, "Rick Astley", "Album-Interpret")
        equal(simple.year, 1987, "Jahr")
        equal(simple.playableTracks.count, 2, "Zwei Stücke")
        equal(simple.labelSummary, "RCA · PB 41447", "Label und Katalognummer")
        let simpleNeutral = simple.asLookupRelease()
        equal(GenreSource.style.value(from: simpleNeutral), "Euro-Disco", "Style bevorzugt")
        equal(GenreSource.genre.value(from: simpleNeutral), "Electronic; Pop", "Genre wahlweise")
        equal(GenreSource.both.value(from: simpleNeutral), "Electronic; Pop; Euro-Disco",
              "Beides kombiniert")

        // MARK: - Eigenheiten

        section("Discogs-Eigenheiten")
        let tricky = try JSONDecoder().decode(DiscogsRelease.self, from: try fixture("release-tricky"))

        equal(tricky.tracklist?.count, 6, "Sechs Einträge in der Tracklist")
        equal(tricky.playableTracks.count, 4, "Überschrift und Index-Eintrag sind raus")
        check(!tricky.playableTracks.contains { $0.title == "Medley" },
              "Index-Eintrag ohne Position übersprungen")

        let fernVorschau = tricky.asLookupRelease().tracks
        equal(tricky.albumArtist, "Nirvana & Die Ärzte, Queen Featuring",
              "Mehrere Künstler zusammengesetzt, Suffix „(2)\" entfernt")
        equal(fernVorschau[1].artistName, "Böhse Mädelz Feat. NeonRost",
              "Track-eigene Künstler mit join")

        equal(TrackPosition.parse("1-3"), TrackPosition(disc: 1, number: 3), "Position „1-3\"")
        equal(TrackPosition.parse("CD2-4"), TrackPosition(disc: 2, number: 4), "Position „CD2-4\"")
        equal(TrackPosition.parse("2.5"), TrackPosition(disc: 2, number: 5), "Position „2.5\"")
        equal(TrackPosition.parse("12"), TrackPosition(disc: nil, number: 12), "Reine Nummer")
        equal(TrackPosition.parse("B2"), TrackPosition(disc: nil, number: nil), "Vinylseite")
        equal(TrackPosition.parse(nil), TrackPosition(), "Ohne Angabe")
        equal(tricky.discCount, 2, "Doppel-CD erkannt")

        // MARK: - Zuordnung

        section("Zuordnung")
        func lokal(_ titles: [String?]) -> [ReleaseMatcher.LocalTrack] {
            titles.enumerated().map {
                ReleaseMatcher.LocalTrack(id: UUID(), title: $0.element,
                                          filename: "\($0.offset + 1).mp3")
            }
        }

        let trickyNeutral = tricky.asLookupRelease()
        let fern = trickyNeutral.tracks
        let vier = lokal(["Erstes Stück", "Zweites Stück", "Drittes Stück", "Viertes Stück"])
        equal(ReleaseMatcher.suggest(local: vier, remote: fern),
              [0, 1, 2, 3], "Gleiche Anzahl, gleiche Reihenfolge")

        let ohneTitel = lokal([nil, nil, nil, nil])
        equal(ReleaseMatcher.suggest(local: ohneTitel, remote: fern),
              [0, 1, 2, 3], "Ohne Titel gilt die Reihenfolge")

        // Bonustrack am Ende: die vier bekannten müssen trotzdem sitzen.
        let mitBonus = lokal(["Erstes Stück", "Zweites Stück", "Drittes Stück",
                              "Viertes Stück", "Bonus aus der Radiosendung"])
        let bonusPaarung = ReleaseMatcher.suggest(local: mitBonus, remote: fern)
        equal(Array(bonusPaarung.prefix(4)), [0, 1, 2, 3], "Bekannte Stücke sitzen")
        equal(bonusPaarung[4], nil, "Bonustrack bleibt ohne Gegenstück")

        // Vertauschte Reihenfolge — hier muss der Titelabgleich greifen.
        let vertauscht = lokal(["Viertes Stück", "Erstes Stück", "Drittes Stück", "Zweites Stück"])
        equal(ReleaseMatcher.suggest(local: vertauscht, remote: fern),
              [3, 0, 2, 1], "Vertauschte Dateien werden über den Titel zugeordnet")

        equal(ReleaseMatcher.normalize("03 - Haut bloß ab!"), "haut bloß ab",
              "Normalisierung entfernt Tracknummer und Satzzeichen")
        check(ReleaseMatcher.similarity("Erstes Stück", "erstes stueck") < 1.0,
              "Ähnlichkeit ist kein blinder Gleichheitstest")
        check(ReleaseMatcher.similarity("Erstes Stück", "Erstes Stück") == 1.0, "Gleich ist 1.0")
        check(ReleaseMatcher.similarity("Erstes Stück", "Ganz was anderes") < 0.4,
              "Unterschiedliches bleibt unten")

        // MARK: - Vorgeschlagene Felder

        section("Vorgeschlagene Felder")
        let vorschlaege = ReleaseMatcher.proposals(
            release: trickyNeutral, local: vier,
            pairing: [0, 1, 2, 3], genreSource: .style)
        equal(vorschlaege.count, 4, "Ein Vorschlag je Datei")

        let erster = vorschlaege[0].values
        equal(erster[.title], "Erstes Stück", "Titel")
        equal(erster[.album], "Die Hüllen - Sampler", "Album")
        equal(erster[.albumArtist], "Nirvana & Die Ärzte, Queen Featuring", "Album-Interpret")
        equal(erster[.year], "1994", "Jahr")
        equal(erster[.genre], "Melodic Death Metal; Doom Metal", "Style statt Genre")
        equal(erster[.trackNumber], "1", "Tracknummer aus der Position")
        equal(erster[.discNumber], "1", "Discnummer aus der Position")
        equal(erster[.discTotal], "2", "Zwei Tonträger")
        equal(erster[.trackTotal], "2", "Zwei Stücke auf dieser Disc")

        let zweiter = vorschlaege[1].values
        equal(zweiter[.artist], "Böhse Mädelz Feat. NeonRost",
              "Track-eigener Künstler schlägt den Album-Interpreten")
        let dritter = vorschlaege[2].values
        equal(dritter[.discNumber], "2", "Zweite Disc")
        equal(dritter[.trackNumber], "1", "Auf Disc 2 wieder bei 1")

        // MARK: - MusicBrainz

        section("MusicBrainz — ohne Token")
        let mbRelease = try JSONDecoder().decode(
            MBRelease.self,
            from: JSONSanitizer.escapingControlCharactersInStrings(
                try fixture("musicbrainz-release")))
        let mbNeutral = mbRelease.asLookupRelease()
        equal(mbNeutral.title, "Whenever You Need Somebody", "Titel")
        equal(mbNeutral.albumArtist, "Rick Astley", "Interpret aus artist-credit")
        equal(mbNeutral.year, 1987, "Jahr aus dem Datum")
        equal(mbNeutral.country, "US", "Land")
        equal(mbNeutral.tracks.count, 10, "Zehn Stücke über alle Medien")
        equal(mbNeutral.tracks.first?.title, "Never Gonna Give You Up", "Erstes Stück")
        equal(mbNeutral.tracks.first?.number, 1, "Tracknummer")
        equal(mbNeutral.tracks.first?.duration, "3:37", "Dauer aus Millisekunden")
        equal(mbNeutral.provider, .musicBrainz, "Quelle vermerkt")
        check(mbNeutral.labelSummary?.contains("BMG") == true, "Label gelesen",
              detail: mbNeutral.labelSummary ?? "—")
        check(mbNeutral.thumbnailURL?.absoluteString.contains("coverartarchive.org") == true,
              "Cover kommt aus dem offenen Cover Art Archive")

        // MusicBrainz kennt keine Styles — die Wahl muss trotzdem etwas liefern.
        equal(GenreSource.style.value(from: mbNeutral), GenreSource.genre.value(from: mbNeutral),
              "Ohne Styles fällt die Style-Wahl auf Genres zurück")

        let mbSearch = try JSONDecoder().decode(
            MBSearchResponse.self, from: try fixture("musicbrainz-search"))
        let treffer = (mbSearch.releases ?? []).map { $0.asLookupSearchResult() }
        check(!treffer.isEmpty, "Suchtreffer gelesen", detail: "\(treffer.count)")
        check(treffer.first?.subtitle.contains("Rick Astley") == true,
              "Untertitel nennt den Interpreten", detail: treffer.first?.subtitle ?? "—")
        equal(treffer.first?.provider, .musicBrainz, "Quelle am Treffer vermerkt")

        equal(MusicBrainzClient.userAgent, "Sleeve/1.0 ( https://github.com/NeonRost/Sleeve )",
              "User-Agent nennt Anwendung und Kontakt")
        check(!LookupProvider.musicBrainz.needsToken, "MusicBrainz braucht keinen Token")
        check(LookupProvider.discogs.needsToken, "Discogs schon")

        // Beide Quellen durch denselben Matcher.
        let mbLokal = lokal(mbNeutral.tracks.map(\.title))
        equal(ReleaseMatcher.suggest(local: mbLokal, remote: mbNeutral.tracks),
              Array(0..<mbNeutral.tracks.count), "Derselbe Matcher trägt beide Quellen")

        // MARK: - Rate-Limit

        section("Rate-Limit")
        let limiter = RateLimiter(limit: 3, per: .milliseconds(400))
        let start = ContinuousClock().now
        for _ in 0..<3 { await limiter.acquire() }
        let nachDrei = ContinuousClock().now - start
        check(nachDrei < .milliseconds(100), "Die ersten drei gehen sofort durch",
              detail: "\(nachDrei)")

        await limiter.acquire()   // die vierte muss warten
        let nachVier = ContinuousClock().now - start
        check(nachVier >= .milliseconds(380), "Die vierte wartet auf das Fenster",
              detail: "\(nachVier)")

        let discogs = RateLimiter.forDiscogs(authenticated: true)
        check(await discogs.currentLoad == 0, "Frischer Limiter ist leer")

        // MARK: - Client ohne Token

        section("Client")
        let client = DiscogsClient(token: nil)
        check(!(await client.hasToken), "Ohne Token als solcher erkannt")
        do {
            _ = try await client.search(.init(artist: "egal"))
            check(false, "Suche ohne Token wirft")
        } catch let error as DiscogsClient.ClientError {
            equal(error, .missingToken, "Suche ohne Token meldet fehlenden Token")
        }
        await client.updateToken("  ")
        check(!(await client.hasToken), "Leerraum gilt nicht als Token")
        await client.updateToken("abc123")
        check(await client.hasToken, "Echter Token wird übernommen")
        equal(DiscogsClient.userAgent, "Sleeve/1.0 +https://github.com/NeonRost/Sleeve",
              "User-Agent wie in der Spec")

        await sharedSearch()

        print("\n\(checks - failures)/\(checks) Prüfungen bestanden")
        if failures > 0 {
            print("✗ \(failures) fehlgeschlagen")
            return 1
        }
        print("✓ Alles grün.")
        return 0
    }

    // MARK: - Gemeinsame Suche

    /// „Album nachschlagen" und „Titel nachschlagen" teilen sich die Suche.
    /// Geprüft ohne Netz: die Antworten kommen aus `fixtures/`.
    @MainActor
    static func sharedSearch() async {
        section("Gemeinsame Suche beider Blätter")
        equal(LookupProvider.preferred(hasDiscogsToken: false), .musicBrainz,
              "Ohne Token ist MusicBrainz die Vorgabe")
        equal(LookupProvider.preferred(hasDiscogsToken: true), .discogs,
              "Mit Token Discogs — in beiden Blättern")

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
        check(search.canSearch, "Mit Suchbegriff und ohne Sperre darf gesucht werden")
        await search.search()
        check(!search.results.isEmpty, "Treffer aus der Suche", detail: "\(search.results.count)")
        check(search.message == nil, "Keine Meldung, wenn etwas gefunden wurde")

        // Die Dateien: die Titel des Albums, eine davon zehn Sekunden zu lang.
        guard let data = try? fixture("musicbrainz-release"),
              let album = try? JSONDecoder().decode(
                MBRelease.self, from: JSONSanitizer.escapingControlCharactersInStrings(data))
                .asLookupRelease()
        else { check(false, "Fixture lesbar"); return }
        let dateien = album.tracks.enumerated().map { index, track in
            ReleaseMatcher.LocalTrack(
                id: UUID(), title: track.title, filename: "\(index + 1).mp3",
                duration: (track.duration.flatMap(Timecode.parse) ?? 0) + (index == 3 ? 10 : 0.4))
        }
        let session = LookupSession(search: search, local: dateien, genreSource: .style)
        equal(session.matchedCount, 0, "Ohne gewähltes Album ist nichts zugeordnet")

        await search.select(search.results[0].id)
        check(search.release != nil, "Treffer gewählt, Album geladen")
        equal(search.selectedID, search.results[0].id, "Der Treffer bleibt markiert")
        equal(session.matchedCount, dateien.count, "Die Zuordnung folgt dem geladenen Album")
        equal(session.remoteDuration(for: 0), 217, "Länge des zugeordneten Tracks in Sekunden")
        equal(session.deviationCount, 1,
              "Genau die Datei, die zehn Sekunden abweicht, fällt auf — 0,4 s nicht")
        check(!session.proposals().isEmpty, "Vorschläge zum Übernehmen")

        session.assign(remoteIndex: nil, toLocal: 3)
        equal(session.matchedCount, dateien.count - 1, "Von Hand gelöst")
        equal(session.deviationCount, 0, "Ohne Zuordnung keine Abweichung")

        await search.select(nil)
        check(search.release == nil, "Auswahl aufgehoben, Album weg")
        equal(session.matchedCount, 0, "…und mit ihm die Zuordnung")

        let bisher = FixtureProtocol.requests
        await search.switchProvider(to: .discogs)
        equal(search.provider, .discogs, "Quelle gewechselt")
        check(search.results.isEmpty, "Treffer der anderen Quelle sind weg")
        check(search.providerBlocker != nil, "Ohne Token: Hinweis statt Suche")
        check(!search.canSearch, "Suchen gesperrt")
        equal(FixtureProtocol.requests, bisher, "Und es ging keine Anfrage raus")

        await search.switchProvider(to: .musicBrainz)
        check(!search.results.isEmpty, "Zurück bei MusicBrainz wird gleich neu gesucht")

        search.query = DiscogsClient.SearchQuery()
        check(!search.canSearch, "Ohne Suchbegriff kein Suchen")

        check(!LookupComparison.deviates(200, from: 203), "3 s gelten noch als passend")
        check(LookupComparison.deviates(200, from: 203.5), "darüber nicht")
        check(!LookupComparison.deviates(nil, from: 200), "Ohne eigene Länge keine Abweichung")
    }
}

/// Beantwortet MusicBrainz-Anfragen aus `fixtures/`: die Suche mit der
/// gespeicherten Trefferliste, jeden Albumabruf mit dem gespeicherten Album.
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
