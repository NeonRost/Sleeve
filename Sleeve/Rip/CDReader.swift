//
//  CDReader.swift
//  Sleeve
//
//  Das Herzstück: aus Sektoren wird das Audio einer Spur.
//
//  Zwei Dinge passieren hier, die der Dateisystem-Weg über die gemounteten
//  `.aiff` prinzipbedingt nicht kann — genau deshalb der Rohzugriff:
//
//  1. **Leseversatz herausrechnen.** Jedes Laufwerk liefert Audio um einige
//     Samples verschoben. Unkorrigiert klingt nichts falsch, aber die
//     Prüfsummen passen zu keiner anderen Kopie derselben Scheibe.
//  2. **Mehrfach lesen und vergleichen.** Erst dadurch fällt auf, wenn eine
//     Stelle nicht sicher gelesen werden konnte.
//

import Foundation

/// Prüfsumme über die reinen Audiodaten, wie sie auch EAC und XLD im Log
/// führen. Das übliche CRC-32 mit dem Polynom 0xEDB88320.
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1 != 0) ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
        }
        return value
    }

    static func compute(_ data: Data, seed: UInt32 = 0) -> UInt32 {
        finish(continue_(~seed, with: data))
    }

    /// Anfangswert für eine stückweise Berechnung.
    static let seed: UInt32 = 0xFFFF_FFFF

    /// Schreibt die Prüfsumme über weitere Bytes fort. Nötig, weil ein Abbild
    /// nie vollständig im Speicher liegt.
    static func continue_(_ crc: UInt32, with data: Data) -> UInt32 {
        var value = crc
        for byte in data {
            value = (value >> 8) ^ table[Int((value ^ UInt32(byte)) & 0xFF)]
        }
        return value
    }

    static func finish(_ crc: UInt32) -> UInt32 { ~crc }
}

struct TrackRipResult: Sendable {
    var track: DiscTrack
    var audio: Data
    var crc: UInt32
    /// Sektoren, die auch nach allen Wiederholungen strittig blieben.
    var suspiciousSectors: [Int]
    /// Sektoren, deren C2-Zeiger Fehler meldeten.
    var c2ErrorSectors: [Int]
    /// Wie oft insgesamt nachgelesen werden musste.
    var retryCount: Int
    /// Bei `testBeforeCopy`: Prüfsumme des zweiten Durchgangs.
    var verificationCRC: UInt32?

    var isAccurate: Bool {
        suspiciousSectors.isEmpty && c2ErrorSectors.isEmpty
            && (verificationCRC == nil || verificationCRC == crc)
    }
}

/// Eine Klasse, kein Wert: über einen Durchgang hinweg wird gemerkt, ob das
/// Laufwerk bei C2 unterwegs aussteigt.
final class CDReader {
    let drive: CDDrive
    let settings: RipSettings

    /// Wird gesetzt, sobald ein C2-Lesen unbrauchbar zurückkam. Ab dann läuft
    /// der Rest des Durchgangs ohne C2 weiter, statt abzubrechen.
    private(set) var c2Fellthrough = false

    init(drive: CDDrive, settings: RipSettings) {
        self.drive = drive
        self.settings = settings
    }

    /// Wie viele Sektoren auf einmal. 27 ist der Wert, den auch andere Ripper
    /// nehmen: groß genug für Durchsatz, klein genug, dass ein strittiger
    /// Block nicht viel Wiederholung kostet.
    static let chunkSectors = 27

    enum Progress: Sendable {
        case sector(done: Int, total: Int)
        case retrying(lba: Int, attempt: Int)
    }

