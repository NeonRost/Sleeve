//
//  RipReport.swift
//  Sleeve
//
//  Das Protokoll eines Durchgangs — und das Cue Sheet.
//
//  Ein Rip-Log ist kein Beiwerk: es ist der einzige Nachweis, unter welchen
//  Bedingungen gelesen wurde und ob etwas nicht sauber ankam. Deshalb steht
//  dort auch, was *nicht* geprüft wurde.
//

import Foundation

struct RipReport: Sendable {
    struct Entry: Sendable {
        var number: Int
        var crc: UInt32
        var verificationCRC: UInt32?
        var suspiciousSectors: [Int]
        var c2ErrorSectors: [Int]
        var retryCount: Int
        var isrc: String?

        var isAccurate: Bool {
            suspiciousSectors.isEmpty && c2ErrorSectors.isEmpty
                && (verificationCRC == nil || verificationCRC == crc)
        }

        init(result: TrackRipResult) {
            self.number = result.track.number
            self.crc = result.crc
            self.verificationCRC = result.verificationCRC
            self.suspiciousSectors = result.suspiciousSectors
            self.c2ErrorSectors = result.c2ErrorSectors
            self.retryCount = result.retryCount
            self.isrc = result.track.isrc
        }
    }

    var drive: CDDriveInfo
    var toc: DiscTOC
    var settings: RipSettings
    var entries: [Entry]
    var started: Date
    var ended: Date

    var allAccurate: Bool { entries.allSatisfy(\.isAccurate) }

    // MARK: - Protokoll

    func logText(albumTitle: String? = nil, albumArtist: String? = nil) -> String {
        var lines: [String] = []
        let stamp = started.formatted(date: .numeric, time: .shortened)

        lines.append("Sleeve — CD-Rip-Protokoll")
        lines.append(stamp)
        lines.append("")
        if let albumArtist { lines.append("Interpret:   \(albumArtist)") }
        if let albumTitle { lines.append("Album:       \(albumTitle)") }
        lines.append("Laufwerk:    \(drive.displayName) \(drive.revision)")
        lines.append("")
        lines.append("Modus:       \(settings.mode == .secure ? "Sicher" : "Burst")")
        lines.append("Leseversatz: \(settings.readOffset) Samples")
        if settings.c2WasRequestedButUnavailable {
            lines.append("C2:          angefordert, vom Laufwerk nicht geliefert")
        } else {
            lines.append("C2:          \(settings.usesC2 ? "genutzt" : "nicht genutzt")")
        }
        lines.append("Geschwind.:  \(settings.speedMultiplier.map { "\($0)×" } ?? "automatisch")")
        lines.append("Doppelrip:   \(settings.testBeforeCopy ? "ja" : "nein")")
        lines.append("")
        lines.append("Disc ID:     \(toc.musicBrainzDiscID)")
        lines.append("FreeDB:      \(toc.freeDBID)")
        if let mcn = toc.mcn { lines.append("MCN:         \(mcn)") }
        lines.append("")

        for entry in entries.sorted(by: { $0.number < $1.number }) {
            lines.append("Track \(String(format: "%2d", entry.number))")
            lines.append("    CRC32            \(String(format: "%08X", entry.crc))")
            if let verification = entry.verificationCRC {
                let verdict = verification == entry.crc
                    ? "stimmt überein" : "WEICHT AB"
                lines.append("    Zweiter Durchgang \(String(format: "%08X", verification))  \(verdict)")
            }
            if let isrc = entry.isrc { lines.append("    ISRC             \(isrc)") }
            if entry.retryCount > 0 {
                lines.append("    Wiederholungen   \(entry.retryCount)")
            }
            if !entry.c2ErrorSectors.isEmpty {
                lines.append("    C2-Fehler        \(entry.c2ErrorSectors.count) Sektoren")
            }
            if !entry.suspiciousSectors.isEmpty {
                lines.append("    UNGEKLÄRT        \(entry.suspiciousSectors.count) Sektoren ab "
                    + "\(entry.suspiciousSectors[0])")
            }
            lines.append("    \(entry.isAccurate ? "ohne Beanstandung" : "NICHT SAUBER GELESEN")")
            lines.append("")
        }

        lines.append(allAccurate
            ? "Alle Spuren ohne Beanstandung."
            : "Mindestens eine Spur konnte nicht sicher gelesen werden.")
        lines.append("")
        // Ehrlich bleiben: ohne Abgleich gegen fremde Rips ist das eine
        // Aussage über die Wiederholbarkeit, nicht über die Richtigkeit.
        lines.append("Hinweis: Sleeve gleicht nicht gegen eine externe Datenbank ab.")
        lines.append("Geprüft wurde, ob sich dieselbe Scheibe in diesem Laufwerk")
        lines.append("reproduzierbar lesen lässt — nicht, ob der Leseversatz stimmt.")

        return lines.joined(separator: "\n")
    }

    // MARK: - Cue Sheet

    /// `fileType` ist `WAVE` für alles mit Kopf und `BINARY` für den rohen
    /// Strom eines BIN-Abbilds — steht es falsch da, findet das
    /// Abspielprogramm die Trackgrenzen um 44 Byte verschoben.
    ///
    /// Bekannte Einschränkung: geschrieben wird nur `INDEX 01`. Die Pausen
    /// zwischen den Spuren stecken im Abbild, aber wo genau eine Pause
    /// beginnt (`INDEX 00`), sagt die TOC nicht — dafür bräuchte es den
    /// Subchannel, den das Testlaufwerk nicht verlässlich liefert (§6.1.1).
    /// Für die üblichen Zwecke genügt INDEX 01; lückenlos bleibt es ohnehin,
    /// weil nichts herausgeschnitten wird.
    func cueSheet(albumTitle: String?, albumArtist: String?,
                  audioFileName: String, fileType: String = "WAVE",
                  titles: [Int: String] = [:]) -> String {
        var lines: [String] = []
        if let mcn = toc.mcn { lines.append("CATALOG \(mcn)") }
        if let albumArtist { lines.append("PERFORMER \"\(escape(albumArtist))\"") }
        if let albumTitle { lines.append("TITLE \"\(escape(albumTitle))\"") }
        lines.append("FILE \"\(escape(audioFileName))\" \(fileType)")

        for track in toc.tracks where !track.isData {
            lines.append("  TRACK \(String(format: "%02d", track.number)) AUDIO")
            if let title = titles[track.number], !title.isEmpty {
                lines.append("    TITLE \"\(escape(title))\"")
            }
            if let isrc = track.isrc { lines.append("    ISRC \(isrc)") }
            lines.append("    INDEX 01 \(Self.msf(track.startLBA))")
        }
        return lines.joined(separator: "\n")
    }

    private func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: "'")
    }

    /// Cue Sheets zählen in Minuten:Sekunden:Frames ab Track 1.
    static func msf(_ lba: Int) -> String {
        let frames = max(0, lba)
        return String(format: "%02d:%02d:%02d",
                      frames / (75 * 60),
                      (frames / 75) % 60,
                      frames % 75)
    }
}
