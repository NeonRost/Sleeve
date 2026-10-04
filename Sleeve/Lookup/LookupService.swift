//
//  LookupService.swift
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
//  A facade in front of both sources. The UI asks here, not Discogs or
//  MusicBrainz directly.
//

import Foundation

actor LookupService {

    let discogs: DiscogsClient
    let musicBrainz: MusicBrainzClient

    init(discogs: DiscogsClient, musicBrainz: MusicBrainzClient = MusicBrainzClient()) {
        self.discogs = discogs
        self.musicBrainz = musicBrainz
    }

    func search(_ query: DiscogsClient.SearchQuery,
                using provider: LookupProvider) async throws -> [LookupSearchResult] {
        switch provider {
        case .discogs:
            try await discogs.search(query).map { $0.asLookupSearchResult() }
        case .musicBrainz:
            try await musicBrainz.search(query)
        }
    }

    func release(_ result: LookupSearchResult) async throws -> LookupRelease {
        switch result.provider {
        case .discogs:
            guard let id = Int(result.id) else { throw DiscogsClient.ClientError.notFound }
            return try await discogs.release(id: id).asLookupRelease()
        case .musicBrainz:
            return try await musicBrainz.release(id: result.id)
        }
    }

    /// The release's cover as image data, from whichever source it came.
    func cover(of release: LookupRelease) async throws -> Data {
        guard let url = release.coverURL else { throw MusicBrainzClient.ClientError.notFound }
        switch release.provider {
        case .discogs:     return try await discogs.imageData(from: url)
        case .musicBrainz: return try await musicBrainz.imageData(from: url)
        }
    }

    /// For the error message in the UI — each source has its own error types.
    static func describe(_ error: Error) -> String {
        if let discogs = error as? DiscogsClient.ClientError { return discogs.readableDescription }
        if let mb = error as? MusicBrainzClient.ClientError { return mb.readableDescription }
        return error.localizedDescription
    }
}
