//
//  CDBurner.swift
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
//  Writing an image back onto a CD-R (spec §6.10).
//
//  Verified on one drive: a burned CD read back byte for byte identical to
//  the image it came from (spec §6.10.1). The first test run on a blank
//  found the one mistake the tests without a drive could not — what
//  `address` counts.
//
//  Via DiscRecording, without a third-party library. The numbers fit
//  without conversion: `kDRBlockSizeAudio` is 2352, exactly the sector size
//  used for reading as well.
//

import DiscRecording
import Foundation

enum BurnMediaState: Equatable, Sendable {
    case noDrive
    case noDisc
    /// A disc is inserted but unsuitable — already written, or not a CD-R
    /// at all.
    case unusable(reason: String)
    case blank(sectors: Int)

    var isReady: Bool { if case .blank = self { true } else { false } }
}

struct BurnDeviceInfo: Equatable, Sendable, Identifiable {
    /// The IORegistry path: stays the same while the drive is connected,
    /// with or without a disc.
    var id: String
    var vendor: String
    var product: String
    /// Apple distinguishes "unsupported, but will be tried" from "cannot be
    /// used". Only the latter is an obstacle.
    var supportLevel: String
    var isUsable: Bool

    var displayName: String {
        [vendor, product].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

// MARK: - Inspection

enum CDBurner {

    /// Every drive that can write a CD, in the order macOS lists them.
    static func devices() -> [DRDevice] {
        DRDevice.devices().compactMap { $0 as? DRDevice }.filter { $0.writesCD() }
    }

    /// The picked drive, or without a pick the first one. A picked drive
    /// that has gone gives `nil` — never quietly another drive.
    static func device(id: String?) -> DRDevice? {
        guard let id else { return devices().first }
        return devices().first { $0.ioRegistryEntryPath() == id }
    }

    /// Whether the disc with this BSD name sits in that burner — then a copy
    /// has to swap discs in between. `deviceForBSDName` takes the name of
    /// the medium (`disk4`) and returns the drive it is in; measured.
    static func isDrive(of bsdName: String, burner id: String?) -> Bool {
        guard let reader = DRDevice(forBSDName: bsdName),
              let burner = device(id: id) else { return false }
        return reader.isEqual(to: burner)
    }

    /// Unmounts and opens the tray of the drive the disc is in. `false` for a
    /// drive DiscRecording does not know — a pure reader.
    @discardableResult
    static func eject(bsdName: String) -> Bool {
        DRDevice(forBSDName: bsdName)?.ejectMedia() ?? false
    }

    static func info(of device: DRDevice) -> BurnDeviceInfo {
        let info = device.info() ?? [:]
        let level = (info[DRDeviceSupportLevelKey] as? String) ?? ""
        return BurnDeviceInfo(
            id: device.ioRegistryEntryPath() ?? device.displayName() ?? "",
            vendor: (info[DRDeviceVendorNameKey] as? String) ?? "",
            product: (info[DRDeviceProductNameKey] as? String) ?? "",
            supportLevel: level,
            // According to Apple's header, `…LevelNone` explicitly means "cannot
            // be used"; `…LevelUnsupported`, on the other hand, "will try to use
            // it anyway".
            isUsable: level != (kDRDeviceSupportLevelNone as String))
    }

    static func mediaState(of device: DRDevice?) -> BurnMediaState {
        guard let device else { return .noDrive }
        let status = device.status() ?? [:]

        guard let state = status[DRDeviceMediaStateKey] as? String,
              state == (kDRDeviceMediaStateMediaPresent as String) else {
            return .noDisc
        }
        guard let media = status[DRDeviceMediaInfoKey] as? [AnyHashable: Any] else {
            return .unusable(reason: String(localized: "The disc could not be read."))
        }

        let type = (media[DRDeviceMediaTypeKey] as? String) ?? ""
        let isBlank = (media[DRDeviceMediaIsBlankKey] as? Bool) ?? false
        let writable = type == (kDRDeviceMediaTypeCDR as String)
            || type == (kDRDeviceMediaTypeCDRW as String)

        guard writable else {
            // Name the type. "No writable blank" is plainly confusing with an
            // empty DVD-R inserted — it *is* writable, just not for an
            // audio CD.
            let name = Self.mediaName(type)
            return .unusable(reason: isBlank
                ? String(localized: "This is a \(name). An audio CD needs a CD-R or CD-RW.")
                : String(localized: "This is a \(name), not a blank CD-R."))
        }
        guard isBlank else {
            return .unusable(reason: String(localized: "This disc already carries data."))
        }

        let free = (media[DRDeviceMediaBlocksFreeKey] as? Int) ?? 0
        return .blank(sectors: free)
    }
}

// MARK: - Supplying data

/// Supplies the bytes of one track from the image while burning.
///
/// The most delicate spot of the whole process: an error of one sector
/// produces a disc on which every track starts shifted — and one only
/// notices when listening. That is why the computation here is a pure
/// function (`byteOffset(forAddress:)`) and tested as such, even without
/// a drive.
///
/// `address` is relative to the start of the track and counts **bytes**,
/// not sectors. Apple's header calls it "the sector address on the disc from
/// the start of the track", which reads like a sector number — the first test
/// run on a blank showed otherwise: the calls come at 0, 129360, 258720,
/// steps of exactly 55 sectors. Taking it for a sector number read far
/// beyond the end of the image and failed the burn (spec §6.10.1).
///
/// Not `Sendable`: the callbacks arrive on the burn thread, but always one
/// after the other and only for this one track. Only `CDBurner.burn` ever
/// holds the object.
final class ImageTrackProducer: NSObject, DRTrackDataProduction {

    /// Start of the track in the image file, in bytes — already includes a
    /// file header, if any.
    let baseOffset: Int
    let sectorCount: Int
    private let url: URL
    private var handle: FileHandle?

    init(url: URL, headerBytes: Int, startSector: Int, sectorCount: Int) {
        self.url = url
        self.baseOffset = headerBytes + startSector * CDGeometry.bytesPerSector
        self.sectorCount = sectorCount
    }

    /// Pure computation, so that it can be tested without a burner.
    func byteOffset(forAddress address: UInt64) -> Int {
        baseOffset + Int(address)
    }

    /// Bytes of the track from `address` to its end.
    func remainingBytes(fromAddress address: UInt64) -> Int {
        max(0, sectorCount * CDGeometry.bytesPerSector - Int(address))
    }

    // MARK: DRTrackDataProduction

    func estimateLength(of track: DRTrack!) -> UInt64 { UInt64(sectorCount) }

    func prepare(_ track: DRTrack!, for burn: DRBurn!, toMedia mediaInfo: [AnyHashable: Any]!) -> Bool {
        handle = try? FileHandle(forReadingFrom: url)
        #if DEBUG
        BurnTrace.write("prepare start=\(baseOffset / CDGeometry.bytesPerSector) count=\(sectorCount) ok=\(handle != nil)")
        #endif
        return handle != nil
    }

    func cleanupTrack(afterBurn track: DRTrack!) {
        try? handle?.close()
        handle = nil
    }

    func produceData(for track: DRTrack!, intoBuffer buffer: UnsafeMutablePointer<CChar>!,
                     length bufferLength: UInt32, atAddress address: UInt64,
                     blockSize: UInt32, ioFlags flags: UnsafeMutablePointer<UInt32>!) -> UInt32 {
        let produced = fill(buffer, length: bufferLength, address: address, blockSize: blockSize)
        #if DEBUG
        trace(produced, length: bufferLength, address: address, blockSize: blockSize)
        #endif
        return produced
    }

    private func fill(_ buffer: UnsafeMutablePointer<CChar>, length bufferLength: UInt32,
                      address: UInt64, blockSize: UInt32) -> UInt32 {
        // Never past the end of the track: that would be the next track's
        // audio.
        let wanted = min(Int(bufferLength), remainingBytes(fromAddress: address))
        guard let handle, wanted > 0 else { return 0 }
        do {
            try handle.seek(toOffset: UInt64(byteOffset(forAddress: address)))
            guard let data = try handle.read(upToCount: wanted), !data.isEmpty else { return 0 }
            data.withUnsafeBytes { raw in
                buffer.withMemoryRebound(to: UInt8.self, capacity: data.count) { target in
                    target.update(from: raw.bindMemory(to: UInt8.self).baseAddress!,
                                  count: data.count)
                }
            }
            // At the end of the file, pad with silence to a multiple of the
            // block size — the drive does not take half sectors.
            if data.count < Int(bufferLength) {
                let padding = Int(bufferLength) - data.count
                let rounded = (data.count + Int(blockSize) - 1) / Int(blockSize) * Int(blockSize)
                guard rounded > data.count else { return UInt32(data.count) }
                memset(buffer + data.count, 0, min(padding, rounded - data.count))
                return UInt32(rounded)
            }
            return UInt32(data.count)
        } catch {
            return 0
        }
    }

    /// The pause before track 1 is silence. Returning 0 bytes here would tell
    /// the engine that the producer has nothing to deliver — the buffer has
    /// to be filled.
    func producePreGap(for track: DRTrack!, intoBuffer buffer: UnsafeMutablePointer<CChar>!,
                       length bufferLength: UInt32, atAddress address: UInt64,
                       blockSize: UInt32, ioFlags flags: UnsafeMutablePointer<UInt32>!) -> UInt32 {
        memset(buffer, 0, Int(bufferLength))
        #if DEBUG
        BurnTrace.write("pregap start=\(baseOffset / CDGeometry.bytesPerSector) address=\(address) length=\(bufferLength)")
        #endif
        return bufferLength
    }

    #if DEBUG
    private var traced = 0

    /// The first calls per track, and every call that delivers less than
    /// asked — that is where a production error comes from.
    private func trace(_ produced: UInt32, length: UInt32, address: UInt64, blockSize: UInt32) {
        traced += 1
        guard traced <= 3 || produced < length else { return }
        BurnTrace.write("data start=\(baseOffset / CDGeometry.bytesPerSector) count=\(sectorCount) "
            + "address=\(address) length=\(length) block=\(blockSize) produced=\(produced)")
    }
    #endif

    // The remaining requirements of the interface. We leave verification
    // after burning to the system (`kDRBurnVerifyDiscKey`), hence no logic
    // of our own here.
    func prepareTrack(forVerification track: DRTrack!) -> Bool { true }
    func verifyPreGap(for track: DRTrack!, inBuffer buffer: UnsafePointer<CChar>!,
                      length bufferLength: UInt32, atAddress address: UInt64,
                      blockSize: UInt32, ioFlags flags: UnsafeMutablePointer<UInt32>!) -> Bool { true }
    func verifyData(for track: DRTrack!, inBuffer buffer: UnsafePointer<CChar>!,
                    length bufferLength: UInt32, atAddress address: UInt64,
                    blockSize: UInt32, ioFlags flags: UnsafeMutablePointer<UInt32>!) -> Bool { true }
    func cleanupTrack(afterVerification track: DRTrack!) -> Bool { true }
}

// MARK: - Burning

extension CDBurner {

    enum BurnEvent: Sendable {
        case progress(Double)
        case finished(wasSimulated: Bool)
        case failed(String)
    }

    struct Layout: Sendable {
        var imageURL: URL
        /// How many bytes precede the audio data — 0 for BIN, 44 for WAV.
        var headerBytes: Int
        var tracks: [CueSheet.Track]
        var sectorCounts: [Int: Int]

        var totalSectors: Int { sectorCounts.values.reduce(0, +) }
    }

    /// A layout straight from a BIN or WAV image and its cue sheet — for a
    /// copy, where Sleeve wrote both itself a moment earlier. FLAC has to
    /// be unpacked first and is not taken here.
    static func layout(cueURL: URL) -> Layout? {
        guard let text = try? String(contentsOf: cueURL, encoding: .utf8),
              let cue = CueSheet(text: text) else { return nil }
        let audioURL = cueURL.deletingLastPathComponent().appendingPathComponent(cue.audioFileName)
        let header: Int
        switch audioURL.pathExtension.lowercased() {
        case "bin": header = 0
        case "wav": header = 44
        default:    return nil
        }
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: audioURL.path(percentEncoded: false))
        guard let size = attributes?[.size] as? Int, size > header else { return nil }
        let total = (size - header) / CDGeometry.bytesPerSector
        return Layout(imageURL: audioURL, headerBytes: header, tracks: cue.tracks,
                      sectorCounts: cue.sectorCounts(totalSectors: total))
    }

    /// Builds the track list without burning. Testable without a drive, hence
    /// separate from the actual process.
    static func makeTracks(_ layout: Layout) -> [DRTrack] {
        layout.tracks.compactMap { track in
            guard let count = layout.sectorCounts[track.number], count > 0 else { return nil }
            let producer = ImageTrackProducer(url: layout.imageURL,
                                              headerBytes: layout.headerBytes,
                                              startSector: track.startLBA,
                                              sectorCount: count)
            guard let drTrack = DRTrack(producer: producer) else { return nil }
            drTrack.setProperties([
                DRTrackLengthKey: DRMSF(frames: UInt32(count)) as Any,
                DRBlockSizeKey: NSNumber(value: kDRBlockSizeAudio),
                DRBlockTypeKey: NSNumber(value: kDRBlockTypeAudio),
                DRDataFormKey: NSNumber(value: kDRDataFormAudio),
                DRTrackModeKey: NSNumber(value: kDRTrackModeAudio),
                DRSessionFormatKey: NSNumber(value: kDRSessionFormatAudio),
                // The system adds the pause before track 1; between the tracks
                // there must be none, the image already carries them.
                DRPreGapLengthKey: DRMSF(frames: track.number == 1 ? 150 : 0) as Any,
            ])
            return drTrack
        }
    }

    /// Writes the image onto the inserted blank.
    ///
    /// `simulated` keeps the laser off: the whole process runs through,
    /// nothing is written, the blank stays unwritten. That is the way to check
    /// everything except the last step.
    static func burn(_ layout: Layout, simulated: Bool,
                     deviceID: String?) -> AsyncStream<BurnEvent> {
        AsyncStream { continuation in
            let task = Task.detached {
                guard let device = CDBurner.device(id: deviceID) else {
                    continuation.yield(.failed(String(localized: "No optical drive found.")))
                    continuation.finish()
                    return
                }
                guard info(of: device).isUsable else {
                    continuation.yield(.failed(String(localized: "macOS cannot use this drive for burning.")))
                    continuation.finish()
                    return
                }
                let media = mediaState(of: device)
                guard case .blank = media else {
                    continuation.yield(.failed(Self.describe(media)))
                    continuation.finish()
                    return
                }

                let tracks = makeTracks(layout)
                guard !tracks.isEmpty else {
                    continuation.yield(.failed(String(localized: "The image has no audio tracks.")))
                    continuation.finish()
                    return
                }

                let burn = DRBurn(device: device)!
                burn.setProperties([
                    DRBurnTestingKey: NSNumber(value: simulated),
                    // Gapless: all tracks in one pass, disc closed.
                    DRBurnStrategyKey: kDRBurnStrategyCDSAO as String,
                    DRBurnAppendableKey: NSNumber(value: false),
                    DRBurnCompletionActionKey: kDRBurnCompletionActionEject as String,
                    DRBurnVerifyDiscKey: NSNumber(value: !simulated),
                ])
                #if DEBUG
                BurnTrace.start(simulated: simulated, tracks: layout.tracks.count)
                #endif
                burn.writeLayout(tracks)

                // Instead of intercepting notifications the state is polled —
                // less flexible, and progress only comes coarsely anyway.
                while !Task.isCancelled {
                    let status = burn.status() ?? [:]
                    let state = (status[DRStatusStateKey] as? String) ?? ""
                    // -1 while the engine cannot tell yet (preparing, closing).
                    if let fraction = status[DRStatusPercentCompleteKey] as? Double, fraction >= 0 {
                        continuation.yield(.progress(min(fraction, 1)))
                    }
                    if state == (kDRStatusStateDone as String) {
                        if let error = status[DRErrorStatusKey] as? [AnyHashable: Any],
                           let code = error[DRErrorStatusErrorKey] as? Int, code != 0 {
                            let text = (error[DRErrorStatusErrorStringKey] as? String)
                                ?? String(localized: "The burn failed.")
                            continuation.yield(.failed(text))
                        } else {
                            continuation.yield(.finished(wasSimulated: simulated))
                        }
                        break
                    }
                    #if DEBUG
                    if state == (kDRStatusStateDone as String) || state == (kDRStatusStateFailed as String) {
                        BurnTrace.write("final status: \(status)")
                    }
                    #endif
                    if state == (kDRStatusStateFailed as String) {
                        let error = status[DRErrorStatusKey] as? [AnyHashable: Any]
                        continuation.yield(.failed((error?[DRErrorStatusErrorStringKey] as? String)
                            ?? String(localized: "The burn failed.")))
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(400))
                }
                if Task.isCancelled { burn.abort() }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Readable name for what is in the drive.
    static func mediaName(_ type: String) -> String {
        // The constants are `CFString?` and therefore unusable as `case`
        // patterns — hence a mapping that is built once.
        let names: [(CFString?, String)] = [
            (kDRDeviceMediaTypeCDROM, "CD-ROM"),
            (kDRDeviceMediaTypeCDR, "CD-R"),
            (kDRDeviceMediaTypeCDRW, "CD-RW"),
            (kDRDeviceMediaTypeDVDROM, "DVD-ROM"),
            (kDRDeviceMediaTypeDVDR, "DVD-R"),
            (kDRDeviceMediaTypeDVDRW, "DVD-RW"),
            (kDRDeviceMediaTypeDVDRAM, "DVD-RAM"),
            (kDRDeviceMediaTypeDVDPlusR, "DVD+R"),
            (kDRDeviceMediaTypeDVDPlusRW, "DVD+RW"),
            (kDRDeviceMediaTypeBDR, "BD-R"),
            (kDRDeviceMediaTypeBDRE, "BD-RE"),
            (kDRDeviceMediaTypeBDROM, "BD-ROM"),
        ]
        for (constant, name) in names where (constant as String?) == type {
            return name
        }
        return String(localized: "disc of an unknown kind")
    }

    static func describe(_ state: BurnMediaState) -> String {
        switch state {
        case .noDrive:              String(localized: "No optical drive found.")
        case .noDisc:               String(localized: "Insert a blank CD-R.")
        case .unusable(let reason): reason
        case .blank:                ""
        }
    }
}

#if DEBUG
/// What DiscRecording asked the producers for, in a text file next to the
/// temporary files — the burn engine itself logs nothing usable.
enum BurnTrace {
    static let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sleeve-burn-trace.txt")
    private static let lock = NSLock()

    static func start(simulated: Bool, tracks: Int) {
        lock.withLock {
            try? Data().write(to: url)
        }
        write("burn simulated=\(simulated) tracks=\(tracks)")
    }

    static func write(_ line: String) {
        lock.withLock {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((line + "\n").utf8))
        }
    }
}
#endif
