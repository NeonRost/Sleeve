//
//  ConvertTests.swift
//
//  Modus „Konvertieren" (§5): ffmpeg-Erkennung, Aufrufparameter, Zielpfade
//  und der eigentliche Punkt — dass Tags und Coverbild die Umwandlung
//  überstehen.
//

import Foundation

enum ConvertTests {

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

    static func run() async throws -> Int32 {
        let root = FileManager.default.currentDirectoryPath
        let work = NSTemporaryDirectory() + "sleeve-convert-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: work) }

        func copyTestFile(_ name: String, to folder: String? = nil) throws -> URL {
            let target = URL(fileURLWithPath: folder ?? work).appendingPathComponent(name)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: root + "/TestFiles/" + name), to: target)
            return target
        }

        // MARK: - ffmpeg finden

        section("ffmpeg finden")
        let locator = FFmpegLocator()
        guard let tool = await locator.locate() else {
            print("  ✗ Kein ffmpeg gefunden — die übrigen Prüfungen entfallen")
            return 1
        }
        check(!tool.version.isEmpty, "Version gelesen", detail: tool.version)
        check(tool.banner.lowercased().contains("ffmpeg version"), "Banner erkannt")
        check(tool.audioEncoders.contains("flac"), "Encoder-Liste enthält flac",
              detail: "\(tool.audioEncoders.count) Audio-Encoder gefunden")
        check(!tool.audioEncoders.contains("libx264"), "Videoencoder sind nicht dabei")
        check(tool.supports(.flac), "FLAC wird unterstützt")
        equal(FFmpegLocator.parseVersion(from: "ffmpeg version 9.0.1 Copyright (c) 2000"),
              "9.0.1", "Versionsnummer aus dem Banner")

        // Ein Format, das dieses ffmpeg nicht kann, muss als solches gelten.
        for format in AudioFormat.allCases where !tool.supports(format) {
            print("    · \(format.displayName) fehlt in diesem Build — wird gemeldet, nicht versteckt")
        }

        // MARK: - Aufrufparameter

        section("Aufrufparameter")
        var settings = ConversionSettings()
        settings.format = .flac
        let planner = ConversionPlanner(tool: tool, settings: settings)
        let quelle = URL(fileURLWithPath: "/m/in.mp3")
        let ziel = URL(fileURLWithPath: "/m/out.flac")
        let args = try planner.arguments(source: quelle, destination: ziel)

        check(args.contains("-map_metadata") &&
              args[(args.firstIndex(of: "-map_metadata") ?? 0) + 1] == "-1",
              "ffmpegs eigene Tag-Übernahme ist abgeschaltet")
        check(args.contains("-vn"), "Coverbild-Stream wird verworfen (wir schreiben ihn selbst)")
        check(args.contains("-nostdin"), "Kein Warten auf Eingaben")
        equal(args.last, ziel.path, "Zielpfad steht am Ende")
        check(!args.contains("-b:a"), "Verlustfreies Format bekommt keine Bitrate")
        check(args.contains("-compression_level"), "FLAC bekommt eine Packdichte")

        var lossySettings = ConversionSettings()
        lossySettings.format = .mp3
        lossySettings.bitrate = 192
        let lossyArgs = try ConversionPlanner(tool: tool, settings: lossySettings)
            .arguments(source: quelle, destination: URL(fileURLWithPath: "/m/out.mp3"))
        check(lossyArgs.contains("192k"), "Bitrate wird übergeben")
        check(lossyArgs.contains("libmp3lame"), "MP3 nutzt LAME")
        check(!lossyArgs.contains("-compression_level"), "MP3 bekommt keine Packdichte")

        // MARK: - Zielpfade

        section("Zielpfade")
        var tags = AudioTags()
        tags.artist = "NeonRost"
        tags.title = "Haut bloß ab"
        tags.trackNumber = 3

        var patternSettings = ConversionSettings()
        patternSettings.format = .flac
        patternSettings.filenamePattern = "%track% - %artist% - %title%"
        let patternPlanner = ConversionPlanner(tool: tool, settings: patternSettings)
        let benannt = patternPlanner.destination(for: .init(
            trackID: UUID(), url: URL(fileURLWithPath: "/m/egal.mp3"), tags: tags))
        equal(benannt.lastPathComponent, "03 - NeonRost - Haut bloß ab.flac",
              "Dateiname aus dem Muster, Endung vom Zielformat")

        let ohneMuster = ConversionPlanner(tool: tool, settings: settings).destination(for: .init(
            trackID: UUID(), url: URL(fileURLWithPath: "/m/Originalname.mp3"), tags: tags))
        equal(ohneMuster.lastPathComponent, "Originalname.flac",
              "Ohne Muster bleibt der Name des Originals")

        var folderSettings = settings
        folderSettings.destinationFolder = URL(fileURLWithPath: "/woanders")
        let anderswo = ConversionPlanner(tool: tool, settings: folderSettings).destination(for: .init(
            trackID: UUID(), url: URL(fileURLWithPath: "/m/x.mp3"), tags: tags))
        equal(anderswo.deletingLastPathComponent().path, "/woanders", "Zielordner wird beachtet")

        // MARK: - Der eigentliche Punkt

        section("Tags überleben die Umwandlung")
        let original = try copyTestFile("01 - id3v2.3 - voll.mp3")
        let vorher = try TagLibBridge.read(from: original).tags
        check(!vorher.artwork.isEmpty, "Quelle hat ein Coverbild")

        var runSettings = ConversionSettings()
        runSettings.format = .flac
        runSettings.keepsOriginals = true
        let runPlanner = ConversionPlanner(tool: tool, settings: runSettings)
        let queue = ConversionQueue(
            planner: runPlanner,
            artworkOptions: ArtworkProcessor.Options(maximumEdge: 400, jpegQuality: 0.8,
                                                     output: .jpeg))
        let jobs = try runPlanner.plan([.init(trackID: UUID(), url: original, tags: vorher)])

        var outcomes: [ConversionQueue.Outcome] = []
        for await outcome in queue.run(jobs) { outcomes.append(outcome) }
        equal(outcomes.count, 1, "Ein Ergebnis")
        guard let outcome = outcomes.first, let converted = outcome.destination else {
            check(false, "Umwandlung gelungen", detail: "\(outcomes.first?.error as Any)")
            return 1
        }
        check(outcome.succeeded, "Umwandlung ohne Fehler")
        equal(converted.pathExtension, "flac", "Endung stimmt")
        check(FileManager.default.fileExists(atPath: converted.path), "Zieldatei liegt da")
        check(FileManager.default.fileExists(atPath: original.path), "Original behalten")

        let nachher = try TagLibBridge.read(from: converted).tags
        equal(nachher.title, vorher.title, "  Titel")
        equal(nachher.artist, vorher.artist, "  Interpret")
        equal(nachher.albumArtist, vorher.albumArtist, "  Album-Interpret über Formatgrenze")
        equal(nachher.composer, vorher.composer, "  Komponist")
        equal(nachher.genre, vorher.genre, "  Genre")
        equal(nachher.year, vorher.year, "  Jahr")
        equal(nachher.trackNumber, vorher.trackNumber, "  Tracknummer")
        equal(nachher.trackTotal, vorher.trackTotal, "  Trackgesamtzahl")
        equal(nachher.discNumber, vorher.discNumber, "  Discnummer")
        equal(nachher.artwork.count, 1, "  Coverbild ist da")
        check((nachher.artwork.first?.data.count ?? 0) > 0, "  Coverbild hat Inhalt")
        check(nachher.artwork.first?.data != vorher.artwork.first?.data,
              "  Coverbild wurde skaliert, nicht durchgereicht")

        // Gegenprobe: ohne unseren Tag-Schritt käme nichts an.
        section("Gegenprobe — ffmpeg allein überträgt nichts")
        let nackt = URL(fileURLWithPath: work + "/nackt.flac")
        let nacktArgs = try runPlanner.arguments(source: original, destination: nackt)
        let run = try await ProcessRunner.run(tool.url, arguments: nacktArgs)
        check(run.succeeded, "ffmpeg lief durch", detail: run.standardError)
        let nackteTags = try TagLibBridge.read(from: nackt).tags
        equal(nackteTags.title, nil, "Kein Titel — `-map_metadata -1` wirkt")
        equal(nackteTags.artist, nil, "Kein Interpret")
        equal(nackteTags.artwork.count, 0, "Kein Coverbild — `-vn` wirkt")

        // MARK: - Originale löschen

        section("Originale verwerfen")
        let zweitesOriginal = try copyTestFile("02 - id3v2.4.mp3", to: work + "/loeschen")
        var deleteSettings = ConversionSettings()
        deleteSettings.format = .flac
        deleteSettings.keepsOriginals = false
        let deletePlanner = ConversionPlanner(tool: tool, settings: deleteSettings)
        let deleteQueue = ConversionQueue(planner: deletePlanner,
                                          artworkOptions: .passthrough)
        let deleteTags = try TagLibBridge.read(from: zweitesOriginal).tags
        for await result in deleteQueue.run(try deletePlanner.plan(
            [.init(trackID: UUID(), url: zweitesOriginal, tags: deleteTags)])) {
            check(result.succeeded, "Umwandlung gelungen")
            check(!FileManager.default.fileExists(atPath: zweitesOriginal.path),
                  "Original entfernt")
            check(FileManager.default.fileExists(atPath: result.destination?.path ?? ""),
                  "Zieldatei liegt da")
        }

        // MARK: - Kollisionen

        section("Kollisionen")
        let gleichesFormat = try copyTestFile("03 - ohne tag.mp3", to: work + "/kollision")
        var sameSettings = ConversionSettings()
        sameSettings.format = .mp3          // MP3 → MP3, gleicher Ordner, gleicher Name
        sameSettings.bitrate = 128
        sameSettings.keepsOriginals = true
        let samePlanner = ConversionPlanner(tool: tool, settings: sameSettings)
        let sameQueue = ConversionQueue(planner: samePlanner,
                                        artworkOptions: .passthrough)
        let vorherGroesse = try Data(contentsOf: gleichesFormat).count
        for await result in sameQueue.run(try samePlanner.plan(
            [.init(trackID: UUID(), url: gleichesFormat, tags: AudioTags())])) {
            check(result.succeeded, "Umwandlung gelungen")
            check(result.destination?.standardizedFileURL != gleichesFormat.standardizedFileURL,
                  "Ziel weicht der Quelle aus statt sie zu überschreiben",
                  detail: result.destination?.lastPathComponent ?? "—")
            equal(try Data(contentsOf: gleichesFormat).count, vorherGroesse,
                  "Quelle ist unverändert")
        }

        print("\n\(checks - failures)/\(checks) Prüfungen bestanden")
        if failures > 0 {
            print("✗ \(failures) fehlgeschlagen")
            return 1
        }
        print("✓ Alles grün.")
        return 0
    }
}
