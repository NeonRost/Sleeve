//
//  LookupSession.swift
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
//  State of "Look Up Album" (spec §4.6). Lives only while the sheet is
//  open — AppState stays out of it.
//
//  The search itself is the same as in the Track Splitter
//  (`ReleaseSearch`); added here is what only tagging needs: which file
//  belongs to which track, and which fields are taken over.
//

import Foundation

@Observable
@MainActor
final class LookupSession {

    let search: ReleaseSearch
    let local: [ReleaseMatcher.LocalTrack]

    /// Per file, the index in the selected album's track list. Follows the
    /// album: another one selected, a new proposal.
    var pairing: ReleaseMatcher.Pairing = []

    /// What is taken over. Preset with what one usually wants.
    var selectedFields: Set<TagField> = Set(LookupSession.selectableFields)
    var genreSource: GenreSource

    static let selectableFields: [TagField] = [
        .title, .artist, .albumArtist, .album, .year, .genre,
        .trackNumber, .trackTotal, .discNumber, .discTotal,
    ]

    init(search: ReleaseSearch, local: [ReleaseMatcher.LocalTrack], genreSource: GenreSource) {
        self.search = search
        self.local = local
        self.genreSource = genreSource
        self.pairing = Array(repeating: nil, count: local.count)
        search.onReleaseChange = { [weak self] release in self?.pair(with: release) }
    }

    var release: LookupRelease? { search.release }
    var remoteTracks: [LookupTrack] { release?.tracks ?? [] }

    private func pair(with release: LookupRelease?) {
        pairing = release.map { ReleaseMatcher.suggest(local: local, remote: $0.tracks) }
            ?? Array(repeating: nil, count: local.count)
    }

    // MARK: - Matching

    /// Changes the matching by hand. A track of the album belongs to at most
    /// one file — assigned elsewhere, it disappears from its old place.
    func assign(remoteIndex: Int?, toLocal localIndex: Int) {
        guard pairing.indices.contains(localIndex) else { return }
        if let remoteIndex, let previous = pairing.firstIndex(of: remoteIndex) {
            pairing[previous] = nil
        }
        pairing[localIndex] = remoteIndex
    }

    /// "Everything shifted by one" is the automatic matching's most common
    /// mistake — for instance when the album has an intro that is missing
    /// locally.
    func shift(by offset: Int) {
        guard !pairing.isEmpty else { return }
        let count = remoteTracks.count
        pairing = pairing.enumerated().map { index, _ in
            let candidate = index + offset
            return (0..<count).contains(candidate) ? candidate : nil
        }
    }

    func assigned(to localIndex: Int) -> LookupTrack? {
        guard let remoteIndex = pairing[safe: localIndex] ?? nil,
              remoteTracks.indices.contains(remoteIndex) else { return nil }
        return remoteTracks[remoteIndex]
    }

    /// Length of the assigned track in seconds, where the source knows it.
    func remoteDuration(for localIndex: Int) -> Double? {
        assigned(to: localIndex)?.duration.flatMap(Timecode.parse)
    }

    var matchedCount: Int { pairing.compactMap { $0 }.count }

    /// How many files differ from their assigned track by more than the
    /// tolerance — a sign of a wrong match or a different version.
    var deviationCount: Int {
        local.indices.filter {
            LookupComparison.deviates(local[$0].duration, from: remoteDuration(for: $0))
        }.count
    }

    func proposals() -> [ReleaseMatcher.Proposal] {
        guard let release else { return [] }
        return ReleaseMatcher.proposals(release: release, local: local,
                                        pairing: pairing, genreSource: genreSource)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
