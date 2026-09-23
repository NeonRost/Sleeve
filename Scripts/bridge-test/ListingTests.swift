//
//  ListingTests.swift
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
//  Track lists from outside (§7.12): pasted text and aligning the boundaries.
//

import Foundation

enum ListingTests {

    static func run() -> Int32 {
        var failures = 0, checks = 0
        func check(_ condition: Bool, _ label: String, _ detail: String = "") {
            checks += 1
            if condition { print("  ✓ \(label)") }
            else { failures += 1; print("  ✗ \(label)\(detail.isEmpty ? "" : " — \(detail)")") }
        }
        func close(_ a: Double, _ b: Double, _ tol: Double, _ label: String) {
            check(abs(a - b) <= tol, label, String(format: "is %.2f, expected %.2f", a, b))
        }

        print("\n— Pasted track list —")
        // Exactly the text from the YouTube description, including link,
        // heading and total length.
        let pasted = """
        https://www.youtube.com/watch?v=dsZvuCeUh8c&t=318s
        BEAST - IMagination∞lenS (Full Album)
        (44:49)

        Tracklist:
        Beast City 0:00
        Vision (ISM∞Version) 1:35
        Chemical 5:16
        Spiral Cave 9:32
        48k Rate Change[Freeze]⇒Convert22 14:07
        Lynch 16:33
        LUV 18:55
        Deadly Nightshade 22:50
        Cowboy 25:34
        Dayz&Diez 28:57
        LR-7 32:35
        New Noise 36:12
        Slider 39:30
        """
        let listing = TrackListing(pasted: pasted)
        check(listing.entries.count == 13, "thirteen tracks, link and total length skipped",
              "\(listing.entries.count)")
        check(listing.entries.first?.title == "Beast City", "first title")
        check(listing.entries[1].title == "Vision (ISM∞Version)", "parentheses and ∞ stay in the title")
        check(listing.entries[4].title == "48k Rate Change[Freeze]⇒Convert22",
              "special characters stay in the title")
        check(listing.entries[9].title == "Dayz&Diez", "ampersand stays")
        close(listing.entries[5].start ?? 0, 993, 0.01, "Lynch starts at 16:33")
        check(listing.hasStarts, "every entry has a start time")

        print("\n— Other notations —")
        let variants = TrackListing(pasted: """
        00:00 Intro
        01. First Piece - 1:02:03
        [1:05:10] Second Piece
        3) Third – 1:09:00
        A comment without a time
        """)
        check(variants.entries.map(\.title) == ["Intro", "First Piece", "Second Piece", "Third"],
              "time at the front, at the end, in brackets, with a number", "\(variants.entries.map(\.title))")
        close(variants.entries[1].start ?? 0, 3723, 0.01, "hours are read")

        let backwards = TrackListing(pasted: "A 0:00\nB 5:00\nC 2:00\nD 9:00")
        check(backwards.entries.map(\.title) == ["A", "B", "D"],
              "times jumping backwards do not belong to the list")

        check(TrackListing(pasted: "no times here").entries.isEmpty, "no times, no list")

        print("\n— Boundaries from start times —")
        // Cuts detected on the real album (excerpt), plus the uploader's
        // times. Where a silence is nearby, the boundary snaps to it; at
        // Lynch there is none — there the given time applies.
        let cuts: [Double] = [95.8, 316.5, 573.0, 848.1, 886.4, 1136.7]
        let aligned = AudioSplitter.alignedRanges(
            starts: [0, 95, 316, 572, 847, 993, 1135], duration: 1370, candidates: cuts)
        check(aligned.count == 7, "seven tracks from seven start times")
        close(aligned[1].start, 95.8, 0.001, "1:35 snaps to the silence at 1:35.8")
        close(aligned[4].start, 848.1, 0.001, "14:07 snaps to 14:08.1")
        close(aligned[5].start, 993, 0.001, "Lynch: no silence nearby, the given time applies")
        close(aligned[6].start, 1136.7, 0.001, "LUV snaps to 18:56.7")
        check(!aligned.contains { abs($0.start - 886.4) < 0.01 },
              "the pause in the middle of \"48k\" does not become a boundary")
        check(zip(aligned, aligned.dropFirst()).allSatisfy { $0.end == $1.start },
              "gapless")
        close(aligned.last!.end, 1370, 0.001, "up to the end of the file")

        print("\n— Boundaries from lengths —")
        // Lengths as from MusicBrainz, but the recording has one second more
        // pause at every transition. Added up blindly the error would grow to
        // 3 s; computed from the snapped predecessor it stays at zero.
        let cuts2: [Double] = [101, 202, 303]
        let fromLengths = AudioSplitter.alignedRanges(
            durations: [100, 100, 100, 100], duration: 400, candidates: cuts2)
        close(fromLengths[1].start, 101, 0.001, "first boundary snaps")
        close(fromLengths[2].start, 202, 0.001, "second from the snapped predecessor")
        close(fromLengths[3].start, 303, 0.001, "third likewise — no drifting error")

        let farOff = AudioSplitter.alignedRanges(
            durations: [100, 100], duration: 300, candidates: [150])
        close(farOff[1].start, 100, 0.001, "without a silence nearby the length applies")

        print("\n  \(checks) checks, \(failures) failures")
        return failures == 0 ? 0 : 1
    }
}
