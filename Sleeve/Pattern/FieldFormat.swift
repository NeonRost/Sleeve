//
//  FieldFormat.swift
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
//  Fill one field from a pattern (spec §4.3.2) — what Mp3tag calls "Format
//  value": album artist = `%artist%`, title = `%track% %title%`, or the
//  title from the file name with `%filename%`.
//
//  The same placeholders as renaming, plus two that describe the file rather
//  than its tags. And unlike renaming the result is a tag, not a file name:
//  a "/" or ":" in it is fine and stays.
//

import Foundation

struct FieldFormat: Sendable, Equatable {
    var pattern = ""
    /// Leading zeros for track and disc numbers — off by default, a tag
    /// usually holds "3", not "03".
    var padsNumbers = false

    /// Placeholders about the file, not its tags.
    enum FileToken: String, CaseIterable, Sendable {
        /// The file name without extension.
        case filename
        /// The name of the folder the file is in.
        case folder

        var placeholder: String { "%\(rawValue)%" }
    }

    enum Element: Equatable, Sendable {
        case literal(String)
        case tag(PatternToken)
        case file(FileToken)
    }

    /// Like `PatternSyntax.parse`, with the file placeholders added. `%%` is
    /// a percent sign; an unknown `%name%` stays text.
    static func parse(_ pattern: String) -> [Element] {
        var elements: [Element] = []
        var literal = ""
        var rest = Substring(pattern)

        while let start = rest.firstIndex(of: "%") {
            literal += rest[rest.startIndex..<start]
            let afterStart = rest.index(after: start)

            if afterStart < rest.endIndex, rest[afterStart] == "%" {
                literal += "%"
                rest = rest[rest.index(after: afterStart)...]
                continue
            }

            let name = rest[afterStart...].firstIndex(of: "%")
                .map { String(rest[afterStart..<$0]).lowercased() }
            let element: Element? = name.flatMap { name in
                PatternToken(rawValue: name).map(Element.tag)
                    ?? FileToken(rawValue: name).map(Element.file)
            }
            guard let element, let name else {
                literal += "%"
                rest = rest[afterStart...]
                continue
            }

            if !literal.isEmpty {
                elements.append(.literal(literal))
                literal = ""
            }
            elements.append(element)
            rest = rest[rest.index(afterStart, offsetBy: name.count + 1)...]
        }

        literal += rest
        if !literal.isEmpty { elements.append(.literal(literal)) }
        return elements
    }

    /// Whether the pattern has a placeholder at all — without one, every
    /// track would get the same text, which is better done in the inspector.
    var containsToken: Bool {
        Self.parse(pattern).contains { if case .literal = $0 { false } else { true } }
    }

    /// The value for one file. As with file names, a missing value takes
    /// the text before it along: "%artist% - %title%" without an artist
    /// gives "Title", not " - Title". `nil` when nothing is left.
    func render(tags: AudioTags, fileURL: URL) -> String? {
        var result = ""
        var pendingLiteral = ""

        for element in Self.parse(pattern) {
            switch element {
            case .literal(let text):
                pendingLiteral += text
            case .tag(let token):
                if let value = value(of: token, in: tags), !value.isEmpty {
                    result += pendingLiteral + value
                }
                pendingLiteral = ""
            case .file(let token):
                let value = Self.fileValue(of: token, for: fileURL)
                if !value.isEmpty { result += pendingLiteral + value }
                pendingLiteral = ""
            }
        }
        result += pendingLiteral

        // Only spaces and separators at the edges go — the ones a dropped
        // group leaves behind. A full stop stays: "Vol. 2." is a title.
        let edges = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-–—_,:/"))
        var cleaned = result.trimmingCharacters(in: edges)
        while cleaned.contains("  ") {
            cleaned = cleaned.replacingOccurrences(of: "  ", with: " ")
        }
        return cleaned.isEmpty ? nil : cleaned
    }

    private func value(of token: PatternToken, in tags: AudioTags) -> String? {
        guard let raw = tags.stringValue(for: token.field) else { return nil }
        guard token.isNumeric else { return raw }
        guard let number = Int(raw) else { return raw }
        return padsNumbers && token.padding > 0
            ? String(format: "%0\(token.padding)d", number)
            : String(number)
    }

    static func fileValue(of token: FileToken, for url: URL) -> String {
        switch token {
        case .filename: url.deletingPathExtension().lastPathComponent
        case .folder:   url.deletingLastPathComponent().lastPathComponent
        }
    }
}
