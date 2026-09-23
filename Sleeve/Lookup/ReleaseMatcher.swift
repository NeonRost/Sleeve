//
//  ReleaseMatcher.swift
//  Sleeve
//
//  Ordnet lokale Dateien den Discogs-Tracks zu (Spec §4.6).
//
//  Automatik trifft es bei Live-Alben, Bonustracks und Doppel-CDs regelmäßig
//  nicht. Deshalb ist das hier ausdrücklich nur ein **Vorschlag** — die
//  Oberfläche lässt ihn korrigieren.
//

import Foundation

enum ReleaseMatcher {

    struct LocalTrack: Sendable, Identifiable, Equatable {
        var id: UUID
        var title: String?
        var filename: String
        /// Spielzeit in Sekunden — zum Vergleich mit der Länge im Album.
        var duration: Double? = nil

        /// Womit verglichen wird: der Titel, sonst der Dateiname ohne Endung.
        var comparisonText: String {
            if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty { return title }
            return (filename as NSString).deletingPathExtension
        }

        var hasTitle: Bool {
            !(title ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// Je lokalem Track der Index im Discogs-Tracklisting, oder `nil`.
    typealias Pairing = [Int?]

    // MARK: - Vorschlag

    static func suggest(local: [LocalTrack], remote: [LookupTrack]) -> Pairing {
        guard !local.isEmpty, !remote.isEmpty else {
            return Array(repeating: nil, count: local.count)
        }

        let byOrder: Pairing = (0..<local.count).map { $0 < remote.count ? $0 : nil }

        // Ohne lokale Titel gibt es nichts zu vergleichen — Reihenfolge ist
        // dann die einzige sinnvolle Annahme.
        guard local.contains(where: \.hasTitle) else { return byOrder }

        let byTitle = greedyByTitle(local: local, remote: remote)
        // Die Reihenfolge bleibt der Standard; nur wenn der Titelabgleich
        // spürbar besser passt, gewinnt er. Sonst würden zwei ähnlich
        // benannte Stücke die ganze Liste verschieben.
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

    // MARK: - Ähnlichkeit

    /// 0 bis 1, auf Basis der Levenshtein-Distanz über normalisierten Text.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = normalize(a), y = normalize(b)
        if x.isEmpty || y.isEmpty { return 0 }
        if x == y { return 1 }
        let distance = levenshtein(Array(x), Array(y))
        return 1 - Double(distance) / Double(max(x.count, y.count))
    }

    /// Kleinschreibung, Satzzeichen raus, Leerraum zusammengezogen. Eine
    /// führende Tracknummer aus dem Dateinamen stört den Vergleich, also weg.
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

    // MARK: - Vorgeschlagene Tags

    struct Proposal: Sendable, Identifiable {
        var id: UUID { trackID }
        var trackID: UUID
        /// Nur die Felder, für die Discogs etwas hergibt.
        var values: [TagField: String]
        var remoteTitle: String?
    }

    /// Baut aus Release und Zuordnung die Feldwerte je lokalem Track.
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
                // Track-eigener Künstler hat Vorrang — bei Samplern steht auf
                // jedem Stück ein anderer.
                values[.artist] = remoteTrack.artistName ?? albumArtist

                // Nummer aus der Quelle, sonst die laufende Nummer der Liste.
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

    /// Release-Titel bei Discogs lautet oft „Künstler - Album". Für das
    /// Album-Feld ist nur der hintere Teil gemeint.
    static func normalizedTitle(_ title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
