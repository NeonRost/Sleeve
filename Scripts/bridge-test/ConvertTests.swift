//
//  ConvertTests.swift
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
//  The Convert mode (§5): locating ffmpeg, arguments, target paths and the
//  actual point — that tags and cover picture survive the conversion.
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
        check(actual == expected, label, detail: "is \(actual), expected \(expected)")
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

        // MARK: - Locating ffmpeg

        section("Locating ffmpeg")
        let locator = FFmpegLocator()
        guard let tool = await locator.locate() else {
            print("  ✗ No ffmpeg found — the remaining checks are skipped")
            return 1
        }
        check(!tool.version.isEmpty, "version read", detail: tool.version)
        check(tool.banner.lowercased().contains("ffmpeg version"), "banner recognized")
        check(tool.audioEncoders.contains("flac"), "encoder list contains flac",
              detail: "\(tool.audioEncoders.count) audio encoders found")
        check(!tool.audioEncoders.contains("libx264"), "video encoders are not included")
        check(tool.supports(.flac), "FLAC is supported")
        equal(FFmpegLocator.parseVersion(from: "ffmpeg version 9.0.1 Copyright (c) 2000"),
              "9.0.1", "version number from the banner")

        // A format this ffmpeg cannot do has to count as such.
        for format in AudioFormat.allCases where !tool.supports(format) {
            print("    · \(format.displayName) is missing from this build — reported, not hidden")
        }

        // MARK: - Arguments

        section("Arguments")
        var settings = ConversionSettings()
        settings.format = .flac
        let planner = ConversionPlanner(tool: tool, settings: settings)
        let source = URL(fileURLWithPath: "/m/in.mp3")
        let target = URL(fileURLWithPath: "/m/out.flac")
        let args = try planner.arguments(source: source, destination: target)

        check(args.contains("-map_metadata") &&
              args[(args.firstIndex(of: "-map_metadata") ?? 0) + 1] == "-1",
              "ffmpeg's own tag copying is switched off")
        check(args.contains("-vn"), "cover picture stream is dropped (we write it ourselves)")
        check(args.contains("-nostdin"), "no waiting for input")
        equal(args.last, target.path, "target path comes last")
        check(!args.contains("-b:a"), "a lossless format gets no bitrate")
        check(args.contains("-compression_level"), "FLAC gets a compression level")

        var lossySettings = ConversionSettings()
        lossySettings.format = .mp3
        lossySettings.bitrate = 192
        let lossyArgs = try ConversionPlanner(tool: tool, settings: lossySettings)
            .arguments(source: source, destination: URL(fileURLWithPath: "/m/out.mp3"))
        check(lossyArgs.contains("192k"), "bitrate is passed on")
        check(lossyArgs.contains("libmp3lame"), "MP3 uses LAME")
        check(!lossyArgs.contains("-compression_level"), "MP3 gets no compression level")

        // MARK: - Target paths

        section("Target paths")
        var tags = AudioTags()
        tags.artist = "NeonRost"
        tags.title = "Haut bloß ab"
        tags.trackNumber = 3

        var patternSettings = ConversionSettings()
        patternSettings.format = .flac
        patternSettings.filenamePattern = "%track% - %artist% - %title%"
        let patternPlanner = ConversionPlanner(tool: tool, settings: patternSettings)
        let named = patternPlanner.destination(for: .init(
            trackID: UUID(), url: URL(fileURLWithPath: "/m/whatever.mp3"), tags: tags))
        equal(named.lastPathComponent, "03 - NeonRost - Haut bloß ab.flac",
              "file name from the pattern, extension from the target format")

        let noPattern = ConversionPlanner(tool: tool, settings: settings).destination(for: .init(
            trackID: UUID(), url: URL(fileURLWithPath: "/m/OriginalName.mp3"), tags: tags))
        equal(noPattern.lastPathComponent, "OriginalName.flac",
              "without a pattern the original's name stays")

        var folderSettings = settings
        folderSettings.destinationFolder = URL(fileURLWithPath: "/elsewhere")
        let elsewhere = ConversionPlanner(tool: tool, settings: folderSettings).destination(for: .init(
            trackID: UUID(), url: URL(fileURLWithPath: "/m/x.mp3"), tags: tags))
        equal(elsewhere.deletingLastPathComponent().path, "/elsewhere", "target folder is respected")

        // MARK: - The actual point

        section("Tags survive the conversion")
        let original = try copyTestFile("01 - id3v2.3 - full.mp3")
        let before = try TagLibBridge.read(from: original).tags
        check(!before.artwork.isEmpty, "source has a cover picture")

        var runSettings = ConversionSettings()
        runSettings.format = .flac
        runSettings.keepsOriginals = true
        let runPlanner = ConversionPlanner(tool: tool, settings: runSettings)
        let queue = ConversionQueue(
            planner: runPlanner,
            artworkOptions: ArtworkProcessor.Options(maximumEdge: 400, jpegQuality: 0.8,
                                                     output: .jpeg))
        let jobs = try runPlanner.plan([.init(trackID: UUID(), url: original, tags: before)])

        var outcomes: [ConversionQueue.Outcome] = []
        for await outcome in queue.run(jobs) { outcomes.append(outcome) }
        equal(outcomes.count, 1, "one result")
        guard let outcome = outcomes.first, let converted = outcome.destination else {
            check(false, "conversion succeeded", detail: "\(outcomes.first?.error as Any)")
            return 1
        }
        check(outcome.succeeded, "conversion without errors")
        equal(converted.pathExtension, "flac", "extension is right")
        check(FileManager.default.fileExists(atPath: converted.path), "target file exists")
        check(FileManager.default.fileExists(atPath: original.path), "original kept")

        let after = try TagLibBridge.read(from: converted).tags
        equal(after.title, before.title, "  title")
        equal(after.artist, before.artist, "  artist")
        equal(after.albumArtist, before.albumArtist, "  album artist across the format boundary")
        equal(after.composer, before.composer, "  composer")
        equal(after.genre, before.genre, "  genre")
        equal(after.year, before.year, "  year")
        equal(after.trackNumber, before.trackNumber, "  track number")
        equal(after.trackTotal, before.trackTotal, "  track total")
        equal(after.discNumber, before.discNumber, "  disc number")
        equal(after.artwork.count, 1, "  cover picture is there")
        check((after.artwork.first?.data.count ?? 0) > 0, "  cover picture has content")
        check(after.artwork.first?.data != before.artwork.first?.data,
              "  cover picture was scaled, not passed through")

        // Counter-check: without our tag step nothing would arrive.
        section("Counter-check — ffmpeg alone carries nothing over")
        let bare = URL(fileURLWithPath: work + "/bare.flac")
        let bareArgs = try runPlanner.arguments(source: original, destination: bare)
        let run = try await ProcessRunner.run(tool.url, arguments: bareArgs)
        check(run.succeeded, "ffmpeg ran through", detail: run.standardError)
        let bareTags = try TagLibBridge.read(from: bare).tags
        equal(bareTags.title, nil, "no title — `-map_metadata -1` works")
        equal(bareTags.artist, nil, "no artist")
        equal(bareTags.artwork.count, 0, "no cover picture — `-vn` works")

        // MARK: - Deleting originals

        section("Discarding originals")
        let secondOriginal = try copyTestFile("02 - id3v2.4.mp3", to: work + "/delete")
        var deleteSettings = ConversionSettings()
        deleteSettings.format = .flac
        deleteSettings.keepsOriginals = false
        let deletePlanner = ConversionPlanner(tool: tool, settings: deleteSettings)
        let deleteQueue = ConversionQueue(planner: deletePlanner,
                                          artworkOptions: .passthrough)
        let deleteTags = try TagLibBridge.read(from: secondOriginal).tags
        for await result in deleteQueue.run(try deletePlanner.plan(
            [.init(trackID: UUID(), url: secondOriginal, tags: deleteTags)])) {
            check(result.succeeded, "conversion succeeded")
            check(!FileManager.default.fileExists(atPath: secondOriginal.path),
                  "original removed")
            check(FileManager.default.fileExists(atPath: result.destination?.path ?? ""),
                  "target file exists")
        }

        // MARK: - Collisions

        section("Collisions")
        let sameFormat = try copyTestFile("03 - no tag.mp3", to: work + "/collision")
        var sameSettings = ConversionSettings()
        sameSettings.format = .mp3          // MP3 → MP3, same folder, same name
        sameSettings.bitrate = 128
        sameSettings.keepsOriginals = true
        let samePlanner = ConversionPlanner(tool: tool, settings: sameSettings)
        let sameQueue = ConversionQueue(planner: samePlanner,
                                        artworkOptions: .passthrough)
        let sizeBefore = try Data(contentsOf: sameFormat).count
        for await result in sameQueue.run(try samePlanner.plan(
            [.init(trackID: UUID(), url: sameFormat, tags: AudioTags())])) {
            check(result.succeeded, "conversion succeeded")
            check(result.destination?.standardizedFileURL != sameFormat.standardizedFileURL,
                  "the target avoids the source instead of overwriting it",
                  detail: result.destination?.lastPathComponent ?? "—")
            equal(try Data(contentsOf: sameFormat).count, sizeBefore,
                  "source is unchanged")
        }

        print("\n\(checks - failures)/\(checks) checks passed")
        if failures > 0 {
            print("✗ \(failures) failed")
            return 1
        }
        print("✓ All green.")
        return 0
    }
}
