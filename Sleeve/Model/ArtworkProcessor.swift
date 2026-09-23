//
//  ArtworkProcessor.swift
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

import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Scales cover pictures when they are added. A 4000×4000 PNG in every track
/// bloats an album by 200 MB (spec §4.5) — so the picture is scaled down when
/// it is added, not only when saving.
///
/// The work is done with ImageIO, not via `NSImage` and a self-made
/// `NSGraphicsContext`. The first attempt did exactly that and produced
/// **black pictures**: an `NSBitmapImageRep` with three channels and no
/// alpha means 24 bits per pixel, and CoreGraphics cannot back a bitmap
/// context with that. `NSGraphicsContext(bitmapImageRep:)` then returns
/// `nil`, drawing goes nowhere, and what remains is the zeroed bitmap.
/// ImageIO avoids this, is faster, keeps the color profile and rotates
/// EXIF-oriented pictures correctly by itself.
enum ArtworkProcessor {

    /// What should come out.
    enum Output: String, CaseIterable, Identifiable, Equatable, Sendable {
        /// Keep the source format. A PNG stays a PNG — even when scaled down.
        /// Before, it silently ended up in the tag as JPEG, although "convert"
        /// was switched off.
        case keepSource
        case jpeg

        var id: String { rawValue }

        var label: LocalizedStringResource {
            switch self {
            case .keepSource: "Keep original format"
            case .jpeg:       "JPEG"
            }
        }
    }

    struct Options: Equatable, Sendable {
        /// 0 means: do not scale.
        var maximumEdge: Int = 0
        var jpegQuality: Double = 0.85
        var output: Output = .keepSource

        /// Touch nothing — the picture goes into the tag unchanged.
        static let passthrough = Options()
    }

    static func prepare(
        _ data: Data,
        pictureType: PictureType = .frontCover,
        description: String? = nil,
        options: Options
    ) -> Artwork? {
        let sourceMime = Artwork.detectMimeType(of: data)
        guard sourceMime.hasPrefix("image/"),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else { return nil }

        func unchanged() -> Artwork {
            Artwork(data: data, mimeType: sourceMime,
                    pictureType: pictureType, description: description)
        }

        guard let size = pixelSize(of: source) else { return unchanged() }

        let longestEdge = max(size.width, size.height)
        let needsResize = options.maximumEdge > 0 && longestEdge > options.maximumEdge
        // PNG covers are the most common reason for bloated files.
        let needsConversion = options.output == .jpeg && sourceMime != "image/jpeg"
        guard needsResize || needsConversion else { return unchanged() }

        // When scaling down without converting, keep the source format as far
        // as we can write it; anything exotic ends up as JPEG.
        let targetMime = options.output == .jpeg
            ? "image/jpeg"
            : (sourceMime == "image/png" ? "image/png" : "image/jpeg")

        guard let image = makeImage(from: source,
                                    maximumEdge: needsResize ? options.maximumEdge : nil),
              let encoded = encode(image, as: targetMime, quality: options.jpegQuality)
        else {
            // Better to embed the original than nothing at all.
            return unchanged()
        }

        return Artwork(data: encoded, mimeType: targetMime,
                       pictureType: pictureType, description: description)
    }

    // MARK: - Internal

    /// Real pixel dimensions from the metadata — not `NSImage.size`, which
    /// returns points and is off for pictures with an unusual DPI value.
    static func pixelSize(of source: CGImageSource) -> (width: Int, height: Int)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return nil }
        return (width, height)
    }

    private static func makeImage(from source: CGImageSource, maximumEdge: Int?) -> CGImage? {
        guard let maximumEdge else {
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumEdge,
            // Rotates EXIF-oriented pictures right away instead of writing them
            // into the tag lying on their side.
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func encode(_ image: CGImage, as mimeType: String, quality: Double) -> Data? {
        let type: UTType = mimeType == "image/png" ? .png : .jpeg
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, type.identifier as CFString, 1, nil)
        else { return nil }

        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)

        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// Pixel dimensions without going through a `CGImageSource` — for the UI.
    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return pixelSize(of: source)
    }
}
