//
//  AppStateTests.swift
//
//  Prüft die Schichten über der Bridge: Ordner einlesen, Mehrfachbearbeitung,
//  Speichern mit Fehlersammlung, Undo. Schritte 4–7 der Spec §8.
//  Was hier nicht geprüft wird, ist das SwiftUI-Rendering selbst.
//

import Foundation

enum AppStateTests {

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

    /// Dateinamen und Tags eines Rips kommen aus derselben Quelle — sonst
    /// heißt die Datei anders, als in ihr steht.
    @MainActor
    static func ripNaming() {
        print("\n━━ Rippen — Dateinamen aus dem Muster")
        let state = AppState()
        state.discAlbum = "Peter und der Wolf"
        state.discArtist = "Malte Arkona, Dresdner Philharmonie"
        state.discTitles = [3: "Andantino", 7: "Der Großvater", 9: ""]
        state.selectedRipTracks = [3, 7, 9]

        state.ripSettings.filenamePattern = "%track% - %title%"
        state.ripSettings.format = .flac
        equal(state.previewFilename(forTrack: 3), "03 - Andantino.flac",
              "Tracknummer wird zweistellig, Titel angehängt")
        equal(state.previewFilename(forTrack: 7), "07 - Der Großvater.flac",
              "Umlaute bleiben im Dateinamen")

        state.ripSettings.format = .mp3
        equal(state.previewFilename(forTrack: 3), "03 - Andantino.mp3",
              "Endung folgt dem Zielformat")

        // Ohne Titel bliebe vom Muster nur ein Trennzeichen übrig.
        equal(state.previewFilename(forTrack: 9), "09.mp3",
              "ohne Titel bleibt die Tracknummer")

        state.ripSettings.filenamePattern = ""
        equal(state.previewFilename(forTrack: 3), "03.mp3",
              "leeres Muster heißt: nur die Tracknummer")

        state.ripSettings.filenamePattern = "%artist% - %album% - %title%"
        equal(state.previewFilename(forTrack: 3),
              "Malte Arkona, Dresdner Philharmonie - Peter und der Wolf - Andantino.mp3",
              "mehrere Platzhalter")

        // Die Tags müssen zum Namen passen.
        let tags = state.tags(forTrack: 3)
        equal(tags.title, "Andantino", "Titel im Tag")
        equal(tags.album, "Peter und der Wolf", "Album im Tag")
        equal(tags.trackNumber, 3, "Tracknummer im Tag")

        print("\n━━ Rippen — Jahr, Genre, Komponist, Mehrfachausgabe")
        state.discYear = "2021"
        state.discGenre = "Klassik"
        state.discComposer = "Sergej Prokofjew"
        let full = state.tags(forTrack: 3)
        equal(full.year, 2021, "Jahr landet im Tag")
        equal(full.genre, "Klassik", "Genre landet im Tag")
        equal(full.composer, "Sergej Prokofjew", "Komponist landet im Tag")
        check(full.discNumber == nil, "Einzel-CD bekommt keine CD-Nummer")

        state.discTotal = 2
        state.discNumber = 2
        let set = state.tags(forTrack: 3)
        equal(set.discNumber, 2, "bei Mehrfachausgabe steht die CD-Nummer drin")
        equal(set.discTotal, 2, "und die Gesamtzahl")
        state.discTotal = 1

        // Die Platzhalter müssen jetzt alle etwas ergeben — ein Muster, das
        // ins Leere läuft, ist schlimmer als keins.
        state.ripSettings.format = .flac
        state.ripSettings.filenamePattern = "%year% %genre% %composer% %track% %title%"
        equal(state.previewFilename(forTrack: 3),
              "2021 Klassik Sergej Prokofjew 03 Andantino.flac",
              "Jahr, Genre und Komponist füllen ihre Platzhalter")

        print("\n━━ Rippen — abweichender Interpret je Track")
        state.discTrackArtists = [7: "Peter Schreier, Walter Olberz"]
        equal(state.tags(forTrack: 7).artist, "Peter Schreier, Walter Olberz",
              "Track mit eigenem Interpreten behält ihn")
        equal(state.tags(forTrack: 7).albumArtist, "Malte Arkona, Dresdner Philharmonie",
              "der Album-Interpret bleibt davon unberührt")
        equal(state.tags(forTrack: 3).artist, "Malte Arkona, Dresdner Philharmonie",
              "Track ohne eigenen Interpreten erbt den des Albums")
        state.discTrackArtists = [:]
        state.ripSettings.filenamePattern = "%track% - %title%"

        print("\n━━ Rippen — Albumordner")
        state.ripFolderName = ""
        equal(state.sanitizedAlbumFolderName,
              "Malte Arkona, Dresdner Philharmonie - Peter und der Wolf",
              "ohne eigenen Eintrag aus Interpret und Album")
        equal(state.suggestedAlbumFolderName, state.sanitizedAlbumFolderName,
              "der Vorschlag ist genau das, was sonst genommen wird")
        state.ripFolderName = "Prokofjew — Peter und der Wolf"
        equal(state.sanitizedAlbumFolderName, "Prokofjew — Peter und der Wolf",
              "eigener Eintrag sticht den Vorschlag")
        state.ripFolderName = "  Mit/Schrägstrich  "
        equal(state.sanitizedAlbumFolderName, "Mit_Schrägstrich",
              "eigener Eintrag wird für das Dateisystem entschärft")
        state.ripFolderName = ""

        print("\n━━ Rippen — Standardmuster und Zurücksetzen")
        equal(RipSettings.defaultFilenamePattern, "%track% - %title%",
              "der Standard ist knapp")
        var fresh = RipSettings()
        equal(fresh.filenamePattern, RipSettings.defaultFilenamePattern,
              "ein frisches Einstellungsobjekt trägt den Standard")
        fresh.filenamePattern = "%artist%"
        check(fresh.filenamePattern != RipSettings.defaultFilenamePattern,
              "und lässt sich ändern")

        print("\n━━ Rippen — was das Starten verhindert")
        state.disc = nil
        check(state.ripBlocker != nil, "ohne Scheibe kein Rip")
        state.ripSettings.format = .wav
        check(state.ripBlocker != nil, "auch mit WAV nicht ohne Scheibe")
    }

