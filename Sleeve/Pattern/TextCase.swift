//
//  TextCase.swift
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
//  Capitalization (spec §4.3).
//

import Foundation

enum TextCase: String, CaseIterable, Identifiable, Sendable {
    case titleCase
    case upperCase
    case lowerCase

    var id: String { rawValue }

    var label: LocalizedStringResource {
        switch self {
        case .titleCase: "Title Case"
        case .upperCase: "UPPERCASE"
        case .lowerCase: "lowercase"
        }
    }

    /// Words kept lowercase in Title Case. Language-dependent — "Die Ärzte"
    /// and "The Doors" need different lists.
    enum Language: String, CaseIterable, Identifiable, Sendable {
        case english, german, spanish

        var id: String { rawValue }

        var label: LocalizedStringResource {
            switch self {
            case .english: "English"
            case .german:  "German"
            case .spanish: "Spanish"
            }
        }

        var locale: Locale {
            switch self {
            case .english: Locale(identifier: "en_US")
            case .german:  Locale(identifier: "de_DE")
            case .spanish: Locale(identifier: "es_ES")
            }
        }

        var minorWords: Set<String> {
            switch self {
            case .english:
                ["a", "an", "the", "and", "but", "or", "nor", "for", "so", "yet",
                 "at", "by", "in", "of", "on", "to", "up", "as", "off", "per",
                 "via", "from", "into", "onto", "over", "with", "vs", "vs."]
            case .german:
                ["der", "die", "das", "den", "dem", "des", "ein", "eine", "einen",
                 "einem", "eines", "und", "oder", "aber", "doch", "sondern",
                 "an", "am", "auf", "aus", "bei", "bis", "für", "im", "in",
                 "mit", "nach", "um", "von", "vom", "vor", "zu", "zum", "zur"]
            case .spanish:
                ["el", "la", "los", "las", "un", "una", "unos", "unas",
                 "y", "e", "o", "u", "pero", "de", "del", "a", "al", "en",
                 "con", "por", "para", "sin", "sobre"]
            }
        }
    }

    func apply(to text: String, language: Language = .english) -> String {
        switch self {
        case .upperCase:
            return text.uppercased(with: language.locale)
        case .lowerCase:
            return text.lowercased(with: language.locale)
        case .titleCase:
            return titleCased(text, language: language)
        }
    }

    private func titleCased(_ text: String, language: Language) -> String {
        // Split at spaces but keep the separators, so that multiple spaces
        // are not lost.
        let words = text.split(separator: " ", omittingEmptySubsequences: false)
        let minor = language.minorWords

        let result = words.enumerated().map { index, word -> String in
            let plain = String(word)
            guard !plain.isEmpty else { return plain }

            // Start, end — and anything that opens a new subtitle:
            // "Live (At the BBC)", "Reise: Der Anfang".
            let opensClause = plain.first.map { "([{\"'".contains($0) } ?? false
            let followsBreak = index > 0
                && (words[index - 1].last.map { ":;–—".contains($0) } ?? false)
            let isEdge = index == 0 || index == words.count - 1
                || opensClause || followsBreak

            let bare = plain.trimmingCharacters(in: .punctuationCharacters)
                .lowercased(with: language.locale)

            if !isEdge, minor.contains(bare) {
                return plain.lowercased(with: language.locale)
            }
            return capitalizeFirstLetter(plain, language: language)
        }
        return result.joined(separator: " ")
    }

    /// Capitalize from the first letter on — `(live)` becomes `(Live)`,
    /// not `(live)`.
    private func capitalizeFirstLetter(_ word: String, language: Language) -> String {
        let lowered = word.lowercased(with: language.locale)
        guard let index = lowered.firstIndex(where: { $0.isLetter }) else { return lowered }
        return lowered.replacingCharacters(
            in: index...index,
            with: lowered[index...index].uppercased(with: language.locale)
        )
    }
}
