//
//  PatternToken.swift
//  Sleeve
//

import Foundation

/// Die Platzhalter der Pattern-Engine. Dieselbe Syntax in beide Richtungen:
/// Tags → Dateiname und Dateiname → Tags (Spec §4.4).
enum PatternToken: String, CaseIterable, Identifiable, Sendable {
    case artist
    case albumartist
    case album
    case title
    case track
    case disc
    case year
    case genre
    case composer

    var id: String { rawValue }

    var placeholder: String { "%\(rawValue)%" }

    /// Hängt den Platzhalter an ein Muster an und setzt dabei ein
    /// Trennzeichen, wenn keines da ist.
    ///
    /// Ohne das entsteht beim Zusammenklicken `%title%%artist%` — zwei
    /// Angaben ohne Lücke, was praktisch nie gemeint ist und im fertigen
    /// Dateinamen erst auffällt, wenn man genau hinsieht.
    func appended(to pattern: String) -> String {
        guard !pattern.isEmpty else { return placeholder }
        let separators: Set<Character> = [" ", "-", "_", ".", ",", "/", "(", "["]
        guard let last = pattern.last, !separators.contains(last) else {
            return pattern + placeholder
        }
        return pattern + " - " + placeholder
    }

    var field: TagField {
        switch self {
        case .artist:      .artist
        case .albumartist: .albumArtist
        case .album:       .album
        case .title:       .title
        case .track:       .trackNumber
        case .disc:        .discNumber
        case .year:        .year
        case .genre:       .genre
        case .composer:    .composer
        }
    }

    /// Numerische Token werden beim Rendern mit führenden Nullen aufgefüllt
    /// und beim Parsen nur auf Ziffern gematcht.
    var isNumeric: Bool {
        switch self {
        case .track, .disc, .year: true
        default: false
        }
    }

    /// Jahreszahlen bekommen keine führenden Nullen.
    var padding: Int {
        switch self {
        case .track, .disc: 2
        default:            0
        }
    }
}

/// Ein Pattern zerfällt in Literale und Token.
enum PatternElement: Equatable, Sendable {
    case literal(String)
    case token(PatternToken)
}

enum PatternSyntax {

    /// Zerlegt `%track% - %title%` in Literale und Token.
    /// Ein `%%` steht für ein wörtliches Prozentzeichen.
    static func parse(_ pattern: String) -> [PatternElement] {
        var elements: [PatternElement] = []
        var literal = ""
        var rest = Substring(pattern)

        while let start = rest.firstIndex(of: "%") {
            literal += rest[rest.startIndex..<start]
            let afterStart = rest.index(after: start)

            // "%%" → wörtliches Prozentzeichen
            if afterStart < rest.endIndex, rest[afterStart] == "%" {
                literal += "%"
                rest = rest[rest.index(after: afterStart)...]
                continue
            }

            guard let end = rest[afterStart...].firstIndex(of: "%"),
                  let token = PatternToken(rawValue: String(rest[afterStart..<end]).lowercased())
            else {
                // Kein gültiges Token — das Prozentzeichen bleibt Literal.
                literal += "%"
                rest = rest[afterStart...]
                continue
            }

            if !literal.isEmpty {
                elements.append(.literal(literal))
                literal = ""
            }
            elements.append(.token(token))
            rest = rest[rest.index(after: end)...]
        }

        literal += rest
        if !literal.isEmpty { elements.append(.literal(literal)) }
        return elements
    }

    /// Prüft, ob überhaupt ein Token vorkommt — ein Pattern ohne Token würde
    /// alle Dateien gleich benennen.
    static func containsToken(_ pattern: String) -> Bool {
        parse(pattern).contains { if case .token = $0 { true } else { false } }
    }
}