    @MainActor
    static func run() async throws -> Int32 {
        let root = FileManager.default.currentDirectoryPath
        let workDir = NSTemporaryDirectory() + "sleeve-appstate-" + UUID().uuidString
        let nested = workDir + "/Album/CD2"
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: workDir) }

        // Testmaterial in eine verschachtelte Ordnerstruktur kopieren,
        // plus eine Datei, die gar kein Audio ist.
        let quellen = ["01 - id3v2.3 - voll.mp3", "04 - vorbis.flac", "05 - mp4.m4a"]
        for (index, name) in quellen.enumerated() {
            let ziel = index == 0 ? workDir + "/Album" : nested
            try FileManager.default.copyItem(
                atPath: root + "/TestFiles/" + name,
                toPath: ziel + "/" + name
            )
        }
        try "kein audio".write(toFile: workDir + "/Album/liesmich.txt",
                               atomically: true, encoding: .utf8)

        let state = AppState()

        // MARK: - Ordner rekursiv einlesen

        section("Dateien laden — Ordner rekursiv")
        await state.addFiles([URL(fileURLWithPath: workDir)])
        equal(state.trackList.tracks.count, 3, "Drei Audiodateien gefunden")
        check(!state.trackList.tracks.contains { $0.filename.hasSuffix(".txt") },
              "Nicht-Audio übersprungen")
        equal(state.failures.count, 0, "Keine Fehler beim Import")
        check(state.trackList.tracks.allSatisfy { !$0.isDirty },
              "Frisch geladene Dateien sind nicht geändert")

        section("Dateien laden — dieselben Pfade erneut")
        await state.addFiles([URL(fileURLWithPath: workDir)])
        equal(state.trackList.tracks.count, 3, "Keine Duplikate")

        // MARK: - Mehrfachbearbeitung

        section("Mehrfachauswahl — Album auf alle anwenden")
        state.trackList.selection = Set(state.trackList.tracks.map(\.id))
        let auswahl = state.trackList.selectedTracks
        equal(auswahl.count, 3, "Drei Tracks ausgewählt")

        auswahl.forEach { $0.set("Sleeve Sampler", for: .album) }
        check(auswahl.allSatisfy { $0.edited.album == "Sleeve Sampler" },
              "Album auf allen gesetzt")
        check(auswahl.allSatisfy { $0.touchedFields == [.album] },
              "Genau ein Feld als berührt vorgemerkt")
        equal(state.trackList.changedCount, 3, "Drei geänderte Tracks")

        section("Berühren nur bei echter Änderung")
        let probe = state.trackList.tracks[0]
        probe.touchedFields.removeAll()

        // Das macht SwiftUI beim bloßen Klick ins Feld: Setter mit dem
        // unveränderten Text. Darf nichts vormerken.
        probe.set(probe.edited.title, for: .title)
        check(probe.touchedFields.isEmpty, "Klick ohne Änderung merkt nichts vor")

        probe.set("  \(probe.edited.album ?? "")  ", for: .album)
        check(probe.touchedFields.isEmpty, "Nur Leerraum drumherum zählt nicht als Änderung")

        probe.set("Wirklich neu", for: .title)
        equal(probe.touchedFields, [.title], "Echte Änderung wird vorgemerkt")

        // Ein Feld absichtlich leeren ist eine Änderung, kein Nichtstun.
        probe.set("", for: .comment)
        let kommentarVorher = probe.original.comment
        check(kommentarVorher == nil || probe.touchedFields.contains(.comment),
              "Vorhandenes Feld leeren wird vorgemerkt")
        probe.revert()
        equal(probe.touchedFields, [], "Verwerfen räumt auf")

        // Die Auswahl wieder wie vorher herstellen.
        auswahl.forEach { $0.set("Sleeve Sampler", for: .album) }

        // MARK: - Speichern

        section("Speichern")
        let vorherTitel = state.trackList.tracks.map(\.edited.title)
        await state.save()
        equal(state.failures.count, 0, "Keine Fehler beim Schreiben")
        equal(state.trackList.changedCount, 0, "Nach dem Speichern nichts mehr offen")
        check(state.trackList.tracks.allSatisfy { $0.touchedFields.isEmpty },
              "touchedFields geleert")

        // Gegen die Platte gegenprüfen, nicht gegen den Speicher.
        for track in state.trackList.tracks {
            let aufPlatte = try TagLibBridge.read(from: track.url).tags
            equal(aufPlatte.album, "Sleeve Sampler", "  \(track.filename): Album auf der Platte")
        }
        equal(state.trackList.tracks.map(\.edited.title), vorherTitel,
              "Titel unangetastet — nur Album war berührt")

        // MARK: - Undo

        section("Undo — letzter Schreibvorgang zurück")
        check(state.canUndo, "Undo steht bereit")
        await state.undoLastSave()
        equal(state.failures.count, 0, "Undo ohne Fehler")
        for track in state.trackList.tracks {
            let aufPlatte = try TagLibBridge.read(from: track.url).tags
            check(aufPlatte.album != "Sleeve Sampler",
                  "  \(track.filename): Album zurückgesetzt",
                  detail: aufPlatte.album ?? "—")
        }
        check(!state.canUndo, "Undo ist verbraucht")

        // MARK: - Verwerfen

        section("Änderungen verwerfen")
        let ersterTrack = state.trackList.tracks[0]
        let originalTitel = ersterTrack.edited.title
        ersterTrack.set("Wird verworfen", for: .title)
        equal(state.trackList.changedCount, 1, "Eine Änderung offen")
        state.trackList.selection = []
        state.revertSelection()
        equal(ersterTrack.edited.title, originalTitel, "Titel zurückgesetzt")
        equal(state.trackList.changedCount, 0, "Nichts mehr offen")

        section("Feld bei der ganzen Auswahl leeren")
        // Der Ablauf aus der Praxis: heruntergeladene MP3s tragen im Kommentar
        // die Adresse der Quelle. Alle markieren, Feld leeren, speichern.
        for (index, track) in state.trackList.tracks.enumerated() {
            // Einer bleibt absichtlich leer — der darf nicht als berührt gelten.
            track.set(index == 0 ? nil : "https://getrockmusic.net", for: .comment)
        }
        await state.save()
        equal(state.trackList.tracks.compactMap(\.edited.comment).count, 2,
              "Zwei Tracks haben einen Kommentar")

        let alle = state.trackList.tracks
        alle.forEach { $0.set(nil, for: .comment) }

        let berührt = alle.filter { $0.touchedFields.contains(.comment) }
        equal(berührt.count, 2, "Nur die beiden mit Inhalt gelten als berührt")
        check(!alle[0].touchedFields.contains(.comment),
              "Ein bereits leeres Feld wird nicht unnötig vorgemerkt")

        await state.save()
        for track in alle {
            let aufPlatte = try TagLibBridge.read(from: track.url).tags
            equal(aufPlatte.comment, nil, "  \(track.filename): Kommentar von der Platte weg")
        }

        section("Mehrere Coverbilder")
        let bild = try Data(contentsOf: URL(fileURLWithPath: root + "/TestFiles/cover.jpg"))
        let vorne = ArtworkProcessor.prepare(bild, pictureType: .frontCover,
                                             options: .passthrough)!
        let booklet = ArtworkProcessor.prepare(bild, pictureType: .leafletPage,
                                               options: .passthrough)!
        let hinten = ArtworkProcessor.prepare(bild, pictureType: .backCover,
                                              options: .passthrough)!

        state.trackList.selection = [state.trackList.tracks[0].id]
        let einer = state.trackList.tracks[0]

        state.applyArtwork(vorne, replacing: true)
        equal(einer.edited.artwork.count, 1, "Erstes Bild gesetzt")

        state.applyArtwork(booklet, replacing: false)
        equal(einer.edited.artwork.count, 2, "Zweites Bild kommt dazu, ersetzt nicht")

        state.applyArtwork(hinten, replacing: false)
        equal(einer.edited.artwork.count, 3, "Drittes Bild kommt dazu")
        equal(Set(einer.edited.artwork.map(\.pictureType)),
              Set([.frontCover, .leafletPage, .backCover]), "Drei verschiedene Bildtypen")

        // Derselbe Typ nochmal ersetzt nur diesen einen.
        state.applyArtwork(vorne, replacing: false)
        equal(einer.edited.artwork.count, 3, "Gleicher Bildtyp ersetzt statt zu häufen")

        // Die Vorderseite muss vorn stehen, auch wenn sie später kommt:
        // Abspielprogramme nehmen meist schlicht das erste Bild.
        equal(einer.edited.artwork.first?.pictureType, .frontCover,
              "Vorderseite steht an erster Stelle")

        state.removeArtwork(at: 0)
        equal(einer.edited.artwork.count, 2, "Vorderseite entfernt")
        check(!einer.edited.artwork.contains { $0.pictureType == .frontCover },
              "… und ist wirklich weg")

        state.applyArtwork(vorne, replacing: false)
        equal(einer.edited.artwork.first?.pictureType, .frontCover,
              "Nachträglich eingefügte Vorderseite rutscht wieder nach vorn")
        equal(einer.edited.artwork.count, 3, "Die anderen bleiben erhalten")
        equal(einer.edited.artwork.dropFirst().map(\.pictureType), [.leafletPage, .backCover],
              "Reihenfolge der übrigen Bilder bleibt unangetastet")

        state.removeArtwork(at: 1)
        equal(einer.edited.artwork.count, 2, "Einzelnes Bild entfernt")

        state.applyArtwork(vorne, replacing: true)
        equal(einer.edited.artwork.count, 1, "Ersetzen räumt die übrigen weg")

        state.removeArtwork()
        equal(einer.edited.artwork.count, 0, "Alle entfernt")
        state.trackList.selection = []

        // MARK: - Fehler brechen den Batch nicht ab

        section("Fehlersammlung — eine schreibgeschützte Datei unter drei")
        let gesperrt = state.trackList.tracks[1]
        try FileManager.default.setAttributes([.posixPermissions: 0o444],
                                              ofItemAtPath: gesperrt.url.path)
        state.trackList.tracks.forEach { $0.set("Batch", for: .genre) }
        await state.save()

        equal(state.failures.count, 1, "Genau ein Fehler gesammelt")
        equal(state.failures.first?.filename, gesperrt.filename, "Richtige Datei gemeldet")
        check(state.isShowingFailureSheet, "Fehler-Sheet wird gezeigt")
        check(gesperrt.lastError != nil, "Fehler am Track vermerkt")
        equal(gesperrt.status, .failed, "Status ist „fehlgeschlagen\"")

        let andere = state.trackList.tracks.filter { $0.id != gesperrt.id }
        check(andere.allSatisfy { !$0.isDirty }, "Die anderen beiden wurden geschrieben")
        for track in andere {
            let aufPlatte = try TagLibBridge.read(from: track.url).tags
            equal(aufPlatte.genre, "Batch", "  \(track.filename): Genre auf der Platte")
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                              ofItemAtPath: gesperrt.url.path)

        // MARK: - Modusverfügbarkeit

        section("Modi")
        check(state.availability(of: .tag).isAvailable, "Taggen ist verfügbar")
        // Konvertieren ist auch ohne ffmpeg betretbar: die Anleitung, wie man
        // ffmpeg installiert, steht in genau diesem Bereich. Den Modus dafür
        // zu sperren wäre ein Zirkelschluss.
        check(state.availability(of: .convert).isAvailable,
              "Konvertieren ist betretbar, auch ohne ffmpeg")
        // Wie beim Konvertieren: betretbar, auch wenn keine Scheibe drin
        // liegt. Woran es fehlt, sagt der Bereich selbst.
        check(state.availability(of: .rip).isAvailable,
              "Rippen ist betretbar, auch ohne eingelegte CD")
        equal(AppMode.allCases.count, 3, "Alle drei Modi sichtbar, keiner ausgeblendet")

        // Am Starten hindert stattdessen der Blocker.
        state.ffmpeg = nil
        check(state.conversionBlocker != nil, "Ohne ffmpeg meldet der Blocker das Hindernis",
              detail: state.conversionBlocker ?? "—")

        // MARK: - Ergebnis

        ripNaming()

        print("\n\(checks - failures)/\(checks) Prüfungen bestanden")
        if failures > 0 {
            print("✗ \(failures) fehlgeschlagen")
            return 1
        }
        print("✓ Alles grün.")
        return 0
    }
}
