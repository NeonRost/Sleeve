//
//  ReleaseMatcher.swift
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
//  Matches local files to the release's tracks (spec §4.6).
//
//  The automatic matching regularly misses on live albums, bonus tracks and
//  double CDs. That is why this is explicitly only a **proposal** — the UI
//  lets the user correct it.
//

import Foundation

enum ReleaseMatcher {

    struct LocalTrack: Sendable, Identifiable, Equatable {
        var id: UUID
        var title: String?
        var filename: String
        /// Playing time in seconds — to compare with the length in the album.
        var duration: Double? = nil

        /// What gets compared: the title, otherwise the file name without
        /// extension.
        var comparisonText: String {
            if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty { return title }
            return (filename as NSString).deletingPathExtension
        }

        var hasTitle: Bool {
            !(title ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// Per local track the index in the release's track list, or `nil`.
    typealias Pairing = [Int?]

    // MARK: - Proposal

    static func suggest(local: [LocalTrack], remote: [LookupTrack]) -> Pairing {
        guard !local.isEmpty, !remote.isEmpty else {
            return Array(repeating: nil, count: local.count)
        }

        let byOrder: Pairing = (0..<local.count).map { $0 < remote.count ? $0 : nil }

        // Without local titles there is nothing to compare — order is then
        // the only sensible assumption.
        guard local.contains(where: \.hasTitle) else { return byOrder }

        let byTitle = greedyByTitle(local: local, remote: remote)
        // Order stays the default; the title match only wins if it fits
        // noticeably better. Otherwise two similarly named pieces would
        // shift the whole list.
        return score(byTitle, local: local, remote: remote)
            > score(byOrder, local: local, remote: remote) + 0.08
            ? byTitle
            : byOrder
    }

    private static func greedyByTitle(local: [LocalTrack], remote: [LookupTrack]) -> Pairing {
        var candidates: [(score: Double, localIndex: Int, remoteIndex: Int)] = []
        for (l, localTrack) in local.enumerated() {
            for (r, remoteTrack) in remote.enumerated() {
                let value = similarity(localTrack.comparisonText, remoteTrack.title ?? "")
                if value >= 0.55 { candidates.append((value, l, r)) }
            }
        }
        candidates.sort { $0.score > $1.score }

        var result = Pairing(repeating: nil, count: local.count)
        var usedRemote: Set<Int> = []
        for candidate in candidates {
            guard result[candidate.localIndex] == nil,
                  !usedRemote.contains(candidate.remoteIndex) else { continue }
            result[candidate.localIndex] = candidate.remoteIndex
            usedRemote.insert(candidate.remoteIndex)
        }
        return result
    }

    private static func score(_ pairing: Pairing, local: [LocalTrack], remote: [LookupTrack]) -> Double {
        guard !local.isEmpty else { return 0 }
        let total = pairing.enumerated().reduce(0.0) { sum, entry in
            guard let remoteIndex = entry.element, remote.indices.contains(remoteIndex)
            else { return sum }
            return sum + similarity(local[entry.offset].comparisonText,
                                    remote[remoteIndex].title ?? "")
        }
        return total / Double(local.count)
    }

    // MARK: - Similarity

    /// 0 to 1, based on the Levenshtein distance over normalized text.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = normalize(a), y = normalize(b)
        if x.isEmpty || y.isEmpty { return 0 }
        if x == y { return 1 }
        let distance = levenshtein(Array(x), Array(y))
        return 1 - Double(distance) / Double(max(x.count, y.count))
    }

    /// Lowercase, punctuation out, whitespace collapsed. A leading track
    /// number from the file name disturbs the comparison, so it goes.
    static func normalize(_ text: String) -> String {
        var value = text.lowercased()
        value = value.replacing(/^\s*\d{1,3}\s*[-._)]?\s+/, with: "")
        value = value.replacing(/[\p{P}\p{S}]/, with: " ")
        value = value.replacing(/\s+/, with: " ")
        return value.trimmingCharacters(in: .whitespaces)
    }

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    // MARK: - Proposed tags

    struct Proposal: Sendable, Identifiable {
        var id: UUID { trackID }
        var trackID: UUID
        /// Only the fields for which the source has something.
        var values: [TagField: String]
        var remoteTitle: String?
    }

    /// Builds the field values per local track from release and matching.
    static func proposals(
        release: LookupRelease,
        local: [LocalTrack],
        pairing: Pairing,
        genreSource: GenreSource
    ) -> [Proposal] {
        let remote = release.tracks
        let albumArtist = release.albumArtist
        let genre = genreSource.value(from: release)

        let discTotal = release.discCount
        var perDiscTotals: [Int: Int] = [:]
        for track in remote {
            perDiscTotals[track.disc ?? 1, default: 0] += 1
        }

        return local.enumerated().map { localIndex, track in
            var values: [TagField: String] = [:]

            if let album = normalizedTitle(release.title) { values[.album] = album }
            if let albumArtist { values[.albumArtist] = albumArtist }
            if let year = release.year, year > 0 { values[.year] = String(year) }
            if let genre { values[.genre] = genre }

            if let remoteIndex = pairing[localIndex], remote.indices.contains(remoteIndex) {
                let remoteTrack = remote[remoteIndex]
                if let title = remoteTrack.title?.trimmingCharacters(in: .whitespaces),
                   !title.isEmpty {
                    values[.title] = title
                }
                // The track's own artist takes precedence — on a compilation
                // every piece has a different one.
                values[.artist] = remoteTrack.artistName ?? albumArtist

                // Number from the source, otherwise the list's running number.
                values[.trackNumber] = String(remoteTrack.number ?? (remoteIndex + 1))
                values[.trackTotal] = String(perDiscTotals[remoteTrack.disc ?? 1] ?? remote.count)
                if let disc = remoteTrack.disc {
                    values[.discNumber] = String(disc)
                    if discTotal > 0 { values[.discTotal] = String(discTotal) }
                }

                return Proposal(trackID: track.id, values: values, remoteTitle: remoteTrack.title)
            }

            return Proposal(trackID: track.id, values: values, remoteTitle: nil)
        }
    }

    /// At Discogs the release title often reads "Artist - Album". For the
    /// album field only the latter part is meant.
    static func normalizedTitle(_ title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
