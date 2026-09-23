//
//  TagLibBridge.swift
//  Sleeve
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
//  The only place in the project where `unsafe` and C pointers occur. To
//  the outside only `AudioFileInfo` goes in and out.
//
//  Principle (spec §2.1.1): reading and writing go exclusively through the
//  PropertyMap. When an ID3v2 frame is missing, the legacy tag API silently
//  falls back to the Latin-1 ID3v1 appendix and then returns garbled
//  letters.
//

import Foundation
import CTagLib

enum TagError: Error, Equatable, Sendable {
    /// TagLib could not open the file or does not recognize the format.
    case cannotOpen(URL)
    /// The file is open, but TagLib considers it unusable.
    case invalidFile(URL)
    /// `taglib_file_save` returned FALSE — usually missing write permission.
    case saveFailed(URL)
    /// Renaming failed (permissions, target name taken).
    case renameFailed(URL)
}

enum TagLibBridge {

    /// In `tag_c.h`, `TagLib_File` is a complete struct type, so Swift does not
    /// import pointers to it as `OpaquePointer`.
    typealias FileRef = UnsafeMutablePointer<TagLib_File>

    // MARK: - Reading

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

        // Vorbis comments additionally have keys of their own for the
        // total. Those take precedence when present.
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

    /// The complete PropertyMap — useful as raw data for a later "show all
    /// tags" inspector as well.
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

    /// Reads **all** embedded pictures. `taglib_picture_from_complex_property`
    /// only returns the first — so the outer array is walked here by hand.
    /// Files with several APIC frames are the normal case, not the exception.
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
            // Some files leave the MIME type empty — then guess it from the bytes.
            mimeType: mimeType.flatMap { $0.isEmpty ? nil : $0 }
                ?? Artwork.detectMimeType(of: data),
            pictureType: pictureType,
            description: description.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    // MARK: - Writing

    /// Writes **only** the fields in `fields`.
    ///
    /// That is the core of spec §4.1: a field the user did not touch is left
    /// alone — even when its value looks empty. The decision is made
    /// exclusively via this set, never via a value comparison.
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

        // Number and total share one property. If the user touches only
        // one half, the other has to be written along from the current
        // state — otherwise it would be lost.
        case .trackNumber, .trackTotal:
            let pair = NumberPair(number: tags.trackNumber, total: tags.trackTotal)
            set(PropertyKeys.trackNumber, pair.formatted, on: file)
            // Clean up the separate Vorbis keys so that they do not contradict
            // the combined notation.
            set("TRACKTOTAL", nil, on: file)

        case .discNumber, .discTotal:
            let pair = NumberPair(number: tags.discNumber, total: tags.discTotal)
            set(PropertyKeys.discNumber, pair.formatted, on: file)
            set("DISCTOTAL", nil, on: file)

        case .isCompilation:
            // For `false`, remove the property instead of writing "0" —
            // which is what the Music app and common taggers do.
            set(PropertyKeys.compilation, tags.isCompilation ? "1" : nil, on: file)

        case .artwork:
            break   // separately, see writeArtwork
        }
    }

    /// `value == nil` removes the property.
    private static func set(_ key: String, _ value: String?, on file: FileRef) {
        if let value, !value.isEmpty {
            taglib_property_set(file, key, value)
        } else {
            taglib_property_set(file, key, nil)
        }
    }

    /// The C macro `TAGLIB_COMPLEX_PROPERTY_PICTURE` cannot be reached from
    /// Swift, so the attribute array is built by hand. All buffers have to
    /// live until after the `set` call — `Arena` takes care of that.
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

    // MARK: - C infrastructure

    private static func withFile<T>(
        at url: URL,
        _ body: (FileRef) throws -> T
    ) throws -> T {
        let path = url.path(percentEncoded: false)

        // `taglib_file_new` returns a valid handle even for a file that does not
        // exist and only reports an error via `is_valid`. Without this check,
        // "file missing" and "file damaged" would be indistinguishable for the
        // user.
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

    /// Copy a NULL-terminated `char**` into a Swift array.
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

/// Keeps the C buffers alive for one `taglib_complex_property_set` call and
/// frees them all at once afterwards.
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

    /// Builds the NULL-terminated attribute array for a picture.
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
