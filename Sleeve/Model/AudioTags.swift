//
//  AudioTags.swift
//  Sleeve
//

import Foundation

/// Einzelnes Tag-Feld. Grundlage für `TrackFile.touchedFields`: geschrieben
/// wird ausschließlich, was hier drinsteht — nie auf Basis eines
/// String-Vergleichs. Siehe Spec §4.1.
enum TagField: String, CaseIterable, Sendable, Hashable {
    case title
    case artist
    case albumArtist
    case album
    case composer
    case genre
    case year
    case trackNumber
    case trackTotal
    case discNumber
    case discTotal
    case comment
    case lyrics
    case isCompilation
    case artwork
}

struct AudioTags: Equatable, Sendable {
    var title: String?
    var artist: String?
    var albumArtist: String?
    var album: String?
    var composer: String?
    var genre: String?
    var year: Int?
    var trackNumber: Int?
    var trackTotal: Int?
    var discNumber: Int?
    var discTotal: Int?
    var comment: String?
    /// Unsynchronisierter Songtext. TagLib legt ihn als `USLT` (MP3),
    /// `©lyr` (MP4) bzw. `LYRICS` (Vorbis) ab.
    var lyrics: String?
    var isCompilation: Bool
    var artwork: [Artwork]

    init(
        title: String? = nil,
        artist: String? = nil,
        albumArtist: String? = nil,
        album: String? = nil,
        composer: String? = nil,
        genre: String? = nil,
        year: Int? = nil,
        trackNumber: Int? = nil,
        trackTotal: Int? = nil,
        discNumber: Int? = nil,
        discTotal: Int? = nil,
        comment: String? = nil,
        lyrics: String? = nil,
        isCompilation: Bool = false,
        artwork: [Artwork] = []
    ) {
        self.title = title
        self.artist = artist
        self.albumArtist = albumArtist
        self.album = album
        self.composer = composer
        self.genre = genre
        self.year = year
        self.trackNumber = trackNumber
        self.trackTotal = trackTotal
        self.discNumber = discNumber
        self.discTotal = discTotal
        self.comment = comment
        self.lyrics = lyrics
        self.isCompilation = isCompilation
        self.artwork = artwork
    }

    /// Textwert eines Feldes — für Inspector-Bindings und den
    /// `<Verschiedene>`-Vergleich bei Mehrfachauswahl.
    func stringValue(for field: TagField) -> String? {
        switch field {
        case .title:         title
        case .artist:        artist
        case .albumArtist:   albumArtist
        case .album:         album
        case .composer:      composer
        case .genre:         genre
        case .comment:       comment
        case .lyrics:        lyrics
        case .year:          year.map(String.init)
        case .trackNumber:   trackNumber.map(String.init)
        case .trackTotal:    trackTotal.map(String.init)
        case .discNumber:    discNumber.map(String.init)
        case .discTotal:     discTotal.map(String.init)
        case .isCompilation: isCompilation ? "1" : "0"
        case .artwork:       artwork.isEmpty ? nil : "\(artwork.count)"
        }
    }

    /// Gegenstück zu `stringValue(for:)`. Ein leerer String bedeutet
    /// „Feld leeren", nicht „nicht anfassen" — die Unterscheidung trifft
    /// allein `touchedFields`.
    mutating func setStringValue(_ value: String?, for field: TagField) {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = (text?.isEmpty ?? true) ? nil : text
        let number = cleaned.flatMap(Int.init)

        switch field {
        case .title:         title = cleaned
        case .artist:        artist = cleaned
        case .albumArtist:   albumArtist = cleaned
        case .album:         album = cleaned
        case .composer:      composer = cleaned
        case .genre:         genre = cleaned
        case .comment:       comment = cleaned
        case .lyrics:        lyrics = cleaned
        case .year:          year = number
        case .trackNumber:   trackNumber = number
        case .trackTotal:    trackTotal = number
        case .discNumber:    discNumber = number
        case .discTotal:     discTotal = number
        case .isCompilation: isCompilation = (cleaned == "1" || cleaned?.lowercased() == "true")
        case .artwork:       break   // Bilder laufen nicht über Text
        }
    }
}

/// Nur-lesende Kenndaten des Audiostreams. Kein Teil von `AudioTags`, weil
/// nichts davon schreibbar ist.
struct AudioProperties: Equatable, Sendable {
    var duration: Duration      // Spielzeit
    var bitrate: Int            // kbit/s
    var sampleRate: Int         // Hz
    var channels: Int

    static let unknown = AudioProperties(
        duration: .zero, bitrate: 0, sampleRate: 0, channels: 0
    )
}

/// Was `TagLibBridge.read` zurückgibt.
struct AudioFileInfo: Equatable, Sendable {
    var tags: AudioTags
    var properties: AudioProperties
}
