//
//  TagLibBridge.swift
//  Sleeve
//
//  Die einzige Stelle im Projekt, an der `unsafe` und C-Zeiger vorkommen.
//  Nach außen gibt es nur `AudioFileInfo` rein und raus.
//
//  Grundsatz (Spec §2.1.1): gelesen und geschrieben wird ausschließlich über
//  die PropertyMap. Die Legacy-Tag-API fällt bei fehlendem ID3v2-Frame stumm
//  auf den Latin-1-ID3v1-Anhang zurück und liefert dann Buchstabensalat.
//

import Foundation
import CTagLib

enum TagError: Error, Equatable, Sendable {
    /// TagLib konnte die Datei nicht öffnen oder erkennt das Format nicht.
    case cannotOpen(URL)
    /// Datei ist geöffnet, aber TagLib hält sie für unbrauchbar.
    case invalidFile(URL)
    /// `taglib_file_save` hat FALSE geliefert — meist fehlende Schreibrechte.
    case saveFailed(URL)
    /// Umbenennen fehlgeschlagen (Rechte, Zielname belegt).
    case renameFailed(URL)
}

enum TagLibBridge {

    /// `TagLib_File` ist in `tag_c.h` ein vollständiger Struct-Typ, Swift
    /// importiert Zeiger darauf deshalb nicht als `OpaquePointer`.
    typealias FileRef = UnsafeMutablePointer<TagLib_File>

    // MARK: - Lesen

    static func read(from url: URL) throws -> AudioFileInfo {
        try withFile(at: url) { file in
            AudioFileInfo(
                tags: readTags(from: file),
                properties: readProperties(from: file)
            )
        }
    }

    private static func readTags(from file: FileRef) -> AudioTags {
        let properties = readPropertyMap(from: file)

        func first(_ key: String) -> String? {
            guard let value = properties[key]?.first, !value.isEmpty else { return nil }
            return value
        }

        let track = NumberPair(parsing: first(PropertyKeys.trackNumber) ?? "")
        let disc = NumberPair(parsing: first(PropertyKeys.discNumber) ?? "")

        // Vorbis-Comments kennen zusätzlich eigene Schlüssel für die
        // Gesamtzahl. Die haben Vorrang, wenn vorhanden.
        let trackTotal = first("TRACKTOTAL").flatMap(Int.init) ?? track.total
        let discTotal = first("DISCTOTAL").flatMap(Int.init) ?? disc.total

        let compilation = first(PropertyKeys.compilation)

        return AudioTags(
            title: first(PropertyKeys.title),
            artist: first(PropertyKeys.artist),
            albumArtist: first(PropertyKeys.albumArtist),
            album: first(PropertyKeys.album),
            composer: first(PropertyKeys.composer),
            genre: first(PropertyKeys.genre),
            year: first(PropertyKeys.date)?.leadingYear,
            trackNumber: track.number,
            trackTotal: trackTotal,
            discNumber: disc.number,
            discTotal: discTotal,
            comment: first(PropertyKeys.comment),
            lyrics: first(PropertyKeys.lyrics),
            isCompilation: compilation == "1" || compilation?.lowercased() == "true",
            artwork: readArtwork(from: file)
        )
    }

    /// Die vollständige PropertyMap — auch als Rohdaten für einen späteren
    /// „Alle Tags anzeigen"-Inspektor nützlich.
    static func readPropertyMap(from file: FileRef) -> [String: [String]] {
        guard let keys = taglib_property_keys(file) else { return [:] }
        defer { taglib_property_free(keys) }

        var result: [String: [String]] = [:]
        var cursor = keys
        while let keyPointer = cursor.pointee {
            let key = String(cString: keyPointer)
            if let values = taglib_property_get(file, key) {
                defer { taglib_property_free(values) }
                result[key] = stringList(from: values)
            }
            cursor = cursor.advanced(by: 1)
        }
        return result
    }

