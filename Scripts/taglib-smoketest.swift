//
//  taglib-smoketest.swift
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
//  Step 1 of the spec: proves that the static TagLib build, the module map
//  and the C API work from Swift — reading, properties, cover picture, and a
//  write round trip against a copy.
//
//  Run:  ./Scripts/run-smoketest.sh
//

import Foundation
import CTagLib

// MARK: - Helpers for the C strings

/// TagLib returns `char*` that are freed with `taglib_tag_free_strings()`.
/// We copy them into Swift strings right away.
private func swiftString(_ cString: UnsafeMutablePointer<CChar>?) -> String? {
    guard let cString else { return nil }
    let s = String(cString: cString)
    return s.isEmpty ? nil : s
}

private func show(_ label: String, _ value: String?) {
    let padded = label.padding(toLength: 16, withPad: " ", startingAt: 0)
    print("    \(padded) \(value ?? "—")")
}

// MARK: - Reading

func dump(path: String) {
    print("\n━━ \((path as NSString).lastPathComponent)")

    guard let file = taglib_file_new(path) else {
        print("    ✗ taglib_file_new returned NULL")
        return
    }
    defer { taglib_file_free(file) }

    guard taglib_file_is_valid(file) != 0 else {
        print("    ✗ file is not valid for TagLib")
        return
    }

    // ── Basic tag ────────────────────────────────────────────────────────────
    if let tag = taglib_file_tag(file) {
        show("Title",   swiftString(taglib_tag_title(tag)))
        show("Artist",  swiftString(taglib_tag_artist(tag)))
        show("Album",   swiftString(taglib_tag_album(tag)))
        show("Genre",   swiftString(taglib_tag_genre(tag)))
        show("Comment", swiftString(taglib_tag_comment(tag)))
        show("Year",    taglib_tag_year(tag)  == 0 ? nil : "\(taglib_tag_year(tag))")
        show("Track",   taglib_tag_track(tag) == 0 ? nil : "\(taglib_tag_track(tag))")
        taglib_tag_free_strings()
    }

    // ── Audio properties ─────────────────────────────────────────────────────
    if let props = taglib_file_audioproperties(file) {
        let length = taglib_audioproperties_length(props)
        show("Length", String(format: "%d:%02d", length / 60, length % 60))
        show("Bitrate", "\(taglib_audioproperties_bitrate(props)) kbit/s")
        show("Sample rate", "\(taglib_audioproperties_samplerate(props)) Hz")
    }

    // ── PropertyMap — this is where ALBUMARTIST, COMPOSER, DISCNUMBER come from
    if let keys = taglib_property_keys(file) {
        defer { taglib_property_free(keys) }
        print("    ── PropertyMap ──")
        var k = keys
        while let keyPtr = k.pointee {
            let key = String(cString: keyPtr)
            var values: [String] = []
            if let valueList = taglib_property_get(file, key) {
                defer { taglib_property_free(valueList) }
                var v = valueList
                while let valuePtr = v.pointee {
                    values.append(String(cString: valuePtr))
                    v = v.advanced(by: 1)
                }
            }
            show("  \(key)", values.joined(separator: " / "))
            k = k.advanced(by: 1)
        }
    }

    // ── Cover pictures via the complex property API ──────────────────────────
    if let complexKeys = taglib_complex_property_keys(file) {
        defer { taglib_complex_property_free_keys(complexKeys) }
        var ck = complexKeys
        while let keyPtr = ck.pointee {
            let key = String(cString: keyPtr)
            if let properties = taglib_complex_property_get(file, key) {
                defer { taglib_complex_property_free(properties) }
                var picture = TagLib_Complex_Property_Picture_Data()
                taglib_picture_from_complex_property(properties, &picture)
                print("    ── Complex Property: \(key) ──")
                show("  MIME", swiftString(picture.mimeType))
                show("  Type", swiftString(picture.pictureType))
                show("  Text", swiftString(picture.description))
                show("  Size", "\(picture.size) bytes")
            }
            ck = ck.advanced(by: 1)
        }
    }
}

// MARK: - Write round trip against a copy

func writeRoundtrip(source: String) {
    print("\n━━ Write round trip (on a copy)")

    let copy = NSTemporaryDirectory() + "sleeve-roundtrip-" + UUID().uuidString + "."
        + (source as NSString).pathExtension
    do {
        try FileManager.default.copyItem(atPath: source, toPath: copy)
    } catch {
        print("    ✗ copy failed: \(error)")
        return
    }
    defer { try? FileManager.default.removeItem(atPath: copy) }

    let newTitle = "Written by Sleeve — Ümläut & 🎧"
    let newAlbumArtist = "Sleeve Test Ensemble"

    guard let file = taglib_file_new(copy) else {
        print("    ✗ cannot open file")
        return
    }
    if let tag = taglib_file_tag(file) {
        taglib_tag_set_title(tag, newTitle)
        taglib_tag_set_year(tag, 2026)
    }
    // Via the PropertyMap, so that the format mapping is left to TagLib.
    taglib_property_set(file, "ALBUMARTIST", newAlbumArtist)
    taglib_property_set(file, "DISCNUMBER", "2/2")

    let saved = taglib_file_save(file) != 0
    taglib_file_free(file)
    print("    taglib_file_save: \(saved ? "OK" : "FAILED")")

    // Open again and check
    guard let verify = taglib_file_new(copy), let tag = taglib_file_tag(verify) else {
        print("    ✗ verification: cannot open file")
        return
    }
    defer { taglib_file_free(verify) }

    let readTitle = swiftString(taglib_tag_title(tag))
    let readYear = taglib_tag_year(tag)
    taglib_tag_free_strings()

    var readAlbumArtist: String?
    if let list = taglib_property_get(verify, "ALBUMARTIST") {
        defer { taglib_property_free(list) }
        readAlbumArtist = swiftString(list.pointee)
    }

    func check(_ label: String, _ actual: String?, _ expected: String) {
        let ok = actual == expected
        print("    \(ok ? "✓" : "✗") \(label): \(actual ?? "—")")
    }
    check("Title (UTF-8)", readTitle, newTitle)
    check("Year", "\(readYear)", "2026")
    check("ALBUMARTIST", readAlbumArtist, newAlbumArtist)
}

// MARK: - Main

taglib_set_strings_unicode(1)   // char* is UTF-8 (the default in TagLib 2.x anyway)

let testDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath + "/TestFiles"

print("TagLib smoke test")
print("Test files: \(testDir)")

let audioExtensions: Set<String> = ["mp3", "m4a", "flac", "aiff", "aif", "wav", "ogg", "opus"]
let files = ((try? FileManager.default.contentsOfDirectory(atPath: testDir)) ?? [])
    .filter { audioExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
    .sorted()

guard !files.isEmpty else {
    print("✗ No audio files in \(testDir)")
    exit(1)
}

for name in files {
    dump(path: testDir + "/" + name)
}

if let first = files.first(where: { ($0 as NSString).pathExtension.lowercased() == "mp3" }) {
    writeRoundtrip(source: testDir + "/" + first)
}

print("\n✓ Smoke test completed.")
