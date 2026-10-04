//
//  RipTests.swift
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
//  The Rip mode (§6). Most of it runs without a drive: TOC parsing,
//  identifiers, CD-TEXT and offset arithmetic are pure logic.
//
//  The checks at the end need an inserted audio CD and are skipped when there
//  is none — they must not turn the suite red just because no drive happens to
//  be connected.
//

import Foundation

enum RipTests {

    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var checks = 0

    static func check(_ condition: Bool, _ label: String, detail: @autoclosure () -> String = "") {
        checks += 1
        if condition {
            print("  ✓ \(label)")
        } else {
            failures += 1
            let extra = detail()
            print("  ✗ \(label)\(extra.isEmpty ? "" : " — \(extra)")")
        }
    }

    static func equal<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
        check(actual == expected, label, detail: "is \(actual), expected \(expected)")
    }

    /// The real TOC of the test disc, as IOKit delivers it. 14 tracks.
    static let realTOC = """
    00bd0101011200a000000000010000011200a1000000000e0000011200a200000000341f2b\
    0112000100000000000200011200020000000003063301120003000000000420 0d011200040\
    0000000052746011200050000000007164801120006000000000a083301120007000000000c\
    074a01120008000000000f01140112000900000000192c020112000a00000000210b0d01120\
    00b000000002308220112000c0000000025031b0112000d0000000026393c0112000e000000\
    00282715
    """.replacingOccurrences(of: " ", with: "")

    static func hexData(_ hex: String) -> Data {
        var bytes = [UInt8]()
        var index = hex.startIndex
        while let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return Data(bytes)
    }

    /// The whole route through `RipEngine`: identify the disc, rip a track,
    /// write the WAV — and hold the result against what macOS sees.
    static func engineEndToEnd(toc: DiscTOC, track: DiscTrack, aiff: Data) throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("sleeve-rip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var settings = RipSettings()
        settings.mode = .burst          // one pass is enough for the test run
        settings.usesC2 = true          // on purpose: has to drop out silently
        settings.readOffset = 0
        settings.readsSubchannel = false

        let engine = RipEngine()
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var report: RipReport?
        nonisolated(unsafe) var written: URL?
        nonisolated(unsafe) var failures: [String] = []

        Task {
            for await event in engine.rip(tracks: [track.number], to: folder, settings: settings) {
                switch event {
                case let .trackFinished(_, url):        written = url
                case let .trackFailed(_, reason):       failures.append(reason)
                case let .finished(finished):           report = finished
                default: break
                }
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 180) == .success else {
            check(false, "ripping finishes in the expected time")
            return
        }

        check(failures.isEmpty, "ripping without errors", detail: failures.joined(separator: "; "))
        guard let written, let report else {
            check(false, "the engine delivers file and log")
            return
        }
        check(true, "the engine delivers file and log")

        let wav = try Data(contentsOf: written)
        let pcm = Data(wav.dropFirst(44))
        equal(pcm.count, track.byteCount, "the WAV contains the whole track")
        equal(pcm, Data(aiff.dropFirst(2352)), "the ripped track matches what macOS reads")

        // C2 was requested, the drive cannot do it — the pass still has to run
        // through cleanly and the log has to say so.
        if !report.settings.usesC2 {
            check(report.settings.c2WasRequestedButUnavailable,
                  "missing C2 is noted in the log")
        }

        let log = report.logText(albumTitle: "Peter und der Wolf", albumArtist: "Malte Arkona")
        check(log.contains("Disc ID:     \(toc.musicBrainzDiscID)"), "the disc ID is in the log")
        check(log.contains(String(format: "%08X", report.entries[0].crc)),
              "the checksum is in the log")
        check(log.contains("does not compare against an external database"),
              "the log says what it did not check")

        let cue = report.cueSheet(albumTitle: "Peter und der Wolf",
                                  albumArtist: "Malte Arkona", audioFileName: "album.wav")
        check(cue.contains("TRACK 01 AUDIO"), "the cue sheet lists the first track")
        // Computed from the inserted disc's TOC — whichever CD is in the drive.
        if toc.tracks.count > 1 {
            check(cue.contains("INDEX 01 \(RipReport.msf(toc.tracks[1].startLBA))"),
                  "the cue sheet names the start of the second track")
        }
    }

    static func run() throws -> Int32 {
        tocParsing()
        discIdentifiers()
        cdTextParsing()
        offsetArithmetic()
        checksums()
        wavAndCue()
        discImage()
        try live()

        print("\n  \(checks) checks, \(failures) failures")
        return failures == 0 ? 0 : 1
    }

    // MARK: - TOC

    static func tocParsing() {
        print("\n— Table of contents —")
        guard let toc = DiscTOC(rawTOC: hexData(realTOC)) else {
            check(false, "the TOC can be parsed")
            return
        }
        check(true, "the TOC can be parsed")
        equal(toc.firstTrack, 1, "first track")
        equal(toc.lastTrack, 14, "last track")
        equal(toc.tracks.count, 14, "fourteen tracks")
        // drutil reports 236218 blocks for the same disc.
        equal(toc.leadOutLBA, 236218, "the lead-out matches drutil")
        equal(toc.tracks[0].startLBA, 0, "track 1 starts at sector 0")
        equal(toc.tracks[1].startLBA, 13851, "track 2 starts at 13851")
        equal(toc.tracks[0].sectorCount, 13851, "length of the first track")
        // The last track reaches to the lead-out.
        equal(toc.tracks[13].endLBA, 236218, "the last track ends at the lead-out")
        check(!toc.hasDataTrack, "a pure audio CD, no data track")
        equal(toc.tracks.reduce(0) { $0 + $1.sectorCount }, 236218,
              "track lengths add up to the whole disc")

        check(DiscTOC(rawTOC: Data()) == nil, "an empty TOC is rejected")
        check(DiscTOC(rawTOC: Data([0, 4, 1, 1])) == nil, "a TOC without tracks is rejected")
    }

    // MARK: - Identifiers

    static func discIdentifiers() {
        print("\n— Identifiers —")

        // The worked example from the MusicBrainz documentation. Without this
        // check every computed disc ID would be a mere claim.
        let reference = DiscTOC(
            firstTrack: 1, lastTrack: 6, leadOutLBA: 95462 - 150,
            tracks: (1...6).map { number in
                let offsets = [150, 15363, 32314, 46592, 63414, 80489]
                let next = number < 6 ? offsets[number] : 95462
                return DiscTrack(number: number,
                                 startLBA: offsets[number - 1] - 150,
                                 sectorCount: next - offsets[number - 1],
                                 isData: false)
            })
        equal(reference.musicBrainzDiscID, "49HHV7Eb8UKF3aQiNmu1GR8vKTY-",
              "the disc ID matches the official worked example")

        guard let toc = DiscTOC(rawTOC: hexData(realTOC)) else { return }
        equal(toc.musicBrainzDiscID, "CObFGuFtiL4ToRbdSL_Q0bncOe8-",
              "disc ID of the test disc")
        equal(toc.freeDBID, "b40c4d0e", "FreeDB identifier of the test disc")
        check(toc.musicBrainzTOCParameter.hasPrefix("1+14+236368+150+"),
              "TOC parameter for the fallback search",
              detail: String(toc.musicBrainzTOCParameter.prefix(40)))
    }

    // MARK: - CD-TEXT

    static func cdTextParsing() {
        print("\n— CD-TEXT —")
        let url = URL(fileURLWithPath: "Scripts/bridge-test/fixtures/cdtext-peter-und-der-wolf.bin")
        guard let data = try? Data(contentsOf: url) else {
            check(false, "CD-TEXT fixture present")
            return
        }
        let text = CDText(packets: [UInt8](data))
        check(!text.isEmpty, "CD-TEXT can be parsed")
        equal(text.albumTitle, "Peter und der Wolf", "album title")
        equal(text.albumArtist, "Malte Arkona, Dresdner Philharmonie", "album artist")
        equal(text.albumComposer, "Sergej Prokofjew", "composer")
        equal(text.title(forTrack: 4), "Der Vogel", "title of the fourth track")

        // The reason for this check: the first attempt produced
        // "Der Gro�vater" here — CD-TEXT is Latin-1, not UTF-8.
        equal(text.title(forTrack: 7), "Der Großvater", "umlauts and ß arrive correctly")
        equal(text.title(forTrack: 13), "Ein vertontes Märchen", "umlaut in the title")
        equal(text.title(forTrack: 14), "Das hässliche junge Entlein", "ß in the title")
        equal(text.performer(forTrack: 12), "Peter Schreier, Walter Olberz",
              "a different artist on a single track")
        equal(text.performer(forTrack: 4), "Malte Arkona, Dresdner Philharmonie",
              "a track without an artist of its own inherits the album's")

        check(CDText(packets: []).isEmpty, "empty CD-TEXT stays empty")
        check(CDText(packets: [UInt8](repeating: 0, count: 17)).isEmpty,
              "a truncated pack does not tip it over")
    }

    // MARK: - Offset

    static func offsetArithmetic() {
        print("\n— Read offset —")
        // A drive with offset +6 delivers sample p+6 when asked for p.
        // Whoever wants it from `start` has to ask from `start−6`.
        let samplesPerSector = CDGeometry.samplesPerSector
        equal(samplesPerSector, 588, "samples per sector")
        equal(CDGeometry.bytesPerSector, 2352, "bytes per sector")
        equal(samplesPerSector * CDGeometry.bytesPerSample, CDGeometry.bytesPerSector,
              "the sector size divides into samples")

        let track = DiscTrack(number: 2, startLBA: 13851, sectorCount: 6412, isData: false)
        equal(track.endLBA, 20263, "end of track")
        equal(track.byteCount, 6412 * 2352, "byte count of the track")
        equal(Int(track.duration.components.seconds), 85, "playing time in seconds")

        for offset in [0, 6, -6, 667, -582] {
            let start = track.startLBA * samplesPerSector - offset
            let end = track.endLBA * samplesPerSector - offset
            equal(end - start, track.sectorCount * samplesPerSector,
                  "offset \(offset) does not change the length")
        }
    }

    // MARK: - Checksums

    static func checksums() {
        print("\n— Checksums —")
        // The usual test value for CRC-32.
        equal(CRC32.compute(Data("123456789".utf8)), 0xCBF4_3926,
              "CRC-32 over \"123456789\"")
        equal(CRC32.compute(Data()), 0, "CRC-32 over nothing")
        check(CRC32.compute(Data([1, 2, 3])) != CRC32.compute(Data([3, 2, 1])),
              "order goes into the checksum")
    }

    // MARK: - Image

    static func discImage() {
        print("\n— Disc image —")

        // An image is never computed in one piece: 550 MB in memory would be
        // wasteful. So the continued checksum has to match the one computed in
        // one go exactly — otherwise no figure in the log is right.
        let blob = Data((0..<50_000).map { UInt8(($0 &* 31 &+ 7) & 0xFF) })
        var running = CRC32.seed
        var offset = 0
        for size in [1, 2, 3, 7, 1024, 4096, 9999] {
            let end = min(offset + size, blob.count)
            guard offset < end else { break }
            running = CRC32.continue_(running, with: blob.subdata(in: offset..<end))
            offset = end
        }
        running = CRC32.continue_(running, with: blob.subdata(in: offset..<blob.count))
        equal(CRC32.finish(running), CRC32.compute(blob),
              "the piecewise checksum equals the one computed in one go")
        equal(CRC32.finish(CRC32.seed), CRC32.compute(Data()),
              "an empty stream gives the same checksum as nothing")

        // The file type in the cue sheet. If it says WAVE instead of BINARY,
        // the player looks for the track boundaries shifted by 44 bytes.
        equal(DiscImageFormat.bin.cueFileType, "BINARY", "BIN is BINARY")
        equal(DiscImageFormat.wav.cueFileType, "WAVE", "WAV is WAVE")
        equal(DiscImageFormat.flac.cueFileType, "WAVE", "FLAC counts as WAVE as well")
        check(!DiscImageFormat.bin.needsFFmpeg, "BIN works without ffmpeg")
        check(!DiscImageFormat.wav.needsFFmpeg, "WAV works without ffmpeg")
        check(DiscImageFormat.flac.needsFFmpeg, "FLAC needs ffmpeg")

        guard let toc = DiscTOC(rawTOC: hexData(realTOC)) else { return }
        let report = RipReport(drive: CDDriveInfo(bsdName: "disk9", vendor: "ASUS",
                                                 product: "BW-16D1X-U", revision: "A105"),
                               toc: toc, settings: RipSettings(), entries: [],
                               started: .now, ended: .now)

        let binCue = report.cueSheet(albumTitle: "Peter und der Wolf",
                                     albumArtist: "Malte Arkona",
                                     audioFileName: "album.bin", fileType: "BINARY",
                                     titles: [1: "Intro: Malte und Mezzo", 2: "Vorspiel"])
        check(binCue.contains("FILE \"album.bin\" BINARY"), "BIN image in the cue sheet")
        check(binCue.contains("    TITLE \"Intro: Malte und Mezzo\""),
              "track titles are in the cue sheet")
        check(binCue.contains("  TRACK 01 AUDIO\n    TITLE"),
              "the title follows right after the track line")
        equal(binCue.components(separatedBy: "INDEX 01").count - 1, 14,
              "fourteen track marks")
        check(binCue.contains("INDEX 01 00:00:00"), "the image starts at zero")
        check(binCue.contains("INDEX 01 03:04:51"), "start of the second track")

        let wavCue = report.cueSheet(albumTitle: nil, albumArtist: nil,
                                     audioFileName: "album.flac", fileType: "WAVE")
        check(wavCue.contains("FILE \"album.flac\" WAVE"), "FLAC image in the cue sheet")
        check(!wavCue.contains("PERFORMER"), "no artist, no empty line")
        check(!wavCue.contains("TITLE \"\""), "no title, no empty title line")

        // Quotes in the title would break the cue sheet apart.
        let tricky = report.cueSheet(albumTitle: "Say \"Hello\"", albumArtist: nil,
                                     audioFileName: "a.wav")
        check(!tricky.contains("\"Say \"Hello\"\""), "quotes are defused")
    }

    // MARK: - WAV and cue

    static func wavAndCue() {
        print("\n— WAV and cue sheet —")
        let pcm = Data(repeating: 0, count: 2352 * 10)
        let header = WAVWriter.header(forPCMByteCount: pcm.count)
        equal(header.count, 44, "the header is 44 bytes long")
        equal(String(decoding: header[0..<4], as: UTF8.self), "RIFF", "RIFF identifier")
        equal(String(decoding: header[8..<12], as: UTF8.self), "WAVE", "WAVE identifier")
        let declared = header[40..<44].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        equal(Int(UInt32(littleEndian: declared)), pcm.count, "data length in the header")

        equal(RipReport.msf(0), "00:00:00", "sector 0 as MSF")
        equal(RipReport.msf(75), "00:01:00", "one second")
        equal(RipReport.msf(13851), "03:04:51", "start of the second track as MSF")
    }

    // MARK: - On the real drive

    static func live() throws {
        print("\n— Drive —")
        guard let info = CDDriveFinder.availableDrives().first,
              let raw = info.rawTOC, let toc = DiscTOC(rawTOC: raw) else {
            print("  … skipped, no audio CD inserted")
            return
        }
        check(true, "drive found: \(info.displayName)")
        check(!info.vendor.isEmpty, "vendor read", detail: info.vendor)
        check(info.devicePath.hasPrefix("/dev/r"), "character device, not block device")

        let drive: CDDrive
        do {
            drive = try CDDrive(info: info)
        } catch {
            check(false, "device opens without special privileges", detail: "\(error)")
            return
        }
        check(true, "device opened without special privileges")

        if let speed = drive.currentSpeed() {
            check(speed > 0, "speed readable", detail: "\(speed) kB/s")
        }

        // Read raw and hold it against what macOS sees: the mounted CDDA file
        // system shows the same tracks as AIFC. If both match byte for byte,
        // the addressing is right.
        guard let track = toc.audioTracks.dropFirst(2).first else { return }
        let aiffURL = URL(fileURLWithPath:
            "/Volumes/Audio CD/\(track.number) Audio Track.aiff")
        guard let aiff = try? Data(contentsOf: aiffURL) else {
            print("  … comparison skipped, volume not mounted")
            return
        }

        // Comparing only the beginning is enough and does not take long.
        let sectors = 200
        let read = try drive.read(lba: track.startLBA, count: sectors, withC2: false)
        equal(read.audio.count, sectors * 2352, "raw reading delivers full sectors")

        // C2 cannot be taken for granted. When asked for payload *and* error
        // pointers, this drive sometimes reports success over the full buffer,
        // sometimes over only an eighth — and in neither case does the audio
        // part match an ordinary read. So the content comparison decides, not
        // the reported length.
        let hasC2 = drive.supportsC2(probeLBA: track.startLBA)
        check(drive.supportsC2(probeLBA: track.startLBA) == hasC2,
              "C2 capability is determined consistently",
              detail: hasC2 ? "drive delivers C2" : "drive delivers no C2")

        // A comparison piece from the middle of the track: large enough to
        // span several blocks, small enough for a quick test run.
        let sliceStart = track.startLBA + 100
        let sliceSectors = 400
        let aiffSlice = Data(aiff.dropFirst(2352 + 100 * 2352).prefix(sliceSectors * 2352))

        var settings = RipSettings()
        settings.mode = .secure
        settings.usesC2 = false
        settings.readOffset = 0
        let reader = CDReader(drive: drive, settings: settings)
        let piece = DiscTrack(number: 99, startLBA: sliceStart,
                              sectorCount: sliceSectors, isData: false)

        let ripped = try reader.rip(track: piece)
        equal(ripped.audio.count, sliceSectors * 2352, "secure mode delivers the full length")
        equal(ripped.audio, aiffSlice, "secure mode matches what macOS reads")
        check(ripped.suspiciousSectors.isEmpty, "no unresolved sectors",
              detail: "\(ripped.suspiciousSectors.count)")
        check(ripped.isAccurate, "rated as read cleanly")

        // The sharpest check of the offset correction: an offset of exactly
        // one sector has to give the same as a piece shifted by one sector. If
        // that holds, the arithmetic is right — not just the length.
        settings.readOffset = CDGeometry.samplesPerSector
        let shifted = try CDReader(drive: drive, settings: settings).rip(track: piece)
        let expectedShift = try drive.read(lba: sliceStart - 1, count: sliceSectors, withC2: false)
        equal(shifted.audio, expectedShift.audio,
              "an offset of one whole sector shifts the window correctly")
        check(shifted.audio != ripped.audio, "the shifted window really is different audio")

        // And an odd offset: 6 samples are 24 bytes.
        settings.readOffset = 6
        let odd = try CDReader(drive: drive, settings: settings).rip(track: piece)
        let wide = try drive.read(lba: sliceStart - 1, count: sliceSectors + 1, withC2: false)
        let expectedOdd = wide.audio.subdata(
            in: (2352 - 24)..<(2352 - 24 + sliceSectors * 2352))
        equal(odd.audio, expectedOdd, "an offset of 6 samples is exact to the byte")

        // Burst has to deliver the same as secure as long as the disc is clean.
        settings.readOffset = 0
        settings.mode = .burst
        let burst = try CDReader(drive: drive, settings: settings).rip(track: piece)
        equal(burst.audio, ripped.audio, "burst and secure agree on a clean disc")
        equal(burst.crc, ripped.crc, "same checksum")

        // Second pass: the same pass twice, the checksums have to match.
        settings.mode = .secure
        settings.testBeforeCopy = true
        let verified = try CDReader(drive: drive, settings: settings).rip(track: piece)
        equal(verified.verificationCRC, verified.crc, "the second pass confirms itself")
        equal(verified.crc, ripped.crc, "and agrees with the single pass")

        // Write the WAV and read it back.
        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sleeve-rip-test.wav")
        try WAVWriter.write(pcm: ripped.audio, to: wavURL)
        defer { try? FileManager.default.removeItem(at: wavURL) }
        let written = try Data(contentsOf: wavURL)
        equal(written.count, 44 + ripped.audio.count, "the WAV file has the expected size")
        equal(Data(written.dropFirst(44)), ripped.audio, "PCM arrives in the file unchanged")

        // Streaming has to give byte for byte the same as the route over a
        // whole track — otherwise an image would be something else than a rip.
        for offset in [0, 6, -6, 588] {
            var streaming = RipSettings()
            streaming.mode = .burst
            streaming.readOffset = offset
            let reader = CDReader(drive: drive, settings: streaming)

            var streamed = Data()
            let summary = try reader.readContiguous(
                fromSector: sliceStart, toSector: sliceStart + 120) { streamed.append($0) }

            let piece = DiscTrack(number: 98, startLBA: sliceStart,
                                  sectorCount: 120, isData: false)
            let whole = try CDReader(drive: drive, settings: streaming).rip(track: piece)
            equal(streamed, whole.audio,
                  "stream and track agree, offset \(offset)")
            equal(summary.finishedCRC, whole.crc,
                  "same checksum, offset \(offset)")
        }
        equal(try CDReader(drive: drive, settings: {
            var s = RipSettings(); s.mode = .burst; return s
        }()).readContiguous(fromSector: sliceStart, toSector: sliceStart + 120) { _ in }
            .suspiciousSectors.count, 0, "no unresolved sectors while streaming")

        try engineEndToEnd(toc: toc, track: track, aiff: aiff)

        if let mcn = drive.readMCN() {
            check(mcn.allSatisfy(\.isNumber), "the MCN consists of digits", detail: mcn)
        }
        // ISRCs are read as a set and discarded as a set as soon as a value
        // appears twice — this drive's known bug gives a track its
        // predecessor's code. So the check is not "does something come back"
        // but "is what came back consistent in itself".
        let isrcs = drive.readISRCs(for: toc.tracks)
        if isrcs.isEmpty {
            check(true, "ISRCs discarded because they cannot be read reliably")
        } else {
            equal(Set(isrcs.values).count, isrcs.count,
                  "no value twice — otherwise the set would have been discarded")
            check(isrcs.values.allSatisfy { $0.count == 12 },
                  "every delivered ISRC is twelve characters long")
            check(isrcs.keys.allSatisfy { number in
                toc.tracks.contains { $0.number == number && !$0.isData }
            }, "ISRCs belong to audio tracks")
        }

        if let text = drive.readCDText() {
            check(!text.isEmpty, "CD-TEXT read from the disc",
                  detail: text.albumTitle ?? "")
        }
    }
}