    /// Liest eine Spur vollständig, mit Versatzkorrektur und je nach
    /// Einstellung mit Prüfung.
    func rip(track: DiscTrack,
             onProgress: (Progress) -> Void = { _ in }) throws -> TrackRipResult {
        guard !track.isData else { throw CDDriveError.dataTrack }

        var suspicious: [Int] = []
        var c2Errors: [Int] = []
        var retries = 0

        let audio = try readCorrected(track: track,
                                      suspicious: &suspicious,
                                      c2Errors: &c2Errors,
                                      retries: &retries,
                                      onProgress: onProgress)
        let crc = CRC32.compute(audio)

        // Ein zweiter vollständiger Durchgang. Stimmen beide Prüfsummen
        // überein, war das Lesen reproduzierbar — ganz ohne fremde Datenbank.
        var verification: UInt32?
        if settings.testBeforeCopy {
            var ignoredSuspicious: [Int] = []
            var ignoredC2: [Int] = []
            var ignoredRetries = 0
            let second = try readCorrected(track: track,
                                           suspicious: &ignoredSuspicious,
                                           c2Errors: &ignoredC2,
                                           retries: &ignoredRetries,
                                           onProgress: onProgress)
            verification = CRC32.compute(second)
            retries += ignoredRetries
            suspicious = Array(Set(suspicious).union(ignoredSuspicious)).sorted()
        }

        return TrackRipResult(track: track, audio: audio, crc: crc,
                              suspiciousSectors: suspicious,
                              c2ErrorSectors: c2Errors,
                              retryCount: retries,
                              verificationCRC: verification)
    }

    // MARK: - Am Stück lesen

    /// Liest einen Sektorbereich und reicht ihn häppchenweise weiter, statt
    /// ihn zu sammeln.
    ///
    /// Für ein Abbild unverzichtbar: eine ganze CD sind rund 550 MB. Die
    /// erst vollständig in den Speicher zu legen und dann zu schreiben wäre
    /// verschwendet — und bei mehreren Scheiben hintereinander unhöflich.
    ///
    /// Die Versatzkorrektur funktioniert dabei genauso wie bei einer
    /// einzelnen Spur: gelesen wird sektorweise, das Sample-Fenster wird am
    /// Anfang um `byteShift` nach vorn geschoben und am Ende hart
    /// abgeschnitten.
    @discardableResult
    func readContiguous(fromSector first: Int,
                        toSector last: Int,
                        onChunk: (Data) throws -> Void,
                        onProgress: (Progress) -> Void = { _ in }) throws -> ReadSummary {
        let samplesPerSector = CDGeometry.samplesPerSector
        let startSample = first * samplesPerSector - settings.readOffset
        let endSample = last * samplesPerSector - settings.readOffset

        let firstSector = Int((Double(startSample) / Double(samplesPerSector)).rounded(.down))
        let lastSector = Int((Double(endSample) / Double(samplesPerSector)).rounded(.up))

        var skip = (startSample - firstSector * samplesPerSector) * CDGeometry.bytesPerSample
        var remaining = (endSample - startSample) * CDGeometry.bytesPerSample

        var summary = ReadSummary()
        let totalSectors = lastSector - firstSector
        var doneSectors = 0

        var sector = firstSector
        while sector < lastSector, remaining > 0 {
            try Task.checkCancellation()
            let count = min(Self.chunkSectors, lastSector - sector)

            // Vor Sektor 0 gibt es nichts zu lesen — dort steht Stille.
            var chunk: Data
            if sector < 0 {
                let silent = min(count, -sector)
                chunk = Data(repeating: 0, count: silent * CDGeometry.bytesPerSector)
                sector += silent
                doneSectors += silent
            } else {
                chunk = try readChunk(lba: sector, count: count,
                                      suspicious: &summary.suspiciousSectors,
                                      c2Errors: &summary.c2ErrorSectors,
                                      retries: &summary.retryCount,
                                      onProgress: onProgress)
                sector += count
                doneSectors += count
            }

            if skip > 0 {
                let drop = min(skip, chunk.count)
                chunk = chunk.dropFirst(drop)
                skip -= drop
            }
            if chunk.count > remaining { chunk = chunk.prefix(remaining) }
            guard !chunk.isEmpty else {
                onProgress(.sector(done: doneSectors, total: totalSectors))
                continue
            }

            remaining -= chunk.count
            summary.crc = CRC32.continue_(summary.crc, with: chunk)
            try onChunk(Data(chunk))
            onProgress(.sector(done: doneSectors, total: totalSectors))
        }

        // Hinter dem Lead-Out ebenfalls Stille, falls der Versatz darüber
        // hinausgereicht hat.
        if remaining > 0 {
            let padding = Data(repeating: 0, count: remaining)
            summary.crc = CRC32.continue_(summary.crc, with: padding)
            try onChunk(padding)
        }
        return summary
    }

