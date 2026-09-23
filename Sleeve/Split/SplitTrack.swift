//
//  SplitTrack.swift
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
//  One track in the splitter: its boundaries as detection found them, and as
//  they are now.
//
//  Boundaries are only **stored** here, never moved. Moving goes exclusively
//  through `AppState.moveBoundary`, because every boundary is also the
//  neighbour's — a track moving its own boundary would tear open a gap, and
//  whatever lies in it would end up in no file (spec §7.3, §7.8).
//

import Foundation

@MainActor
@Observable
final class SplitTrack: Identifiable {
    let id = UUID()
    private(set) var range: TrackRange
    /// Where "Reset" leads: what detection found — or, after splitting or
    /// merging, the state after that. Otherwise Reset would lead to a boundary
    /// that no longer exists.
    var detected: TrackRange
    /// Empty means: just the track number, as when ripping.
    var title = ""
    /// What the time fields show — while typing it may differ from the stored
    /// value.
    var startText: String
    var endText: String

    /// Moving a boundary must not make a track shorter than this.
    static let minimumLength: Double = 0.5

    init(range: TrackRange) {
        self.range = range
        self.detected = range
        self.startText = Timecode.format(range.start)
        self.endText = Timecode.format(range.end)
    }

    var isAdjusted: Bool {
        abs(range.start - detected.start) > 0.05 || abs(range.end - detected.end) > 0.05
    }

    /// For `AppState` only — it checks against the neighbour first.
    func assign(start: Double) {
        range.start = start
        startText = Timecode.format(start)
    }

    /// For `AppState` only — it checks against the neighbour first.
    func assign(end: Double) {
        range.end = end
        endText = Timecode.format(end)
    }
}
