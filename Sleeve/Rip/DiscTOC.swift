//
//  DiscTOC.swift
//  Sleeve
//
//  Das Inhaltsverzeichnis der CD und alles, was sich allein daraus ergibt:
//  Tracklängen, MusicBrainz Disc ID, FreeDB-ID, Cue Sheet.
//
//  Reine Rechnerei ohne Gerätezugriff — deshalb vollständig testbar, ohne
//  dass eine Scheibe im Laufwerk liegen muss.
//

import CryptoKit
import Foundation

/// Ein Sektor einer Audio-CD fasst 588 Stereo-Samples zu je 4 Byte.
enum CDGeometry {
    static let bytesPerSector = 2352
    static let samplesPerSector = 588
    static let bytesPerSample = 4
    static let sectorsPerSecond = 75
    /// CDs zählen ab 00:02:00, nicht ab null. Der Versatz von 150 Sektoren
    /// steckt in jeder Adressumrechnung.
    static let leadInSectors = 150
}

struct DiscTrack: Equatable, Sendable, Identifiable {
    var number: Int
    /// Startsektor, gemessen ab Track 1 = 0 (also ohne die 150 Lead-In-Sektoren).
    var startLBA: Int
    var sectorCount: Int
    var isData: Bool
    /// Aus dem Subchannel gelesen, falls vorhanden.
    var isrc: String?

    var id: Int { number }
    var endLBA: Int { startLBA + sectorCount }
    var duration: Duration {
        .seconds(Double(sectorCount) / Double(CDGeometry.sectorsPerSecond))
    }
    var byteCount: Int { sectorCount * CDGeometry.bytesPerSector }
}

struct DiscTOC: Equatable, Sendable {
    var firstTrack: Int
    var lastTrack: Int
    /// Startsektor des Lead-Out, also das Ende der letzten Spur.
    var leadOutLBA: Int
    var tracks: [DiscTrack]
    var mcn: String?

    var audioTracks: [DiscTrack] { tracks.filter { !$0.isData } }
    var hasDataTrack: Bool { tracks.contains(where: \.isData) }

    var totalDuration: Duration {
        .seconds(Double(leadOutLBA) / Double(CDGeometry.sectorsPerSecond))
    }

    // MARK: - Rohe TOC aus IOKit auswerten

    /// Wertet die `TOC`-Eigenschaft eines `IOCDMedia`-Objekts aus. Das ist ein
    /// `CDTOC`: vier Byte Kopf, dann 11-Byte-Deskriptoren.
    ///
    /// Interessant sind die Sonderpunkte 0xA0 (erster Track), 0xA1 (letzter)
    /// und 0xA2 (Lead-Out) sowie die Punkte 1…99 für die Spuren selbst.
    init?(rawTOC data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }

        // Das Längenfeld zählt ab hinter sich selbst.
        let declared = (Int(bytes[0]) << 8 | Int(bytes[1])) + 2
        let limit = min(declared, bytes.count)

        var first = 0, last = 0, leadOut = -1
        var starts: [Int: (lba: Int, isData: Bool)] = [:]

        var i = 4
        while i + 11 <= limit {
            let d = Array(bytes[i..<(i + 11)])
            i += 11

            let control = d[1] & 0x0F
            let point = d[3]
            // Die P-Adresse steht als Minute/Sekunde/Frame in den letzten
            // drei Byte des Deskriptors.
            let pLBA = (Int(d[8]) * 60 + Int(d[9])) * CDGeometry.sectorsPerSecond
                + Int(d[10]) - CDGeometry.leadInSectors

            switch point {
            case 0xA0: first = Int(d[8])
            case 0xA1: last = Int(d[8])
            case 0xA2: leadOut = pLBA
            case 1...99:
                // Bit 2 des Control-Nibbles unterscheidet Daten von Audio.
                starts[Int(point)] = (pLBA, control & 0x04 != 0)
            default: break
            }
        }

        guard first > 0, last >= first, leadOut > 0, !starts.isEmpty else { return nil }

        // Die Länge einer Spur ergibt sich erst aus dem Anfang der nächsten.
        var built: [DiscTrack] = []
        for number in first...last {
            guard let entry = starts[number] else { continue }
            let next = starts[number + 1]?.lba ?? leadOut
            built.append(DiscTrack(number: number,
                                   startLBA: entry.lba,
                                   sectorCount: max(0, next - entry.lba),
                                   isData: entry.isData))
        }
        guard !built.isEmpty else { return nil }

        self.firstTrack = first
        self.lastTrack = last
        self.leadOutLBA = leadOut
        self.tracks = built
        self.mcn = nil
    }

    /// Direkter Weg für Tests.
    init(firstTrack: Int, lastTrack: Int, leadOutLBA: Int,
         tracks: [DiscTrack], mcn: String? = nil) {
        self.firstTrack = firstTrack
        self.lastTrack = lastTrack
        self.leadOutLBA = leadOutLBA
        self.tracks = tracks
        self.mcn = mcn
    }

    // MARK: - Kennungen

    /// MusicBrainz Disc ID: SHA-1 über erste und letzte Tracknummer, den
    /// Lead-Out und 99 Trackoffsets, alle als Hex in Großbuchstaben. Das
    /// Ergebnis wandert in Base64, wobei `+/=` durch `._-` ersetzt werden,
    /// damit die Kennung in eine URL passt.
    ///
    /// Geprüft gegen das Rechenbeispiel aus der MusicBrainz-Dokumentation.
    var musicBrainzDiscID: String {
        var input = String(format: "%02X%02X", firstTrack, lastTrack)
        input += String(format: "%08X", leadOutLBA + CDGeometry.leadInSectors)

        var offsets = [Int](repeating: 0, count: 100)
        for track in tracks where (1...99).contains(track.number) {
            offsets[track.number] = track.startLBA + CDGeometry.leadInSectors
        }
        for number in 1...99 {
            input += String(format: "%08X", number <= lastTrack ? offsets[number] : 0)
        }

        let digest = Data(Insecure.SHA1.hash(data: Data(input.utf8)))
        return digest.base64EncodedString()
            .replacingOccurrences(of: "+", with: ".")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "-")
    }

    /// Die alte FreeDB-Kennung. MusicBrainz nimmt sie als zweiten Suchweg an,
    /// und XLD führt sie im Log mit.
    var freeDBID: String {
        var checksum = 0
        for track in tracks {
            var seconds = (track.startLBA + CDGeometry.leadInSectors) / CDGeometry.sectorsPerSecond
            while seconds > 0 {
                checksum += seconds % 10
                seconds /= 10
            }
        }
        let firstStart = tracks.first?.startLBA ?? 0
        let total = (leadOutLBA + CDGeometry.leadInSectors) / CDGeometry.sectorsPerSecond
            - (firstStart + CDGeometry.leadInSectors) / CDGeometry.sectorsPerSecond
        let value = (UInt32(checksum % 255) << 24) | (UInt32(total) << 8) | UInt32(lastTrack & 0xFF)
        return String(format: "%08x", value)
    }

    /// Für die MusicBrainz-Suche, wenn die Disc ID nicht eingetragen ist:
    /// `erster letzter leadout offset1 offset2 …`
    var musicBrainzTOCParameter: String {
        var parts = [String(firstTrack), String(lastTrack),
                     String(leadOutLBA + CDGeometry.leadInSectors)]
        parts += tracks.map { String($0.startLBA + CDGeometry.leadInSectors) }
        return parts.joined(separator: "+")
    }
}
