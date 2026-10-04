//
//  TextReplacement.swift
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
//  Find and replace in tags (spec §4.3.1): "feat." to "ft.", removing
//  "(Remastered 2011)", tidying up what a download site left behind.
//
//  Plain text and regular expressions go through the same engine: plain text
//  is escaped into a pattern, so both behave identically apart from the
//  special characters. In regex mode the replacement understands `$1` for
//  the first group.
//

import Foundation

struct TextReplacement: Sendable, Equatable {
    var find = ""
    var replacement = ""
    var matchesCase = false
    var usesRegularExpression = false

    enum Problem: Error, Equatable {
        /// The regular expression does not compile; the message is the
        /// system's.
        case invalidPattern(String)
    }

    /// Whether there is anything to search for at all.
    var isEmpty: Bool { find.isEmpty }

    /// Checks the pattern without replacing anything — for the error message
    /// while typing.
    func validate() -> Problem? {
        do { _ = try compiled(); return nil }
        catch let problem as Problem { return problem }
        catch { return .invalidPattern(error.localizedDescription) }
    }

    /// The text with every match replaced, or `nil` if nothing matched.
    ///
    /// Whitespace left at the edges is trimmed and doubled spaces collapsed,
    /// but only where something was replaced: removing "(Live)" from
    /// "Song (Live)" should give "Song", not "Song ". Texts without a match
    /// stay exactly as they are.
    func apply(to text: String) throws -> String? {
        guard let (regex, template) = try compiled() else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard regex.firstMatch(in: text, range: range) != nil else { return nil }
        let replaced = regex.stringByReplacingMatches(in: text, range: range,
                                                      withTemplate: template)
        return replaced
            .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private func compiled() throws -> (NSRegularExpression, String)? {
        guard !find.isEmpty else { return nil }
        let pattern = usesRegularExpression
            ? find : NSRegularExpression.escapedPattern(for: find)
        let template = usesRegularExpression
            ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
        do {
            let regex = try NSRegularExpression(
                pattern: pattern, options: matchesCase ? [] : [.caseInsensitive])
            return (regex, template)
        } catch {
            throw Problem.invalidPattern(error.localizedDescription)
        }
    }
}