    private static func readProperties(from file: FileRef) -> AudioProperties {
        guard let audio = taglib_file_audioproperties(file) else { return .unknown }
        return AudioProperties(
            duration: .seconds(Int(taglib_audioproperties_length(audio))),
            bitrate: Int(taglib_audioproperties_bitrate(audio)),
            sampleRate: Int(taglib_audioproperties_samplerate(audio)),
            channels: Int(taglib_audioproperties_channels(audio))
        )
    }

    /// Liest **alle** eingebetteten Bilder. `taglib_picture_from_complex_property`
    /// liefert nur das erste — deshalb wird das äußere Array hier selbst
    /// durchlaufen. Dateien mit mehreren APIC-Frames sind der Normalfall, nicht
    /// die Ausnahme.
    private static func readArtwork(from file: FileRef) -> [Artwork] {
        guard let pictures = taglib_complex_property_get(file, PropertyKeys.picture) else {
            return []
        }
        defer { taglib_complex_property_free(pictures) }

        var result: [Artwork] = []
        var pictureCursor = pictures
        while let attributes = pictureCursor.pointee {
            if let artwork = artwork(fromAttributes: attributes) {
                result.append(artwork)
            }
            pictureCursor = pictureCursor.advanced(by: 1)
        }
        return result
    }

