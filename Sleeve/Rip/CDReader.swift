//
//  CDReader.swift
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
//  The heart of it: sectors become the audio of a track.
//
//  Two things happen here that the file system route via the mounted
//  `.aiff` files cannot do by design — which is exactly why raw access is
//  used:
//
//  1. **Correcting the read offset.** Every drive delivers audio shifted by
//     a few samples. Uncorrected, nothing sounds wrong, but the checksums
//     match no other copy of the same disc.
//  2. **Reading several times and comparing.** Only that reveals when a
//     spot could not be read reliably.
//

import Foundation

/// Checksum over the pure audio data, as EAC and XLD list it in their logs.
/// The usual CRC-32 with the polynomial 0xEDB88320.
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

    /// Initial value for a piecewise computation.
    static let seed: UInt32 = 0xFFFF_FFFF

    /// Continues the checksum over further bytes. Needed because an image is
    /// never held in memory completely.
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
    /// The audio, when it was asked for in memory. Empty when the track was
    /// written straight to a file — a track of a single-track disc can be
    /// most of a gigabyte.
    var audio: Data
    var crc: UInt32
    /// Sectors that stayed disputed even after all retries.
    var suspiciousSectors: [Int]
    /// Sectors whose C2 pointers reported errors that no retry cleared.
    var c2ErrorSectors: [Int]
    /// Sectors the drive could not deliver at all — filled with silence.
    var unreadableSectors: [Int] = []
    /// How often re-reading was needed in total.
    var retryCount: Int
    /// With `testBeforeCopy`: checksum of the second pass.
    var verificationCRC: UInt32?

    var isAccurate: Bool {
        suspiciousSectors.isEmpty && c2ErrorSectors.isEmpty && unreadableSectors.isEmpty
            && (verificationCRC == nil || verificationCRC == crc)
    }
}

/// A class, not a value: across one pass it remembers whether the drive
/// gives up on C2 along the way.
final class CDReader {
    let drive: CDDrive
    let settings: RipSettings
    /// Where the readable audio ends (session 1's lead-out). The offset can
    /// shift the window past it; drives refuse those sectors, so they are
    /// silence — as before sector 0.
    let leadOutLBA: Int?

    /// Set as soon as a C2 read came back unusable. From then on the rest of
    /// the pass continues without C2 instead of aborting.
    private(set) var c2Fellthrough = false

    /// Sectors given up on in the pass in progress.
    private var unreadable: [Int] = []

    init(drive: CDDrive, settings: RipSettings, leadOutLBA: Int? = nil) {
        self.drive = drive
        self.settings = settings
        self.leadOutLBA = leadOutLBA
    }

    /// How many sectors at once. 27 is the value other rippers use too: large
    /// enough for throughput, small enough that a disputed block does not cost
    /// much re-reading.
    static let chunkSectors = 27

    /// More unreadable sectors than this in one pass, and the disc is given
    /// up on: ten seconds of silence are no rip any more, and every failed
    /// sector costs the drive seconds.
    static let unreadableLimit = 750

    enum Progress: Sendable {
        case sector(done: Int, total: Int)
        case retrying(lba: Int, attempt: Int)
    }

    /// Reads a track completely, with offset correction and, depending on the
    /// settings, with verification.
    ///
    /// With `url` the track goes straight into a WAV file there and
    /// `audio` stays empty; nothing but one block is ever held in memory.
    /// A file left half-written by an error or a stop is removed.
    func rip(track: DiscTrack,
             writingTo url: URL? = nil,
             onProgress: (Progress) -> Void = { _ in }) throws -> TrackRipResult {
        guard !track.isData else { throw CDDriveError.dataTrack }

        var audio = Data()
        var handle: FileHandle?
        if let url {
            guard FileManager.default.createFile(atPath: url.path(percentEncoded: false),
                                                 contents: WAVWriter.header(
                                                    forPCMByteCount: track.sectorCount * CDGeometry.bytesPerSector)),
                  let opened = try? FileHandle(forWritingTo: url) else {
                throw CDDriveError.cannotOpen(url.lastPathComponent)
            }
            _ = try? opened.seekToEnd()
            handle = opened
        }
        var finished = false
        defer {
            try? handle?.close()
            if !finished, let url { try? FileManager.default.removeItem(at: url) }
        }

        let first = try readContiguous(fromSector: track.startLBA, toSector: track.endLBA) { chunk in
            if let handle { try handle.write(contentsOf: chunk) } else { audio.append(chunk) }
        } onProgress: { onProgress($0) }

        var summary = first
        // A second complete pass, of which only the checksum is kept. If
        // both agree, the reading was reproducible — without any external
        // database.
        var verification: UInt32?
        if settings.testBeforeCopy {
            let second = try readContiguous(fromSector: track.startLBA,
                                            toSector: track.endLBA) { _ in }
                onProgress: { onProgress($0) }
            verification = second.finishedCRC
            summary.retryCount += second.retryCount
            summary.suspiciousSectors = Array(Set(first.suspiciousSectors)
                .union(second.suspiciousSectors)).sorted()
            summary.unreadableSectors = Array(Set(first.unreadableSectors)
                .union(second.unreadableSectors)).sorted()
        }
        finished = true

        return TrackRipResult(track: track, audio: audio, crc: first.finishedCRC,
                              suspiciousSectors: summary.suspiciousSectors,
                              c2ErrorSectors: summary.c2ErrorSectors,
                              unreadableSectors: summary.unreadableSectors,
                              retryCount: summary.retryCount,
                              verificationCRC: verification)
    }

