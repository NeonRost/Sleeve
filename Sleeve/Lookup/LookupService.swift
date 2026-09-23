//
//  LookupService.swift
//  Sleeve
//
//  Eine Fassade vor beiden Quellen. Die Oberfläche fragt hier, nicht bei
//  Discogs oder MusicBrainz.
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

    /// Für die Fehlermeldung in der Oberfläche — beide Quellen haben eigene
    /// Fehlertypen.
    static func describe(_ error: Error) -> String {
        if let discogs = error as? DiscogsClient.ClientError { return discogs.readableDescription }
        if let mb = error as? MusicBrainzClient.ClientError { return mb.readableDescription }
        return error.localizedDescription
    }
}
