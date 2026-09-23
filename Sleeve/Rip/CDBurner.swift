//
//  CDBurner.swift
//  Sleeve
//
//  Ein Abbild zurück auf eine CD-R schreiben (Spec §6.10).
//
//  **Ungeprüft bis zum ersten Rohling.** Alles andere in diesem Projekt ist am
//  Gerät nachgemessen; hier fehlte die leere Scheibe. Was geprüft ist und was
//  nicht, steht in §6.10.1 — bitte nachlesen, bevor man sich darauf verlässt.
//
//  Über DiscRecording, ohne Fremdbibliothek. Die Zahlen passen ohne
//  Umrechnung: `kDRBlockSizeAudio` ist 2352, also genau die Sektorgröße, mit
//  der auch gelesen wird.
//

import DiscRecording
import Foundation

enum BurnMediaState: Equatable, Sendable {
    case noDrive
    case noDisc
    /// Eine Scheibe liegt drin, taugt aber nicht — schon beschrieben, oder
    /// gar keine CD-R.
    case unusable(reason: String)
    case blank(sectors: Int)

    var isReady: Bool { if case .blank = self { true } else { false } }
}

struct BurnDeviceInfo: Equatable, Sendable {
    var vendor: String
    var product: String
    /// Apple unterscheidet „nicht unterstützt, wird aber versucht" von „kann
    /// nicht benutzt werden". Nur das Zweite ist ein Hindernis.
    var supportLevel: String
    var isUsable: Bool

