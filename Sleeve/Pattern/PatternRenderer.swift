//
//  PatternRenderer.swift
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
//  Tags → file name (spec §4.4).
//

import Foundation

struct PatternRenderer: Sendable {

    /// Characters that have no business in a file name. `/` separates path
    /// components on APFS, `:` is the historical Finder separator and shows up
    /// in the Finder as `/`. The rest is not for macOS but for SMB and exFAT —
    /// music collections end up on NAS drives.
    ///
    /// `%` is deliberately **not** in here: it is allowed everywhere, and a
    /// `%%` in the pattern should arrive in the name as a percent sign.
    static let invalidCharacters = CharacterSet(charactersIn: "/:\\?*|\"<>")
        .union(.controlCharacters)

    /// What invalid characters are replaced with — configurable (spec §4.4).
    var replacement: String = "_"

    /// Leading zeros for track and disc numbers (01 instead of 1), spec §4.2.
    var padsNumbers: Bool = true

    func render(_ pattern: String, tags: AudioTags) -> String {
        let elements = PatternSyntax.parse(pattern)

        // A token and the literal before it form a group. If the tag value
        // is missing, the whole group is dropped — otherwise the result
        // would be "01 -  - Title" (spec §4.4).
        var result = ""
        var pendingLiteral = ""

        for element in elements {
            switch element {
            case .literal(let text):
                pendingLiteral += text
            case .token(let token):
                if let value = value(of: token, in: tags), !value.isEmpty {
                    result += pendingLiteral + value
                }
                pendingLiteral = ""
            }
        }
        result += pendingLiteral

        return sanitize(result)
    }

    private func value(of token: PatternToken, in tags: AudioTags) -> String? {
        guard let raw = tags.stringValue(for: token.field) else { return nil }
        guard token.isNumeric else { return raw }
        guard let number = Int(raw) else { return nil }
        return padsNumbers && token.padding > 0
            ? String(format: "%0\(token.padding)d", number)
            : String(number)
    }

    /// Replace invalid characters, clear separators off the edges.
    func sanitize(_ name: String) -> String {
        var cleaned = name
            .components(separatedBy: Self.invalidCharacters)
            .joined(separator: replacement)

        // Leading and trailing separators appear when a group at the edge
        // was dropped.
        let trimmable = CharacterSet(charactersIn: " -_.")
        while let first = cleaned.unicodeScalars.first, trimmable.contains(first) {
            cleaned.removeFirst()
        }
        while let last = cleaned.unicodeScalars.last, trimmable.contains(last) {
            cleaned.removeLast()
        }

        // Collapse repeated spaces.
        while cleaned.contains("  ") {
            cleaned = cleaned.replacingOccurrences(of: "  ", with: " ")
        }
        return cleaned
    }

    /// Renders for a whole list and resolves name collisions with `" (2)"`.
    /// Files in the same folder that would get the same name would otherwise
    /// overwrite each other.
    func renderAll(
        _ pattern: String,
        for entries: [(url: URL, tags: AudioTags)]
    ) -> [String] {
        var used: Set<String> = []
        var results: [String] = []

        for entry in entries {
            let ext = entry.url.pathExtension
            var base = render(pattern, tags: entry.tags)
            if base.isEmpty { base = entry.url.deletingPathExtension().lastPathComponent }

            let folder = entry.url.deletingLastPathComponent().path(percentEncoded: false)
            var candidate = base
            var counter = 2
            // Case-insensitive comparison, because that is APFS's default.
            while !used.insert("\(folder)/\(candidate.lowercased()).\(ext.lowercased())").inserted {
                candidate = "\(base) (\(counter))"
                counter += 1
            }

            results.append(ext.isEmpty ? candidate : "\(candidate).\(ext)")
        }
        return results
    }
}
