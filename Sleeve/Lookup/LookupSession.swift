//
//  LookupSession.swift
//  Sleeve
//
//  Zustand von „Album nachschlagen" (Spec §4.6). Lebt nur, solange das Blatt
//  offen ist — der AppState bleibt davon frei.
//
//  Die Suche selbst ist dieselbe wie im Track Splitter (`ReleaseSearch`); hier
//  kommt dazu, was nur beim Taggen gebraucht wird: welche Datei zu welchem
//  Track gehört und welche Felder übernommen werden.
//

import Foundation

@Observable
@MainActor
final class LookupSession {

    let search: ReleaseSearch
    let local: [ReleaseMatcher.LocalTrack]

    /// Je Datei der Index im Tracklisting des gewählten Albums. Folgt dem
    /// Album: ein anderes gewählt, ein neuer Vorschlag.
    var pairing: ReleaseMatcher.Pairing = []

    /// Was übernommen wird. Vorbelegt mit dem, was man üblicherweise will.
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

    // MARK: - Zuordnen

    /// Zuordnung von Hand ändern. Ein Track des Albums hängt an höchstens
    /// einer Datei — wird er woanders gesetzt, verschwindet er an der alten
    /// Stelle.
    func assign(remoteIndex: Int?, toLocal localIndex: Int) {
        guard pairing.indices.contains(localIndex) else { return }
        if let remoteIndex, let previous = pairing.firstIndex(of: remoteIndex) {
            pairing[previous] = nil
        }
        pairing[localIndex] = remoteIndex
    }

    /// „Alles um eins verschoben" ist der häufigste Fehlgriff der Automatik —
    /// etwa wenn das Album ein Intro führt, das lokal fehlt.
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

    /// Länge des zugeordneten Tracks in Sekunden, wo die Quelle sie kennt.
    func remoteDuration(for localIndex: Int) -> Double? {
        assigned(to: localIndex)?.duration.flatMap(Timecode.parse)
    }

    var matchedCount: Int { pairing.compactMap { $0 }.count }

    /// Wie viele Dateien mehr als die Toleranz vom zugeordneten Track
    /// abweichen — ein Zeichen für eine falsche Zuordnung oder Fassung.
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
