//
//  SplitTrack.swift
//  Sleeve
//
//  Ein Track im Splitter: seine Grenzen, wie die Erkennung sie fand, und wie
//  sie jetzt sind.
//
//  Grenzen werden hier nur **gespeichert**, nicht verschoben. Verschieben geht
//  ausschließlich über `AppState.moveBoundary`, weil jede Grenze zugleich die
//  des Nachbarn ist — ein Track, der seine eigene Grenze verschöbe, rissen eine
//  Lücke auf, und was darin liegt, stünde in keiner Datei (Spec §7.3, §7.8).
//

import Foundation

@MainActor
@Observable
final class SplitTrack: Identifiable {
    let id = UUID()
    private(set) var range: TrackRange
    /// Wohin „Zurücksetzen" führt: was die Erkennung gefunden hat — oder, nach
    /// Teilen oder Zusammenlegen, der Stand danach. Sonst führte Zurücksetzen
    /// an eine Grenze, die es gar nicht mehr gibt.
    var detected: TrackRange
    /// Leer heißt: nur die Tracknummer, wie beim Rippen.
    var title = ""
    /// Was in den Zeitfeldern steht — während des Tippens darf es vom
    /// gespeicherten Wert abweichen.
    var startText: String
    var endText: String

    /// Kürzer darf ein Track durch Verschieben nicht werden.
    static let minimumLength: Double = 0.5

    init(range: TrackRange) {
        self.range = range
        self.detected = range
        self.startText = Timecode.format(range.start)
        self.endText = Timecode.format(range.end)
    }

    var isAdjusted: Bool {
        abs(range.start - detected.start) > 0.05 || abs(range.end - detected.end) > 0.05
    }

    /// Nur für `AppState` — der prüft vorher gegen den Nachbarn.
    func assign(start: Double) {
        range.start = start
        startText = Timecode.format(start)
    }

    /// Nur für `AppState` — der prüft vorher gegen den Nachbarn.
    func assign(end: Double) {
        range.end = end
        endText = Timecode.format(end)
    }
}
