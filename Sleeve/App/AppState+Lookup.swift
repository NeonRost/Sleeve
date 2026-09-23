//
//  AppState+Lookup.swift
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
//  Looking up releases on MusicBrainz and Discogs (spec §4.6).
//

import Foundation

extension AppState {

    var hasDiscogsToken: Bool { (discogsToken?.isEmpty == false) }

    /// Creates the session state for "Look Up Album" and guesses the search
    /// terms from the existing tags, otherwise from the folder name.
    func makeLookupSession() -> LookupSession? {
        let targets = operationTargetsInDisplayOrder
        guard !targets.isEmpty else { return nil }

        let local = targets.map {
            let length = $0.properties.duration.components
            let seconds = Double(length.seconds) + Double(length.attoseconds) * 1e-18
            return ReleaseMatcher.LocalTrack(id: $0.id, title: $0.edited.title,
                                             filename: $0.filename,
                                             duration: seconds > 0 ? seconds : nil)
        }
        return LookupSession(
            search: makeReleaseSearch(query: Self.guessQuery(from: targets)),
            local: local,
            genreSource: genreSource
        )
    }

    /// The search used by both lookup sheets — with the same default source.
    func makeReleaseSearch(query: DiscogsClient.SearchQuery,
                           provider: LookupProvider? = nil) -> ReleaseSearch {
        ReleaseSearch(service: lookup,
                      provider: provider ?? .preferred(hasDiscogsToken: hasDiscogsToken),
                      query: query,
                      hasDiscogsToken: hasDiscogsToken)
    }

    /// Step 2 of §4.6: guess the search terms.
    static func guessQuery(from tracks: [TrackFile]) -> DiscogsClient.SearchQuery {
        var query = DiscogsClient.SearchQuery()

        // Album artist before artist: on a compilation every track has a
        // different artist, the album artist is the more reliable one.
        query.artist = tracks.compactMap { $0.edited.albumArtist }.first
            ?? tracks.compactMap { $0.edited.artist }.first
            ?? ""
        query.releaseTitle = tracks.compactMap { $0.edited.album }.first ?? ""
        if let year = tracks.compactMap({ $0.edited.year }).first, year > 0 {
            query.year = String(year)
        }

        // Nothing in the tags? Then the folder name — often
        // "Artist - Album" or simply the album's name.
        if query.artist.isEmpty, query.releaseTitle.isEmpty,
           let folder = tracks.first?.url.deletingLastPathComponent().lastPathComponent,
           !folder.isEmpty {
            let parts = folder.components(separatedBy: " - ")
            if parts.count >= 2 {
                query.artist = parts[0].trimmingCharacters(in: .whitespaces)
                query.releaseTitle = parts.dropFirst().joined(separator: " - ")
                    .trimmingCharacters(in: .whitespaces)
            } else {
                query.releaseTitle = folder
            }
        }
        return query
    }

    /// Applies the proposals to the **editor state**, not to disk (spec §4.6,
    /// step 9). Nothing is written until the user saves.
    func applyLookup(_ proposals: [ReleaseMatcher.Proposal], fields: Set<TagField>) {
        for proposal in proposals {
            guard let track = trackList.track(id: proposal.trackID) else { continue }
            for (field, value) in proposal.values where fields.contains(field) {
                track.set(value, for: field)
            }
        }
    }

    func updateDiscogsToken(_ token: String?) async {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        discogsToken = (trimmed?.isEmpty == false) ? trimmed : nil
        KeychainStore.set(discogsToken, for: KeychainStore.discogsToken)
        await discogs.updateToken(discogsToken)
    }
}
