//
//  PatternParser.swift
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
//  File name → tags (spec §4.4). The same pattern backwards: every
//  `%token%` becomes a named capture group, everything in between is
//  escaped literally.
//

import Foundation

struct PatternParser: Sendable {

    struct Match: Sendable {
        var values: [TagField: String] = [:]
        var isEmpty: Bool { values.isEmpty }
    }

    enum ParserError: Error, Equatable {
        case noTokens
        case invalidPattern(String)
    }

    let pattern: String
    private let regex: NSRegularExpression
    private let tokens: [PatternToken]
    /// Does the pattern include folder names (`%artist%/%album%/…`)?
    private let usesFolders: Bool

    init(pattern: String) throws {
        self.pattern = pattern
        let elements = PatternSyntax.parse(pattern)

        var tokens: [PatternToken] = []
        var expression = ""
        var seen: Set<PatternToken> = []

        for element in elements {
            switch element {
            case .literal(let text):
                expression += NSRegularExpression.escapedPattern(for: text)
            case .token(let token):
                tokens.append(token)
                // If the same token occurs twice, the group must not carry the
                // same name twice.
                let name = seen.insert(token).inserted
                    ? token.rawValue
                    : "\(token.rawValue)_\(tokens.count)"
                expression += "(?<\(name)>\(token.isNumeric ? "\\d+" : ".+?"))"
            }
        }

        guard !tokens.isEmpty else { throw ParserError.noTokens }
        self.tokens = tokens
        self.usesFolders = pattern.contains("/")

        // Anchor at start and end, or the pattern matches somewhere in the
        // middle and yields nonsense.
        do {
            self.regex = try NSRegularExpression(pattern: "^" + expression + "$")
        } catch {
            throw ParserError.invalidPattern(expression)
        }
    }

    /// The text matched against: the file name without extension, and for
    /// folder patterns with as many parent folders in front as the pattern
    /// has levels.
    func subject(for url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        guard usesFolders else { return base }

        let levels = pattern.filter { $0 == "/" }.count
        var components: [String] = [base]
        var folder = url.deletingLastPathComponent()
        for _ in 0..<levels {
            let name = folder.lastPathComponent
            guard !name.isEmpty, name != "/" else { break }
            components.insert(name, at: 0)
            folder = folder.deletingLastPathComponent()
        }
        return components.joined(separator: "/")
    }

    func match(_ url: URL) -> Match? {
        let subject = subject(for: url)
        let range = NSRange(subject.startIndex..., in: subject)
        guard let result = regex.firstMatch(in: subject, range: range) else { return nil }

        var match = Match()
        var seen: Set<PatternToken> = []
        for (index, token) in tokens.enumerated() {
            let name = seen.insert(token).inserted
                ? token.rawValue
                : "\(token.rawValue)_\(index + 1)"
            let groupRange = result.range(withName: name)
            guard groupRange.location != NSNotFound,
                  let swiftRange = Range(groupRange, in: subject)
            else { continue }

            let value = String(subject[swiftRange])
                .trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }

            // Leading zeros are dropped — the tag holds a number.
            match.values[token.field] = token.isNumeric
                ? String(Int(value) ?? 0)
                : value
        }
        return match.isEmpty ? nil : match
    }

    /// Ready-made patterns from spec §4.4.
    static let presets: [String] = [
        "%track% - %title%",
        "%artist% - %title%",
        "%track%. %artist% - %title%",
        "%artist% - %album% - %track% - %title%",
        "%artist%/%album%/%track% - %title%",
    ]
}
