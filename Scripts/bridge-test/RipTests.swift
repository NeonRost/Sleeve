//
//  RipTests.swift
//
//  Modus „Rippen" (§6). Der überwiegende Teil läuft ohne Laufwerk: TOC-
//  Auswertung, Kennungen, CD-TEXT und Versatzrechnung sind reine Logik.
//
//  Die Prüfungen am Ende brauchen eine eingelegte Audio-CD und werden
//  übersprungen, wenn keine da ist — sie dürfen die Suite nicht rot färben,
//  nur weil gerade kein Laufwerk hängt.
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
        check(actual == expected, label, detail: "ist \(actual), erwartet \(expected)")
    }

    /// Die echte TOC der Testscheibe, wie IOKit sie liefert. 14 Spuren.
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

    /// Der ganze Weg über `RipEngine`: Scheibe erkennen, eine Spur rippen,
    /// WAV schreiben — und das Ergebnis gegen die Sicht von macOS halten.
    static func engineEndToEnd(toc: DiscTOC, track: DiscTrack, aiff: Data) throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("sleeve-rip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var settings = RipSettings()
        settings.mode = .burst          // für den Testlauf genügt ein Durchgang
        settings.usesC2 = true          // absichtlich an: muss still abfallen
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
            check(false, "Rippen läuft in der vorgesehenen Zeit durch")
            return
        }

        check(failures.isEmpty, "Rippen ohne Fehler", detail: failures.joined(separator: "; "))
        guard let written, let report else {
            check(false, "Engine liefert Datei und Protokoll")
            return
        }
        check(true, "Engine liefert Datei und Protokoll")

        let wav = try Data(contentsOf: written)
        let pcm = Data(wav.dropFirst(44))
        equal(pcm.count, track.byteCount, "WAV enthält die ganze Spur")
        equal(pcm, Data(aiff.dropFirst(2352)), "gerippte Spur deckt sich mit dem, was macOS liest")

        // C2 war angefordert, das Laufwerk kann es nicht — der Durchgang muss
        // trotzdem sauber durchlaufen und das Protokoll muss es sagen.
        if !report.settings.usesC2 {
            check(report.settings.c2WasRequestedButUnavailable,
                  "fehlendes C2 wird im Protokoll vermerkt")
        }

        let log = report.logText(albumTitle: "Peter und der Wolf", albumArtist: "Malte Arkona")
        check(log.contains("Disc ID:     \(toc.musicBrainzDiscID)"), "Disc ID steht im Protokoll")
        check(log.contains(String(format: "%08X", report.entries[0].crc)),
              "Prüfsumme steht im Protokoll")
        check(log.contains("gleicht nicht gegen eine externe Datenbank ab"),
              "Protokoll sagt, was es nicht geprüft hat")

        let cue = report.cueSheet(albumTitle: "Peter und der Wolf",
                                  albumArtist: "Malte Arkona", audioFileName: "album.wav")
        check(cue.contains("TRACK 01 AUDIO"), "Cue Sheet führt die erste Spur")
        check(cue.contains("INDEX 01 03:04:51"), "Cue Sheet nennt den Beginn der zweiten Spur")
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

        print("\n  \(checks) Prüfungen, \(failures) Fehler")
        return failures == 0 ? 0 : 1
    }

    // MARK: - TOC

    static func tocParsing() {
        print("\n— Inhaltsverzeichnis —")
        guard let toc = DiscTOC(rawTOC: hexData(realTOC)) else {
            check(false, "TOC lässt sich auswerten")
            return
        }
        check(true, "TOC lässt sich auswerten")
        equal(toc.firstTrack, 1, "erste Spur")
        equal(toc.lastTrack, 14, "letzte Spur")
        equal(toc.tracks.count, 14, "vierzehn Spuren")
        // drutil meldet für dieselbe Scheibe 236218 Blöcke.
        equal(toc.leadOutLBA, 236218, "Lead-Out deckt sich mit drutil")
        equal(toc.tracks[0].startLBA, 0, "Spur 1 beginnt bei Sektor 0")
        equal(toc.tracks[1].startLBA, 13851, "Spur 2 beginnt bei 13851")
        equal(toc.tracks[0].sectorCount, 13851, "Länge der ersten Spur")
        // Die letzte Spur reicht bis zum Lead-Out.
        equal(toc.tracks[13].endLBA, 236218, "letzte Spur endet am Lead-Out")
        check(!toc.hasDataTrack, "reine Audio-CD, keine Datenspur")
        equal(toc.tracks.reduce(0) { $0 + $1.sectorCount }, 236218,
              "Spurlängen ergeben zusammen die ganze Scheibe")

        check(DiscTOC(rawTOC: Data()) == nil, "leere TOC wird abgelehnt")
        check(DiscTOC(rawTOC: Data([0, 4, 1, 1])) == nil, "TOC ohne Spuren wird abgelehnt")
    }

    // MARK: - Kennungen

    static func discIdentifiers() {
        print("\n— Kennungen —")

        // Das Rechenbeispiel aus der MusicBrainz-Dokumentation. Ohne diese
        // Prüfung wäre jede berechnete Disc ID bloß eine Behauptung.
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
              "Disc ID stimmt mit dem offiziellen Rechenbeispiel überein")

        guard let toc = DiscTOC(rawTOC: hexData(realTOC)) else { return }
        equal(toc.musicBrainzDiscID, "CObFGuFtiL4ToRbdSL_Q0bncOe8-",
              "Disc ID der Testscheibe")
        equal(toc.freeDBID, "b40c4d0e", "FreeDB-Kennung der Testscheibe")
        check(toc.musicBrainzTOCParameter.hasPrefix("1+14+236368+150+"),
              "TOC-Parameter für die Ersatzsuche",
              detail: String(toc.musicBrainzTOCParameter.prefix(40)))
    }

    // MARK: - CD-TEXT

    static func cdTextParsing() {
        print("\n— CD-TEXT —")
        let url = URL(fileURLWithPath: "Scripts/bridge-test/fixtures/cdtext-peter-und-der-wolf.bin")
        guard let data = try? Data(contentsOf: url) else {
            check(false, "CD-TEXT-Vorlage vorhanden")
            return
        }
        let text = CDText(packets: [UInt8](data))
        check(!text.isEmpty, "CD-TEXT lässt sich auswerten")
        equal(text.albumTitle, "Peter und der Wolf", "Albumtitel")
        equal(text.albumArtist, "Malte Arkona, Dresdner Philharmonie", "Albuminterpret")
        equal(text.albumComposer, "Sergej Prokofjew", "Komponist")
        equal(text.title(forTrack: 4), "Der Vogel", "Titel der vierten Spur")

        // Der Grund für diese Prüfung: beim ersten Anlauf stand hier
        // „Der Gro�vater" — CD-TEXT ist Latin-1, nicht UTF-8.
        equal(text.title(forTrack: 7), "Der Großvater", "Umlaute und ß kommen richtig an")
        equal(text.title(forTrack: 13), "Ein vertontes Märchen", "Umlaut im Titel")
        equal(text.title(forTrack: 14), "Das hässliche junge Entlein", "ß im Titel")
        equal(text.performer(forTrack: 12), "Peter Schreier, Walter Olberz",
              "abweichender Interpret einer einzelnen Spur")
        equal(text.performer(forTrack: 4), "Malte Arkona, Dresdner Philharmonie",
              "Spur ohne eigenen Interpreten erbt den des Albums")

        check(CDText(packets: []).isEmpty, "leeres CD-TEXT bleibt leer")
        check(CDText(packets: [UInt8](repeating: 0, count: 17)).isEmpty,
              "angeschnittenes Paket kippt nicht um")
    }

    // MARK: - Versatz

    static func offsetArithmetic() {
        print("\n— Leseversatz —")
        // Ein Laufwerk mit Versatz +6 liefert auf Anfrage nach p das Sample
        // p+6. Wer ab `start` will, muss ab `start−6` anfragen.
        let samplesPerSector = CDGeometry.samplesPerSector
        equal(samplesPerSector, 588, "Samples je Sektor")
        equal(CDGeometry.bytesPerSector, 2352, "Bytes je Sektor")
        equal(samplesPerSector * CDGeometry.bytesPerSample, CDGeometry.bytesPerSector,
              "Sektorgröße geht in Samples auf")

        let track = DiscTrack(number: 2, startLBA: 13851, sectorCount: 6412, isData: false)
        equal(track.endLBA, 20263, "Spurende")
        equal(track.byteCount, 6412 * 2352, "Bytezahl der Spur")
        equal(Int(track.duration.components.seconds), 85, "Spieldauer in Sekunden")

        for offset in [0, 6, -6, 667, -582] {
            let start = track.startLBA * samplesPerSector - offset
            let end = track.endLBA * samplesPerSector - offset
            equal(end - start, track.sectorCount * samplesPerSector,
                  "Versatz \(offset) ändert die Länge nicht")
        }
    }

    // MARK: - Prüfsummen

    static func checksums() {
        print("\n— Prüfsummen —")
        // Der übliche Testwert für CRC-32.
        equal(CRC32.compute(Data("123456789".utf8)), 0xCBF4_3926,
              "CRC-32 über \"123456789\"")
        equal(CRC32.compute(Data()), 0, "CRC-32 über nichts")
        check(CRC32.compute(Data([1, 2, 3])) != CRC32.compute(Data([3, 2, 1])),
              "Reihenfolge geht in die Prüfsumme ein")
    }

    // MARK: - Abbild

    static func discImage() {
        print("\n— Abbild —")

        // Ein Abbild wird nie am Stück berechnet: 550 MB im Speicher wären
        // Verschwendung. Also muss die fortgeschriebene Prüfsumme exakt der
        // in einem Rutsch berechneten entsprechen — sonst stimmt keine
        // Angabe im Protokoll.
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
              "stückweise Prüfsumme gleicht der am Stück berechneten")
        equal(CRC32.finish(CRC32.seed), CRC32.compute(Data()),
              "leerer Strom ergibt dieselbe Prüfsumme wie nichts")

        // Der Dateityp im Cue Sheet. Steht dort WAVE statt BINARY, sucht das
        // Abspielprogramm die Trackgrenzen um 44 Byte verschoben.
        equal(DiscImageFormat.bin.cueFileType, "BINARY", "BIN ist BINARY")
        equal(DiscImageFormat.wav.cueFileType, "WAVE", "WAV ist WAVE")
        equal(DiscImageFormat.flac.cueFileType, "WAVE", "FLAC gilt ebenfalls als WAVE")
        check(!DiscImageFormat.bin.needsFFmpeg, "BIN kommt ohne ffmpeg aus")
        check(!DiscImageFormat.wav.needsFFmpeg, "WAV kommt ohne ffmpeg aus")
        check(DiscImageFormat.flac.needsFFmpeg, "FLAC braucht ffmpeg")

        guard let toc = DiscTOC(rawTOC: hexData(realTOC)) else { return }
        let report = RipReport(drive: CDDriveInfo(bsdName: "disk9", vendor: "ASUS",
                                                 product: "BW-16D1X-U", revision: "A105"),
                               toc: toc, settings: RipSettings(), entries: [],
                               started: .now, ended: .now)

        let binCue = report.cueSheet(albumTitle: "Peter und der Wolf",
                                     albumArtist: "Malte Arkona",
                                     audioFileName: "album.bin", fileType: "BINARY",
                                     titles: [1: "Intro: Malte und Mezzo", 2: "Vorspiel"])
        check(binCue.contains("FILE \"album.bin\" BINARY"), "BIN-Abbild im Cue Sheet")
        check(binCue.contains("    TITLE \"Intro: Malte und Mezzo\""),
              "Tracktitel stehen im Cue Sheet")
        check(binCue.contains("  TRACK 01 AUDIO\n    TITLE"),
              "Titel folgt direkt auf die Trackzeile")
        equal(binCue.components(separatedBy: "INDEX 01").count - 1, 14,
              "vierzehn Trackmarken")
        check(binCue.contains("INDEX 01 00:00:00"), "Abbild beginnt bei null")
        check(binCue.contains("INDEX 01 03:04:51"), "Beginn der zweiten Spur")

        let wavCue = report.cueSheet(albumTitle: nil, albumArtist: nil,
                                     audioFileName: "album.flac", fileType: "WAVE")
        check(wavCue.contains("FILE \"album.flac\" WAVE"), "FLAC-Abbild im Cue Sheet")
        check(!wavCue.contains("PERFORMER"), "ohne Interpret keine leere Zeile")
        check(!wavCue.contains("TITLE \"\""), "ohne Titel keine leere Titelzeile")

        // Anführungszeichen im Titel würden das Cue Sheet zerlegen.
        let tricky = report.cueSheet(albumTitle: "Say \"Hello\"", albumArtist: nil,
                                     audioFileName: "a.wav")
        check(!tricky.contains("\"Say \"Hello\"\""), "Anführungszeichen werden entschärft")
    }

    // MARK: - WAV und Cue

    static func wavAndCue() {
        print("\n— WAV und Cue Sheet —")
        let pcm = Data(repeating: 0, count: 2352 * 10)
        let header = WAVWriter.header(forPCMByteCount: pcm.count)
        equal(header.count, 44, "Kopf ist 44 Byte lang")
        equal(String(decoding: header[0..<4], as: UTF8.self), "RIFF", "RIFF-Kennung")
        equal(String(decoding: header[8..<12], as: UTF8.self), "WAVE", "WAVE-Kennung")
        let declared = header[40..<44].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        equal(Int(UInt32(littleEndian: declared)), pcm.count, "Datenlänge im Kopf")

        equal(RipReport.msf(0), "00:00:00", "Sektor 0 als MSF")
        equal(RipReport.msf(75), "00:01:00", "eine Sekunde")
        equal(RipReport.msf(13851), "03:04:51", "Beginn der zweiten Spur als MSF")
    }

    // MARK: - Am echten Laufwerk

    static func live() throws {
        print("\n— Laufwerk —")
        guard let info = CDDriveFinder.availableDrives().first,
              let raw = info.rawTOC, let toc = DiscTOC(rawTOC: raw) else {
            print("  … übersprungen, keine Audio-CD eingelegt")
            return
        }
        check(true, "Laufwerk gefunden: \(info.displayName)")
        check(!info.vendor.isEmpty, "Hersteller ausgelesen", detail: info.vendor)
        check(info.devicePath.hasPrefix("/dev/r"), "Zeichengerät, nicht Blockgerät")

        let drive: CDDrive
        do {
            drive = try CDDrive(info: info)
        } catch {
            check(false, "Gerät ohne Sonderrechte zu öffnen", detail: "\(error)")
            return
        }
        check(true, "Gerät ohne Sonderrechte geöffnet")

        if let speed = drive.currentSpeed() {
            check(speed > 0, "Geschwindigkeit lesbar", detail: "\(speed) kB/s")
        }

        // Rohlesen und gegen die Sicht von macOS halten: das gemountete
        // CDDA-Dateisystem zeigt dieselben Spuren als AIFC. Stimmen beide
        // byteweise überein, sitzt die Adressierung.
        guard let track = toc.audioTracks.dropFirst(2).first else { return }
        let aiffURL = URL(fileURLWithPath:
            "/Volumes/Audio CD/\(track.number) Audio Track.aiff")
        guard let aiff = try? Data(contentsOf: aiffURL) else {
            print("  … Vergleich übersprungen, Volume nicht gemountet")
            return
        }

        // Nur den Anfang vergleichen, das genügt und dauert nicht.
        let sectors = 200
        let read = try drive.read(lba: track.startLBA, count: sectors, withC2: false)
        equal(read.audio.count, sectors * 2352, "Rohlesen liefert volle Sektoren")

        // C2 ist nicht selbstverständlich. Dieses Laufwerk meldet auf die
        // Anfrage nach Nutzdaten *und* Fehlerzeigern mal Erfolg über den
        // vollen Puffer, mal nur über ein Achtel — und der Audioanteil passt
        // in keinem Fall zu einem gewöhnlichen Lesen. Deshalb entscheidet
        // der Inhaltsvergleich, nicht die gemeldete Länge.
        let hasC2 = drive.supportsC2(probeLBA: track.startLBA)
        check(drive.supportsC2(probeLBA: track.startLBA) == hasC2,
              "C2-Tauglichkeit wird stabil festgestellt",
              detail: hasC2 ? "Laufwerk liefert C2" : "Laufwerk liefert kein C2")

        // Vergleichsstück aus der Mitte der Spur: groß genug, um mehrere
        // Blöcke zu umfassen, klein genug für einen schnellen Testlauf.
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
        equal(ripped.audio.count, sliceSectors * 2352, "sicherer Modus liefert die volle Länge")
        equal(ripped.audio, aiffSlice, "sicherer Modus deckt sich mit dem, was macOS liest")
        check(ripped.suspiciousSectors.isEmpty, "keine ungeklärten Sektoren",
              detail: "\(ripped.suspiciousSectors.count)")
        check(ripped.isAccurate, "als sauber gelesen gewertet")

        // Die schärfste Prüfung der Versatzkorrektur: ein Versatz von genau
        // einem Sektor muss dasselbe ergeben wie ein um einen Sektor
        // verschobenes Stück. Stimmt das, sitzt die Rechnung — und nicht
        // bloß die Länge.
        settings.readOffset = CDGeometry.samplesPerSector
        let shifted = try CDReader(drive: drive, settings: settings).rip(track: piece)
        let expectedShift = try drive.read(lba: sliceStart - 1, count: sliceSectors, withC2: false)
        equal(shifted.audio, expectedShift.audio,
              "Versatz von einem ganzen Sektor verschiebt das Fenster richtig")
        check(shifted.audio != ripped.audio, "verschobenes Fenster ist wirklich anderes Audio")

        // Und ein krummer Versatz: 6 Samples sind 24 Byte.
        settings.readOffset = 6
        let odd = try CDReader(drive: drive, settings: settings).rip(track: piece)
        let wide = try drive.read(lba: sliceStart - 1, count: sliceSectors + 1, withC2: false)
        let expectedOdd = wide.audio.subdata(
            in: (2352 - 24)..<(2352 - 24 + sliceSectors * 2352))
        equal(odd.audio, expectedOdd, "Versatz von 6 Samples trifft auf das Byte genau")

        // Burst muss dasselbe liefern wie Sicher, solange die Scheibe sauber ist.
        settings.readOffset = 0
        settings.mode = .burst
        let burst = try CDReader(drive: drive, settings: settings).rip(track: piece)
        equal(burst.audio, ripped.audio, "Burst und Sicher stimmen bei sauberer Scheibe überein")
        equal(burst.crc, ripped.crc, "gleiche Prüfsumme")

        // Doppelrip: derselbe Durchgang zweimal, Prüfsummen müssen passen.
        settings.mode = .secure
        settings.testBeforeCopy = true
        let verified = try CDReader(drive: drive, settings: settings).rip(track: piece)
        equal(verified.verificationCRC, verified.crc, "Doppelrip bestätigt sich selbst")
        equal(verified.crc, ripped.crc, "und stimmt mit dem einfachen Durchgang überein")

        // WAV schreiben und wieder einlesen.
        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sleeve-rip-test.wav")
        try WAVWriter.write(pcm: ripped.audio, to: wavURL)
        defer { try? FileManager.default.removeItem(at: wavURL) }
        let written = try Data(contentsOf: wavURL)
        equal(written.count, 44 + ripped.audio.count, "WAV-Datei hat die erwartete Größe")
        equal(Data(written.dropFirst(44)), ripped.audio, "PCM kommt unverändert in der Datei an")

        // Strömendes Lesen muss byteweise dasselbe ergeben wie der Weg über
        // eine ganze Spur — sonst wäre ein Abbild etwas anderes als der Rip.
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
                  "Strom und Spur stimmen überein, Versatz \(offset)")
            equal(summary.finishedCRC, whole.crc,
                  "gleiche Prüfsumme, Versatz \(offset)")
        }
        equal(try CDReader(drive: drive, settings: {
            var s = RipSettings(); s.mode = .burst; return s
        }()).readContiguous(fromSector: sliceStart, toSector: sliceStart + 120) { _ in }
            .suspiciousSectors.count, 0, "keine ungeklärten Sektoren beim Strömen")

        try engineEndToEnd(toc: toc, track: track, aiff: aiff)

        if let mcn = drive.readMCN() {
            check(mcn.allSatisfy(\.isNumber), "MCN besteht aus Ziffern", detail: mcn)
        }
        // ISRCs werden als Satz gelesen und als Satz verworfen, sobald ein
        // Wert doppelt auftaucht — der bekannte Fehler dieses Laufwerks gibt
        // einer Spur die Kennung ihrer Vorgängerin. Geprüft wird deshalb
        // nicht „kommt etwas zurück", sondern „ist das Gelieferte in sich
        // stimmig".
        let isrcs = drive.readISRCs(for: toc.tracks)
        if isrcs.isEmpty {
            check(true, "ISRCs verworfen, weil nicht verlässlich lesbar")
        } else {
            equal(Set(isrcs.values).count, isrcs.count,
                  "kein Wert doppelt — sonst wäre der Satz verworfen worden")
            check(isrcs.values.allSatisfy { $0.count == 12 },
                  "jede gelieferte ISRC ist zwölf Zeichen lang")
            check(isrcs.keys.allSatisfy { number in
                toc.tracks.contains { $0.number == number && !$0.isData }
            }, "ISRCs gehören zu Audiospuren")
        }

        if let text = drive.readCDText() {
            check(!text.isEmpty, "CD-TEXT von der Scheibe gelesen",
                  detail: text.albumTitle ?? "")
        }
    }
}
