//
//  PatternRenderer.swift
//  Sleeve
//
//  Tags → Dateiname (Spec §4.4).
//

import Foundation

struct PatternRenderer: Sendable {

    /// Zeichen, die in einem Dateinamen nichts verloren haben. `/` trennt auf
    /// APFS Pfadkomponenten, `:` ist der historische Finder-Trenner und taucht
    /// im Finder als `/` wieder auf. Der Rest ist nicht macOS-, sondern
    /// SMB- und exFAT-Rücksicht — Musiksammlungen landen auf NAS-Laufwerken.
    ///
    /// `%` steht bewusst **nicht** drin: es ist überall zulässig, und ein
    /// `%%` im Pattern soll als Prozentzeichen im Namen ankommen.
    static let invalidCharacters = CharacterSet(charactersIn: "/:\\?*|\"<>")
        .union(.controlCharacters)

    /// Womit ungültige Zeichen ersetzt werden — konfigurierbar (Spec §4.4).
    var replacement: String = "_"

    /// Führende Nullen bei Track- und Disc-Nummern (01 statt 1), Spec §4.2.
    var padsNumbers: Bool = true

    func render(_ pattern: String, tags: AudioTags) -> String {
        let elements = PatternSyntax.parse(pattern)

        // Ein Token und das Literal davor bilden eine Gruppe. Fehlt der
        // Tag-Wert, entfällt die ganze Gruppe — sonst entstünde
        // „01 -  - Titel" (Spec §4.4).
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

    /// Ungültige Zeichen ersetzen, Trennzeichen an den Rändern abräumen.
    func sanitize(_ name: String) -> String {
        var cleaned = name
            .components(separatedBy: Self.invalidCharacters)
            .joined(separator: replacement)

        // Führende und schließende Trennzeichen entstehen, wenn eine Gruppe am
        // Rand entfallen ist.
        let trimmable = CharacterSet(charactersIn: " -_.")
        while let first = cleaned.unicodeScalars.first, trimmable.contains(first) {
            cleaned.removeFirst()
        }
        while let last = cleaned.unicodeScalars.last, trimmable.contains(last) {
            cleaned.removeLast()
        }

        // Mehrfache Leerzeichen zusammenziehen.
        while cleaned.contains("  ") {
            cleaned = cleaned.replacingOccurrences(of: "  ", with: " ")
        }
        return cleaned
    }

    /// Rendert für eine ganze Liste und löst Namenskollisionen mit `" (2)"` auf.
    /// Dateien im selben Ordner, die denselben Namen bekämen, würden einander
    /// sonst überschreiben.
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
            // Vergleich case-insensitiv, weil APFS standardmäßig so arbeitet.
            while !used.insert("\(folder)/\(candidate.lowercased()).\(ext.lowercased())").inserted {
                candidate = "\(base) (\(counter))"
                counter += 1
            }

            results.append(ext.isEmpty ? candidate : "\(candidate).\(ext)")
        }
        return results
    }
}
