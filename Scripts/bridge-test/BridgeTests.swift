//
//  BridgeTests.swift
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
//  Checks TagLibBridge against TestFiles/ — always on copies, never on the
//  originals. The German and emoji test data is deliberate.
//

import Foundation
import CTagLib
import CTagLibShim

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
        check(actual == expected, label, detail: "is \(actual), expected \(expected)")
    }

    static func section(_ title: String) { print("\n━━ \(title)") }

    static func run() throws -> Int32 {
        // MARK: - Environment

        let root = FileManager.default.currentDirectoryPath
        let testFiles = root + "/TestFiles"
        let workDir = NSTemporaryDirectory() + "sleeve-bridge-test-" + UUID().uuidString
        try! FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: workDir) }

        /// Working copy of a test file.
        func copyOfTestFile(_ name: String) throws -> URL {
            let source = URL(fileURLWithPath: testFiles).appendingPathComponent(name)
            let target = URL(fileURLWithPath: workDir).appendingPathComponent(name)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: source, to: target)
            return target
        }

        // MARK: - 1. Reading, all three formats

        section("Reading — MP3 with full ID3v2.3")
        do {
            let url = try copyOfTestFile("01 - id3v2.3 - full.mp3")
            let info = try TagLibBridge.read(from: url)
            let t = info.tags
            equal(t.title, "Tëst Träck 🎵", "title with umlaut and emoji")
            equal(t.artist, "NeonRost", "artist")
            equal(t.albumArtist, "Various Artists", "album artist (TPE2)")
            equal(t.album, "Sleeve Demo", "album")
            equal(t.composer, "J. S. Bach", "composer (TCOM)")
            equal(t.genre, "Melodic Death Metal", "genre")
            equal(t.year, 1987, "year")
            equal(t.trackNumber, 3, "track number from \"3/12\"")
            equal(t.trackTotal, 12, "track total from \"3/12\"")
            equal(t.discNumber, 1, "disc number from \"1/2\" (TPOS)")
            equal(t.discTotal, 2, "disc total")
            equal(t.artwork.count, 1, "one cover picture")
            equal(t.artwork.first?.mimeType, "image/jpeg", "cover MIME type")
            equal(t.artwork.first?.pictureType, .frontCover, "cover type")
            check((t.artwork.first?.data.count ?? 0) > 1000, "cover has content",
                  detail: "\(t.artwork.first?.data.count ?? 0) bytes")
            check(info.properties.sampleRate == 44100, "sample rate")
            check(info.properties.duration > .zero, "duration read")
        }

        section("Reading — FLAC / Vorbis comments")
        do {
            let url = try copyOfTestFile("04 - vorbis.flac")
            let t = try TagLibBridge.read(from: url).tags
            equal(t.title, "FLAC Vorbis Comment", "title")
            equal(t.albumArtist, "Various Artists", "ALBUMARTIST")
            equal(t.discNumber, 1, "DISCNUMBER without total")
            equal(t.discTotal, nil, "no disc total invented")
        }

        section("Reading — M4A / MP4 atoms")
        do {
            let url = try copyOfTestFile("05 - mp4.m4a")
            let t = try TagLibBridge.read(from: url).tags
            equal(t.title, "M4A Track", "title")
            equal(t.albumArtist, "Various Artists", "aART")
        }

        section("Reading — file without tags")
        do {
            let url = try copyOfTestFile("03 - no tag.mp3")
            let info = try TagLibBridge.read(from: url)
            equal(info.tags.title, nil, "title is nil, not \"\"")
            equal(info.tags.isCompilation, false, "compilation default")
            equal(info.tags.artwork.count, 0, "no pictures")
            check(info.properties.bitrate > 0, "audio properties readable anyway")
        }

        // MARK: - 2. touchedFields — the core point of the spec

        section("Lyrics")
        // Multi-line, with umlauts, across all three formats.
        let lyrics = """
        First line
        Second line with Ümläut
        Third line
        """
        for name in ["01 - id3v2.3 - full.mp3", "04 - vorbis.flac", "05 - mp4.m4a"] {
            let url = try copyOfTestFile(name)
            var tags = try TagLibBridge.read(from: url).tags
            equal(tags.lyrics, nil, "  \(name): no lyrics at first")

            tags.lyrics = lyrics
            try TagLibBridge.write(tags, fields: [.lyrics], to: url)
            let read = try TagLibBridge.read(from: url).tags
            equal(read.lyrics, lyrics, "  \(name): complete round trip")
            equal(read.title, tags.title, "  \(name): title untouched")

            var cleared = read
            cleared.lyrics = nil
            try TagLibBridge.write(cleared, fields: [.lyrics], to: url)
            equal(try TagLibBridge.read(from: url).tags.lyrics, nil,
                  "  \(name): can be removed again")
        }

        section("Writing — an MP3 keeps its ID3 version")
        do {
            func id3(_ url: URL) -> (version: Int32, hasV1: Bool) {
                guard let file = url.path.withCString({ taglib_file_new($0) }) else { return (-1, false) }
                defer { taglib_file_free(file) }
                return (sleeve_taglib_id3v2_version(file), sleeve_taglib_has_id3v1(file) != 0)
            }
            for (name, version) in [("01 - id3v2.3 - full.mp3", Int32(3)), ("02 - id3v2.4.mp3", Int32(4))] {
                let url = try copyOfTestFile(name)
                let before = id3(url)
                equal(before.version, version, "  \(name): ID3v2.\(version) before")
                var tags = try TagLibBridge.read(from: url).tags
                tags.title = "Für Elise — ß"
                try TagLibBridge.write(tags, fields: [.title], to: url)
                let after = id3(url)
                equal(after.version, version, "  \(name): still ID3v2.\(version) after saving")
                equal(after.hasV1, before.hasV1, "  \(name): no ID3v1 tag added or removed")
                equal(try TagLibBridge.read(from: url).tags.title, "Für Elise — ß",
                      "  \(name): the umlauts arrive")
            }
            // A file without any tag gets a current one.
            let bare = try copyOfTestFile("03 - no tag.mp3")
            var tags = AudioTags()
            tags.title = "Neu"
            try TagLibBridge.write(tags, fields: [.title], to: bare)
            equal(id3(bare).version, 4, "  an MP3 without a tag gets ID3v2.4")
            equal(id3(bare).hasV1, false, "  and no ID3v1 tag")
        }

        section("Writing — several values, full dates, FLAC numbers and pictures")
        do {
            func properties(_ url: URL) -> [String: [String]] {
                guard let file = url.path.withCString({ taglib_file_new($0) }) else { return [:] }
                defer { taglib_file_free(file) }
                return TagLibBridge.readPropertyMap(from: file)
            }
            func flacPictureGeometry(_ url: URL) -> (width: Int, height: Int)? {
                guard let file = url.path.withCString({ taglib_file_new($0) }) else { return nil }
                defer { taglib_file_free(file) }
                guard let pictures = taglib_complex_property_get(file, "PICTURE"),
                      let attributes = pictures.pointee else { return nil }
                defer { taglib_complex_property_free(pictures) }
                var width = 0, height = 0
                var cursor = attributes
                while let attribute = cursor.pointee {
                    let key = String(cString: attribute.pointee.key)
                    if key == "width" { width = Int(attribute.pointee.value.value.intValue) }
                    if key == "height" { height = Int(attribute.pointee.value.value.intValue) }
                    cursor = cursor.advanced(by: 1)
                }
                return (width, height)
            }
            func setRaw(_ url: URL, _ key: String, _ values: [String]) {
                guard let file = url.path.withCString({ taglib_file_new($0) }) else { return }
                defer { taglib_file_free(file) }
                taglib_property_set(file, key, values.first)
                for more in values.dropFirst() { taglib_property_set_append(file, key, more) }
                _ = taglib_file_save(file)
            }

            let flac = try copyOfTestFile("04 - vorbis.flac")
            setRaw(flac, "ARTIST", ["Peter", "der Wolf"])
            setRaw(flac, "DATE", ["2001-05-12"])
            var tags = try TagLibBridge.read(from: flac).tags
            equal(tags.artist, "Peter; der Wolf", "  two artists are shown, joined")

            // Touching the title must not touch the artists; touching the
            // year with the same year must not cut the date.
            tags.title = "Neu"
            try TagLibBridge.write(tags, fields: [.title, .year], to: flac)
            equal(properties(flac)["ARTIST"], ["Peter", "der Wolf"], "  both artists survive")
            equal(properties(flac)["DATE"], ["2001-05-12"], "  the full date survives the same year")

            // Edited, the joined form is split again.
            tags.artist = "Peter; der Wolf; Großvater"
            try TagLibBridge.write(tags, fields: [.artist], to: flac)
            equal(properties(flac)["ARTIST"], ["Peter", "der Wolf", "Großvater"],
                  "  an edited list is written as three values")

            // Another year replaces the date.
            tags.year = 1999
            try TagLibBridge.write(tags, fields: [.year], to: flac)
            equal(properties(flac)["DATE"], ["1999"], "  another year replaces the date")

            // FLAC: number and total apart.
            tags.trackNumber = 3
            tags.trackTotal = 12
            try TagLibBridge.write(tags, fields: [.trackNumber, .trackTotal], to: flac)
            equal(properties(flac)["TRACKNUMBER"], ["3"], "  FLAC: TRACKNUMBER carries only the number")
            equal(properties(flac)["TRACKTOTAL"], ["12"], "  FLAC: TRACKTOTAL carries the total")
            let back = try TagLibBridge.read(from: flac).tags
            equal(back.trackNumber, 3, "  FLAC: number read back")
            equal(back.trackTotal, 12, "  FLAC: total read back")

            // MP3 keeps the combined form.
            let mp3 = try copyOfTestFile("02 - id3v2.4.mp3")
            var mp3Tags = try TagLibBridge.read(from: mp3).tags
            mp3Tags.trackNumber = 3
            mp3Tags.trackTotal = 12
            try TagLibBridge.write(mp3Tags, fields: [.trackNumber], to: mp3)
            equal(properties(mp3)["TRACKNUMBER"], ["3/12"], "  MP3: number and total in one frame")

            // A FLAC picture states its size.
            let cover = try Data(contentsOf: URL(fileURLWithPath: testFiles + "/cover.jpg"))
            tags.artwork = [Artwork(data: cover, mimeType: "image/jpeg", pictureType: .frontCover,
                                    description: nil)]
            try TagLibBridge.write(tags, fields: [.artwork], to: flac)
            let geometry = flacPictureGeometry(flac)
            check((geometry?.width ?? 0) > 0 && (geometry?.height ?? 0) > 0,
                  "  FLAC: the picture block states its size",
                  detail: "\(geometry.map { "\($0.width)×\($0.height)" } ?? "none")")
        }

        section("Writing — only touched fields (spec §4.1)")
        do {
            let url = try copyOfTestFile("01 - id3v2.3 - full.mp3")
            let before = try TagLibBridge.read(from: url).tags

            // The user changes ONLY the title. All other fields are deliberately
            // empty in the editor state — that must not touch the file.
            var edited = AudioTags()          // completely empty!
            edited.title = "Only the title"

            try TagLibBridge.write(edited, fields: [.title], to: url)

            let after = try TagLibBridge.read(from: url).tags
            equal(after.title, "Only the title", "title was written")
            equal(after.artist, before.artist, "artist untouched")
            equal(after.album, before.album, "album untouched")
            equal(after.albumArtist, before.albumArtist, "album artist untouched")
            equal(after.composer, before.composer, "composer untouched")
            equal(after.genre, before.genre, "genre untouched")
            equal(after.year, before.year, "year untouched")
            equal(after.trackNumber, before.trackNumber, "track number untouched")
            equal(after.trackTotal, before.trackTotal, "track total untouched")
            equal(after.artwork.count, before.artwork.count, "cover untouched")
        }

        section("Writing — clearing is allowed when the field was touched")
        do {
            let url = try copyOfTestFile("01 - id3v2.3 - full.mp3")
            var tags = try TagLibBridge.read(from: url).tags
            tags.comment = nil

            try TagLibBridge.write(tags, fields: [.comment], to: url)

            let after = try TagLibBridge.read(from: url).tags
            equal(after.comment, nil, "comment removed")
            equal(after.title, tags.title, "title still there")
        }

        section("Writing — number and total share one property")
        do {
            let url = try copyOfTestFile("01 - id3v2.3 - full.mp3")
            var tags = try TagLibBridge.read(from: url).tags
            tags.trackNumber = 7                       // only the number touched

            try TagLibBridge.write(tags, fields: [.trackNumber], to: url)

            let after = try TagLibBridge.read(from: url).tags
            equal(after.trackNumber, 7, "new track number")
            equal(after.trackTotal, 12, "total survives")
        }

        // MARK: - 3. Writing across format boundaries

        section("Writing — all fields, all three formats")
        for name in ["01 - id3v2.3 - full.mp3", "04 - vorbis.flac", "05 - mp4.m4a"] {
            print("  · \(name)")
            let url = try copyOfTestFile(name)
            var tags = AudioTags()
            tags.title = "Sleeve writes — Ümläut & 🎧"
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
            tags.comment = "Comment with Ümlaut"
            tags.isCompilation = true

            let fields = Set(TagField.allCases).subtracting([.artwork])
            try TagLibBridge.write(tags, fields: fields, to: url)

            let n = try TagLibBridge.read(from: url).tags
            equal(n.title, tags.title, "    title (UTF-8)")
            equal(n.albumArtist, tags.albumArtist, "    album artist")
            equal(n.composer, tags.composer, "    composer")
            equal(n.year, tags.year, "    year")
            equal(n.trackNumber, tags.trackNumber, "    track number")
            equal(n.trackTotal, tags.trackTotal, "    track total")
            equal(n.discNumber, tags.discNumber, "    disc number")
            equal(n.comment, tags.comment, "    comment")
            equal(n.isCompilation, true, "    compilation")
        }

        // MARK: - 4. Cover pictures

        section("Cover pictures — setting, several, removing")
        do {
            let url = try copyOfTestFile("03 - no tag.mp3")
            let jpeg = try Data(contentsOf: URL(fileURLWithPath: testFiles + "/cover.jpg"))

            let front = Artwork(data: jpeg, mimeType: "image/jpeg",
                                pictureType: .frontCover, description: "Front")
            let back = Artwork(data: jpeg, mimeType: "image/jpeg",
                               pictureType: .backCover, description: "Back")

            var tags = AudioTags()
            tags.artwork = [front, back]
            try TagLibBridge.write(tags, fields: [.artwork], to: url)

            let read = try TagLibBridge.read(from: url).tags.artwork
            equal(read.count, 2, "two pictures written and read")
            equal(read.first?.pictureType, .frontCover, "the first is Front Cover")
            equal(read.last?.pictureType, .backCover, "the second is Back Cover")
            equal(read.first?.description, "Front", "description preserved")
            equal(read.first?.data.count, jpeg.count, "picture data unchanged")
            equal(read.first?.data, jpeg, "picture data byte-identical")

            // A booklet: several pages, each with its own picture type.
            var booklet = AudioTags()
            booklet.artwork = [
                Artwork(data: jpeg, mimeType: "image/jpeg", pictureType: .frontCover),
                Artwork(data: jpeg, mimeType: "image/jpeg", pictureType: .leafletPage,
                        description: "Page 1"),
                Artwork(data: jpeg, mimeType: "image/jpeg", pictureType: .backCover),
            ]
            let bookletFile = try copyOfTestFile("02 - id3v2.4.mp3")
            try TagLibBridge.write(booklet, fields: [.artwork], to: bookletFile)
            let bookletRead = try TagLibBridge.read(from: bookletFile).tags.artwork
            equal(bookletRead.count, 3, "booklet: three pictures in one file")
            equal(Set(bookletRead.map(\.pictureType)),
                  Set([.frontCover, .leafletPage, .backCover]),
                  "booklet: all three picture types preserved")
            equal(bookletRead.first { $0.pictureType == .leafletPage }?.description,
                  "Page 1", "booklet: the page's description preserved")

            // Order: what we write has to come back exactly like that —
            // keeping the front cover in front relies on it.
            var order = AudioTags()
            order.artwork = [
                Artwork(data: jpeg, mimeType: "image/jpeg", pictureType: .backCover),
                Artwork(data: jpeg, mimeType: "image/jpeg", pictureType: .leafletPage),
                Artwork(data: jpeg, mimeType: "image/jpeg", pictureType: .frontCover),
            ]
            let orderFile = try copyOfTestFile("03 - no tag.mp3")
            try TagLibBridge.write(order, fields: [.artwork], to: orderFile)
            equal(try TagLibBridge.read(from: orderFile).tags.artwork.map(\.pictureType),
                  [.backCover, .leafletPage, .frontCover],
                  "picture order survives writing and reading")

            // Removing
            tags.artwork = []
            try TagLibBridge.write(tags, fields: [.artwork], to: url)
            equal(try TagLibBridge.read(from: url).tags.artwork.count, 0, "all pictures removed")
        }

        section("Cover pictures — replacing the cover leaves the tags alone")
        do {
            let url = try copyOfTestFile("01 - id3v2.3 - full.mp3")
            let before = try TagLibBridge.read(from: url).tags
            let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: 0x42, count: 512))

            var tags = before
            tags.artwork = [Artwork(data: png, mimeType: Artwork.detectMimeType(of: png))]
            try TagLibBridge.write(tags, fields: [.artwork], to: url)

            let after = try TagLibBridge.read(from: url).tags
            equal(after.artwork.count, 1, "exactly one picture, not appended")
            equal(after.artwork.first?.mimeType, "image/png", "MIME recognized from the bytes")
            equal(after.title, before.title, "title untouched")
            equal(after.albumArtist, before.albumArtist, "album artist untouched")
        }

        // MARK: - 5. Failure cases — where taggers usually die

        section("Failure cases")
        do {
            let missing = URL(fileURLWithPath: workDir + "/doesnotexist.mp3")
            do {
                _ = try TagLibBridge.read(from: missing)
                check(false, "a missing file throws")
            } catch let error as TagError {
                equal(error, .cannotOpen(missing), "missing file → cannotOpen")
            }

            // Broken file: MP3 extension, garbage inside.
            let broken = URL(fileURLWithPath: workDir + "/broken.mp3")
            try Data(repeating: 0x7F, count: 4096).write(to: broken)
            do {
                _ = try TagLibBridge.read(from: broken)
                check(true, "a damaged file does not crash (empty tags)")
            } catch {
                check(true, "a damaged file throws a clean TagError: \(error)")
            }

            // Read-only file
            let readOnly = try copyOfTestFile("02 - id3v2.4.mp3")
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: readOnly.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: readOnly.path) }

            check((try? TagLibBridge.read(from: readOnly)) != nil, "a read-only file is readable")

            var tags = AudioTags()
            tags.title = "Must not get through"
            do {
                try TagLibBridge.write(tags, fields: [.title], to: readOnly)
                check(false, "a read-only file throws when writing")
            } catch let error as TagError {
                check(error == .saveFailed(readOnly) || error == .cannotOpen(readOnly),
                      "read-only file → clean error", detail: "\(error)")
            }

            // An empty set of fields must do nothing at all.
            let untouched = try copyOfTestFile("01 - id3v2.3 - full.mp3")
            let bytesBefore = try Data(contentsOf: untouched)
            try TagLibBridge.write(AudioTags(), fields: [], to: untouched)
            equal(try Data(contentsOf: untouched), bytesBefore, "an empty set of fields leaves the file byte-identical")
        }

        // MARK: - Result

        print("\n\(checks - failures)/\(checks) checks passed")
        if failures > 0 {
            print("✗ \(failures) failed")
            return 1
        }
        print("✓ All green.")
        return 0

    }
}
