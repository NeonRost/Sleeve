//
//  DiscLookupSession.swift
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
//  State of "Look Up Disc" in the Rip section (spec §6.2.2). The same search
//  as the other two lookup sheets; added here is what only a CD has: exact
//  track lengths from its table of contents.
//
//  Those lengths are what makes the comparison worth something. A pressing
//  found by a similar TOC, or by text, is only right if its lengths match the
//  disc to the second — and a multi-disc release has to be narrowed down to
//  the one disc that is in the drive.
//

import Foundation

@Observable
@MainActor
final class DiscLookupSession {

    let search: ReleaseSearch
    /// Length of every audio track on the inserted disc, in seconds, in order.
    let discLengths: [Double]
    /// The track numbers belonging to `discLengths`.
    let discNumbers: [Int]

    /// Which disc of a multi-disc release is compared. `nil` for a release
    /// with a single disc.
    var medium: Int?

    var selectedFields: Set<TagField> = Set(DiscLookupSession.selectableFields)

    /// `.discNumber` stands for "part of a multi-disc set, disc n of m".
    static let selectableFields: [TagField] = [.title, .artist, .album, .year, .genre, .discNumber]

    init(search: ReleaseSearch, discNumbers: [Int], discLengths: [Double]) {
        self.search = search
        self.discNumbers = discNumbers
        self.discLengths = discLengths
        search.onReleaseChange = { [weak self] release in
            guard let self else { return }
            medium = release.flatMap { Self.bestMedium(of: $0, lengths: discLengths) }
        }
    }

    var release: LookupRelease? { search.release }

    /// The discs of the release, if it has more than one.
    var media: [Int] {
        guard let release else { return [] }
        return Self.mediaNumbers(of: release)
    }

    /// The release's tracks on the compared disc.
    var remoteTracks: [LookupTrack] {
        guard let release else { return [] }
        return Self.tracks(of: release, medium: medium)
    }

    func remoteLength(at index: Int) -> Double? {
        remoteTracks[safe: index]?.duration.flatMap(Timecode.parse)
    }

    /// How many tracks deviate by more than the tolerance.
    var deviationCount: Int {
        discLengths.indices.filter {
            LookupComparison.deviates(discLengths[$0], from: remoteLength(at: $0))
        }.count
    }

    /// What the selected release can deliver: the disc switch only for a
    /// multi-disc release.
    var availableFields: Set<TagField> {
        var fields = Set(Self.selectableFields)
        if media.count < 2 { fields.remove(.discNumber) }
        return fields
    }

    // MARK: - Pure logic, testable without a network

    static func mediaNumbers(of release: LookupRelease) -> [Int] {
        Array(Set(release.tracks.compactMap(\.disc))).sorted()
    }

    static func tracks(of release: LookupRelease, medium: Int?) -> [LookupTrack] {
        guard let medium, mediaNumbers(of: release).count > 1 else { return release.tracks }
        return release.tracks.filter { $0.disc == medium }
    }

    /// The disc of a multi-disc release that fits the inserted CD best: the
    /// same number of tracks first, then the smallest total deviation of the
    /// lengths. A four-CD audio drama has four candidates with similar track
    /// counts; the lengths tell them apart.
    static func bestMedium(of release: LookupRelease, lengths: [Double]) -> Int? {
        let candidates = mediaNumbers(of: release)
        guard candidates.count > 1 else { return nil }
        func score(_ medium: Int) -> (Int, Double) {
            let own = Self.tracks(of: release, medium: medium)
            let countMismatch = abs(own.count - lengths.count)
            let deviation = zip(own, lengths).reduce(0.0) { sum, pair in
                guard let theirs = pair.0.duration.flatMap(Timecode.parse) else { return sum + 60 }
                return sum + abs(theirs - pair.1)
            }
            return (countMismatch, deviation)
        }
        return candidates.min { score($0) < score($1) }
    }
}