    // MARK: - Reading in one piece

    /// Reads a range of sectors and passes it on in chunks instead of
    /// collecting it.
    ///
    /// The one way in which audio is read — for a track as for a whole
    /// image: a whole CD is about 550 MB, and putting all of it in memory
    /// first would be wasteful.
    ///
    /// Offset correction: the window is shifted by the offset, read sector
    /// by sector, cut at the front by `skip` and hard at the end. Before
    /// sector 0 and from the lead-out on there is nothing to read; that part
    /// of the window is silence, which is what every ripper does.
    @discardableResult
    func readContiguous(fromSector first: Int,
                        toSector last: Int,
                        onChunk: (Data) throws -> Void,
                        onProgress: (Progress) -> Void = { _ in }) throws -> ReadSummary {
        let samplesPerSector = CDGeometry.samplesPerSector
        let startSample = first * samplesPerSector + settings.readOffset
        let endSample = last * samplesPerSector + settings.readOffset

        let firstSector = Int((Double(startSample) / Double(samplesPerSector)).rounded(.down))
        let lastSector = Int((Double(endSample) / Double(samplesPerSector)).rounded(.up))

        var skip = (startSample - firstSector * samplesPerSector) * CDGeometry.bytesPerSample
        var remaining = (endSample - startSample) * CDGeometry.bytesPerSample

        var summary = ReadSummary()
        unreadable = []
        defer { summary.unreadableSectors = unreadable }
        let totalSectors = lastSector - firstSector
        var doneSectors = 0

        var sector = firstSector
        while sector < lastSector, remaining > 0 {
            try Task.checkCancellation()
            var count = min(Self.chunkSectors, lastSector - sector)

            var chunk: Data
            if sector < 0 || (leadOutLBA.map { sector >= $0 } ?? false) {
                // Nothing to read here: silence.
                let silent = sector < 0 ? min(count, -sector) : count
                chunk = Data(repeating: 0, count: silent * CDGeometry.bytesPerSector)
                sector += silent
                doneSectors += silent
            } else {
                if let end = leadOutLBA { count = min(count, end - sector) }
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

        // Beyond the lead-out likewise silence, in case the offset reached
        // past it.
        if remaining > 0 {
            let padding = Data(repeating: 0, count: remaining)
            summary.crc = CRC32.continue_(summary.crc, with: padding)
            try onChunk(padding)
        }
        summary.unreadableSectors = unreadable
        return summary
    }

    struct ReadSummary {
        var crc: UInt32 = CRC32.seed
        var suspiciousSectors: [Int] = []
        var c2ErrorSectors: [Int] = []
        var unreadableSectors: [Int] = []
        var retryCount = 0

        var finishedCRC: UInt32 { CRC32.finish(crc) }
        var isClean: Bool {
            suspiciousSectors.isEmpty && c2ErrorSectors.isEmpty && unreadableSectors.isEmpty
        }
    }

    // MARK: - One block

    /// Reads a block and gives way on C2 instead of throwing away the whole
    /// pass.
    ///
    /// The reason is measured: a drive passed the upfront check on track 1
    /// and, in the middle of track 3, returned only 6468 bytes when asked for
    /// 15876. No upfront check catches something like that — so normal
    /// operation has to.
    private func readSafely(lba: Int, count: Int) throws -> CDDrive.SectorRead {
        let wantsC2 = settings.usesC2 && !c2Fellthrough
        do {
            return try drive.read(lba: lba, count: count, withC2: wantsC2)
        } catch CDDriveError.shortRead where wantsC2 {
            c2Fellthrough = true
            return try drive.read(lba: lba, count: count, withC2: false)
        }
    }

    /// A block, and when the drive cannot deliver it — a scratch — the same
    /// block sector by sector, so that one bad spot costs its own sectors
    /// and not the track. A sector that does not come after all retries is
    /// silence and is recorded; the log names it.
    private func readChunk(lba: Int, count: Int,
                           suspicious: inout [Int],
                           c2Errors: inout [Int],
                           retries: inout Int,
                           onProgress: (Progress) -> Void) throws -> Data {
        do {
            return try readVerified(lba: lba, count: count, suspicious: &suspicious,
                                    c2Errors: &c2Errors, retries: &retries,
                                    onProgress: onProgress)
        } catch let error as CDDriveError {
            switch error {
            case .readFailed, .shortRead: break
            default: throw error
            }
        }

        var data = Data(capacity: count * CDGeometry.bytesPerSector)
        for single in lba..<(lba + count) {
            try Task.checkCancellation()
            var sectorData: Data?
            for attempt in 0...min(settings.maxRetries, 3) {
                if attempt > 0 {
                    retries += 1
                    onProgress(.retrying(lba: single, attempt: attempt))
                }
                do {
                    sectorData = try readVerified(lba: single, count: 1,
                                                  suspicious: &suspicious,
                                                  c2Errors: &c2Errors, retries: &retries,
                                                  onProgress: onProgress)
                    break
                } catch let error as CDDriveError {
                    switch error {
                    case .readFailed, .shortRead: continue
                    default: throw error
                    }
                }
            }
            if let sectorData {
                data.append(sectorData)
            } else {
                unreadable.append(single)
                guard unreadable.count <= Self.unreadableLimit else {
                    throw CDDriveError.unreadable(lba: single)
                }
                data.append(Data(repeating: 0, count: CDGeometry.bytesPerSector))
            }
        }
        return data
    }

    /// One block as the mode wants it: in burst read once, in secure read
    /// until two reads agree. C2 flags count only if no retry got past them —
    /// a sector that came out the same twice without flags is clean.
    private func readVerified(lba: Int, count: Int,
                              suspicious: inout [Int],
                              c2Errors: inout [Int],
                              retries: inout Int,
                              onProgress: (Progress) -> Void) throws -> Data {
        let first = try readSafely(lba: lba, count: count)
        var flagged = c2FailingSectors(in: first.c2, lba: lba)

        guard settings.mode == .secure else {
            c2Errors.append(contentsOf: flagged)
            return first.audio
        }

        // In secure mode only what comes out the same twice counts.
        let second = try readSafely(lba: lba, count: count)
        flagged.append(contentsOf: c2FailingSectors(in: second.c2, lba: lba))
        if first.audio == second.audio, flagged.isEmpty { return first.audio }

        // Disagreement: retry and let the majority decide per byte.
        var candidates = [first.audio, second.audio]
        for attempt in 1...max(1, settings.maxRetries) {
            retries += 1
            onProgress(.retrying(lba: lba, attempt: attempt))
            let again = try readSafely(lba: lba, count: count)
            candidates.append(again.audio)

            // Two matching reads after a mismatch are enough.
            if candidates.suffix(2).first == again.audio,
               c2FailingSectors(in: again.c2, lba: lba).isEmpty {
                return again.audio
            }
        }

        c2Errors.append(contentsOf: Set(flagged).sorted())
        let resolved = majorityVote(candidates)
        if resolved.agreed {
            return resolved.data
        }
        suspicious.append(contentsOf: (lba..<(lba + count)))
        return resolved.data
    }

    /// Every bit in the C2 data stands for an audio byte the drive could
    /// not read reliably.
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

    /// Majority vote per byte. `agreed` says whether every position had a real
    /// majority — otherwise the position stays questionable, even though a
    /// value was filled in.
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
            // Majority means more than half, not just the most frequent value.
            if winner.value * 2 <= arrays.count { agreed = false }
        }
        return (result, agreed)
    }
}
