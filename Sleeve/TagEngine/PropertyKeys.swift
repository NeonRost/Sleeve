//
//  PropertyKeys.swift
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

/// Keys of the TagLib PropertyMap.
///
/// TagLib translates these generic names into the native field itself
/// (`TPE2` / `aART` / `ALBUMARTIST` …). That is why **everything** in Sleeve
/// goes through the PropertyMap and nothing through the legacy tag API — see
/// spec §2.1.1.
enum PropertyKeys {
    static let title       = "TITLE"
    static let artist      = "ARTIST"
    static let albumArtist = "ALBUMARTIST"
    static let album       = "ALBUM"
    static let composer    = "COMPOSER"
    static let genre       = "GENRE"
    static let date        = "DATE"
    static let trackNumber = "TRACKNUMBER"
    static let discNumber  = "DISCNUMBER"
    static let comment     = "COMMENT"
    static let lyrics      = "LYRICS"
    static let compilation = "COMPILATION"

    /// Complex property for embedded pictures.
    static let picture     = "PICTURE"

    /// Attribute names inside a PICTURE complex property.
    enum PictureAttribute {
        static let data        = "data"
        static let mimeType    = "mimeType"
        static let description = "description"
        static let pictureType = "pictureType"
    }
}

/// Depending on the format, `TRACKNUMBER` and `DISCNUMBER` carry either just
/// the number ("3") or number and total ("3/12"). TagLib does not normalize
/// this — Sleeve has to read both forms and put them back together when
/// writing.
struct NumberPair: Equatable, Sendable {
    var number: Int?
    var total: Int?

    init(number: Int? = nil, total: Int? = nil) {
        self.number = number
        self.total = total
    }

    init(parsing value: String) {
        let parts = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        number = parts.first.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        total = parts.count > 1
            ? Int(parts[1].trimmingCharacters(in: .whitespaces))
            : nil
    }

    /// `nil` when there is nothing to write — the property is then removed.
    var formatted: String? {
        switch (number, total) {
        case let (.some(n), .some(t)): "\(n)/\(t)"
        case let (.some(n), .none):    "\(n)"
        // A total without a number is not a valid value in any format.
        case (.none, _):               nil
        }
    }
}

extension String {
    /// `DATE` can be "1987", "1987-05-01" or "1987-05". Only the year matters to
    /// Sleeve.
    var leadingYear: Int? {
        let digits = prefix { $0.isNumber }
        guard digits.count == 4 else { return nil }
        return Int(digits)
    }
}