    struct ReadSummary {
        var crc: UInt32 = CRC32.seed
        var suspiciousSectors: [Int] = []
        var c2ErrorSectors: [Int] = []
        var retryCount = 0

        var finishedCRC: UInt32 { CRC32.finish(crc) }
        var isClean: Bool { suspiciousSectors.isEmpty && c2ErrorSectors.isEmpty }
    }

    // MARK: - Versatzkorrektur

    /// Der Leseversatz verschiebt das Fenster, aus dem gelesen wird.
    ///
    /// Ein Laufwerk mit Versatz `o` liefert auf die Anfrage nach Position `p`
    /// in Wahrheit das Sample `p + o`. Wer die Spur ab `start` haben will,
    /// muss also ab `start − o` anfragen.
    ///
    /// An den Rändern der Scheibe kann das ins Nichts zeigen: vor Sektor 0
    /// und hinter dem Lead-Out gibt es nichts zu lesen. Diese Samples werden
    /// mit Stille aufgefüllt — so hält es jeder Ripper.
    private func readCorrected(track: DiscTrack,
                               suspicious: inout [Int],
                               c2Errors: inout [Int],
                               retries: inout Int,
                               onProgress: (Progress) -> Void) throws -> Data {
        let samplesPerSector = CDGeometry.samplesPerSector
        let startSample = track.startLBA * samplesPerSector - settings.readOffset
        let endSample = track.endLBA * samplesPerSector - settings.readOffset

        // Sektorgrenzen um das gewünschte Sample-Fenster herum.
        let firstSector = Int((Double(startSample) / Double(samplesPerSector)).rounded(.down))
        let lastSector = Int((Double(endSample) / Double(samplesPerSector)).rounded(.up))
        let sampleShift = startSample - firstSector * samplesPerSector

        var raw = Data(capacity: (lastSector - firstSector) * CDGeometry.bytesPerSector)
        let total = lastSector - firstSector
        var done = 0

        var sector = firstSector
        while sector < lastSector {
            let count = min(Self.chunkSectors, lastSector - sector)

            // Vor dem Anfang und hinter dem Ende der Scheibe steht Stille.
            if sector < 0 || sector >= track.endLBA + Self.chunkSectors {
                let usable = sector < 0 ? min(count, -sector) : count
                raw.append(Data(repeating: 0, count: usable * CDGeometry.bytesPerSector))
                sector += usable
                done += usable
                onProgress(.sector(done: done, total: total))
                continue
            }

            let chunk = try readChunk(lba: sector, count: count,
                                      suspicious: &suspicious,
                                      c2Errors: &c2Errors,
                                      retries: &retries,
                                      onProgress: onProgress)
            raw.append(chunk)
            sector += count
            done += count
            onProgress(.sector(done: done, total: total))
        }

        // Aus dem sektorweise gelesenen Rohmaterial das Sample-Fenster
        // herausschneiden, das die Spur wirklich ausmacht.
        let byteShift = sampleShift * CDGeometry.bytesPerSample
        let byteCount = (endSample - startSample) * CDGeometry.bytesPerSample
        guard byteShift >= 0, byteShift + byteCount <= raw.count else {
            // Kann nur passieren, wenn die TOC nicht zu dem passt, was das
            // Laufwerk liefert. Lieber Stille am Rand als ein Absturz.
            var padded = raw.dropFirst(max(0, byteShift))
            if padded.count < byteCount {
                padded.append(Data(repeating: 0, count: byteCount - padded.count))
            }
            return Data(padded.prefix(byteCount))
        }
        return raw.subdata(in: byteShift..<(byteShift + byteCount))
    }

    // MARK: - Ein Block

