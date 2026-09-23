//
//  JSONSanitizer.swift
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

/// Discogs delivers raw control characters in free-text fields such as
/// `notes` — above all `\r` and `\n` in the middle of a string. That is not
/// allowed by the JSON standard, and `JSONDecoder` then rejects the **entire**
/// response:
///
///     Unescaped control character '0xd' around line 2, column 0.
///
/// A good part of the database is affected. So the bytes are straightened
/// out beforehand.
///
/// The trap: `JSONDecoder` checks **lazily**. It only trips if a declared
/// field actually reads the broken string. `DiscogsRelease` does not know
/// `notes` and would get through today even without straightening — whoever
/// adds the field later breaks decoding for part of the releases, and only
/// for some. Those are the nastiest bugs. So the bytes are always
/// straightened rather than betting on which fields the model happens to
/// contain.
enum JSONSanitizer {

    /// Replaces control characters **inside strings** with their escaped form.
    /// Outside strings, control characters are allowed as whitespace and stay
    /// untouched.
    ///
    /// Working byte by byte is safe here: in UTF-8 all continuation bytes are
    /// above 0x7F, so `"` and `\` can never be part of a multibyte character.
    static func escapingControlCharactersInStrings(_ data: Data) -> Data {
        var output = Data()
        output.reserveCapacity(data.count + 32)

        var insideString = false
        var escaped = false

        for byte in data {
            if escaped {
                // The previous byte was a backslash — this one belongs to it.
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
