//
//  Artwork.swift
//  Sleeve
//

import Foundation

/// Bildtyp nach ID3v2-APIC-Konvention. TagLib verwendet dieselbe Nummerierung
/// für alle Formate und reicht sie als Klartext-String durch die
/// Complex-Property-API durch.
enum PictureType: UInt8, CaseIterable, Sendable, Hashable {
    case other              = 0x00
    case fileIcon           = 0x01
    case otherFileIcon      = 0x02
    case frontCover         = 0x03
    case backCover          = 0x04
    case leafletPage        = 0x05
    case media              = 0x06
    case leadArtist         = 0x07
    case artist             = 0x08
    case conductor          = 0x09
    case band               = 0x0A
    case composer           = 0x0B
    case lyricist           = 0x0C
    case recordingLocation  = 0x0D
    case duringRecording    = 0x0E
    case duringPerformance  = 0x0F
    case movieScreenCapture = 0x10
    case colouredFish       = 0x11
    case illustration       = 0x12
    case bandLogo           = 0x13
    case publisherLogo      = 0x14

    /// Exakt die Schreibweise, die `TagLib::Utils::pictureTypeToString` liefert
    /// und `pictureTypeFromString` wieder akzeptiert. Nicht frei formulieren —
    /// TagLib matcht auf Gleichheit und fällt sonst stumm auf `Other` zurück.
    var taglibName: String {
        switch self {
        case .other:              "Other"
        case .fileIcon:           "File Icon"
        case .otherFileIcon:      "Other File Icon"
        case .frontCover:         "Front Cover"
        case .backCover:          "Back Cover"
        case .leafletPage:        "Leaflet Page"
        case .media:              "Media"
        case .leadArtist:         "Lead Artist"
        case .artist:             "Artist"
        case .conductor:          "Conductor"
        case .band:               "Band"
        case .composer:           "Composer"
        case .lyricist:           "Lyricist"
        case .recordingLocation:  "Recording Location"
        case .duringRecording:    "During Recording"
        case .duringPerformance:  "During Performance"
        case .movieScreenCapture: "Movie Screen Capture"
        case .colouredFish:       "Coloured Fish"
        case .illustration:       "Illustration"
        case .bandLogo:           "Band Logo"
        case .publisherLogo:      "Publisher Logo"
        }
    }

    init(taglibName: String) {
        self = PictureType.allCases.first { $0.taglibName == taglibName } ?? .other
    }

    /// Was in einer Musiksammlung tatsächlich vorkommt. Die vollständige
    /// Liste aus 21 Einträgen — samt „Coloured Fish" — wäre in einem Menü
    /// nur im Weg.
    static let commonCases: [PictureType] = [
        .frontCover, .backCover, .leafletPage, .media,
        .artist, .band, .composer, .illustration, .other,
    ]

    var label: LocalizedStringResource {
        switch self {
        case .frontCover:   "Front cover"
        case .backCover:    "Back cover"
        case .leafletPage:  "Booklet page"
        case .media:        "Disc or label"
        case .artist:       "Artist"
        case .band:         "Band"
        case .composer:     "Composer"
        case .illustration: "Illustration"
        default:            "Other"
        }
    }
}

struct Artwork: Equatable, Sendable, Identifiable {
    let id: UUID
    var data: Data
    var mimeType: String              // image/jpeg, image/png
    var pictureType: PictureType      // frontCover, backCover, artist, …
    var description: String?

    init(
        id: UUID = UUID(),
        data: Data,
        mimeType: String,
        pictureType: PictureType = .frontCover,
        description: String? = nil
    ) {
        self.id = id
        self.data = data
        self.mimeType = mimeType
        self.pictureType = pictureType
        self.description = description
    }

    /// Zwei Bilder sind gleich, wenn ihr Inhalt gleich ist — die `id` ist nur
    /// zur Identifikation in der Liste da und darf den Vergleich nicht stören.
    /// Sonst gälte bei Mehrfachauswahl jedes Cover als „verschieden".
    static func == (lhs: Artwork, rhs: Artwork) -> Bool {
        lhs.data == rhs.data
            && lhs.mimeType == rhs.mimeType
            && lhs.pictureType == rhs.pictureType
            && lhs.description == rhs.description
    }

    /// Bringt die Vorderseite an die erste Stelle.
    ///
    /// Abspielprogramme greifen sich in der Regel das **erste** eingebettete
    /// Bild; nur ein Teil von ihnen wertet den Bildtyp aus. Wer nachträglich
    /// eine neue Vorderseite einfügt, bekäme sie sonst hinter der
    /// Booklet-Seite einsortiert — und im Player das Booklet als Cover.
    ///
    /// Alles außer der Vorderseite behält seine Reihenfolge: Booklet-Seiten
    /// nach Bildtyp umzusortieren würde ihre Abfolge zerstören.
    static func sortedForEmbedding(_ artwork: [Artwork]) -> [Artwork] {
        artwork.enumerated()
            .sorted { left, right in
                let leftRank = left.element.pictureType == .frontCover ? 0 : 1
                let rightRank = right.element.pictureType == .frontCover ? 0 : 1
                return leftRank == rightRank
                    ? left.offset < right.offset
                    : leftRank < rightRank
            }
            .map(\.element)
    }

    /// MIME-Typ aus den ersten Bytes ableiten — verlässlicher als die
    /// Dateiendung, gerade bei Drag & Drop aus dem Browser.
    static func detectMimeType(of data: Data) -> String {
        let prefix = [UInt8](data.prefix(12))
        switch prefix {
        case let p where p.starts(with: [0xFF, 0xD8, 0xFF]):
            return "image/jpeg"
        case let p where p.starts(with: [0x89, 0x50, 0x4E, 0x47]):
            return "image/png"
        case let p where p.starts(with: [0x47, 0x49, 0x46]):
            return "image/gif"
        case let p where p.count >= 12
            && Array(p[0..<4]) == [0x52, 0x49, 0x46, 0x46]
            && Array(p[8..<12]) == [0x57, 0x45, 0x42, 0x50]:
            return "image/webp"
        default:
            return "application/octet-stream"
        }
    }
}
