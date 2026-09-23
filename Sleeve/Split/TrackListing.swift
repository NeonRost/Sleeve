//
//  TrackListing.swift
//  Sleeve
//
//  Eine Trackliste von außen — aus MusicBrainz oder aus eingefügtem Text —
//  und wie sie auf die gefundenen Tracks gelegt wird (Spec §7.12).
//
//  Die beiden Quellen liefern Verschiedenes: MusicBrainz kennt die **Länge**
//  jedes Tracks, eine YouTube-Beschreibung die **Startzeit**. Beides reicht,
//  um die Grenzen auszurichten — und beides findet Übergänge, an denen keine
//  Stille liegt.
//

import Foundation

struct TrackListing: Equatable, Sendable {

    struct Entry: Equatable, Sendable {
        var title: String
        /// Aus einer eingefügten Liste.
        var start: Double?
        /// Aus MusicBrainz.
        var duration: Double?
    }

    var entries: [Entry]
    var album: String?
    var artist: String?
    var year: Int?
    var genre: String?

    var hasStarts: Bool { !entries.isEmpty && entries.allSatisfy { $0.start != nil } }
    var hasDurations: Bool { !entries.isEmpty && entries.allSatisfy { $0.duration != nil } }

    // MARK: - Eingefügter Text

    /// Liest eine Trackliste, wie sie unter Album-Videos steht:
    ///
    ///     Beast City 0:00
    ///     Vision (ISM∞Version) 1:35
    ///     01. Chemical – 5:16
    ///     [9:32] Spiral Cave
    ///
    /// Zeilen ohne Zeitangabe werden übergangen — Überschriften, Links, die
    /// Gesamtlänge in Klammern. Die Zeitangabe darf vorn oder hinten stehen.
    init(pasted text: String) {
        var result: [Entry] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let match = line.range(of: #"(?<![\d:])(\d{1,2}:)?\d{1,2}:\d{2}(?![\d:])"#,
                                         options: .regularExpression),
                  let seconds = Timecode.parse(String(line[match]))
            else { continue }

            var title = line
            title.removeSubrange(match)
            title = Self.clean(title)
            // „(44:49)" hat nach dem Entfernen der Zeit keinen Titel mehr —
            // das ist die Gesamtlänge, kein Track.
            guard !title.isEmpty else { continue }
            result.append(Entry(title: title, start: seconds, duration: nil))
        }
        // Eine Trackliste läuft vorwärts. Was rückwärts springt, ist etwas
        // anderes — ein Kommentar, eine zweite Liste.
        var ordered: [Entry] = []
        for entry in result where (entry.start ?? 0) >= (ordered.last?.start ?? -1) {
            ordered.append(entry)
        }
        self.entries = ordered
    }

    init(entries: [Entry], album: String? = nil, artist: String? = nil, year: Int? = nil,
         genre: String? = nil) {
        self.entries = entries
        self.album = album
        self.artist = artist
        self.year = year
        self.genre = genre
    }

    /// Nimmt, was um den Titel herum an Satzzeichen und Nummerierung stehen
    /// bleibt: „01. ", " – ", „[]", „()".
    private static func clean(_ text: String) -> String {
        var title = text
        title = title.replacingOccurrences(of: #"[\[\(]\s*[\]\)]"#, with: "",
                                           options: .regularExpression)
        let edge = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-–—|:·•.,"))
        title = title.trimmingCharacters(in: edge)
        // Führende Nummer („01.", „1)", „#3") — aber nicht, wenn der Titel
        // selbst eine Zahl ist.
        if let number = title.range(of: #"^#?\d{1,3}[.)]\s+"#, options: .regularExpression) {
            title.removeSubrange(number)
        }
        return title.trimmingCharacters(in: edge)
    }

    // MARK: - Aus MusicBrainz

    init(release: LookupRelease, genreSource: GenreSource = .style) {
        self.entries = release.tracks.map {
            Entry(title: $0.title ?? "", start: nil,
                  duration: $0.duration.flatMap { Timecode.parse($0) })
        }
        self.album = release.title
        self.artist = release.albumArtist
        self.year = release.year
        self.genre = genreSource.value(from: release)
    }

    /// Welche Tag-Felder diese Liste füllen kann. Eine eingefügte Liste kennt
    /// nur Titel; ein Album aus MusicBrainz oder Discogs meist alles.
    var availableFields: Set<TagField> {
        var fields: Set<TagField> = entries.contains { !$0.title.isEmpty } ? [.title] : []
        if artist != nil { fields.insert(.artist) }
        if album != nil { fields.insert(.album) }
        if year != nil { fields.insert(.year) }
        if genre != nil { fields.insert(.genre) }
        return fields
    }

    /// Was der Track Splitter aus einer Liste übernehmen kann.
    static let takeOverFields: [TagField] = [.title, .artist, .album, .year, .genre]
}

// MARK: - Grenzen ausrichten

extension AudioSplitter {

    /// Wie weit eine Zeitangabe von einer erkannten Stille entfernt sein darf,
    /// um dort einzurasten. Uploader schreiben ganze Sekunden, oft mitten in
    /// die Pause.
    static let snapTolerance: Double = 5

    /// Alle Stellen, an denen die Erkennung einen Schnitt setzen würde — vor
    /// dem Ausdünnen. Daran rasten ausgerichtete Grenzen ein.
    static func candidateCuts(silences: [SilenceInterval], duration: Double,
                              levels: WaveformSampler.Waveform?) -> [Double] {
        bridge(silences.sorted { $0.start < $1.start }, within: noiseLength)
            .filter { $0.start >= edgeBuffer && $0.end <= duration - edgeBuffer }
            .map { cutPosition(in: $0, levels: levels) }
    }

    /// Grenzen aus **Startzeiten** — jede für sich eingerastet.
    static func alignedRanges(starts: [Double], duration: Double,
                              candidates: [Double]) -> [TrackRange] {
        guard !starts.isEmpty else { return [] }
        var bounds = [0.0]
        for start in starts.dropFirst() {
            bounds.append(snap(start, to: candidates))
        }
        return ranges(from: bounds, duration: duration)
    }

    /// Grenzen aus **Längen** — fortlaufend addiert, aber jede neu vom
    /// eingerasteten Vorgänger aus gerechnet. Addierte man stur, wanderte ein
    /// Fehler mit jedem Track weiter: ein YouTube-Mitschnitt hat selten
    /// dieselben Pausen wie die CD, auf die sich die Längen beziehen.
    static func alignedRanges(durations: [Double], duration: Double,
                              candidates: [Double]) -> [TrackRange] {
        guard !durations.isEmpty else { return [] }
        var bounds = [0.0]
        for length in durations.dropLast() {
            bounds.append(snap(bounds.last! + length, to: candidates))
        }
        return ranges(from: bounds, duration: duration)
    }

    private static func snap(_ target: Double, to candidates: [Double]) -> Double {
        guard let nearest = candidates.min(by: { abs($0 - target) < abs($1 - target) }),
              abs(nearest - target) <= snapTolerance else { return target }
        return nearest
    }

    /// Macht aus Grenzen lückenlose Tracks; unbrauchbare — außerhalb der Datei
    /// oder rückwärts — fallen weg.
    private static func ranges(from bounds: [Double], duration: Double) -> [TrackRange] {
        var clean: [Double] = []
        for bound in bounds where bound >= 0 && bound < duration {
            if let last = clean.last, bound <= last + 0.5 { continue }
            clean.append(bound)
        }
        return clean.indices.map { index in
            TrackRange(start: clean[index],
                       end: index + 1 < clean.count ? clean[index + 1] : duration)
        }
    }
}
