//
//  taglib-smoketest.swift
//
//  Schritt 1 aus der Spec: beweist, dass der statische TagLib-Build, die
//  Module-Map und die C-API aus Swift heraus funktionieren — lesen, Properties,
//  Coverbild, und ein Schreib-Roundtrip gegen eine Kopie.
//
//  Aufruf:  ./Scripts/run-smoketest.sh
//

import Foundation
import CTagLib

// MARK: - Hilfen für die C-Strings

/// TagLib gibt `char*` zurück, die mit `taglib_tag_free_strings()` freigegeben
/// werden. Wir kopieren sofort in Swift-Strings.
private func swiftString(_ cString: UnsafeMutablePointer<CChar>?) -> String? {
    guard let cString else { return nil }
    let s = String(cString: cString)
    return s.isEmpty ? nil : s
}

private func show(_ label: String, _ value: String?) {
    let padded = label.padding(toLength: 16, withPad: " ", startingAt: 0)
    print("    \(padded) \(value ?? "—")")
}

// MARK: - Lesen

func dump(path: String) {
    print("\n━━ \((path as NSString).lastPathComponent)")

    guard let file = taglib_file_new(path) else {
        print("    ✗ taglib_file_new lieferte NULL")
        return
    }
    defer { taglib_file_free(file) }

    guard taglib_file_is_valid(file) != 0 else {
        print("    ✗ Datei ist für TagLib nicht valide")
        return
    }

    // ── Basis-Tag ────────────────────────────────────────────────────────────
    if let tag = taglib_file_tag(file) {
        show("Titel",     swiftString(taglib_tag_title(tag)))
        show("Interpret", swiftString(taglib_tag_artist(tag)))
        show("Album",     swiftString(taglib_tag_album(tag)))
        show("Genre",     swiftString(taglib_tag_genre(tag)))
        show("Kommentar", swiftString(taglib_tag_comment(tag)))
        show("Jahr",      taglib_tag_year(tag)  == 0 ? nil : "\(taglib_tag_year(tag))")
        show("Track",     taglib_tag_track(tag) == 0 ? nil : "\(taglib_tag_track(tag))")
        taglib_tag_free_strings()
    }

    // ── Audio-Eigenschaften ──────────────────────────────────────────────────
    if let props = taglib_file_audioproperties(file) {
        let length = taglib_audioproperties_length(props)
        show("Dauer", String(format: "%d:%02d", length / 60, length % 60))
        show("Bitrate", "\(taglib_audioproperties_bitrate(props)) kbit/s")
        show("Samplerate", "\(taglib_audioproperties_samplerate(props)) Hz")
    }

    // ── PropertyMap — hier kommen ALBUMARTIST, COMPOSER, DISCNUMBER her ──────
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

    // ── Coverbilder über die Complex-Property-API ────────────────────────────
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
                show("  MIME",  swiftString(picture.mimeType))
                show("  Typ",   swiftString(picture.pictureType))
                show("  Text",  swiftString(picture.description))
                show("  Größe", "\(picture.size) Bytes")
            }
            ck = ck.advanced(by: 1)
        }
    }
}

// MARK: - Schreib-Roundtrip gegen eine Kopie

func writeRoundtrip(source: String) {
    print("\n━━ Schreib-Roundtrip (auf Kopie)")

    let copy = NSTemporaryDirectory() + "sleeve-roundtrip-" + UUID().uuidString + "."
        + (source as NSString).pathExtension
    do {
        try FileManager.default.copyItem(atPath: source, toPath: copy)
    } catch {
        print("    ✗ Kopie fehlgeschlagen: \(error)")
        return
    }
    defer { try? FileManager.default.removeItem(atPath: copy) }

    let neuerTitel = "Geschrieben von Sleeve — Ümläut & 🎧"
    let neuerAlbumInterpret = "Sleeve Test Ensemble"

    guard let file = taglib_file_new(copy) else {
        print("    ✗ Datei nicht zu öffnen")
        return
    }
    if let tag = taglib_file_tag(file) {
        taglib_tag_set_title(tag, neuerTitel)
        taglib_tag_set_year(tag, 2026)
    }
    // Über die PropertyMap, damit das Format-Mapping TagLib überlässt bleibt.
    taglib_property_set(file, "ALBUMARTIST", neuerAlbumInterpret)
    taglib_property_set(file, "DISCNUMBER", "2/2")

    let saved = taglib_file_save(file) != 0
    taglib_file_free(file)
    print("    taglib_file_save: \(saved ? "OK" : "FEHLGESCHLAGEN")")

    // Erneut öffnen und prüfen
    guard let verify = taglib_file_new(copy), let tag = taglib_file_tag(verify) else {
        print("    ✗ Verifikation: Datei nicht zu öffnen")
        return
    }
    defer { taglib_file_free(verify) }

    let gelesenerTitel = swiftString(taglib_tag_title(tag))
    let gelesenesJahr = taglib_tag_year(tag)
    taglib_tag_free_strings()

    var gelesenerAlbumInterpret: String?
    if let list = taglib_property_get(verify, "ALBUMARTIST") {
        defer { taglib_property_free(list) }
        gelesenerAlbumInterpret = swiftString(list.pointee)
    }

    func check(_ label: String, _ ist: String?, _ soll: String) {
        let ok = ist == soll
        print("    \(ok ? "✓" : "✗") \(label): \(ist ?? "—")")
    }
    check("Titel (UTF-8)", gelesenerTitel, neuerTitel)
    check("Jahr", "\(gelesenesJahr)", "2026")
    check("ALBUMARTIST", gelesenerAlbumInterpret, neuerAlbumInterpret)
}

// MARK: - Main

taglib_set_strings_unicode(1)   // char* ist UTF-8 (in TagLib 2.x ohnehin Default)

let testDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath + "/TestFiles"

print("TagLib-Smoketest")
print("Testdateien: \(testDir)")

let audioExtensions: Set<String> = ["mp3", "m4a", "flac", "aiff", "aif", "wav", "ogg", "opus"]
let files = ((try? FileManager.default.contentsOfDirectory(atPath: testDir)) ?? [])
    .filter { audioExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
    .sorted()

guard !files.isEmpty else {
    print("✗ Keine Audiodateien in \(testDir)")
    exit(1)
}

for name in files {
    dump(path: testDir + "/" + name)
}

if let first = files.first(where: { ($0 as NSString).pathExtension.lowercased() == "mp3" }) {
    writeRoundtrip(source: testDir + "/" + first)
}

print("\n✓ Smoketest durchgelaufen.")
