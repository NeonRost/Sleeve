//
//  PatternTests.swift
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
//  Pattern engine in both directions, capitalization, numbering (§4.2–4.4).
//  The German test data is deliberate: umlauts and ß are what breaks taggers.
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
        check(actual == expected, label, detail: "is \(actual), expected \(expected)")
    }

    static func section(_ title: String) { print("\n━━ \(title)") }

    /// Clicking placeholders instead of typing — nothing may stick together.
    static func tokenAppending() {
        print("\n— Appending placeholders —")
        equal(PatternToken.track.appended(to: ""), "%track%",
              "into the empty pattern without a separator")
        equal(PatternToken.title.appended(to: "%track%"), "%track% - %title%",
              "a separator goes between two placeholders")
        equal(PatternToken.title.appended(to: "%track% - "), "%track% - %title%",
              "an existing separator is not doubled")
        equal(PatternToken.title.appended(to: "%track%_"), "%track%_%title%",
              "underscore counts as a separator")
        equal(PatternToken.year.appended(to: "%album% ("), "%album% (%year%",
              "an opening parenthesis counts as a separator")
        equal(PatternToken.artist.appended(to: "Best of"), "Best of - %artist%",
              "after free text too")
    }

    static func run() -> Int32 {
        tokenAppending()
        let renderer = PatternRenderer()

        var full = AudioTags()
        full.artist = "Böhse Mädelz"
        full.album = "Einzelfälle"
        full.title = "Haut bloß ab"
        full.trackNumber = 3
        full.discNumber = 1
        full.year = 1987
        full.genre = "Punk"

        // MARK: - Tags → file name

        section("Rendering")
        equal(renderer.render("%track% - %artist% - %title%", tags: full),
              "03 - Böhse Mädelz - Haut bloß ab", "leading zeros and separators")
        equal(renderer.render("%artist%/%album%/%track% - %title%", tags: full),
              "Böhse Mädelz_Einzelfälle_03 - Haut bloß ab",
              "slashes are replaced, not turned into folders")

        var noArtist = full
        noArtist.artist = nil
        equal(renderer.render("%track% - %artist% - %title%", tags: noArtist),
              "03 - Haut bloß ab",
              "a missing tag takes its separator along (instead of \"03 -  - Title\")")

        var titleOnly = AudioTags()
        titleOnly.title = "Einzelstück"
        equal(renderer.render("%track% - %artist% - %title%", tags: titleOnly),
              "Einzelstück", "all leading groups drop out cleanly")

        var nasty = AudioTags()
        nasty.title = "AC/DC: Live?"
        nasty.trackNumber = 1
        equal(renderer.render("%track% - %title%", tags: nasty),
              "01 - AC_DC_ Live", "invalid characters replaced, edges cleaned up")

        var unpadded = PatternRenderer()
        unpadded.padsNumbers = false
        equal(unpadded.render("%track% - %title%", tags: full),
              "3 - Haut bloß ab", "leading zeros can be switched off")

        equal(renderer.render("100%% %title%", tags: titleOnly),
              "100% Einzelstück", "%% is a literal percent sign")

        section("Collisions")
        var a = AudioTags(); a.title = "Same"; a.trackNumber = 1
        var b = AudioTags(); b.title = "Same"; b.trackNumber = 1
        var c = AudioTags(); c.title = "Same"; c.trackNumber = 1
        let names = renderer.renderAll("%track% - %title%", for: [
            (URL(fileURLWithPath: "/tmp/x/a.mp3"), a),
            (URL(fileURLWithPath: "/tmp/x/b.mp3"), b),
            (URL(fileURLWithPath: "/tmp/y/c.mp3"), c),
        ])
        equal(names[0], "01 - Same.mp3", "the first keeps the name")
        equal(names[1], "01 - Same (2).mp3", "the second in the same folder gets (2)")
        equal(names[2], "01 - Same.mp3", "another folder is no collision")

        // MARK: - File name → tags

        section("Parsing")
        do {
            let parser = try PatternParser(pattern: "%track% - %artist% - %title%")
            let match = parser.match(URL(fileURLWithPath: "/m/03 - Böhse Mädelz - Haut bloß ab.mp3"))
            equal(match?.values[.trackNumber], "3", "track number without leading zero")
            equal(match?.values[.artist], "Böhse Mädelz", "artist")
            equal(match?.values[.title], "Haut bloß ab", "title")

            check(parser.match(URL(fileURLWithPath: "/m/whatever.mp3")) == nil,
                  "a non-matching name yields nil instead of guessing nonsense")
        } catch {
            check(false, "parser built", detail: "\(error)")
        }

        do {
            let parser = try PatternParser(pattern: "%artist%/%album%/%track% - %title%")
            let url = URL(fileURLWithPath: "/Music/Böhse Mädelz/Einzelfälle/03 - Haut bloß ab.mp3")
            equal(parser.subject(for: url), "Böhse Mädelz/Einzelfälle/03 - Haut bloß ab",
                  "folder names go into the text matched against")
            let match = parser.match(url)
            equal(match?.values[.artist], "Böhse Mädelz", "artist from the folder")
            equal(match?.values[.album], "Einzelfälle", "album from the folder")
            equal(match?.values[.title], "Haut bloß ab", "title from the file name")
        } catch {
            check(false, "folder parser built", detail: "\(error)")
        }

        do {
            _ = try PatternParser(pattern: "no token here")
            check(false, "a pattern without tokens throws")
        } catch {
            check(error as? PatternParser.ParserError == .noTokens,
                  "a pattern without tokens throws noTokens")
        }

        section("Round trip")
        do {
            let pattern = "%track% - %artist% - %title%"
            let name = renderer.render(pattern, tags: full) + ".mp3"
            let parser = try PatternParser(pattern: pattern)
            let match = parser.match(URL(fileURLWithPath: "/m/" + name))
            equal(match?.values[.artist], full.artist, "artist survives the round trip")
            equal(match?.values[.title], full.title, "title survives the round trip")
            equal(match?.values[.trackNumber], "3", "track number survives the round trip")
        } catch {
            check(false, "round trip", detail: "\(error)")
        }

        // MARK: - Capitalization

        section("Capitalization")
        equal(TextCase.upperCase.apply(to: "haut bloß ab"), "HAUT BLOSS AB",
              "UPPER CASE (ß becomes SS)")
        equal(TextCase.lowerCase.apply(to: "HAUT BLOSS AB"), "hauT bloss ab".lowercased(),
              "lower case")
        equal(TextCase.titleCase.apply(to: "the dark side of the moon", language: .english),
              "The Dark Side of the Moon", "Title Case with the English exception list")
        equal(TextCase.titleCase.apply(to: "der wind der weht", language: .german),
              "Der Wind der Weht", "German Title Case — the last word stays capitalized")
        equal(TextCase.titleCase.apply(to: "LIVE (at the bbc)", language: .english),
              "Live (At the Bbc)", "parentheses are handled")
        equal(TextCase.titleCase.apply(to: "a", language: .english), "A",
              "a single word stays capitalized")

        replacing()

        print("\n\(checks - failures)/\(checks) checks passed")
        if failures > 0 {
            print("✗ \(failures) failed")
            return 1
        }
        print("✓ All green.")
        return 0
    }

    // MARK: - Find and replace

    static func replacing() {
        section("Find and replace")
        func run(_ r: TextReplacement, _ text: String) -> String? { try? r.apply(to: text) }

        var feat = TextReplacement(find: "feat.", replacement: "ft.")
        equal(run(feat, "Song (feat. Someone)"), "Song (ft. Someone)", "plain text is replaced")
        equal(run(feat, "Song (FEAT. Someone)"), "Song (ft. Someone)", "ignoring case by default")
        feat.matchesCase = true
        equal(run(feat, "Song (FEAT. Someone)"), nil, "with match case no hit, and nil says so")
        equal(run(TextReplacement(find: "x", replacement: "y"), "abc"), nil,
              "no match yields nil, not the unchanged text")

        let dot = TextReplacement(find: "a.c", replacement: "-")
        equal(run(dot, "abc a.c"), "abc -", "without regex a dot is just a dot")
        let dollar = TextReplacement(find: "Live", replacement: "$1 (Live)")
        equal(run(dollar, "Live"), "$1 (Live)", "without regex $1 is literal text")

        let remove = TextReplacement(find: "(Remastered 2011)")
        equal(run(remove, "Song (Remastered 2011)"), "Song",
              "removing leaves no trailing space")
        equal(run(remove, "(Remastered 2011) Song  Two"), "Song Two",
              "nor a leading one, and doubled spaces collapse")
        equal(run(TextReplacement(find: "Song"), "Song"), "",
              "a field can be replaced down to nothing")

        var regex = TextReplacement(find: #"\s*\((Live|Remastered)[^)]*\)"#,
                                    usesRegularExpression: true)
        equal(run(regex, "Song (Live at Wembley)"), "Song", "regular expression")
        regex = TextReplacement(find: #"^(\d+)\. "#, replacement: "$1 - ", usesRegularExpression: true)
        equal(run(regex, "03. Song"), "03 - Song", "groups via $1")

        let broken = TextReplacement(find: "(unclosed", usesRegularExpression: true)
        check(broken.validate() != nil, "an invalid regular expression is reported")
        check((try? broken.apply(to: "x")) == nil, "and throws instead of replacing")
        check(TextReplacement(find: "(unclosed").validate() == nil,
              "the same text without regex is fine")
        check(TextReplacement().isEmpty, "nothing to find, nothing to do")
        equal(run(TextReplacement(), "abc"), nil, "an empty search changes nothing")
    }
}
