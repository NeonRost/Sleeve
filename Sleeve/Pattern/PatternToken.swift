//
//  PatternToken.swift
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

/// The placeholders of the pattern engine. The same syntax in both
/// directions: tags → file name and file name → tags (spec §4.4).
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

    /// Appends the placeholder to a pattern, inserting a separator if there
    /// is none.
    ///
    /// Without it, clicking placeholders together yields `%title%%artist%` —
    /// two values without a gap, which is practically never intended and only
    /// shows in the finished file name if one looks closely.
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

    /// Numeric tokens are padded with leading zeros when rendering and only
    /// match digits when parsing.
    var isNumeric: Bool {
        switch self {
        case .track, .disc, .year: true
        default: false
        }
    }

    /// Years get no leading zeros.
    var padding: Int {
        switch self {
        case .track, .disc: 2
        default:            0
        }
    }
}

/// A pattern breaks down into literals and tokens.
enum PatternElement: Equatable, Sendable {
    case literal(String)
    case token(PatternToken)
}

enum PatternSyntax {

    /// Splits `%track% - %title%` into literals and tokens.
    /// A `%%` stands for a literal percent sign.
    static func parse(_ pattern: String) -> [PatternElement] {
        var elements: [PatternElement] = []
        var literal = ""
        var rest = Substring(pattern)

        while let start = rest.firstIndex(of: "%") {
            literal += rest[rest.startIndex..<start]
            let afterStart = rest.index(after: start)

            // "%%" → literal percent sign
            if afterStart < rest.endIndex, rest[afterStart] == "%" {
                literal += "%"
                rest = rest[rest.index(after: afterStart)...]
                continue
            }

            guard let end = rest[afterStart...].firstIndex(of: "%"),
                  let token = PatternToken(rawValue: String(rest[afterStart..<end]).lowercased())
            else {
                // Not a valid token — the percent sign stays a literal.
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

    /// Checks whether there is any token at all — a pattern without tokens
    /// would give every file the same name.
    static func containsToken(_ pattern: String) -> Bool {
        parse(pattern).contains { if case .token = $0 { true } else { false } }
    }
}
