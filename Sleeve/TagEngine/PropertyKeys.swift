//
//  PropertyKeys.swift
//  Sleeve
//

import Foundation

/// Schlüssel der TagLib-PropertyMap.
///
/// TagLib übersetzt diese generischen Namen selbst in das jeweils native Feld
/// (`TPE2` / `aART` / `ALBUMARTIST` …). Deshalb läuft in Sleeve **alles** über
/// die PropertyMap und nichts über die Legacy-Tag-API — siehe Spec §2.1.1.
enum PropertyKeys {
    static let title       = "TITLE"
    static let artist      = "ARTIST"
    static let albumArtist = "ALBUMARTIST"
    static let album       = "ALBUM"
    static let composer    = "COMPOSER"
    static let genre       = "GENRE"
    static let date        = "DATE"
    static let trackNumber = "TRACKNUMBER"
    static let discNumber  = "DISCNUMBER"
    static let comment     = "COMMENT"
    static let lyrics      = "LYRICS"
    static let compilation = "COMPILATION"

    /// Complex Property für eingebettete Bilder.
    static let picture     = "PICTURE"

    /// Attributnamen innerhalb einer PICTURE-Complex-Property.
    enum PictureAttribute {
        static let data        = "data"
        static let mimeType    = "mimeType"
        static let description = "description"
        static let pictureType = "pictureType"
    }
}

/// `TRACKNUMBER` und `DISCNUMBER` transportieren je nach Format entweder nur
/// die Nummer ("3") oder Nummer und Gesamtzahl ("3/12"). TagLib normalisiert
/// das nicht — Sleeve muss beide Formen lesen und beim Schreiben wieder
/// zusammensetzen.
struct NumberPair: Equatable, Sendable {
    var number: Int?
    var total: Int?

    init(number: Int? = nil, total: Int? = nil) {
        self.number = number
        self.total = total
    }

    init(parsing value: String) {
        let parts = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        number = parts.first.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        total = parts.count > 1
            ? Int(parts[1].trimmingCharacters(in: .whitespaces))
            : nil
    }

    /// `nil`, wenn nichts zu schreiben ist — dann wird die Property entfernt.
    var formatted: String? {
        switch (number, total) {
        case let (.some(n), .some(t)): "\(n)/\(t)"
        case let (.some(n), .none):    "\(n)"
        // Gesamtzahl ohne Nummer ergibt in keinem Format einen gültigen Wert.
        case (.none, _):               nil
        }
    }
}

extension String {
    /// `DATE` kann "1987", "1987-05-01" oder "1987-05" sein. Für Sleeve zählt
    /// nur das Jahr.
    var leadingYear: Int? {
        let digits = prefix { $0.isNumber }
        guard digits.count == 4 else { return nil }
        return Int(digits)
    }
}
