//
//  BurnTests.swift
//
//  Zurückbrennen (§6.10). Der Brennvorgang selbst ist ungeprüft — dafür fehlt
//  der Rohling. Geprüft ist alles davor, und das ist der riskantere Teil:
//  die Adressrechnung des Producers, der Spurenaufbau und die Auswertung des
//  Cue Sheets. Ein Fehler um einen Sektor erzeugt eine Scheibe, auf der jede
//  Spur versetzt beginnt, und das merkt man erst beim Anhören.
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
        check(actual == expected, label, detail: "ist \(actual), erwartet \(expected)")
    }

    static func run() throws -> Int32 {
        cueParsing()
        try producerArithmetic()
        trackLayout()
        mediaNames()
        liveDevice()

        print("\n  \(checks) Prüfungen, \(failures) Fehler")
        return failures == 0 ? 0 : 1
    }

    // MARK: - Cue Sheet lesen

    static func cueParsing() {
        print("\n— Cue Sheet auswerten —")

        // Der beste Test ist der Rundlauf: schreiben, lesen, vergleichen.
        guard let toc = DiscTOC(rawTOC: RipTests.hexData(RipTests.realTOC)) else {
            check(false, "TOC verfügbar"); return
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
            check(false, "eigenes Cue Sheet lässt sich wieder lesen"); return
        }
        check(true, "eigenes Cue Sheet lässt sich wieder lesen")
        equal(cue.audioFileName, "Peter und der Wolf.bin", "Dateiname mit Leerzeichen")
        equal(cue.fileType, "BINARY", "Dateityp")
        equal(cue.albumTitle, "Peter und der Wolf", "Albumtitel")
        equal(cue.albumPerformer, "Malte Arkona, Dresdner Philharmonie", "Albuminterpret")
        equal(cue.tracks.count, 14, "vierzehn Spuren")
        equal(cue.tracks[0].title, "Intro: Malte und Mezzo", "Tracktitel")
        equal(cue.tracks[6].title, "Der Großvater", "Umlaut im Tracktitel")
        check(cue.tracks[1].title == nil, "Spur ohne Titel bleibt ohne")

        // Das Entscheidende: die Startsektoren müssen exakt der TOC entsprechen.
        for track in toc.audioTracks {
            guard let parsed = cue.tracks.first(where: { $0.number == track.number }) else {
                check(false, "Spur \(track.number) im Cue Sheet"); continue
            }
            equal(parsed.startLBA, track.startLBA, "Startsektor Spur \(track.number)")
        }

        let counts = cue.sectorCounts(totalSectors: toc.leadOutLBA)
        for track in toc.audioTracks {
            equal(counts[track.number], track.sectorCount, "Länge Spur \(track.number)")
        }

        print("\n— Cue Sheet: Randfälle —")
        equal(CueSheet.lba(fromMSF: "00:00:00"), 0, "MSF null")
        equal(CueSheet.lba(fromMSF: "03:04:51"), 13851, "MSF der zweiten Spur")
        equal(CueSheet.lba(fromMSF: "40:37:21"), 182796, "MSF der letzten Spur")
        check(CueSheet.lba(fromMSF: "00:60:00") == nil, "60 Sekunden gibt es nicht")
        check(CueSheet.lba(fromMSF: "00:00:75") == nil, "75 Frames gibt es nicht")
        check(CueSheet.lba(fromMSF: "kaputt") == nil, "Unsinn wird abgelehnt")
        check(CueSheet(text: "") == nil, "leeres Cue Sheet wird abgelehnt")
        check(CueSheet(text: "FILE \"a.bin\" BINARY") == nil, "Cue ohne Spuren wird abgelehnt")

        // INDEX 00 markiert die Pause und darf den Start nicht verschieben.
        let withPregap = CueSheet(text: """
        FILE "x.wav" WAVE
          TRACK 01 AUDIO
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            INDEX 00 03:02:00
            INDEX 01 03:04:51
        """)
        equal(withPregap?.tracks.count, 2, "zwei Spuren trotz INDEX 00")
        equal(withPregap?.tracks[1].startLBA, 13851, "INDEX 00 verschiebt den Start nicht")

        // Datenspuren gehören nicht auf eine Audio-CD.
        let mixed = CueSheet(text: """
        FILE "x.bin" BINARY
          TRACK 01 AUDIO
            INDEX 01 00:00:00
          TRACK 02 MODE1/2352
            INDEX 01 05:00:00
        """)
        equal(mixed?.tracks.count, 1, "Datenspur wird übergangen")
    }

    // MARK: - Die Adressrechnung

    static func producerArithmetic() throws {
        print("\n— Producer: welche Bytes an welcher Adresse —")

        // Ein Abbild aus erkennbaren Sektoren: Sektor N ist mit N gefüllt.
        let sectors = 40
        var image = Data()
        for index in 0..<sectors {
            image.append(Data(repeating: UInt8(index), count: CDGeometry.bytesPerSector))
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sleeve-burn-\(UUID().uuidString).bin")
        try image.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        // BIN: kein Kopf. Spur 2 beginnt bei Sektor 10.
        let bin = ImageTrackProducer(url: url, headerBytes: 0, startSector: 10, sectorCount: 12)
        equal(bin.byteOffset(forAddress: 0), 10 * 2352, "Adresse 0 zeigt auf den Spuranfang")
        equal(bin.byteOffset(forAddress: 1), 11 * 2352, "Adresse 1 einen Sektor weiter")
        equal(bin.byteOffset(forAddress: 11), 21 * 2352, "letzter Sektor der Spur")

        // WAV: 44 Byte Kopf, alles verschiebt sich.
        let wav = ImageTrackProducer(url: url, headerBytes: 44, startSector: 10, sectorCount: 12)
        equal(wav.byteOffset(forAddress: 0), 44 + 10 * 2352, "WAV-Kopf wird übersprungen")
        equal(wav.byteOffset(forAddress: 5), 44 + 15 * 2352, "und bleibt übersprungen")

        // Und jetzt wirklich lesen: kommen die Bytes heraus, die dort stehen?
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
        equal(Int(produced), 2352 * blocks, "voller Puffer geliefert")
        let bytes = buffer.map { UInt8(bitPattern: $0) }
        equal(bytes[0], 10, "erster Sektor der Spur ist Sektor 10")
        equal(bytes[2352], 11, "danach Sektor 11")
        equal(bytes[2 * 2352], 12, "danach Sektor 12")
        check(bytes[0..<2352].allSatisfy { $0 == 10 }, "der ganze erste Sektor stimmt")

        // Ab Adresse 5 muss Sektor 15 kommen.
        let second = buffer.withUnsafeMutableBufferPointer { raw -> UInt32 in
            var flags: UInt32 = 0
            return bin.produceData(for: nil, intoBuffer: raw.baseAddress,
                                   length: 2352, atAddress: 5,
                                   blockSize: 2352, ioFlags: &flags)
        }
        equal(Int(second), 2352, "ein Sektor geliefert")
        equal(UInt8(bitPattern: buffer[0]), 15, "Adresse 5 der Spur ist Sektor 15")

        // Am Dateiende darf nichts Zufälliges herauskommen.
        let tail = ImageTrackProducer(url: url, headerBytes: 0, startSector: 38, sectorCount: 2)
        _ = tail.prepare(nil, for: nil, toMedia: nil)
        var tailBuffer = [CChar](repeating: 0x7F, count: 2352 * 4)
        let tailProduced = tailBuffer.withUnsafeMutableBufferPointer { raw -> UInt32 in
            var flags: UInt32 = 0
            return tail.produceData(for: nil, intoBuffer: raw.baseAddress,
                                    length: UInt32(raw.count), atAddress: 0,
                                    blockSize: 2352, ioFlags: &flags)
        }
        equal(Int(tailProduced), 2352 * 2, "über das Dateiende hinaus wird nichts erfunden")
        tail.cleanupTrack(afterBurn: nil)
    }

    // MARK: - Spurenaufbau

    static func trackLayout() {
        print("\n— Spurenaufbau —")
        guard let toc = DiscTOC(rawTOC: RipTests.hexData(RipTests.realTOC)) else { return }
        let tracks = toc.audioTracks.map {
            CueSheet.Track(number: $0.number, startLBA: $0.startLBA)
        }
        var counts: [Int: Int] = [:]
        for track in toc.audioTracks { counts[track.number] = track.sectorCount }

        let layout = CDBurner.Layout(imageURL: URL(fileURLWithPath: "/tmp/none.bin"),
                                     headerBytes: 0, tracks: tracks, sectorCounts: counts)
        equal(layout.totalSectors, toc.leadOutLBA, "Spurlängen ergeben die ganze Scheibe")

        let drTracks = CDBurner.makeTracks(layout)
        equal(drTracks.count, 14, "vierzehn DRTracks")

        // `frames()` ist der Frame-*Anteil* einer Zeitangabe (0–74), nicht
        // die Gesamtzahl — dafür ist `sectors()` da. Beim ersten Anlauf stand
        // hier `frames()`, und die Summe über vierzehn Spuren ergab 493
        // statt 236218. Die Prüfung hat den Irrtum gefunden, bevor er in den
        // Brennercode wandern konnte.
        var total = 0
        for (index, drTrack) in drTracks.enumerated() {
            guard let length = drTrack.properties()[DRTrackLengthKey] as? DRMSF else {
                check(false, "Länge an Spur \(index + 1)"); continue
            }
            total += Int(length.sectors())
        }
        equal(total, toc.leadOutLBA, "Summe der DRTrack-Längen deckt sich mit der TOC")

        if let first = drTracks.first?.properties() {
            equal(first[DRBlockSizeKey] as? Int, Int(kDRBlockSizeAudio),
                  "Blockgröße ist 2352 — dieselbe wie beim Lesen")
            equal(first[DRTrackModeKey] as? Int, Int(kDRTrackModeAudio), "Audiospur")
            if let pregap = first[DRPreGapLengthKey] as? DRMSF {
                equal(Int(pregap.sectors()), 150, "Spur 1 bekommt die übliche Pause")
            }
        }
        if drTracks.count > 1, let second = drTracks[1].properties(),
           let pregap = second[DRPreGapLengthKey] as? DRMSF {
            equal(Int(pregap.sectors()), 0,
                  "zwischen den Spuren keine zusätzliche Pause — sie steckt im Abbild")
        }

        // Eine Spur der Länge null darf nicht entstehen.
        var broken = counts
        broken[5] = 0
        let filtered = CDBurner.makeTracks(CDBurner.Layout(
            imageURL: URL(fileURLWithPath: "/tmp/none.bin"),
            headerBytes: 0, tracks: tracks, sectorCounts: broken))
        equal(filtered.count, 13, "Spur ohne Länge wird ausgelassen")
    }

    // MARK: - Am echten Laufwerk

    /// Die Zuordnung Medientyp → Name, unabhängig davon, was gerade im
    /// Laufwerk liegt.
    static func mediaNames() {
        print("\n— Medien beim Namen nennen —")
        equal(CDBurner.mediaName(kDRDeviceMediaTypeCDR as String), "CD-R", "CD-R")
        equal(CDBurner.mediaName(kDRDeviceMediaTypeCDRW as String), "CD-RW", "CD-RW")
        equal(CDBurner.mediaName(kDRDeviceMediaTypeCDROM as String), "CD-ROM", "CD-ROM")
        equal(CDBurner.mediaName(kDRDeviceMediaTypeDVDR as String), "DVD-R", "DVD-R")
        equal(CDBurner.mediaName(kDRDeviceMediaTypeDVDPlusR as String), "DVD+R", "DVD+R")
        equal(CDBurner.mediaName(kDRDeviceMediaTypeBDR as String), "BD-R", "BD-R")
        check(!CDBurner.mediaName("irgendwas").isEmpty,
              "Unbekanntes bekommt trotzdem einen Namen")

        // Der Fall, der in der Praxis vorkommt: ein leerer Rohling, nur vom
        // falschen Typ. Die Meldung muss den Typ nennen — „kein
        // beschreibbarer Rohling" wäre bei 4,38 GiB freiem Platz verwirrend.
        check(CDBurner.mediaName(kDRDeviceMediaTypeDVDR as String) != "CD-R",
              "DVD-R wird nicht für eine CD-R gehalten")
    }

    static func liveDevice() {
        print("\n— Laufwerk und Medium —")
        guard let device = CDBurner.firstDevice() else {
            print("  … übersprungen, kein optisches Laufwerk")
            return
        }
        let info = CDBurner.info(of: device)
        check(!info.displayName.isEmpty, "Laufwerk gefunden", detail: info.displayName)

        // Der Unterschied, den man sich nicht ausdenken kann: „Unsupported"
        // heißt laut Apples Header „wird trotzdem versucht", nur „None" heißt
        // „geht nicht".
        check(info.isUsable, "Laufwerk ist benutzbar", detail: info.supportLevel)

        let state = CDBurner.mediaState(of: device)
        switch state {
        case .blank(let sectors):
            check(sectors > 0, "Rohling erkannt", detail: "\(sectors) Sektoren frei")
        case .unusable(let reason):
            check(true, "eingelegte Scheibe wird als nicht brennbar erkannt")
            print("      → „\(reason)\"")
            check(!CDBurner.describe(state).isEmpty, "mit verständlicher Begründung")
        case .noDisc:
            check(true, "leeres Laufwerk wird erkannt")
        case .noDrive:
            check(false, "Laufwerk verschwunden")
        }
        check(!state.isReady || { if case .blank = state { true } else { false } }(),
              "nur ein Rohling gilt als bereit")
    }
}
