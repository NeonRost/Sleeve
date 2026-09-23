//
//  CDDrive.swift
//  Sleeve
//
//  Der einzige Ort mit Gerätezugriff. Alles darüber arbeitet mit Werten.
//
//  macOS erlaubt den Rohzugriff auf Audio-CDs ohne Sonderrechte: der
//  Geräteknoten gehört dem angemeldeten Benutzer.
//
//      cr--r-----  1 <benutzer>  operator  /dev/rdisk4
//
//  Kein root, kein Helfer-Dienst, keine Entitlements. Der Sandkasten ist für
//  Sleeve ohnehin aus (Spec §2.2).
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
    /// Rohe TOC, wie IOKit sie als Eigenschaft führt.
    var rawTOC: Data?

    var id: String { bsdName }
    /// Zeichengerät, nicht Blockgerät: gepuffert würde uns der Cache
    /// wiederholte Leseversuche beantworten, statt die Scheibe zu fragen.
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

// MARK: - Suchen

enum CDDriveFinder {
    /// Alle Laufwerke mit eingelegter Audio-CD.
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

    /// Hersteller und Modell hängen nicht am Medium, sondern am Laufwerk —
    /// also weiter oben im Registry-Baum. Sie zu kennen ist die Voraussetzung
    /// dafür, den Leseversatz je Modell zu merken.
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

// MARK: - Öffnen und lesen

/// Hält einen offenen Dateideskriptor. Bewusst **nicht** `Sendable`: das
/// Gerät verträgt keine gleichzeitigen Zugriffe, und ein Deskriptor, der
/// zwischen Aufgaben wandert, wäre genau der Fehler, den Swift 6 hier
/// verhindern soll. Gehalten wird er ausschließlich von `RipEngine`.
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

    // MARK: Kennungen von der Scheibe

    /// Der Barcode des Albums, sofern eingebrannt.
    func readMCN() -> String? {
        var request = dk_cd_read_mcn_t()
        guard ioctl(descriptor, kSleeveIOCDReadMCN, &request) == 0 else { return nil }
        return Self.text(of: request.mcn)
    }

    /// Die ISRCs **aller** Spuren auf einmal — einzeln abgefragt wären sie
    /// nicht zu verantworten.
    ///
    /// Gemessen am Testlaufwerk (ASUS BW-16D1X-U): `DKIOCCDREADISRC` liefert
    /// für Spur 2 mal deren eigene Kennung, mal die von Spur 1. Der veraltete
    /// Wert kommt dabei *stabil* zurück — zweimal zu lesen und auf
    /// Übereinstimmung zu warten hilft also nicht, beide Antworten sind dann
    /// gleich falsch. Auch das Anfahren der Spur, wechselnde Lesepositionen und
    /// das Zwischenschalten einer anderen Spur haben es nicht behoben. Der
    /// Q-Subchannel wäre die saubere Quelle, aber dasselbe Laufwerk liefert
    /// auf `kCDSectorAreaSubChannelQ` Audiodaten statt Subchannel.
    ///
    /// Der Fehler hat aber eine verlässliche Signatur: eine Spur bekommt die
    /// Kennung ihrer Vorgängerin, im Satz steht also ein Wert doppelt. Und
    /// welcher der beiden der falsche ist, lässt sich nicht entscheiden.
    /// Deshalb wird der ganze Satz verworfen und neu gelesen; bleibt es
    /// dabei, gibt es keine ISRCs. Eine falsche Kennung im Tag fällt
    /// niemandem auf — eine fehlende schon.
    func readISRCs(for tracks: [DiscTrack], attempts: Int = 4) -> [Int: String] {
        for _ in 0..<attempts {
            var found: [Int: String] = [:]
            for track in tracks where !track.isData {
                // Den Kopf auf die Spur bringen, bevor gefragt wird.
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
        // Großzügig bemessen: CD-TEXT läuft über bis zu acht Blöcke.
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

    // MARK: Geschwindigkeit

    /// In kB/s. 176,4 kB/s sind einfache Geschwindigkeit.
    func currentSpeed() -> Int? {
        var speed: UInt16 = 0
        guard ioctl(descriptor, kSleeveIOCDGetSpeed, &speed) == 0 else { return nil }
        return Int(speed)
    }

    /// Langsamer zu lesen bringt bei zerkratzten Scheiben oft mehr als jede
    /// Wiederholung. `nil` überlässt dem Laufwerk die Wahl.
    @discardableResult
    func setSpeed(multiplier: Int?) -> Bool {
        var value = UInt16(clamping: multiplier.map { $0 * 176 } ?? 0xFFFF)
        return ioctl(descriptor, kSleeveIOCDSetSpeed, &value) == 0
    }

    // MARK: Rohlesen

    struct SectorRead {
        var audio: Data
        /// Je Sektor 294 Byte Fehlerzeiger, ein Bit je Audio-Byte. Leer, wenn
        /// ohne C2 gelesen wurde.
        var c2: Data
    }

    /// Liest `count` Sektoren ab `lba` als rohes CDDA.
    ///
    /// Wichtig: `offset` im ioctl zählt in Byte über die **Sektorgröße 2352**,
    /// nicht über die 2048 der Dateisystemsicht.
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

        // `bufferLength` sagt beim Rücksprung, wie viel wirklich ankam. Das
        // ist keine Formalie: fordert man Nutzdaten und C2-Zeiger zusammen
        // an, meldet mindestens ein Laufwerk Erfolg und füllt trotzdem nur
        // ein Achtel des Puffers. Wer den Wert nicht prüft, schreibt den
        // uninitialisierten Rest als Audio in die Datei.
        guard Int(request.bufferLength) == buffer.count else {
            throw CDDriveError.shortRead(lba: lba,
                                         expected: buffer.count,
                                         received: Int(request.bufferLength))
        }

        guard withC2 else { return SectorRead(audio: Data(buffer), c2: Data()) }

        // Audio und Fehlerzeiger kommen verschränkt zurück, Sektor für Sektor.
        var audio = Data(capacity: CDGeometry.bytesPerSector * count)
        var c2 = Data(capacity: c2Size * count)
        for index in 0..<count {
            let base = index * stride
            audio.append(contentsOf: buffer[base..<(base + CDGeometry.bytesPerSector)])
            c2.append(contentsOf: buffer[(base + CDGeometry.bytesPerSector)..<(base + stride)])
        }
        return SectorRead(audio: audio, c2: c2)
    }

    /// Ob das Laufwerk C2-Fehlerzeiger tatsächlich herausgibt.
    ///
    /// Nicht zu erfragen, nur auszuprobieren — und zwar so, dass ein Laufwerk
    /// nicht durchrutscht, das Erfolg meldet und nichts liefert. Geprüft wird
    /// deshalb beides: kommt die volle Menge zurück, und stimmt der
    /// Audioanteil mit einem gewöhnlichen Lesen überein.
    /// An mehreren Stellen und mit verschiedenen Blockgrößen — ein Laufwerk
    /// hier hat die Prüfung an einer Stelle bestanden und ist an einer
    /// anderen ausgestiegen. Verlässlich ist das trotzdem nicht, deshalb
    /// gibt `CDReader` im Betrieb zusätzlich nach.
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

    // MARK: Intern

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
