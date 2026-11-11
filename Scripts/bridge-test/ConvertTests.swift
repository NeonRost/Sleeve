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
import CTagLib

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

        // MARK: - A program that hangs

        section("A hung program is ended")
        do {
            let started = Date()
            do {
                // Ignores SIGTERM and sits still: only SIGKILL ends it.
                _ = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"),
                                                arguments: ["-c", "trap '' TERM; exec /bin/sleep 120"],
                                                stallTimeout: 2)
                check(false, "a program without processor time counts as hung")
            } catch ProcessRunner.RunError.stalled {
                check(true, "a program without processor time counts as hung")
            }
            let took = Date().timeIntervalSince(started)
            check(took < 15, "and is ended even when it ignores SIGTERM",
                  detail: String(format: "%.1f s", took))
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

        // MARK: - Tags Sleeve has no field for

        section("Tags beyond Sleeve's fields survive, encoder details do not")
        do {
            func properties(_ url: URL) -> [String: [String]] {
                guard let file = url.path.withCString({ taglib_file_new($0) }) else { return [:] }
                defer { taglib_file_free(file) }
                return TagLibBridge.readPropertyMap(from: file)
            }
            let source = try copyTestFile("04 - vorbis.flac", to: work + "/extra")
            if let file = source.path.withCString({ taglib_file_new($0) }) {
                taglib_property_set(file, "REPLAYGAIN_TRACK_GAIN", "-6.20 dB")
                taglib_property_set(file, "MUSICBRAINZ_TRACKID", "0f3c1a2b-0000-4000-8000-000000000001")
                taglib_property_set(file, "BPM", "120")
                taglib_property_set(file, "ARTISTSORT", "Wolf, Peter und der")
                taglib_property_set(file, "ENCODER", "some encoder 1.0")
                _ = taglib_file_save(file)
                taglib_file_free(file)
            }
            var tags = try TagLibBridge.read(from: source).tags
            tags.comment = nil       // cleared in the editor: must stay cleared
            for format in [AudioFormat.mp3, .flac, .aac, .opus] where tool.supports(format) {
                var settings = ConversionSettings()
                settings.format = format
                settings.keepsOriginals = true
                settings.destinationFolder = URL(fileURLWithPath: work + "/extra-\(format.fileExtension)")
                let planner = ConversionPlanner(tool: tool, settings: settings)
                for await outcome in ConversionQueue(planner: planner, artworkOptions: .passthrough)
                    .run(try planner.plan([.init(trackID: UUID(), url: source, tags: tags)])) {
                    guard let target = outcome.destination else {
                        check(false, "  \(format.fileExtension): converted"); continue
                    }
                    let map = properties(target)
                    equal(map["REPLAYGAIN_TRACK_GAIN"], ["-6.20 dB"], "  \(format.fileExtension): ReplayGain survives")
                    equal(map["MUSICBRAINZ_TRACKID"], ["0f3c1a2b-0000-4000-8000-000000000001"],
                          "  \(format.fileExtension): MusicBrainz ID survives")
                    equal(map["BPM"], ["120"], "  \(format.fileExtension): BPM survives")
                    equal(map["ARTISTSORT"], ["Wolf, Peter und der"], "  \(format.fileExtension): sort name survives")
                    check(map["ENCODER"] == nil || map["ENCODER"] != ["some encoder 1.0"],
                          "  \(format.fileExtension): the source's encoder is not claimed")
                    equal(try TagLibBridge.read(from: target).tags.comment, nil,
                          "  \(format.fileExtension): a field cleared in the editor stays cleared")
                }
            }
        }

        // 24 bit stays 24 bit on the way to WAV.
        section("WAV keeps the resolution of the source")
        do {
            let folder = work + "/depth"
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let source = URL(fileURLWithPath: folder + "/hires.flac")
            _ = try await ProcessRunner.run(tool.url, arguments: [
                "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                "-f", "lavfi", "-i", "sine=frequency=440:duration=1:sample_rate=48000",
                "-c:a", "flac", "-sample_fmt", "s32", "-bits_per_raw_sample", "24",
                source.path])
            let info = try TagLibBridge.read(from: source)
            equal(info.properties.bitsPerSample, 24, "the source is 24 bit")
            var settings = ConversionSettings()
            settings.format = .wav
            settings.keepsOriginals = true
            let planner = ConversionPlanner(tool: tool, settings: settings)
            let jobs = try planner.plan([.init(trackID: UUID(), url: source, tags: info.tags,
                                               bitsPerSample: info.properties.bitsPerSample)])
            check(jobs.first?.arguments.contains("pcm_s24le") == true, "WAV is written with 24 bit")
            for await outcome in ConversionQueue(planner: planner, artworkOptions: .passthrough).run(jobs) {
                if let target = outcome.destination {
                    equal(try TagLibBridge.read(from: target).properties.bitsPerSample, 24,
                          "the WAV really has 24 bit")
                }
            }
        }

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
