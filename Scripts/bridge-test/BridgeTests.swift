//
//  BridgeTests.swift
//
//  Prüft TagLibBridge gegen TestFiles/ — immer auf Kopien, nie auf den
//  Originalen. Schritte 2 und 3 der Spec §8.
//

import Foundation

enum BridgeTests {

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

    static func run() throws -> Int32 {
        // MARK: - Umgebung

        let root = FileManager.default.currentDirectoryPath
        let testFiles = root + "/TestFiles"
        let workDir = NSTemporaryDirectory() + "sleeve-bridge-test-" + UUID().uuidString
        try! FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: workDir) }

        /// Arbeitskopie einer Testdatei.
        func copyOfTestFile(_ name: String) throws -> URL {
            let source = URL(fileURLWithPath: testFiles).appendingPathComponent(name)
            let target = URL(fileURLWithPath: workDir).appendingPathComponent(name)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: source, to: target)
            return target
        }

        // MARK: - 1. Lesen, alle drei Formate

        section("Lesen — MP3 mit vollem ID3v2.3")
        do {
            let url = try copyOfTestFile("01 - id3v2.3 - voll.mp3")
            let info = try TagLibBridge.read(from: url)
            let t = info.tags
            equal(t.title, "Tëst Träck 🎵", "Titel mit Umlaut und Emoji")
            equal(t.artist, "NeonRost", "Interpret")
            equal(t.albumArtist, "Various Artists", "Album-Interpret (TPE2)")
            equal(t.album, "Sleeve Demo", "Album")
            equal(t.composer, "J. S. Bach", "Komponist (TCOM)")
            equal(t.genre, "Melodic Death Metal", "Genre")
            equal(t.year, 1987, "Jahr")
            equal(t.trackNumber, 3, "Tracknummer aus \"3/12\"")
            equal(t.trackTotal, 12, "Trackgesamtzahl aus \"3/12\"")
            equal(t.discNumber, 1, "Discnummer aus \"1/2\" (TPOS)")
            equal(t.discTotal, 2, "Discgesamtzahl")
            equal(t.artwork.count, 1, "Ein Coverbild")
            equal(t.artwork.first?.mimeType, "image/jpeg", "Cover-MIME-Typ")
            equal(t.artwork.first?.pictureType, .frontCover, "Cover-Typ")
            check((t.artwork.first?.data.count ?? 0) > 1000, "Cover hat Inhalt",
                  detail: "\(t.artwork.first?.data.count ?? 0) Bytes")
            check(info.properties.sampleRate == 44100, "Samplerate")
            check(info.properties.duration > .zero, "Dauer gelesen")
        }

        section("Lesen — FLAC / Vorbis-Comments")
        do {
            let url = try copyOfTestFile("04 - vorbis.flac")
            let t = try TagLibBridge.read(from: url).tags
            equal(t.title, "FLAC Vorbis Comment", "Titel")
            equal(t.albumArtist, "Various Artists", "ALBUMARTIST")
            equal(t.discNumber, 1, "DISCNUMBER ohne Gesamtzahl")
            equal(t.discTotal, nil, "Keine Discgesamtzahl erfunden")
        }

        section("Lesen — M4A / MP4-Atome")
        do {
            let url = try copyOfTestFile("05 - mp4.m4a")
            let t = try TagLibBridge.read(from: url).tags
            equal(t.title, "M4A Track", "Titel")
            equal(t.albumArtist, "Various Artists", "aART")
        }

        section("Lesen — Datei ohne Tags")
        do {
            let url = try copyOfTestFile("03 - ohne tag.mp3")
            let info = try TagLibBridge.read(from: url)
            equal(info.tags.title, nil, "Titel ist nil, nicht \"\"")
            equal(info.tags.isCompilation, false, "Compilation-Default")
            equal(info.tags.artwork.count, 0, "Keine Bilder")
            check(info.properties.bitrate > 0, "Audio-Properties trotzdem lesbar")
        }

        // MARK: - 2. touchedFields — der Kernpunkt der Spec

        section("Songtexte")
        // Mehrzeilig, mit Umlauten, über alle drei Formate.
        let songtext = """
        Erste Zeile
        Zweite Zeile mit Ümläut
        Dritte Zeile
        """
        for name in ["01 - id3v2.3 - voll.mp3", "04 - vorbis.flac", "05 - mp4.m4a"] {
            let url = try copyOfTestFile(name)
            var tags = try TagLibBridge.read(from: url).tags
            equal(tags.lyrics, nil, "  \(name): anfangs kein Songtext")

            tags.lyrics = songtext
            try TagLibBridge.write(tags, fields: [.lyrics], to: url)
            let gelesen = try TagLibBridge.read(from: url).tags
            equal(gelesen.lyrics, songtext, "  \(name): Rundlauf vollständig")
            equal(gelesen.title, tags.title, "  \(name): Titel unangetastet")

            var leeren = gelesen
            leeren.lyrics = nil
            try TagLibBridge.write(leeren, fields: [.lyrics], to: url)
            equal(try TagLibBridge.read(from: url).tags.lyrics, nil,
                  "  \(name): lässt sich wieder entfernen")
        }

        section("Schreiben — nur berührte Felder (Spec §4.1)")
        do {
            let url = try copyOfTestFile("01 - id3v2.3 - voll.mp3")
            let vorher = try TagLibBridge.read(from: url).tags

            // Der Nutzer ändert NUR den Titel. Alle anderen Felder werden im
            // Editor-Zustand absichtlich geleert — das darf die Datei nicht berühren.
            var bearbeitet = AudioTags()          // komplett leer!
            bearbeitet.title = "Nur der Titel"

            try TagLibBridge.write(bearbeitet, fields: [.title], to: url)

            let nachher = try TagLibBridge.read(from: url).tags
            equal(nachher.title, "Nur der Titel", "Titel wurde geschrieben")
            equal(nachher.artist, vorher.artist, "Interpret unangetastet")
            equal(nachher.album, vorher.album, "Album unangetastet")
            equal(nachher.albumArtist, vorher.albumArtist, "Album-Interpret unangetastet")
            equal(nachher.composer, vorher.composer, "Komponist unangetastet")
            equal(nachher.genre, vorher.genre, "Genre unangetastet")
            equal(nachher.year, vorher.year, "Jahr unangetastet")
            equal(nachher.trackNumber, vorher.trackNumber, "Tracknummer unangetastet")
            equal(nachher.trackTotal, vorher.trackTotal, "Trackgesamtzahl unangetastet")
            equal(nachher.artwork.count, vorher.artwork.count, "Cover unangetastet")
        }

        section("Schreiben — leeren ist erlaubt, wenn das Feld berührt wurde")
        do {
            let url = try copyOfTestFile("01 - id3v2.3 - voll.mp3")
            var tags = try TagLibBridge.read(from: url).tags
            tags.comment = nil

            try TagLibBridge.write(tags, fields: [.comment], to: url)

            let nachher = try TagLibBridge.read(from: url).tags
            equal(nachher.comment, nil, "Kommentar entfernt")
            equal(nachher.title, tags.title, "Titel weiterhin da")
        }

        section("Schreiben — Nummer und Gesamtzahl teilen eine Property")
        do {
            let url = try copyOfTestFile("01 - id3v2.3 - voll.mp3")
            var tags = try TagLibBridge.read(from: url).tags
            tags.trackNumber = 7                       // nur die Nummer berührt

            try TagLibBridge.write(tags, fields: [.trackNumber], to: url)

            let nachher = try TagLibBridge.read(from: url).tags
            equal(nachher.trackNumber, 7, "Neue Tracknummer")
            equal(nachher.trackTotal, 12, "Gesamtzahl überlebt")
        }

        // MARK: - 3. Schreiben über Formatgrenzen

        section("Schreiben — alle Felder, alle drei Formate")
        for name in ["01 - id3v2.3 - voll.mp3", "04 - vorbis.flac", "05 - mp4.m4a"] {
            print("  · \(name)")
            let url = try copyOfTestFile(name)
            var tags = AudioTags()
            tags.title = "Sleeve schreibt — Ümläut & 🎧"
            tags.artist = "NeonRost"
            tags.albumArtist = "Various Artists"
            tags.album = "Roundtrip"
            tags.composer = "Anon"
            tags.genre = "Melodic Death Metal"
            tags.year = 2026
            tags.trackNumber = 4
            tags.trackTotal = 9
            tags.discNumber = 2
            tags.discTotal = 2
            tags.comment = "Kommentar mit Ümlaut"
            tags.isCompilation = true

            let felder = Set(TagField.allCases).subtracting([.artwork])
            try TagLibBridge.write(tags, fields: felder, to: url)

            let n = try TagLibBridge.read(from: url).tags
            equal(n.title, tags.title, "    Titel (UTF-8)")
            equal(n.albumArtist, tags.albumArtist, "    Album-Interpret")
            equal(n.composer, tags.composer, "    Komponist")
            equal(n.year, tags.year, "    Jahr")
            equal(n.trackNumber, tags.trackNumber, "    Tracknummer")
            equal(n.trackTotal, tags.trackTotal, "    Trackgesamtzahl")
            equal(n.discNumber, tags.discNumber, "    Discnummer")
            equal(n.comment, tags.comment, "    Kommentar")
            equal(n.isCompilation, true, "    Compilation")
        }

        // MARK: - 4. Coverbilder

        section("Coverbilder — setzen, mehrere, entfernen")
        do {
            let url = try copyOfTestFile("03 - ohne tag.mp3")
            let jpeg = try Data(contentsOf: URL(fileURLWithPath: testFiles + "/cover.jpg"))

            let front = Artwork(data: jpeg, mimeType: "image/jpeg",
                                pictureType: .frontCover, description: "Vorderseite")
            let back = Artwork(data: jpeg, mimeType: "image/jpeg",
                               pictureType: .backCover, description: "Rückseite")

            var tags = AudioTags()
            tags.artwork = [front, back]
            try TagLibBridge.write(tags, fields: [.artwork], to: url)

            let gelesen = try TagLibBridge.read(from: url).tags.artwork
            equal(gelesen.count, 2, "Zwei Bilder geschrieben und gelesen")
            equal(gelesen.first?.pictureType, .frontCover, "Erstes ist Front Cover")
            equal(gelesen.last?.pictureType, .backCover, "Zweites ist Back Cover")
            equal(gelesen.first?.description, "Vorderseite", "Beschreibung erhalten")
            equal(gelesen.first?.data.count, jpeg.count, "Bilddaten unverändert")
            equal(gelesen.first?.data, jpeg, "Bilddaten byte-identisch")

            // Ein Booklet: mehrere Seiten, jede mit eigenem Bildtyp.
            var booklet = AudioTags()
            booklet.artwork = [
                Artwork(data: jpeg, mimeType: "image/jpeg", pictureType: .frontCover),
                Artwork(data: jpeg, mimeType: "image/jpeg", pictureType: .leafletPage,
                        description: "Seite 1"),
                Artwork(data: jpeg, mimeType: "image/jpeg", pictureType: .backCover),
            ]
            let bookletDatei = try copyOfTestFile("02 - id3v2.4.mp3")
            try TagLibBridge.write(booklet, fields: [.artwork], to: bookletDatei)
            let bookletGelesen = try TagLibBridge.read(from: bookletDatei).tags.artwork
            equal(bookletGelesen.count, 3, "Booklet: drei Bilder in einer Datei")
            equal(Set(bookletGelesen.map(\.pictureType)),
                  Set([.frontCover, .leafletPage, .backCover]),
                  "Booklet: alle drei Bildtypen erhalten")
            equal(bookletGelesen.first { $0.pictureType == .leafletPage }?.description,
                  "Seite 1", "Booklet: Beschreibung der Seite erhalten")

            // Reihenfolge: was wir schreiben, muss genauso zurückkommen —
            // darauf stützt sich, dass die Vorderseite vorn bleibt.
            var reihenfolge = AudioTags()
            reihenfolge.artwork = [
                Artwork(data: jpeg, mimeType: "image/jpeg", pictureType: .backCover),
                Artwork(data: jpeg, mimeType: "image/jpeg", pictureType: .leafletPage),
                Artwork(data: jpeg, mimeType: "image/jpeg", pictureType: .frontCover),
            ]
            let reihenDatei = try copyOfTestFile("03 - ohne tag.mp3")
            try TagLibBridge.write(reihenfolge, fields: [.artwork], to: reihenDatei)
            equal(try TagLibBridge.read(from: reihenDatei).tags.artwork.map(\.pictureType),
                  [.backCover, .leafletPage, .frontCover],
                  "Bildreihenfolge bleibt beim Schreiben und Lesen erhalten")

            // Entfernen
            tags.artwork = []
            try TagLibBridge.write(tags, fields: [.artwork], to: url)
            equal(try TagLibBridge.read(from: url).tags.artwork.count, 0, "Alle Bilder entfernt")
        }

        section("Coverbilder — Cover ersetzen lässt Tags in Ruhe")
        do {
            let url = try copyOfTestFile("01 - id3v2.3 - voll.mp3")
            let vorher = try TagLibBridge.read(from: url).tags
            let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: 0x42, count: 512))

            var tags = vorher
            tags.artwork = [Artwork(data: png, mimeType: Artwork.detectMimeType(of: png))]
            try TagLibBridge.write(tags, fields: [.artwork], to: url)

            let nachher = try TagLibBridge.read(from: url).tags
            equal(nachher.artwork.count, 1, "Genau ein Bild, nicht angehängt")
            equal(nachher.artwork.first?.mimeType, "image/png", "MIME aus Bytes erkannt")
            equal(nachher.title, vorher.title, "Titel unangetastet")
            equal(nachher.albumArtist, vorher.albumArtist, "Album-Interpret unangetastet")
        }

        // MARK: - 5. Fehlerfälle — daran sterben Tagger üblicherweise

        section("Fehlerfälle")
        do {
            let missing = URL(fileURLWithPath: workDir + "/gibtsnicht.mp3")
            do {
                _ = try TagLibBridge.read(from: missing)
                check(false, "Fehlende Datei wirft")
            } catch let error as TagError {
                equal(error, .cannotOpen(missing), "Fehlende Datei → cannotOpen")
            }

            // Kaputte Datei: MP3-Endung, Müll drin.
            let broken = URL(fileURLWithPath: workDir + "/kaputt.mp3")
            try Data(repeating: 0x7F, count: 4096).write(to: broken)
            do {
                _ = try TagLibBridge.read(from: broken)
                check(true, "Beschädigte Datei bricht nicht ab (leere Tags)")
            } catch {
                check(true, "Beschädigte Datei wirft sauberen TagError: \(error)")
            }

            // Schreibgeschützte Datei
            let readOnly = try copyOfTestFile("02 - id3v2.4.mp3")
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: readOnly.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: readOnly.path) }

            check((try? TagLibBridge.read(from: readOnly)) != nil, "Schreibgeschützte Datei ist lesbar")

            var tags = AudioTags()
            tags.title = "Darf nicht durchkommen"
            do {
                try TagLibBridge.write(tags, fields: [.title], to: readOnly)
                check(false, "Schreibgeschützte Datei wirft beim Schreiben")
            } catch let error as TagError {
                check(error == .saveFailed(readOnly) || error == .cannotOpen(readOnly),
                      "Schreibgeschützte Datei → sauberer Fehler", detail: "\(error)")
            }

            // Leere Feldmenge darf gar nichts tun.
            let unberuehrt = try copyOfTestFile("01 - id3v2.3 - voll.mp3")
            let davor = try Data(contentsOf: unberuehrt)
            try TagLibBridge.write(AudioTags(), fields: [], to: unberuehrt)
            equal(try Data(contentsOf: unberuehrt), davor, "Leere Feldmenge lässt die Datei byte-identisch")
        }

        // MARK: - Ergebnis

        print("\n\(checks - failures)/\(checks) Prüfungen bestanden")
        if failures > 0 {
            print("✗ \(failures) fehlgeschlagen")
            return 1
        }
        print("✓ Alles grün.")
        return 0

    }
}
