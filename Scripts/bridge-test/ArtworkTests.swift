//
//  ArtworkTests.swift
//
//  Coverbild-Verarbeitung (§4.5).
//
//  Diese Sammlung entstand nach einem Fehler, der in Betrieb aufgefallen ist:
//  eingefügte Cover kamen **schwarz** an. Ursache war ein `NSBitmapImageRep`
//  mit 24 Bit pro Pixel, das CoreGraphics nicht als Zeichenkontext hinterlegen
//  kann — es wurde ins Leere gezeichnet. Die Helligkeitsprüfung unten hätte
//  das sofort gezeigt.
//

import AppKit
import Foundation

enum ArtworkTests {

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

    static func section(_ title: String) { print("\n━━ \(title)") }

    /// Mittlere Helligkeit über ein Raster. Ein schwarzes Bild liegt bei 0.
    static func brightness(of data: Data) -> Double? {
        guard let image = NSImage(data: data),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        var sum = 0.0
        var count = 0
        let step = max(1, rep.pixelsWide / 30)
        for x in stride(from: 0, to: rep.pixelsWide, by: step) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: step) {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                sum += (color.redComponent + color.greenComponent + color.blueComponent) / 3
                count += 1
            }
        }
        return count > 0 ? sum / Double(count) : nil
    }

    static func dimensions(of data: Data) -> (width: Int, height: Int)? {
        guard let image = NSImage(data: data),
              let rep = image.representations.first else { return nil }
        return (rep.pixelsWide, rep.pixelsHigh)
    }

    /// Erzeugt ein farbiges Testbild über ffmpeg — verlässlicher als ein
    /// selbstgemalter Verlauf, und es liegt ohnehin im Projekt vor.
    static func makeImage(size: String, format: String, into folder: String) throws -> Data {
        let path = "\(folder)/probe-\(size).\(format)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        process.arguments = ["-hide_banner", "-loglevel", "error", "-y",
                             "-f", "lavfi", "-i", "testsrc2=size=\(size):duration=1",
                             "-frames:v", "1", path]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    static func run() throws -> Int32 {
        let work = NSTemporaryDirectory() + "sleeve-artwork-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: work) }

        let gross = try makeImage(size: "1400x1400", format: "jpg", into: work)
        let quer = try makeImage(size: "1400x900", format: "png", into: work)
        let klein = try makeImage(size: "600x600", format: "jpg", into: work)

        // MARK: - Der Fehler, der das hier ausgelöst hat

        section("Skalieren macht das Bild nicht schwarz")
        let original = brightness(of: gross) ?? 0
        check(original > 0.05, "Ausgangsbild ist nicht schwarz", detail: "\(original)")

        let optionen = ArtworkProcessor.Options(maximumEdge: 1000, jpegQuality: 0.85,
                                                output: .jpeg)
        guard let skaliert = ArtworkProcessor.prepare(gross, options: optionen) else {
            check(false, "prepare lieferte ein Ergebnis")
            return 1
        }
        let nachher = brightness(of: skaliert.data) ?? 0
        check(nachher > 0.05, "Ergebnis ist nicht schwarz", detail: "Helligkeit \(nachher)")
        check(abs(nachher - original) < 0.08,
              "Helligkeit bleibt erhalten",
              detail: "vorher \(String(format: "%.3f", original)), nachher \(String(format: "%.3f", nachher))")

        // MARK: - Maße

        section("Maße")
        let masse = dimensions(of: skaliert.data)
        equal(masse?.width, 1000, "Längste Kante auf das Maximum gebracht")
        equal(masse?.height, 1000, "Quadratisch bleibt quadratisch")

        guard let querSkaliert = ArtworkProcessor.prepare(quer, options: optionen) else {
            check(false, "Querformat verarbeitet"); return 1
        }
        let querMasse = dimensions(of: querSkaliert.data)
        equal(querMasse?.width, 1000, "Querformat: Breite auf das Maximum")
        check((querMasse?.height ?? 0) == 643, "Seitenverhältnis bleibt erhalten",
              detail: "\(querMasse?.height ?? 0) statt 643")
        check((brightness(of: querSkaliert.data) ?? 0) > 0.05, "Querformat nicht schwarz")

        // MARK: - Format

        section("Format")
        equal(skaliert.mimeType, "image/jpeg", "JPEG bleibt JPEG")
        equal(querSkaliert.mimeType, "image/jpeg", "PNG wird zu JPEG")
        equal(Artwork.detectMimeType(of: quer), "image/png", "PNG wird als solches erkannt")

        let unberuehrt = ArtworkProcessor.prepare(quer, options: .passthrough)
        equal(unberuehrt?.data, quer, "Ohne Skalieren und Umwandeln bleibt das Original")
        equal(unberuehrt?.mimeType, "image/png", "… samt seinem MIME-Typ")

        // Der Fehler, der bei der Umstellung auffiel: ein PNG wurde beim
        // Verkleinern stillschweigend zu JPEG, obwohl „Format beibehalten"
        // gewählt war.
        var pngVerkleinern = ArtworkProcessor.Options(maximumEdge: 500, output: .keepSource)
        let pngKlein = ArtworkProcessor.prepare(quer, options: pngVerkleinern)
        equal(pngKlein?.mimeType, "image/png", "PNG bleibt beim Verkleinern ein PNG")
        equal(dimensions(of: pngKlein?.data ?? Data())?.width, 500, "… und wird wirklich kleiner")
        check((brightness(of: pngKlein?.data ?? Data()) ?? 0) > 0.05, "… und ist nicht schwarz")

        pngVerkleinern.output = .jpeg
        equal(ArtworkProcessor.prepare(quer, options: pngVerkleinern)?.mimeType, "image/jpeg",
              "Mit ausdrücklicher Wahl wird daraus ein JPEG")

        equal(ArtworkProcessor.pixelSize(of: quer)?.width, 1400, "Pixelmaße direkt aus den Daten")

        let kleinBleibt = ArtworkProcessor.prepare(klein, options: optionen)
        equal(kleinBleibt?.data, klein, "Bild unter dem Maximum wird nicht neu gepackt")

        // MARK: - Randfälle

        section("Randfälle")
        check(ArtworkProcessor.prepare(Data("kein bild".utf8), options: optionen) == nil,
              "Nicht-Bild liefert nil")
        check(ArtworkProcessor.prepare(Data(), options: optionen) == nil,
              "Leere Daten liefern nil")

        var winzig = optionen
        winzig.maximumEdge = 64
        guard let sehrKlein = ArtworkProcessor.prepare(gross, options: winzig) else {
            check(false, "Sehr kleine Zielgröße verarbeitet"); return 1
        }
        equal(dimensions(of: sehrKlein.data)?.width, 64, "Auch 64 px werden getroffen")
        check((brightness(of: sehrKlein.data) ?? 0) > 0.05, "… und sind nicht schwarz")
        check(sehrKlein.data.count < gross.count / 4, "Die Datei wird deutlich kleiner",
              detail: "\(sehrKlein.data.count) statt \(gross.count)")

        equal(sehrKlein.pictureType, .frontCover, "Bildtyp voreingestellt auf Front Cover")

        print("\n\(checks - failures)/\(checks) Prüfungen bestanden")
        if failures > 0 {
            print("✗ \(failures) fehlgeschlagen")
            return 1
        }
        print("✓ Alles grün.")
        return 0
    }
}