    private static func artwork(
        fromAttributes attributes: UnsafeMutablePointer<UnsafeMutablePointer<TagLib_Complex_Property_Attribute>?>
    ) -> Artwork? {
        var data: Data?
        var mimeType: String?
        var description: String?
        var pictureType: PictureType = .other

        var cursor = attributes
        while let attributePointer = cursor.pointee {
            let attribute = attributePointer.pointee
            let key = String(cString: attribute.key)
            let variant = attribute.value

            switch key {
            case PropertyKeys.PictureAttribute.data:
                if variant.type == TagLib_Variant_ByteVector,
                   let bytes = variant.value.byteVectorValue, variant.size > 0 {
                    data = Data(bytes: bytes, count: Int(variant.size))
                }
            case PropertyKeys.PictureAttribute.mimeType:
                mimeType = string(from: variant)
            case PropertyKeys.PictureAttribute.description:
                description = string(from: variant)
            case PropertyKeys.PictureAttribute.pictureType:
                pictureType = PictureType(taglibName: string(from: variant) ?? "")
            default:
                break
            }
            cursor = cursor.advanced(by: 1)
        }

        guard let data, !data.isEmpty else { return nil }
        return Artwork(
            data: data,
            // Manche Dateien lassen den MIME-Typ leer — dann aus den Bytes raten.
            mimeType: mimeType.flatMap { $0.isEmpty ? nil : $0 }
                ?? Artwork.detectMimeType(of: data),
            pictureType: pictureType,
            description: description.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    // MARK: - Schreiben

    /// Schreibt **nur** die Felder aus `fields`.
    ///
    /// Das ist der Kern der Spec §4.1: ein Feld, das der Nutzer nicht angefasst
    /// hat, wird nicht angerührt — auch dann nicht, wenn sein Wert leer
    /// aussieht. Entschieden wird ausschließlich über diese Menge, nie über
    /// einen Wertvergleich.
    static func write(_ tags: AudioTags, fields: Set<TagField>, to url: URL) throws {
        guard !fields.isEmpty else { return }

        try withFile(at: url) { file in
            for field in fields {
                apply(field, of: tags, to: file)
            }
            if fields.contains(.artwork) {
                writeArtwork(tags.artwork, to: file)
            }
            guard taglib_file_save(file) != 0 else {
                throw TagError.saveFailed(url)
            }
        }
    }

    private static func apply(_ field: TagField, of tags: AudioTags, to file: FileRef) {
        switch field {
        case .title:       set(PropertyKeys.title, tags.title, on: file)
        case .artist:      set(PropertyKeys.artist, tags.artist, on: file)
        case .albumArtist: set(PropertyKeys.albumArtist, tags.albumArtist, on: file)
        case .album:       set(PropertyKeys.album, tags.album, on: file)
        case .composer:    set(PropertyKeys.composer, tags.composer, on: file)
        case .genre:       set(PropertyKeys.genre, tags.genre, on: file)
        case .comment:     set(PropertyKeys.comment, tags.comment, on: file)
        case .lyrics:      set(PropertyKeys.lyrics, tags.lyrics, on: file)
        case .year:        set(PropertyKeys.date, tags.year.map(String.init), on: file)

        // Nummer und Gesamtzahl teilen sich eine Property. Berührt der Nutzer
        // nur eine Hälfte, muss die andere aus dem aktuellen Zustand
        // mitgeschrieben werden — sonst fiele sie weg.
        case .trackNumber, .trackTotal:
            let pair = NumberPair(number: tags.trackNumber, total: tags.trackTotal)
            set(PropertyKeys.trackNumber, pair.formatted, on: file)
            // Eigene Vorbis-Schlüssel aufräumen, damit sie der kombinierten
            // Schreibweise nicht widersprechen.
            set("TRACKTOTAL", nil, on: file)

        case .discNumber, .discTotal:
            let pair = NumberPair(number: tags.discNumber, total: tags.discTotal)
            set(PropertyKeys.discNumber, pair.formatted, on: file)
            set("DISCTOTAL", nil, on: file)

        case .isCompilation:
            // Bei `false` die Property entfernen statt "0" zu schreiben —
            // so halten es Music.app und die gängigen Tagger.
            set(PropertyKeys.compilation, tags.isCompilation ? "1" : nil, on: file)

        case .artwork:
            break   // separat, siehe writeArtwork
        }
    }

    /// `value == nil` entfernt die Property.
    private static func set(_ key: String, _ value: String?, on file: FileRef) {
        if let value, !value.isEmpty {
            taglib_property_set(file, key, value)
        } else {
            taglib_property_set(file, key, nil)
        }
    }

    /// Das C-Makro `TAGLIB_COMPLEX_PROPERTY_PICTURE` ist aus Swift nicht
    /// erreichbar, das Attribut-Array wird daher von Hand gebaut. Alle
    /// Puffer müssen bis nach dem `set`-Aufruf leben — dafür sorgt `Arena`.
    private static func writeArtwork(_ artwork: [Artwork], to file: FileRef) {
        guard !artwork.isEmpty else {
            taglib_complex_property_set(file, PropertyKeys.picture, nil)
            return
        }

        let arena = Arena()
        defer { arena.releaseAll() }

        for (index, image) in artwork.enumerated() {
            let attributes = arena.pictureAttributes(for: image)
            if index == 0 {
                taglib_complex_property_set(file, PropertyKeys.picture, attributes)
            } else {
                taglib_complex_property_set_append(file, PropertyKeys.picture, attributes)
            }
        }
    }

    // MARK: - C-Infrastruktur

    private static func withFile<T>(
        at url: URL,
        _ body: (FileRef) throws -> T
    ) throws -> T {
        let path = url.path(percentEncoded: false)

        // `taglib_file_new` liefert auch für eine gar nicht vorhandene Datei
        // einen gültigen Handle und meldet erst über `is_valid` einen Fehler.
        // Ohne diese Prüfung wären „Datei fehlt" und „Datei ist beschädigt"
        // für den Nutzer nicht zu unterscheiden.
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw TagError.cannotOpen(url)
        }

        guard let file = path.withCString({ taglib_file_new($0) }) else {
            throw TagError.cannotOpen(url)
        }
        defer { taglib_file_free(file) }

        guard taglib_file_is_valid(file) != 0 else {
            throw TagError.invalidFile(url)
        }
        return try body(file)
    }

    private static func string(from variant: TagLib_Variant) -> String? {
        guard variant.type == TagLib_Variant_String,
              let pointer = variant.value.stringValue else { return nil }
        return String(cString: pointer)
    }

    /// NULL-terminiertes `char**` in ein Swift-Array kopieren.
    private static func stringList(from list: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> [String] {
        var result: [String] = []
        var cursor = list
        while let pointer = cursor.pointee {
            result.append(String(cString: pointer))
            cursor = cursor.advanced(by: 1)
        }
        return result
    }
}

// MARK: - Arena

/// Hält die C-Puffer für einen `taglib_complex_property_set`-Aufruf am Leben
/// und gibt sie danach in einem Rutsch frei.
private final class Arena {
    private var byteBuffers: [UnsafeMutablePointer<CChar>] = []
    private var attributeBlocks: [UnsafeMutablePointer<TagLib_Complex_Property_Attribute>] = []
    private var pointerBlocks: [UnsafeMutablePointer<UnsafePointer<TagLib_Complex_Property_Attribute>?>] = []

    func releaseAll() {
        byteBuffers.forEach { $0.deallocate() }
        attributeBlocks.forEach { $0.deallocate() }
        pointerBlocks.forEach { $0.deallocate() }
        byteBuffers.removeAll()
        attributeBlocks.removeAll()
        pointerBlocks.removeAll()
    }

    deinit { releaseAll() }

    private func cString(_ value: String) -> UnsafeMutablePointer<CChar> {
        let utf8 = Array(value.utf8CString)
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: utf8.count)
        buffer.update(from: utf8, count: utf8.count)
        byteBuffers.append(buffer)
        return buffer
    }

    private func bytes(_ data: Data) -> UnsafeMutablePointer<CChar> {
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: max(data.count, 1))
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                buffer.withMemoryRebound(to: UInt8.self, capacity: data.count) {
                    $0.update(from: base.assumingMemoryBound(to: UInt8.self), count: data.count)
                }
            }
        }
        byteBuffers.append(buffer)
        return buffer
    }

    /// Baut das NULL-terminierte Attribut-Array für ein Bild.
    func pictureAttributes(
        for artwork: Artwork
    ) -> UnsafeMutablePointer<UnsafePointer<TagLib_Complex_Property_Attribute>?> {
        func variant(string value: String) -> TagLib_Variant {
            var variant = TagLib_Variant()
            variant.type = TagLib_Variant_String
            variant.size = 0
            variant.value.stringValue = cString(value)
            return variant
        }

        var dataVariant = TagLib_Variant()
        dataVariant.type = TagLib_Variant_ByteVector
        dataVariant.size = UInt32(artwork.data.count)
        dataVariant.value.byteVectorValue = bytes(artwork.data)

        let entries: [(String, TagLib_Variant)] = [
            (PropertyKeys.PictureAttribute.data, dataVariant),
            (PropertyKeys.PictureAttribute.mimeType, variant(string: artwork.mimeType)),
            (PropertyKeys.PictureAttribute.description, variant(string: artwork.description ?? "")),
            (PropertyKeys.PictureAttribute.pictureType, variant(string: artwork.pictureType.taglibName)),
        ]

        let attributes = UnsafeMutablePointer<TagLib_Complex_Property_Attribute>
            .allocate(capacity: entries.count)
        attributeBlocks.append(attributes)

        for (index, entry) in entries.enumerated() {
            attributes[index] = TagLib_Complex_Property_Attribute(
                key: cString(entry.0),
                value: entry.1
            )
        }

        let pointers = UnsafeMutablePointer<UnsafePointer<TagLib_Complex_Property_Attribute>?>
            .allocate(capacity: entries.count + 1)
        pointerBlocks.append(pointers)

        for index in 0..<entries.count {
            pointers[index] = UnsafePointer(attributes.advanced(by: index))
        }
        pointers[entries.count] = nil
        return pointers
    }
}