    /// Liest einen Block und gibt bei C2 nach, statt den ganzen Durchgang
    /// hinzuwerfen.
    ///
    /// Der Anlass ist gemessen: ein Laufwerk bestand die Vorabprüfung an
    /// Spur 1 und lieferte mitten in Spur 3 auf die Anfrage nach 15876 Byte
    /// nur 6468 zurück. Keine Vorabprüfung fängt so etwas — also muss der
    /// laufende Betrieb es abfangen.
    private func readSafely(lba: Int, count: Int) throws -> CDDrive.SectorRead {
        let wantsC2 = settings.usesC2 && !c2Fellthrough
        do {
            return try drive.read(lba: lba, count: count, withC2: wantsC2)
        } catch CDDriveError.shortRead where wantsC2 {
            c2Fellthrough = true
            return try drive.read(lba: lba, count: count, withC2: false)
        }
    }

    private func readChunk(lba: Int, count: Int,
                           suspicious: inout [Int],
                           c2Errors: inout [Int],
                           retries: inout Int,
                           onProgress: (Progress) -> Void) throws -> Data {
        let first = try readSafely(lba: lba, count: count)
        var flagged = c2FailingSectors(in: first.c2, lba: lba)
        c2Errors.append(contentsOf: flagged)

        guard settings.mode == .secure else { return first.audio }

        // Im sicheren Modus zählt nur, was zweimal gleich herauskommt.
        let second = try readSafely(lba: lba, count: count)
        flagged.append(contentsOf: c2FailingSectors(in: second.c2, lba: lba))
        if first.audio == second.audio, flagged.isEmpty { return first.audio }

        // Uneinigkeit: wiederholen und je Byte die Mehrheit entscheiden lassen.
        var candidates = [first.audio, second.audio]
        for attempt in 1...settings.maxRetries {
            retries += 1
            onProgress(.retrying(lba: lba, attempt: attempt))
            let again = try readSafely(lba: lba, count: count)
            candidates.append(again.audio)

            // Zwei übereinstimmende Lesungen nach einer Abweichung genügen.
            if candidates.suffix(2).first == again.audio,
               c2FailingSectors(in: again.c2, lba: lba).isEmpty {
                return again.audio
            }
        }

        let resolved = majorityVote(candidates)
        if resolved.agreed {
            return resolved.data
        }
        suspicious.append(contentsOf: (lba..<(lba + count)))
        return resolved.data
    }

    /// Jedes Bit in den C2-Daten steht für ein Audio-Byte, das das Laufwerk
    /// nicht sicher lesen konnte.
    private func c2FailingSectors(in c2: Data, lba: Int) -> [Int] {
        guard !c2.isEmpty else { return [] }
        let perSector = CDDrive.c2BytesPerSector
        var failing: [Int] = []
        for index in 0..<(c2.count / perSector) {
            let start = c2.startIndex + index * perSector
            let slice = c2[start..<(start + perSector)]
            if slice.contains(where: { $0 != 0 }) { failing.append(lba + index) }
        }
        return failing
    }

    /// Byteweise Mehrheitsentscheidung. `agreed` sagt, ob jede Stelle eine
    /// echte Mehrheit hatte — sonst bleibt die Stelle fragwürdig, auch wenn
    /// ein Wert eingesetzt wurde.
    private func majorityVote(_ candidates: [Data]) -> (data: Data, agreed: Bool) {
        guard let length = candidates.first?.count, candidates.count > 1 else {
            return (candidates.first ?? Data(), false)
        }
        var result = Data(repeating: 0, count: length)
        var agreed = true
        let arrays = candidates.map { [UInt8]($0) }

        for position in 0..<length {
            var counts: [UInt8: Int] = [:]
            for array in arrays where position < array.count {
                counts[array[position], default: 0] += 1
            }
            guard let winner = counts.max(by: { $0.value < $1.value }) else { continue }
            result[position] = winner.key
            // Mehrheit heißt: mehr als die Hälfte, nicht bloß der häufigste Wert.
            if winner.value * 2 <= arrays.count { agreed = false }
        }
        return (result, agreed)
    }
}
