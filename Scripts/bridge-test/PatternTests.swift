//
//  PatternTests.swift
//
//  Pattern-Engine in beide Richtungen, Schreibweise, Nummerierung (§4.2–4.4).
//

import Foundation

enum PatternTests {

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

    /// Platzhalter anklicken statt tippen — dabei darf nichts zusammenkleben.
    static func tokenAppending() {
        print("\n— Platzhalter anhängen —")
        equal(PatternToken.track.appended(to: ""), "%track%",
              "ins leere Muster ohne Trennzeichen")
        equal(PatternToken.title.appended(to: "%track%"), "%track% - %title%",
              "zwischen zwei Platzhalter kommt ein Trennzeichen")
        equal(PatternToken.title.appended(to: "%track% - "), "%track% - %title%",
              "ein vorhandenes Trennzeichen wird nicht verdoppelt")
        equal(PatternToken.title.appended(to: "%track%_"), "%track%_%title%",
              "Unterstrich gilt als Trennzeichen")
        equal(PatternToken.year.appended(to: "%album% ("), "%album% (%year%",
              "offene Klammer gilt als Trennzeichen")
        equal(PatternToken.artist.appended(to: "Best of"), "Best of - %artist%",
              "auch hinter freiem Text")
    }

    static func run() -> Int32 {
        tokenAppending()
        let renderer = PatternRenderer()

        var voll = AudioTags()
        voll.artist = "Böhse Mädelz"
        voll.album = "Einzelfälle"
        voll.title = "Haut bloß ab"
        voll.trackNumber = 3
        voll.discNumber = 1
        voll.year = 1987
        voll.genre = "Punk"

        // MARK: - Tags → Dateiname

        section("Rendern")
        equal(renderer.render("%track% - %artist% - %title%", tags: voll),
              "03 - Böhse Mädelz - Haut bloß ab", "Führende Nullen und Trenner")
        equal(renderer.render("%artist%/%album%/%track% - %title%", tags: voll),
              "Böhse Mädelz_Einzelfälle_03 - Haut bloß ab",
              "Schrägstriche werden ersetzt, nicht zu Ordnern")

        var ohneArtist = voll
        ohneArtist.artist = nil
        equal(renderer.render("%track% - %artist% - %title%", tags: ohneArtist),
              "03 - Haut bloß ab",
              "Fehlender Tag nimmt sein Trennzeichen mit (statt „03 -  - Titel\")")

        var nurTitel = AudioTags()
        nurTitel.title = "Einzelstück"
        equal(renderer.render("%track% - %artist% - %title%", tags: nurTitel),
              "Einzelstück", "Alle führenden Gruppen entfallen sauber")

        var boese = AudioTags()
        boese.title = "AC/DC: Live?"
        boese.trackNumber = 1
        equal(renderer.render("%track% - %title%", tags: boese),
              "01 - AC_DC_ Live", "Ungültige Zeichen ersetzt, Rand aufgeräumt")

        var ohnePad = PatternRenderer()
        ohnePad.padsNumbers = false
        equal(ohnePad.render("%track% - %title%", tags: voll),
              "3 - Haut bloß ab", "Führende Nullen abschaltbar")

        equal(renderer.render("100%% %title%", tags: nurTitel),
              "100% Einzelstück", "%% ist ein wörtliches Prozentzeichen")

        section("Kollisionen")
        var a = AudioTags(); a.title = "Gleich"; a.trackNumber = 1
        var b = AudioTags(); b.title = "Gleich"; b.trackNumber = 1
        var c = AudioTags(); c.title = "Gleich"; c.trackNumber = 1
        let namen = renderer.renderAll("%track% - %title%", for: [
            (URL(fileURLWithPath: "/tmp/x/a.mp3"), a),
            (URL(fileURLWithPath: "/tmp/x/b.mp3"), b),
            (URL(fileURLWithPath: "/tmp/y/c.mp3"), c),
        ])
        equal(namen[0], "01 - Gleich.mp3", "Erster behält den Namen")
        equal(namen[1], "01 - Gleich (2).mp3", "Zweiter im selben Ordner bekommt (2)")
        equal(namen[2], "01 - Gleich.mp3", "Anderer Ordner ist keine Kollision")

        // MARK: - Dateiname → Tags

        section("Parsen")
        do {
            let parser = try PatternParser(pattern: "%track% - %artist% - %title%")
            let match = parser.match(URL(fileURLWithPath: "/m/03 - Böhse Mädelz - Haut bloß ab.mp3"))
            equal(match?.values[.trackNumber], "3", "Tracknummer ohne führende Null")
            equal(match?.values[.artist], "Böhse Mädelz", "Interpret")
            equal(match?.values[.title], "Haut bloß ab", "Titel")

            check(parser.match(URL(fileURLWithPath: "/m/irgendwas.mp3")) == nil,
                  "Nicht passender Name liefert nil, statt Unsinn zu raten")
        } catch {
            check(false, "Parser gebaut", detail: "\(error)")
        }

        do {
            let parser = try PatternParser(pattern: "%artist%/%album%/%track% - %title%")
            let url = URL(fileURLWithPath: "/Musik/Böhse Mädelz/Einzelfälle/03 - Haut bloß ab.mp3")
            equal(parser.subject(for: url), "Böhse Mädelz/Einzelfälle/03 - Haut bloß ab",
                  "Ordnernamen kommen in den Vergleichstext")
            let match = parser.match(url)
            equal(match?.values[.artist], "Böhse Mädelz", "Interpret aus dem Ordner")
            equal(match?.values[.album], "Einzelfälle", "Album aus dem Ordner")
            equal(match?.values[.title], "Haut bloß ab", "Titel aus dem Dateinamen")
        } catch {
            check(false, "Ordner-Parser gebaut", detail: "\(error)")
        }

        do {
            _ = try PatternParser(pattern: "kein token hier")
            check(false, "Pattern ohne Token wirft")
        } catch {
            check(error as? PatternParser.ParserError == .noTokens,
                  "Pattern ohne Token wirft noTokens")
        }

        section("Hin und zurück")
        do {
            let pattern = "%track% - %artist% - %title%"
            let name = renderer.render(pattern, tags: voll) + ".mp3"
            let parser = try PatternParser(pattern: pattern)
            let match = parser.match(URL(fileURLWithPath: "/m/" + name))
            equal(match?.values[.artist], voll.artist, "Interpret überlebt den Rundlauf")
            equal(match?.values[.title], voll.title, "Titel überlebt den Rundlauf")
            equal(match?.values[.trackNumber], "3", "Tracknummer überlebt den Rundlauf")
        } catch {
            check(false, "Rundlauf", detail: "\(error)")
        }

        // MARK: - Schreibweise

        section("Schreibweise")
        equal(TextCase.upperCase.apply(to: "haut bloß ab"), "HAUT BLOSS AB",
              "GROSSBUCHSTABEN (ß wird SS)")
        equal(TextCase.lowerCase.apply(to: "HAUT BLOSS AB"), "hauT bloss ab".lowercased(),
              "kleinschreibung")
        equal(TextCase.titleCase.apply(to: "the dark side of the moon", language: .english),
              "The Dark Side of the Moon", "Title Case mit englischer Ausnahmeliste")
        equal(TextCase.titleCase.apply(to: "der wind der weht", language: .german),
              "Der Wind der Weht", "Title Case deutsch — letztes Wort bleibt groß")
        equal(TextCase.titleCase.apply(to: "LIVE (at the bbc)", language: .english),
              "Live (At the Bbc)", "Klammern werden mitgenommen")
        equal(TextCase.titleCase.apply(to: "a", language: .english), "A",
              "Einzelnes Wort bleibt groß")

        print("\n\(checks - failures)/\(checks) Prüfungen bestanden")
        if failures > 0 {
            print("✗ \(failures) fehlgeschlagen")
            return 1
        }
        print("✓ Alles grün.")
        return 0
    }
}
