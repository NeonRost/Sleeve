//
//  CueSheet.swift
//  Sleeve
//
//  Ein Cue Sheet lesen — die Gegenrichtung zu `RipReport.cueSheet`.
//
//  Gebraucht wird es vom Brennen: das Abbild selbst sagt nicht, wo ein Track
//  anfängt. Dieselbe Auswertung trägt später das Einlesen eines Abbilds in die
//  Trackliste (Spec §9.1) — deshalb steht sie hier für sich und nicht im
//  Brenner.
//

import Foundation

struct CueSheet: Equatable, Sendable {

    struct Track: Equatable, Sendable, Identifiable {
        var number: Int
        /// Startsektor ab Beginn der Datei, aus `INDEX 01`.
        var startLBA: Int
        var title: String?
        var performer: String?
        var isrc: String?

        init(number: Int, startLBA: Int, title: String? = nil,
             performer: String? = nil, isrc: String? = nil) {
            self.number = number
            self.startLBA = startLBA
            self.title = title
            self.performer = performer
            self.isrc = isrc
        }

        var id: Int { number }
    }

    var audioFileName: String
    /// `BINARY` für den rohen Strom, `WAVE` für alles mit Kopf.
    var fileType: String
    var albumTitle: String?
    var albumPerformer: String?
    var catalog: String?
    var tracks: [Track]

    // MARK: - Auswerten

    init?(text: String) {
        var fileName: String?
        var type = "WAVE"
        var title: String?
        var performer: String?
        var catalog: String?
        var parsed: [Track] = []
        /// Vor der ersten `TRACK`-Zeile gehören TITLE und PERFORMER zum Album,
        /// danach zur jeweiligen Spur.
        var current: Track?

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let (keyword, rest) = Self.split(line)

            switch keyword {
            case "FILE":
                // FILE "name mit leerzeichen.bin" BINARY
                if let quoted = Self.quoted(rest) {
                    fileName = quoted.value
                    let tail = quoted.remainder.trimmingCharacters(in: .whitespaces)
                    if !tail.isEmpty { type = tail.uppercased() }
                } else {
                    let parts = rest.split(separator: " ", maxSplits: 1)
                    fileName = parts.first.map(String.init)
                    if parts.count > 1 { type = String(parts[1]).uppercased() }
                }

            case "TRACK":
                if let track = current { parsed.append(track) }
                let parts = rest.split(separator: " ")
                let number = parts.first.flatMap { Int($0) } ?? (parsed.count + 1)
                // Datenspuren tauchen im Cue auf, gebrannt werden sie hier nicht.
                let mode = parts.count > 1 ? String(parts[1]).uppercased() : "AUDIO"
                current = mode == "AUDIO" ? Track(number: number, startLBA: 0) : nil

            case "TITLE":
                let value = Self.quoted(rest)?.value ?? rest
                if current != nil { current?.title = value } else { title = value }

            case "PERFORMER":
                let value = Self.quoted(rest)?.value ?? rest
                if current != nil { current?.performer = value } else { performer = value }

            case "ISRC":
                current?.isrc = rest

            case "CATALOG":
                catalog = rest

            case "INDEX":
                // Nur INDEX 01 ist der Beginn der hörbaren Spur; INDEX 00
                // markiert die Pause davor und gehört noch zum Vorgänger.
                let parts = rest.split(separator: " ")
                guard parts.count >= 2, parts[0] == "01",
                      let lba = Self.lba(fromMSF: String(parts[1])) else { break }
                current?.startLBA = lba

            default:
                break
            }
        }
        if let track = current { parsed.append(track) }

        guard let fileName, !parsed.isEmpty else { return nil }
        self.audioFileName = fileName
        self.fileType = type
        self.albumTitle = title
        self.albumPerformer = performer
        self.catalog = catalog
        self.tracks = parsed.sorted { $0.number < $1.number }
    }

    /// Wie viele Sektoren jede Spur umfasst — ergibt sich erst aus dem Beginn
    /// der nächsten, die letzte reicht bis zum Ende der Datei.
    func sectorCounts(totalSectors: Int) -> [Int: Int] {
        var counts: [Int: Int] = [:]
        for (index, track) in tracks.enumerated() {
            let next = index + 1 < tracks.count ? tracks[index + 1].startLBA : totalSectors
            counts[track.number] = max(0, next - track.startLBA)
        }
        return counts
    }

    // MARK: - Kleinteile

    private static func split(_ line: String) -> (String, String) {
        guard let space = line.firstIndex(of: " ") else { return (line.uppercased(), "") }
        return (String(line[line.startIndex..<space]).uppercased(),
                String(line[line.index(after: space)...]).trimmingCharacters(in: .whitespaces))
    }

    /// Holt den Inhalt der ersten Anführungszeichen heraus und gibt zurück,
    /// was danach noch kommt.
    private static func quoted(_ text: String) -> (value: String, remainder: String)? {
        guard let open = text.firstIndex(of: "\""),
              let close = text[text.index(after: open)...].firstIndex(of: "\"")
        else { return nil }
        return (String(text[text.index(after: open)..<close]),
                String(text[text.index(after: close)...]))
    }

    /// `mm:ss:ff` — Minuten, Sekunden, Frames zu 1/75 Sekunde.
    static func lba(fromMSF text: String) -> Int? {
        let parts = text.split(separator: ":")
        guard parts.count == 3,
              let minutes = Int(parts[0]), let seconds = Int(parts[1]), let frames = Int(parts[2]),
              seconds < 60, frames < 75
        else { return nil }
        return (minutes * 60 + seconds) * CDGeometry.sectorsPerSecond + frames
    }
}
