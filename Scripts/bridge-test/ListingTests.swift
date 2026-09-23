//
//  ListingTests.swift
//
//  Trackliste von außen (§7.12): eingefügter Text und Ausrichten der Grenzen.
//

import Foundation

enum ListingTests {

    static func run() -> Int32 {
        var failures = 0, checks = 0
        func check(_ condition: Bool, _ label: String, _ detail: String = "") {
            checks += 1
            if condition { print("  ✓ \(label)") }
            else { failures += 1; print("  ✗ \(label)\(detail.isEmpty ? "" : " — \(detail)")") }
        }
        func close(_ a: Double, _ b: Double, _ tol: Double, _ label: String) {
            check(abs(a - b) <= tol, label, String(format: "ist %.2f, erwartet %.2f", a, b))
        }

        print("\n— Eingefügte Trackliste —")
        // Genau der Text aus der YouTube-Beschreibung, samt Link,
        // Überschrift und Gesamtlänge.
        let pasted = """
        https://www.youtube.com/watch?v=dsZvuCeUh8c&t=318s
        BEAST - IMagination∞lenS (Full Album)
        (44:49)

        Trackliste:
        Beast City 0:00
        Vision (ISM∞Version) 1:35
        Chemical 5:16
        Spiral Cave 9:32
        48k Rate Change[Freeze]⇒Convert22 14:07
        Lynch 16:33
        LUV 18:55
        Deadly Nightshade 22:50
        Cowboy 25:34
        Dayz&Diez 28:57
        LR-7 32:35
        New Noise 36:12
        Slider 39:30
        """
        let listing = TrackListing(pasted: pasted)
        check(listing.entries.count == 13, "dreizehn Tracks, Link und Gesamtlänge übergangen",
              "\(listing.entries.count)")
        check(listing.entries.first?.title == "Beast City", "erster Titel")
        check(listing.entries[1].title == "Vision (ISM∞Version)", "Klammern und ∞ bleiben im Titel")
        check(listing.entries[4].title == "48k Rate Change[Freeze]⇒Convert22",
              "Sonderzeichen bleiben im Titel")
        check(listing.entries[9].title == "Dayz&Diez", "Ampersand bleibt")
        close(listing.entries[5].start ?? 0, 993, 0.01, "Lynch beginnt bei 16:33")
        check(listing.hasStarts, "alle Einträge haben eine Startzeit")

        print("\n— Andere Schreibweisen —")
        let variants = TrackListing(pasted: """
        00:00 Intro
        01. Erstes Stück - 1:02:03
        [1:05:10] Zweites Stück
        3) Drittes – 1:09:00
        Kommentar ohne Zeit
        """)
        check(variants.entries.map(\.title) == ["Intro", "Erstes Stück", "Zweites Stück", "Drittes"],
              "Zeit vorn, hinten, in Klammern, mit Nummer", "\(variants.entries.map(\.title))")
        close(variants.entries[1].start ?? 0, 3723, 0.01, "Stundenangabe wird gelesen")

        let backwards = TrackListing(pasted: "A 0:00\nB 5:00\nC 2:00\nD 9:00")
        check(backwards.entries.map(\.title) == ["A", "B", "D"],
              "rückwärts springende Zeiten gehören nicht zur Liste")

        check(TrackListing(pasted: "keine Zeiten hier").entries.isEmpty, "ohne Zeiten keine Liste")

        print("\n— Grenzen aus Startzeiten —")
        // Erkannte Schnitte am echten Album (Auszug), dazu die Angaben des
        // Uploaders. Wo eine Stille in der Nähe liegt, rastet die Grenze ein;
        // bei Lynch liegt keine — dort gilt die Angabe.
        let cuts: [Double] = [95.8, 316.5, 573.0, 848.1, 886.4, 1136.7]
        let aligned = AudioSplitter.alignedRanges(
            starts: [0, 95, 316, 572, 847, 993, 1135], duration: 1370, candidates: cuts)
        check(aligned.count == 7, "sieben Tracks aus sieben Startzeiten")
        close(aligned[1].start, 95.8, 0.001, "1:35 rastet an der Stille bei 1:35.8 ein")
        close(aligned[4].start, 848.1, 0.001, "14:07 rastet bei 14:08.1 ein")
        close(aligned[5].start, 993, 0.001, "Lynch: keine Stille in der Nähe, die Angabe gilt")
        close(aligned[6].start, 1136.7, 0.001, "LUV rastet bei 18:56.7 ein")
        check(!aligned.contains { abs($0.start - 886.4) < 0.01 },
              "die Pause mitten in „48k“ wird keine Grenze")
        check(zip(aligned, aligned.dropFirst()).allSatisfy { $0.end == $1.start },
              "lückenlos")
        close(aligned.last!.end, 1370, 0.001, "bis zum Dateiende")

        print("\n— Grenzen aus Längen —")
        // Längen wie von MusicBrainz, aber der Mitschnitt hat je Übergang eine
        // Sekunde mehr Pause. Stur addiert wüchse der Fehler auf 3 s; vom
        // eingerasteten Vorgänger aus gerechnet bleibt er bei null.
        let cuts2: [Double] = [101, 202, 303]
        let fromLengths = AudioSplitter.alignedRanges(
            durations: [100, 100, 100, 100], duration: 400, candidates: cuts2)
        close(fromLengths[1].start, 101, 0.001, "erste Grenze rastet ein")
        close(fromLengths[2].start, 202, 0.001, "zweite vom eingerasteten Vorgänger aus")
        close(fromLengths[3].start, 303, 0.001, "dritte ebenso — kein wandernder Fehler")

        let farOff = AudioSplitter.alignedRanges(
            durations: [100, 100], duration: 300, candidates: [150])
        close(farOff[1].start, 100, 0.001, "ohne Stille in der Nähe gilt die Länge")

        print("\n  \(checks) Prüfungen, \(failures) Fehler")
        return failures == 0 ? 0 : 1
    }
}
