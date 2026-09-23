//
//  Numbering.swift
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
//  Numbering (spec §4.2).
//

import Foundation

struct NumberingOptions: Equatable, Sendable {
    /// Also write the total (03/12).
    var writesTotal = true
    /// Start again at 1 on every disc instead of counting across discs.
    var restartsPerDisc = false
    /// Leading zeros in the file name (01 instead of 1).
    var padsNumbers = true
    var startsAt = 1
}

enum Numbering {

    /// Numbers in the order given — which is the table's current sort order,
    /// not the order the files were loaded in.
    @MainActor
    static func apply(_ options: NumberingOptions, to tracks: [TrackFile]) {
        guard !tracks.isEmpty else { return }

        if options.restartsPerDisc {
            // Group by disc, keep the order within each group.
            var groups: [Int: [TrackFile]] = [:]
            for track in tracks {
                groups[track.edited.discNumber ?? 1, default: []].append(track)
            }
            for group in groups.values {
                number(group, options: options)
            }
        } else {
            number(tracks, options: options)
        }
    }

    @MainActor
    private static func number(_ tracks: [TrackFile], options: NumberingOptions) {
        let total = tracks.count
        for (index, track) in tracks.enumerated() {
            track.set(String(options.startsAt + index), for: .trackNumber)
            if options.writesTotal {
                track.set(String(options.startsAt + total - 1), for: .trackTotal)
            }
        }
    }
}
