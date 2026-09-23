//
//  AppState+Lookup.swift
//  Sleeve
//
//  Anbindung des Nachschlagens bei MusicBrainz und Discogs (Spec §4.6).
//

import Foundation

extension AppState {

    var hasDiscogsToken: Bool { (discogsToken?.isEmpty == false) }

    /// Erzeugt den Sitzungszustand für „Album nachschlagen" und rät die
    /// Suchbegriffe aus den vorhandenen Tags, sonst aus dem Ordnernamen.
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

    /// Die Suche beider Nachschlage-Blätter — mit derselben Vorgabe für die
    /// Quelle.
    func makeReleaseSearch(query: DiscogsClient.SearchQuery,
                           provider: LookupProvider? = nil) -> ReleaseSearch {
        ReleaseSearch(service: lookup,
                      provider: provider ?? .preferred(hasDiscogsToken: hasDiscogsToken),
                      query: query,
                      hasDiscogsToken: hasDiscogsToken)
    }

    /// Schritt 2 aus §4.6: Suchbegriffe raten.
    static func guessQuery(from tracks: [TrackFile]) -> DiscogsClient.SearchQuery {
        var query = DiscogsClient.SearchQuery()

        // Album-Interpret vor Interpret: bei Samplern steht auf jedem Stück
        // ein anderer Künstler, der Album-Interpret ist der verlässlichere.
        query.artist = tracks.compactMap { $0.edited.albumArtist }.first
            ?? tracks.compactMap { $0.edited.artist }.first
            ?? ""
        query.releaseTitle = tracks.compactMap { $0.edited.album }.first ?? ""
        if let year = tracks.compactMap({ $0.edited.year }).first, year > 0 {
            query.year = String(year)
        }

        // Nichts in den Tags? Dann der Ordnername — der heißt oft
        // „Interpret - Album" oder schlicht wie das Album.
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

    /// Übernimmt die Vorschläge in den **Editor-Zustand**, nicht auf die
    /// Platte (Spec §4.6, Schritt 8). Geschrieben wird erst beim Speichern.
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
