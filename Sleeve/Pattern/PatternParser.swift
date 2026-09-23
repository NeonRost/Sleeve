//
//  PatternParser.swift
//  Sleeve
//
//  Dateiname → Tags (Spec §4.4). Dasselbe Pattern rückwärts: jedes `%token%`
//  wird zur benannten Capture-Group, alles dazwischen literal escaped.
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
    /// Bezieht der Pattern Ordnernamen ein (`%artist%/%album%/…`)?
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
                // Kommt dasselbe Token zweimal vor, darf die Gruppe nicht
                // zweimal denselben Namen tragen.
                let name = seen.insert(token).inserted
                    ? token.rawValue
                    : "\(token.rawValue)_\(tokens.count)"
                expression += "(?<\(name)>\(token.isNumeric ? "\\d+" : ".+?"))"
            }
        }

        guard !tokens.isEmpty else { throw ParserError.noTokens }
        self.tokens = tokens
        self.usesFolders = pattern.contains("/")

        // Am Anfang und Ende verankern, sonst matcht der Pattern irgendwo
        // mittendrin und liefert Unsinn.
        do {
            self.regex = try NSRegularExpression(pattern: "^" + expression + "$")
        } catch {
            throw ParserError.invalidPattern(expression)
        }
    }

    /// Der Text, gegen den gematcht wird: Dateiname ohne Endung, bei
    /// Ordner-Patterns mit so vielen übergeordneten Ordnern davor, wie der
    /// Pattern Ebenen hat.
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

            // Führende Nullen fallen weg — im Tag steht eine Zahl.
            match.values[token.field] = token.isNumeric
                ? String(Int(value) ?? 0)
                : value
        }
        return match.isEmpty ? nil : match
    }

    /// Fertige Vorlagen aus der Spec §4.4.
    static let presets: [String] = [
        "%track% - %title%",
        "%artist% - %title%",
        "%track%. %artist% - %title%",
        "%artist% - %album% - %track% - %title%",
        "%artist%/%album%/%track% - %title%",
    ]
}
