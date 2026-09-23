//
//  ArtworkProcessor.swift
//  Sleeve
//

import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Skaliert Coverbilder beim Einfügen. Ein 4000×4000-PNG in jedem Track bläht
/// ein Album um 200 MB auf (Spec §4.5) — deshalb wird beim Hinzufügen
/// heruntergerechnet, nicht erst beim Speichern.
///
/// Gearbeitet wird mit ImageIO, nicht über `NSImage` und einen selbst
/// aufgespannten `NSGraphicsContext`. Der erste Anlauf tat genau das und
/// lieferte **schwarze Bilder**: `NSBitmapImageRep` mit drei Kanälen ohne
/// Alpha ergibt 24 Bit pro Pixel, und dafür kann CoreGraphics keinen
/// Bitmap-Kontext hinterlegen. `NSGraphicsContext(bitmapImageRep:)` gibt dann
/// `nil` zurück, gezeichnet wird ins Leere, und übrig bleibt die genullte
/// Bitmap. ImageIO umgeht das, ist schneller, behält das Farbprofil und dreht
/// EXIF-orientierte Bilder von selbst richtig.
enum ArtworkProcessor {

    /// Was hinten herauskommen soll.
    enum Output: String, CaseIterable, Identifiable, Equatable, Sendable {
        /// Format der Quelle beibehalten. Ein PNG bleibt ein PNG — auch beim
        /// Verkleinern. Vorher landete es dabei stillschweigend als JPEG im
        /// Tag, obwohl „umwandeln" ausgeschaltet war.
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
        /// 0 heißt: nicht skalieren.
        var maximumEdge: Int = 0
        var jpegQuality: Double = 0.85
        var output: Output = .keepSource

        /// Nichts anfassen — das Bild wandert unverändert ins Tag.
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
        // PNG-Cover sind der häufigste Grund für aufgeblähte Dateien.
        let needsConversion = options.output == .jpeg && sourceMime != "image/jpeg"
        guard needsResize || needsConversion else { return unchanged() }

        // Beim Verkleinern ohne Umwandeln das Quellformat halten, soweit wir
        // es schreiben können; alles Exotische landet als JPEG.
        let targetMime = options.output == .jpeg
            ? "image/jpeg"
            : (sourceMime == "image/png" ? "image/png" : "image/jpeg")

        guard let image = makeImage(from: source,
                                    maximumEdge: needsResize ? options.maximumEdge : nil),
              let encoded = encode(image, as: targetMime, quality: options.jpegQuality)
        else {
            // Lieber das Original einbetten als gar nichts.
            return unchanged()
        }

        return Artwork(data: encoded, mimeType: targetMime,
                       pictureType: pictureType, description: description)
    }

    // MARK: - Intern

    /// Echte Pixelmaße aus den Metadaten — nicht `NSImage.size`, das liefert
    /// Punkte und geht bei Bildern mit abweichender DPI-Angabe daneben.
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
            // Dreht EXIF-orientierte Bilder gleich richtig, statt sie liegend
            // ins Tag zu schreiben.
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

    /// Pixelmaße ohne Umweg über eine `CGImageSource` — für die Oberfläche.
    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return pixelSize(of: source)
    }
}
