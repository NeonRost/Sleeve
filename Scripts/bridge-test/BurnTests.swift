//
//  BurnTests.swift
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
//  Burning back (§6.10). The burn itself needs a blank and was verified by
//  hand (§6.10.1). What can be tested without one is the riskier part: the
//  producer's address arithmetic, the track layout and parsing the cue
//  sheet. An error of one sector produces a disc on which every track starts
//  shifted, and one only notices when listening.
//

import DiscRecording
import Foundation

enum BurnTests {

    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var checks = 0

    static func check(_ condition: Bool, _ label: String, detail: @autoclosure () -> String = "") {
        checks += 1
        if condition { print("  ✓ \(label)") }
        else {
            failures += 1
            let extra = detail()
            print("  ✗ \(label)\(extra.isEmpty ? "" : " — \(extra)")")
        }
    }

    static func equal<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
        check(actual == expected, label, detail: "is \(actual), expected \(expected)")
    }

    static func run() throws -> Int32 {
        cueParsing()
        try producerArithmetic()
        trackLayout()
        try copyLayout()
        mediaNames()
        liveDevice()

        print("\n  \(checks) checks, \(failures) failures")
        return failures == 0 ? 0 : 1
    }

    // MARK: - Reading a cue sheet

    static func cueParsing() {
        print("\n— Parsing a cue sheet —")

        // The best test is the round trip: write, read, compare.
        guard let toc = DiscTOC(rawTOC: RipTests.hexData(RipTests.realTOC)) else {
            check(false, "TOC available"); return
        }
        let report = RipReport(drive: CDDriveInfo(bsdName: "disk9", vendor: "ASUS",
                                                 product: "BW-16D1X-U", revision: "A105"),
                               toc: toc, settings: RipSettings(), entries: [],
                               started: .now, ended: .now)
        let text = report.cueSheet(albumTitle: "Peter und der Wolf",
                                   albumArtist: "Malte Arkona, Dresdner Philharmonie",
                                   audioFileName: "Peter und der Wolf.bin",
                                   fileType: "BINARY",
                                   titles: [1: "Intro: Malte und Mezzo", 7: "Der Großvater"])

        guard let cue = CueSheet(text: text) else {
            check(false, "our own cue sheet can be read back"); return
        }
        check(true, "our own cue sheet can be read back")
        equal(cue.audioFileName, "Peter und der Wolf.bin", "file name with spaces")
        equal(cue.fileType, "BINARY", "file type")
        equal(cue.albumTitle, "Peter und der Wolf", "album title")
        equal(cue.albumPerformer, "Malte Arkona, Dresdner Philharmonie", "album artist")
        equal(cue.tracks.count, 14, "fourteen tracks")
        equal(cue.tracks[0].title, "Intro: Malte und Mezzo", "track title")
        equal(cue.tracks[6].title, "Der Großvater", "umlaut in the track title")
        check(cue.tracks[1].title == nil, "a track without a title stays without")

        // The decisive part: the start sectors have to match the TOC exactly.
        for track in toc.audioTracks {
            guard let parsed = cue.tracks.first(where: { $0.number == track.number }) else {
                check(false, "track \(track.number) in the cue sheet"); continue
            }
            equal(parsed.startLBA, track.startLBA, "start sector of track \(track.number)")
        }

        let counts = cue.sectorCounts(totalSectors: toc.leadOutLBA)
        for track in toc.audioTracks {
            equal(counts[track.number], track.sectorCount, "length of track \(track.number)")
        }

        print("\n— Cue sheet: edge cases —")
        equal(CueSheet.lba(fromMSF: "00:00:00"), 0, "MSF zero")
        equal(CueSheet.lba(fromMSF: "03:04:51"), 13851, "MSF of the second track")
        equal(CueSheet.lba(fromMSF: "40:37:21"), 182796, "MSF of the last track")
        check(CueSheet.lba(fromMSF: "00:60:00") == nil, "there are no 60 seconds")
        check(CueSheet.lba(fromMSF: "00:00:75") == nil, "there are no 75 frames")
        check(CueSheet.lba(fromMSF: "broken") == nil, "nonsense is rejected")
        check(CueSheet(text: "") == nil, "an empty cue sheet is rejected")
        check(CueSheet(text: "FILE \"a.bin\" BINARY") == nil, "a cue without tracks is rejected")

        // INDEX 00 marks the pause and must not move the start.
        let withPregap = CueSheet(text: """
        FILE "x.wav" WAVE
          TRACK 01 AUDIO
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            INDEX 00 03:02:00
            INDEX 01 03:04:51
        """)
        equal(withPregap?.tracks.count, 2, "two tracks despite INDEX 00")
        equal(withPregap?.tracks[1].startLBA, 13851, "INDEX 00 does not move the start")

        // Data tracks do not belong on an audio CD.
        let mixed = CueSheet(text: """
        FILE "x.bin" BINARY
          TRACK 01 AUDIO
            INDEX 01 00:00:00
          TRACK 02 MODE1/2352
            INDEX 01 05:00:00
        """)
        equal(mixed?.tracks.count, 1, "data track is skipped")
    }

    // MARK: - The address arithmetic

    static func producerArithmetic() throws {
        print("\n— Producer: which bytes at which address —")

        // An image of recognizable sectors: sector N is filled with N.
        let sectors = 40
        var image = Data()
        for index in 0..<sectors {
            image.append(Data(repeating: UInt8(index), count: CDGeometry.bytesPerSector))
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sleeve-burn-\(UUID().uuidString).bin")
        try image.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        // BIN: no header. Track 2 starts at sector 10.
        let bin = ImageTrackProducer(url: url, headerBytes: 0, startSector: 10, sectorCount: 12)
        // The address counts bytes from the start of the track — measured on
        // the first blank, contrary to how Apple's header reads.
        equal(bin.byteOffset(forAddress: 0), 10 * 2352, "address 0 points to the start of the track")
        equal(bin.byteOffset(forAddress: 2352), 11 * 2352, "address 2352 is one sector further")
        equal(bin.byteOffset(forAddress: 11 * 2352), 21 * 2352, "last sector of the track")
        equal(bin.remainingBytes(fromAddress: 11 * 2352), 2352, "one sector left at the last one")
        equal(bin.remainingBytes(fromAddress: 12 * 2352), 0, "nothing left past the end of the track")

        // WAV: 44 bytes of header, everything shifts.
        let wav = ImageTrackProducer(url: url, headerBytes: 44, startSector: 10, sectorCount: 12)
        equal(wav.byteOffset(forAddress: 0), 44 + 10 * 2352, "the WAV header is skipped")
        equal(wav.byteOffset(forAddress: 5 * 2352), 44 + 15 * 2352, "and stays skipped")

        // And now really read: do the bytes come out that are stored there?
        _ = bin.prepare(nil, for: nil, toMedia: nil)
        defer { bin.cleanupTrack(afterBurn: nil) }

        let blocks = 3
        var buffer = [CChar](repeating: 0, count: 2352 * blocks)
        let produced = buffer.withUnsafeMutableBufferPointer { raw -> UInt32 in
            var flags: UInt32 = 0
            return bin.produceData(for: nil, intoBuffer: raw.baseAddress,
                                   length: UInt32(raw.count), atAddress: 0,
                                   blockSize: 2352, ioFlags: &flags)
        }
        equal(Int(produced), 2352 * blocks, "full buffer delivered")
        let bytes = buffer.map { UInt8(bitPattern: $0) }
        equal(bytes[0], 10, "the first sector of the track is sector 10")
        equal(bytes[2352], 11, "then sector 11")
        equal(bytes[2 * 2352], 12, "then sector 12")
        check(bytes[0..<2352].allSatisfy { $0 == 10 }, "the whole first sector is right")

        // From the fifth sector of the track on, sector 15 has to come.
        let second = buffer.withUnsafeMutableBufferPointer { raw -> UInt32 in
            var flags: UInt32 = 0
            return bin.produceData(for: nil, intoBuffer: raw.baseAddress,
                                   length: 2352, atAddress: 5 * 2352,
                                   blockSize: 2352, ioFlags: &flags)
        }
        equal(Int(second), 2352, "one sector delivered")
        equal(UInt8(bitPattern: buffer[0]), 15, "sector 5 of the track is sector 15")

        // A request reaching past the end of the track stops at its end —
        // otherwise the next track's audio would be written twice.
        var longBuffer = [CChar](repeating: 0, count: 2352 * 4)
        let clipped = longBuffer.withUnsafeMutableBufferPointer { raw -> UInt32 in
            var flags: UInt32 = 0
            return bin.produceData(for: nil, intoBuffer: raw.baseAddress,
                                   length: UInt32(raw.count), atAddress: 10 * 2352,
                                   blockSize: 2352, ioFlags: &flags)
        }
        equal(Int(clipped), 2 * 2352, "only the two sectors left in the track")
        equal(UInt8(bitPattern: longBuffer[2352]), 21, "the last one is sector 21, not 22")

        // At the end of the file nothing random may come out.
        let tail = ImageTrackProducer(url: url, headerBytes: 0, startSector: 38, sectorCount: 2)
        _ = tail.prepare(nil, for: nil, toMedia: nil)
        var tailBuffer = [CChar](repeating: 0x7F, count: 2352 * 4)
        let tailProduced = tailBuffer.withUnsafeMutableBufferPointer { raw -> UInt32 in
            var flags: UInt32 = 0
            return tail.produceData(for: nil, intoBuffer: raw.baseAddress,
                                    length: UInt32(raw.count), atAddress: 0,
                                    blockSize: 2352, ioFlags: &flags)
        }
        equal(Int(tailProduced), 2352 * 2, "nothing is invented beyond the end of the file")
        tail.cleanupTrack(afterBurn: nil)
    }

    // MARK: - Track layout

    static func trackLayout() {
        print("\n— Track layout —")
        guard let toc = DiscTOC(rawTOC: RipTests.hexData(RipTests.realTOC)) else { return }
        let tracks = toc.audioTracks.map {
            CueSheet.Track(number: $0.number, startLBA: $0.startLBA)
        }
        var counts: [Int: Int] = [:]
        for track in toc.audioTracks { counts[track.number] = track.sectorCount }

        let layout = CDBurner.Layout(imageURL: URL(fileURLWithPath: "/tmp/none.bin"),
                                     headerBytes: 0, tracks: tracks, sectorCounts: counts)
        equal(layout.totalSectors, toc.leadOutLBA, "track lengths add up to the whole disc")

        let drTracks = CDBurner.makeTracks(layout)
        equal(drTracks.count, 14, "fourteen DRTracks")

        // `frames()` is the frame *component* of a time value (0–74), not the
        // total — that is what `sectors()` is for. The first attempt used
        // `frames()` here, and the sum over fourteen tracks came to 493
        // instead of 236218. The check found the mistake before it could make
        // its way into the burner code.
        var total = 0
        for (index, drTrack) in drTracks.enumerated() {
            guard let length = drTrack.properties()[DRTrackLengthKey] as? DRMSF else {
                check(false, "length on track \(index + 1)"); continue
            }
            total += Int(length.sectors())
        }
        equal(total, toc.leadOutLBA, "the sum of the DRTrack lengths matches the TOC")

        if let first = drTracks.first?.properties() {
            equal(first[DRBlockSizeKey] as? Int, Int(kDRBlockSizeAudio),
                  "block size is 2352 — the same as for reading")
            equal(first[DRTrackModeKey] as? Int, Int(kDRTrackModeAudio), "audio track")
            if let pregap = first[DRPreGapLengthKey] as? DRMSF {
                equal(Int(pregap.sectors()), 150, "track 1 gets the usual pause")
            }
        }
        if drTracks.count > 1, let second = drTracks[1].properties(),
           let pregap = second[DRPreGapLengthKey] as? DRMSF {
            equal(Int(pregap.sectors()), 0,
                  "no extra pause between the tracks — it is in the image")
        }

        // A track of length zero must not come about.
        var broken = counts
        broken[5] = 0
        let filtered = CDBurner.makeTracks(CDBurner.Layout(
            imageURL: URL(fileURLWithPath: "/tmp/none.bin"),
            headerBytes: 0, tracks: tracks, sectorCounts: broken))
        equal(filtered.count, 13, "a track without length is left out")
    }

    // MARK: - On the real drive

    /// The mapping media type → name, regardless of what is currently in
    /// the drive.
    static func mediaNames() {
        print("\n— Naming the media —")
        equal(CDBurner.mediaName(kDRDeviceMediaTypeCDR as String), "CD-R", "CD-R")
        equal(CDBurner.mediaName(kDRDeviceMediaTypeCDRW as String), "CD-RW", "CD-RW")
        equal(CDBurner.mediaName(kDRDeviceMediaTypeCDROM as String), "CD-ROM", "CD-ROM")
        equal(CDBurner.mediaName(kDRDeviceMediaTypeDVDR as String), "DVD-R", "DVD-R")
        equal(CDBurner.mediaName(kDRDeviceMediaTypeDVDPlusR as String), "DVD+R", "DVD+R")
        equal(CDBurner.mediaName(kDRDeviceMediaTypeBDR as String), "BD-R", "BD-R")
        check(!CDBurner.mediaName("whatever").isEmpty,
              "something unknown still gets a name")

        // The case that occurs in practice: an empty blank, only of the wrong
        // type. The message has to name the type — "no writable blank" would
        // be confusing with 4.38 GiB of free space.
        check(CDBurner.mediaName(kDRDeviceMediaTypeDVDR as String) != "CD-R",
              "a DVD-R is not taken for a CD-R")
    }

    static func liveDevice() {
        print("\n— Drive and medium —")
        guard let device = CDBurner.device(id: nil) else {
            print("  … skipped, no optical drive")
            return
        }
        let info = CDBurner.info(of: device)
        check(!info.displayName.isEmpty, "drive found", detail: info.displayName)

        // The difference nobody would think up: according to Apple's header,
        // "Unsupported" means "will be tried anyway"; only "None" means "does
        // not work".
        check(info.isUsable, "drive is usable", detail: info.supportLevel)

        let state = CDBurner.mediaState(of: device)
        switch state {
        case .blank(let sectors):
            check(sectors > 0, "blank recognized", detail: "\(sectors) sectors free")
        case .unusable(let reason):
            check(true, "the inserted disc is recognized as not burnable")
            print("      → \"\(reason)\"")
            check(!CDBurner.describe(state).isEmpty, "with an understandable reason")
        case .noDisc:
            check(true, "an empty drive is recognized")
        case .noDrive:
            check(false, "drive disappeared")
        }
        check(!state.isReady || { if case .blank = state { true } else { false } }(),
              "only a blank counts as ready")

        // Several drives (§6.12): the burner is found by its registry path,
        // and a vanished pick does not fall back to another drive.
        equal(CDBurner.device(id: info.id).map(CDBurner.info)?.id, info.id,
              "the burner is found again by its id")
        check(CDBurner.device(id: "IOService:/gone") == nil,
              "a drive that has gone is not replaced by another")
        if let disc = CDDriveFinder.availableDrives().first {
            check(CDBurner.isDrive(of: disc.bsdName, burner: info.id),
                  "the disc sits in that very burner", detail: disc.bsdName)
        }
    }

    // MARK: - Layout for a copy

    /// "Copy CD" burns what it has just read (§6.11): the layout comes
    /// straight from the BIN image and its cue sheet.
    static func copyLayout() throws {
        print("\n— Layout for a copy —")
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("sleeve-copy-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        try Data(count: 500 * 2352).write(to: folder.appendingPathComponent("disc.bin"))
        let cue = """
            FILE "disc.bin" BINARY
              TRACK 01 AUDIO
                INDEX 01 00:00:00
              TRACK 02 AUDIO
                INDEX 01 00:02:00
            """
        let cueURL = folder.appendingPathComponent("disc.cue")
        try cue.write(to: cueURL, atomically: true, encoding: .utf8)

        guard let layout = CDBurner.layout(cueURL: cueURL) else {
            check(false, "layout from the cue sheet")
            return
        }
        equal(layout.headerBytes, 0, "BIN has no header")
        equal(layout.tracks.count, 2, "two tracks")
        equal(layout.sectorCounts[1], 150, "track 1 up to 00:02:00")
        equal(layout.sectorCounts[2], 350, "track 2 up to the end of the image")
        equal(layout.totalSectors, 500, "all sectors of the image")

        let flac = folder.appendingPathComponent("flac.cue")
        try cue.replacingOccurrences(of: "disc.bin\" BINARY", with: "disc.flac\" WAVE")
            .write(to: flac, atomically: true, encoding: .utf8)
        check(CDBurner.layout(cueURL: flac) == nil, "FLAC is not taken without unpacking")
    }
}
