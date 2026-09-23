//
//  CDText.swift
//  Sleeve
//
//  CD-TEXT steht auf der Scheibe selbst. Für Alben, die in keiner Datenbank
//  eingetragen sind, ist es oft die einzige Quelle — und es kostet kein
//  Netz und keine Wartezeit.
//
//  Aufbau: Pakete zu 18 Byte. Vier Byte Kopf (Typ, Tracknummer, laufende
//  Nummer, Blockinfo), zwölf Byte Text, zwei Byte CRC. Ein Textfeld läuft
//  über beliebig viele Pakete und ist mit einem Nullbyte abgeschlossen;
//  die Pakete eines Typs bilden zusammen eine Kette aus Feldern, in der
//  Eintrag 0 zum Album gehört und 1…n zu den Spuren.
//

import Foundation

struct CDText: Equatable, Sendable {
    /// Index 0 ist das Album, 1…n sind die Spuren.
    var titles: [Int: String] = [:]
    var performers: [Int: String] = [:]
    var songwriters: [Int: String] = [:]
    var composers: [Int: String] = [:]
    var arrangers: [Int: String] = [:]

    var albumTitle: String? { titles[0] }
    var albumArtist: String? { performers[0] }
    var albumComposer: String? { composers[0] }

    var isEmpty: Bool {
        titles.isEmpty && performers.isEmpty && songwriters.isEmpty
            && composers.isEmpty && arrangers.isEmpty
    }

    func title(forTrack number: Int) -> String? { titles[number] }
    func performer(forTrack number: Int) -> String? { performers[number] ?? performers[0] }
    func composer(forTrack number: Int) -> String? { composers[number] ?? composers[0] }

    // MARK: - Auswerten

    private enum PackType: UInt8 {
        case title = 0x80, performer = 0x81, songwriter = 0x82
        case composer = 0x83, arranger = 0x84
        case sizeInfo = 0x8F
    }

    /// `payload` ist der Rumpf der TOC-Antwort im Format 5, also ohne den
    /// vier Byte langen Kopf.
    init(packets payload: [UInt8]) {
        // Der Zeichensatz steht im Size-Info-Paket. 0x00 ist Latin-1, 0x80
        // ist MS-JIS. Ohne Angabe gilt Latin-1 — als UTF-8 gelesen zerfallen
        // Umlaute zu Ersatzzeichen, was beim ersten Anlauf auch passiert ist.
        var encoding = String.Encoding.isoLatin1
        var index = 0
        while index + 18 <= payload.count {
            if payload[index] == PackType.sizeInfo.rawValue, payload[index + 2] == 0 {
                if payload[index + 4] == 0x80 { encoding = .shiftJIS }
                break
            }
            index += 18
        }

        // Erst alle Textbytes je Typ aneinanderhängen, dann an den Nullbytes
        // trennen — ein Feld darf über Paketgrenzen laufen.
        var streams: [UInt8: [UInt8]] = [:]
        var startTrack: [UInt8: Int] = [:]
        index = 0
        while index + 18 <= payload.count {
            let type = payload[index]
            let track = Int(payload[index + 1] & 0x7F)
            if PackType(rawValue: type) != nil, type != PackType.sizeInfo.rawValue {
                if streams[type] == nil { startTrack[type] = track }
                streams[type, default: []].append(contentsOf: payload[(index + 4)..<(index + 16)])
            }
            index += 18
        }

        for (type, bytes) in streams {
            var fields = bytes.split(separator: 0, omittingEmptySubsequences: false)
            // Hinter dem letzten Nullbyte steht nur noch Füllmaterial.
            if !fields.isEmpty { fields.removeLast() }

            var entries: [Int: String] = [:]
            let base = startTrack[type] ?? 0
            for (position, field) in fields.enumerated() {
                guard !field.isEmpty,
                      let text = String(bytes: field, encoding: encoding)?
                          .trimmingCharacters(in: .whitespaces),
                      !text.isEmpty
                else { continue }
                entries[base + position] = text
            }

            switch PackType(rawValue: type) {
            case .title:      titles = entries
            case .performer:  performers = entries
            case .songwriter: songwriters = entries
            case .composer:   composers = entries
            case .arranger:   arrangers = entries
            default: break
            }
        }
    }

    init() {}
}
