//
//  JSONSanitizer.swift
//  Sleeve
//

import Foundation

/// Discogs liefert in Freitextfeldern wie `notes` rohe Steuerzeichen —
/// vor allem `\r` und `\n` mitten im String. Das ist nach JSON-Standard
/// unzulässig, und `JSONDecoder` verweigert daraufhin die **ganze** Antwort:
///
///     Unescaped control character '0xd' around line 2, column 0.
///
/// Betroffen ist ein guter Teil der Datenbank. Deshalb werden die Bytes
/// vorher begradigt.
///
/// Die Falle dabei: `JSONDecoder` prüft **faul**. Er stolpert nur, wenn ein
/// deklariertes Feld die kaputte Zeichenkette tatsächlich liest. `DiscogsRelease`
/// kennt `notes` nicht und käme heute auch ohne Begradigen durch — wer das Feld
/// später ergänzt, bricht die Dekodierung für einen Teil der Releases, und zwar
/// nur für manche. Solche Fehler sind die unangenehmsten. Deshalb wird
/// grundsätzlich begradigt und nicht darauf gewettet, welche Felder im Modell
/// stehen.
enum JSONSanitizer {

    /// Ersetzt Steuerzeichen **innerhalb von Zeichenketten** durch ihre
    /// Escape-Form. Außerhalb von Zeichenketten sind Steuerzeichen als
    /// Leerraum erlaubt und bleiben unangetastet.
    ///
    /// Byteweises Vorgehen ist hier sicher: In UTF-8 liegen alle Folgebytes
    /// über 0x7F, `"` und `\` können also nie Teil eines Mehrbytezeichens sein.
    static func escapingControlCharactersInStrings(_ data: Data) -> Data {
        var output = Data()
        output.reserveCapacity(data.count + 32)

        var insideString = false
        var escaped = false

        for byte in data {
            if escaped {
                // Vorheriges Byte war ein Backslash — dieses gehört dazu.
                output.append(byte)
                escaped = false
                continue
            }

            switch byte {
            case UInt8(ascii: "\\") where insideString:
                escaped = true
                output.append(byte)

            case UInt8(ascii: "\""):
                insideString.toggle()
                output.append(byte)

            case 0x00...0x1F where insideString:
                output.append(contentsOf: Array(escape(byte).utf8))

            default:
                output.append(byte)
            }
        }
        return output
    }

    private static func escape(_ byte: UInt8) -> String {
        switch byte {
        case 0x08: #"\b"#
        case 0x09: #"\t"#
        case 0x0A: #"\n"#
        case 0x0C: #"\f"#
        case 0x0D: #"\r"#
        default:   String(format: #"\u%04x"#, Int(byte))
        }
    }
}
