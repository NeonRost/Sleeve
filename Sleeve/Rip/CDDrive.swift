//
//  CDDrive.swift
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
//  The only place with device access. Everything above it works with
//  values.
//
//  macOS allows raw access to audio CDs without special privileges: the
//  device node belongs to the logged-in user.
//
//      cr--r-----  1 <user>  operator  /dev/rdisk4
//
//  No root, no helper service, no entitlements. The sandbox is off for
//  Sleeve anyway (spec §2.2).
//

import CDShim
import Foundation
import IOKit
import IOKit.storage

struct CDDriveInfo: Equatable, Sendable, Identifiable {
    var bsdName: String
    var vendor: String
    var product: String
    var revision: String
    /// Raw TOC, as IOKit keeps it as a property.
    var rawTOC: Data?

    var id: String { bsdName }
    /// Character device, not block device: buffered, the cache would
    /// answer repeated read attempts instead of asking the disc.
    var devicePath: String { "/dev/r\(bsdName)" }
    var displayName: String {
        [vendor, product].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

enum CDDriveError: Error, Equatable, Sendable {
    case noDrive
    case noDisc
    case cannotOpen(String)
    case readFailed(lba: Int, reason: String)
    case shortRead(lba: Int, expected: Int, received: Int)
    case c2Unsupported
    case unreadable(lba: Int)
    case dataTrack
}

// MARK: - Discovery

enum CDDriveFinder {
    /// All drives with an audio CD inserted.
    static func availableDrives() -> [CDDriveInfo] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching(kIOCDMediaClass),
                                           &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var found: [CDDriveInfo] = []
        while case let media = IOIteratorNext(iterator), media != 0 {
            defer { IOObjectRelease(media) }
            guard let bsdName = string(media, kIOBSDNameKey) else { continue }
            let characteristics = deviceCharacteristics(of: media)
            found.append(CDDriveInfo(
                bsdName: bsdName,
                vendor: characteristics["Vendor Name"] ?? "",
                product: characteristics["Product Name"] ?? "",
                revision: characteristics["Product Revision Level"] ?? "",
                rawTOC: data(media, kIOCDMediaTOCKey)))
        }
        return found
    }

    private static func string(_ entry: io_registry_entry_t, _ key: String) -> String? {
        guard let value = IORegistryEntryCreateCFProperty(
            entry, key as CFString, kCFAllocatorDefault, 0) else { return nil }
        return value.takeRetainedValue() as? String
    }

    private static func data(_ entry: io_registry_entry_t, _ key: String) -> Data? {
        guard let value = IORegistryEntryCreateCFProperty(
            entry, key as CFString, kCFAllocatorDefault, 0) else { return nil }
        return value.takeRetainedValue() as? Data
    }

    /// Vendor and model do not hang off the medium but off the drive —
    /// i.e. further up in the registry tree. Knowing them is the
    /// precondition for remembering the read offset per model.
    private static func deviceCharacteristics(of media: io_registry_entry_t) -> [String: String] {
        var entry = media
        var owned = false
        defer { if owned { IOObjectRelease(entry) } }

        for _ in 0..<12 {
            if let value = IORegistryEntryCreateCFProperty(
                entry, "Device Characteristics" as CFString, kCFAllocatorDefault, 0),
               let dictionary = value.takeRetainedValue() as? [String: Any] {
                return dictionary.compactMapValues { $0 as? String }
            }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS
            else { break }
            if owned { IOObjectRelease(entry) }
            entry = parent
            owned = true
        }
        return [:]
    }
}

// MARK: - Opening and reading

/// Holds an open file descriptor. Deliberately **not** `Sendable`: the
/// device does not tolerate concurrent access, and a descriptor wandering
/// between tasks would be exactly the mistake Swift 6 is meant to prevent
/// here. Only `RipEngine` ever holds it.
final class CDDrive {
    let info: CDDriveInfo
    private let descriptor: Int32

    init(info: CDDriveInfo) throws {
        let fd = open(info.devicePath, O_RDONLY)
        guard fd >= 0 else {
            throw CDDriveError.cannotOpen(String(cString: strerror(errno)))
        }
        self.info = info
        self.descriptor = fd
    }

    deinit { close(descriptor) }

    // MARK: Identifiers from the disc

    /// The album's barcode, if burned in.
    func readMCN() -> String? {
        var request = dk_cd_read_mcn_t()
        guard ioctl(descriptor, kSleeveIOCDReadMCN, &request) == 0 else { return nil }
        return Self.text(of: request.mcn)
    }

    /// The ISRCs of **all** tracks at once — queried one by one they could
    /// not be trusted.
    ///
    /// Measured on the test drive (ASUS BW-16D1X-U): `DKIOCCDREADISRC`
    /// returns for track 2 sometimes its own code, sometimes track 1's. The
    /// stale value comes back *consistently* — reading twice and waiting for
    /// agreement does not help, both answers are then equally wrong. Seeking
    /// to the track, varying read positions and reading another track in
    /// between did not fix it either. The Q subchannel would be the clean
    /// source, but the same drive returns audio data for
    /// `kCDSectorAreaSubChannelQ` instead of subchannel.
    ///
    /// The error does have a reliable signature, though: a track gets its
    /// predecessor's code, so one value appears twice in the set. And which
    /// of the two is wrong cannot be decided. So the whole set is discarded
    /// and read again; if that does not help, there are no ISRCs. A wrong
    /// code in the tag goes unnoticed — a missing one does not.
    func readISRCs(for tracks: [DiscTrack], attempts: Int = 4) -> [Int: String] {
        for _ in 0..<attempts {
            var found: [Int: String] = [:]
            for track in tracks where !track.isData {
                // Bring the head to the track before asking.
                _ = try? read(lba: track.startLBA + 10, count: 1, withC2: false)

                var request = dk_cd_read_isrc_t()
                request.track = UInt8(clamping: track.number)
                guard ioctl(descriptor, kSleeveIOCDReadISRC, &request) == 0,
                      let value = Self.text(of: request.isrc)
                else { continue }
                found[track.number] = value
            }
            guard !found.isEmpty else { return [:] }
            if Set(found.values).count == found.count { return found }
        }
        return [:]
    }