    var displayName: String {
        [vendor, product].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

// MARK: - Nachschauen

enum CDBurner {

    static func firstDevice() -> DRDevice? {
        for case let device as DRDevice in DRDevice.devices() { return device }
        return nil
    }

    static func info(of device: DRDevice) -> BurnDeviceInfo {
        let info = device.info() ?? [:]
        let level = (info[DRDeviceSupportLevelKey] as? String) ?? ""
        return BurnDeviceInfo(
            vendor: (info[DRDeviceVendorNameKey] as? String) ?? "",
            product: (info[DRDeviceProductNameKey] as? String) ?? "",
            supportLevel: level,
            // `…LevelNone` heißt laut Apples Header ausdrücklich „cannot be
            // used"; `…LevelUnsupported` dagegen „will try to use it anyway".
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
            // Den Typ mitnennen. „Kein beschreibbarer Rohling" ist bei einer
            // eingelegten leeren DVD-R schlicht verwirrend — sie *ist* ja
            // beschreibbar, nur eben nicht für eine Audio-CD.
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

// MARK: - Daten nachschieben

/// Liefert während des Brennens die Bytes einer Spur aus dem Abbild.
///
/// Die heikelste Stelle des ganzen Vorgangs: ein Fehler um einen Sektor
/// erzeugt eine Scheibe, auf der jede Spur versetzt beginnt — und das merkt
/// man erst beim Anhören. Deshalb ist die Rechnung hier eine reine Funktion
/// (`byteOffset(forAddress:)`) und als solche geprüft, auch ohne Laufwerk.
///
/// `address` ist laut Apples Dokumentation „the sector address on the disc
/// **from the start of the track**" — also trackrelativ, nicht absolut.
///
/// Nicht `Sendable`: die Rückrufe kommen auf dem Brenn-Thread, aber immer
/// nacheinander und nur für diese eine Spur. Gehalten wird das Objekt
/// ausschließlich von `CDBurner.burn`.
final class ImageTrackProducer: NSObject, DRTrackDataProduction {

    /// Anfang der Spur in der Abbilddatei, in Byte — enthält bereits einen
    /// etwaigen Dateikopf.
    let baseOffset: Int
    let sectorCount: Int
    private let url: URL
    private var handle: FileHandle?

    init(url: URL, headerBytes: Int, startSector: Int, sectorCount: Int) {
        self.url = url
        self.baseOffset = headerBytes + startSector * CDGeometry.bytesPerSector
        self.sectorCount = sectorCount
    }

    /// Reine Rechnung, damit sie ohne Brenner prüfbar ist.
    func byteOffset(forAddress address: UInt64) -> Int {
        baseOffset + Int(address) * CDGeometry.bytesPerSector
    }

    // MARK: DRTrackDataProduction

    func estimateLength(of track: DRTrack!) -> UInt64 { UInt64(sectorCount) }

    func prepare(_ track: DRTrack!, for burn: DRBurn!, toMedia mediaInfo: [AnyHashable: Any]!) -> Bool {
        handle = try? FileHandle(forReadingFrom: url)
        return handle != nil
    }

    func cleanupTrack(afterBurn track: DRTrack!) {
        try? handle?.close()
        handle = nil
    }

    func produceData(for track: DRTrack!, intoBuffer buffer: UnsafeMutablePointer<CChar>!,
                     length bufferLength: UInt32, atAddress address: UInt64,
                     blockSize: UInt32, ioFlags flags: UnsafeMutablePointer<UInt32>!) -> UInt32 {
        guard let handle else { return 0 }
        do {
            try handle.seek(toOffset: UInt64(byteOffset(forAddress: address)))
            guard let data = try handle.read(upToCount: Int(bufferLength)) else { return 0 }
            data.withUnsafeBytes { raw in
                buffer.withMemoryRebound(to: UInt8.self, capacity: data.count) { target in
                    target.update(from: raw.bindMemory(to: UInt8.self).baseAddress!,
                                  count: data.count)
                }
            }
            // Am Dateiende auf ein Vielfaches der Blockgröße mit Stille
            // auffüllen — das Laufwerk nimmt keine halben Sektoren.
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

    // Die übrigen Anforderungen der Schnittstelle. Prüfen nach dem Brennen
    // überlassen wir dem System (`kDRBurnVerifyDiscKey`), deshalb hier keine
    // eigene Logik.
    func producePreGap(for track: DRTrack!, intoBuffer buffer: UnsafeMutablePointer<CChar>!,
                       length bufferLength: UInt32, atAddress address: UInt64,
                       blockSize: UInt32, ioFlags flags: UnsafeMutablePointer<UInt32>!) -> UInt32 { 0 }
    func prepareTrack(forVerification track: DRTrack!) -> Bool { true }
    func verifyPreGap(for track: DRTrack!, inBuffer buffer: UnsafePointer<CChar>!,
                      length bufferLength: UInt32, atAddress address: UInt64,
                      blockSize: UInt32, ioFlags flags: UnsafeMutablePointer<UInt32>!) -> Bool { true }
    func verifyData(for track: DRTrack!, inBuffer buffer: UnsafePointer<CChar>!,
                    length bufferLength: UInt32, atAddress address: UInt64,
                    blockSize: UInt32, ioFlags flags: UnsafeMutablePointer<UInt32>!) -> Bool { true }
    func cleanupTrack(afterVerification track: DRTrack!) -> Bool { true }
}

// MARK: - Brennen

extension CDBurner {

    enum BurnEvent: Sendable {
        case progress(Double)
        case finished(wasSimulated: Bool)
        case failed(String)
    }

    struct Layout: Sendable {
        var imageURL: URL
        /// Wie viele Byte vor den Audiodaten stehen — 0 bei BIN, 44 bei WAV.
        var headerBytes: Int
        var tracks: [CueSheet.Track]
        var sectorCounts: [Int: Int]

        var totalSectors: Int { sectorCounts.values.reduce(0, +) }
    }

    /// Baut die Spurliste, ohne zu brennen. Ohne Laufwerk prüfbar, deshalb
    /// getrennt vom eigentlichen Vorgang.
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
                // Die Pause vor Track 1 legt das System an; zwischen den
                // Spuren soll keine entstehen, das Abbild trägt sie schon.
                DRPreGapLengthKey: DRMSF(frames: track.number == 1 ? 150 : 0) as Any,
            ])
            return drTrack
        }
    }

    /// Schreibt das Abbild auf den eingelegten Rohling.
    ///
    /// `simulated` lässt den Laser aus: der ganze Ablauf läuft durch, es wird
    /// nichts geschrieben, der Rohling bleibt unbeschrieben. Das ist der Weg,
    /// auf dem sich alles außer dem letzten Schritt prüfen lässt.
    static func burn(_ layout: Layout, simulated: Bool) -> AsyncStream<BurnEvent> {
        AsyncStream { continuation in
            let task = Task.detached {
                guard let device = firstDevice() else {
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
                    // Lückenlos: alle Spuren in einem Durchgang, Scheibe zu.
                    DRBurnStrategyKey: kDRBurnStrategyCDSAO as String,
                    DRBurnAppendableKey: NSNumber(value: false),
                    DRBurnCompletionActionKey: kDRBurnCompletionActionEject as String,
                    DRBurnVerifyDiscKey: NSNumber(value: !simulated),
                ])
                burn.writeLayout(tracks)

                // Statt Benachrichtigungen abzufangen wird der Zustand
                // abgefragt — weniger beweglich, und der Fortschritt kommt
                // ohnehin nur grob.
                while !Task.isCancelled {
                    let status = burn.status() ?? [:]
                    let state = (status[DRStatusStateKey] as? String) ?? ""
                    if let fraction = status[DRStatusPercentCompleteKey] as? Double {
                        continuation.yield(.progress(fraction))
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

    /// Lesbarer Name für das, was im Laufwerk liegt.
    static func mediaName(_ type: String) -> String {
        // Die Konstanten sind `CFString?` und taugen deshalb nicht als
        // `case`-Muster — also eine Zuordnung, die einmal aufgebaut wird.
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