    func readCDText() -> CDText? {
        // Generously sized: CD-TEXT runs across up to eight blocks.
        var buffer = [UInt8](repeating: 0, count: 4 + 18 * 2048)
        var request = dk_cd_read_toc_t()
        request.format = 5
        request.bufferLength = UInt16(clamping: buffer.count)

        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            request.buffer = raw.baseAddress
            return ioctl(descriptor, kSleeveIOCDReadTOC, &request) == 0
        }
        let length = Int(request.bufferLength)
        guard ok, length > 4 else { return nil }

        let text = CDText(packets: Array(buffer[4..<min(length, buffer.count)]))
        return text.isEmpty ? nil : text
    }

    // MARK: Speed

    /// In kB/s. 176.4 kB/s is single speed.
    func currentSpeed() -> Int? {
        var speed: UInt16 = 0
        guard ioctl(descriptor, kSleeveIOCDGetSpeed, &speed) == 0 else { return nil }
        return Int(speed)
    }

    /// Reading more slowly often helps scratched discs more than any
    /// retry. `nil` leaves the choice to the drive.
    @discardableResult
    func setSpeed(multiplier: Int?) -> Bool {
        var value = UInt16(clamping: multiplier.map { $0 * 176 } ?? 0xFFFF)
        return ioctl(descriptor, kSleeveIOCDSetSpeed, &value) == 0
    }

    // MARK: Raw reading

    struct SectorRead {
        var audio: Data
        /// 294 bytes of error pointers per sector, one bit per audio byte. Empty
        /// when reading without C2.
        var c2: Data
    }

    /// Reads `count` sectors from `lba` as raw CDDA.
    ///
    /// Important: `offset` in the ioctl counts bytes over the **sector size
    /// 2352**, not over the 2048 of the file system view.
    func read(lba: Int, count: Int, withC2: Bool) throws -> SectorRead {
        precondition(count > 0)
        let c2Size = withC2 ? Self.c2BytesPerSector : 0
        let stride = CDGeometry.bytesPerSector + c2Size
        var buffer = [UInt8](repeating: 0, count: stride * count)

        var request = dk_cd_read_t()
        request.offset = UInt64(lba) * UInt64(CDGeometry.bytesPerSector)
        request.sectorArea = UInt8(kCDSectorAreaUser.rawValue
            | (withC2 ? kCDSectorAreaErrorFlags.rawValue : 0))
        request.sectorType = UInt8(kCDSectorTypeCDDA.rawValue)
        request.bufferLength = UInt32(buffer.count)

        var failure: Int32 = 0
        buffer.withUnsafeMutableBytes { raw in
            request.buffer = raw.baseAddress
            if ioctl(descriptor, kSleeveIOCDRead, &request) != 0 { failure = errno }
        }
        guard failure == 0 else {
            throw CDDriveError.readFailed(lba: lba, reason: String(cString: strerror(failure)))
        }

        // On return, `bufferLength` says how much actually arrived. That is
        // no formality: when requesting payload and C2 pointers together,
        // at least one drive reports success and still fills only an
        // eighth of the buffer. Whoever does not check the value writes the
        // uninitialized rest into the file as audio.
        guard Int(request.bufferLength) == buffer.count else {
            throw CDDriveError.shortRead(lba: lba,
                                         expected: buffer.count,
                                         received: Int(request.bufferLength))
        }

        guard withC2 else { return SectorRead(audio: Data(buffer), c2: Data()) }

        // Audio and error pointers come back interleaved, sector by sector.
        var audio = Data(capacity: CDGeometry.bytesPerSector * count)
        var c2 = Data(capacity: c2Size * count)
        for index in 0..<count {
            let base = index * stride
            audio.append(contentsOf: buffer[base..<(base + CDGeometry.bytesPerSector)])
            c2.append(contentsOf: buffer[(base + CDGeometry.bytesPerSector)..<(base + stride)])
        }
        return SectorRead(audio: audio, c2: c2)
    }

    /// Whether the drive actually delivers C2 error pointers.
    ///
    /// Cannot be queried, only tried — and in a way that does not let a
    /// drive slip through that reports success and delivers nothing. So both
    /// are checked: does the full amount come back, and does the audio part
    /// match an ordinary read. At several positions and with different block
    /// sizes — one drive here passed the check at one position and failed at
    /// another. Even so this is not reliable, which is why `CDReader` also
    /// gives way during operation.
    func supportsC2(probeLBA lba: Int) -> Bool {
        for (offset, count) in [(0, 2), (1000, 8), (5000, 27)] {
            guard let plain = try? read(lba: lba + offset, count: count, withC2: false),
                  let combined = try? read(lba: lba + offset, count: count, withC2: true),
                  combined.audio == plain.audio,
                  combined.c2.count == count * Self.c2BytesPerSector
            else { return false }
        }
        return true
    }

    static let c2BytesPerSector = 294

    // MARK: Internal

    private static func text<T>(of tuple: T) -> String? {
        var copy = tuple
        let string = withUnsafeBytes(of: &copy) { raw -> String in
            guard let base = raw.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
