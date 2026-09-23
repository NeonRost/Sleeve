//
//  DebugHooks.swift
//  Sleeve
//
//  Nur in Debug-Builds. Öffnet Fenster in einem definierten Zustand, damit
//  sich die Oberfläche per Bildschirmfoto prüfen lässt — statt sie aus dem
//  Code heraus für richtig zu halten.
//
//  Anlass: die Hüllkurve im Track Splitter war „fertig", geprüft war aber nur
//  ihre Berechnung. Zu sehen war sie nie.
//
//      Sleeve -SleeveDebugSplit /pfad/zur/datei [-SleeveDebugSelect 3]
//      Sleeve -SleeveDebugTagLookup /pfad/zum/ordner [-SleeveDebugPick 1]
//

#if DEBUG
import SwiftUI

@MainActor
enum DebugHooks {

    /// „Album nachschlagen" mit einem Ordner voller Dateien öffnen, optional
    /// gleich einen Treffer wählen:
    ///
    ///     Sleeve -SleeveDebugTagLookup /pfad/zum/ordner [-SleeveDebugPick 1]
    private static func tagLookup(state: AppState, defaults: UserDefaults) async {
        guard let path = defaults.string(forKey: "SleeveDebugTagLookup") else { return }
        await state.addFiles([URL(fileURLWithPath: path)])
        let pick = defaults.integer(forKey: "SleeveDebugPick")
        state.lookupDebugPick = pick > 0 ? pick : nil
        state.isShowingLookup = true
    }

    static func run(state: AppState, openWindow: OpenWindowAction) async {
        let defaults = UserDefaults.standard
        // „Über Sleeve", auf Wunsch mit dem Lizenzfenster daneben.
        if defaults.bool(forKey: "SleeveDebugAbout") {
            openWindow(id: SleeveApp.aboutWindowID)
        }
        if defaults.bool(forKey: "SleeveDebugLicenses") {
            openWindow(id: SleeveApp.licensesWindowID)
        }
        await tagLookup(state: state, defaults: defaults)
        guard let path = defaults.string(forKey: "SleeveDebugSplit") else { return }

        state.prepareSplit()
        openWindow(id: SleeveApp.splitWindowID)
        state.loadSplitSource(URL(fileURLWithPath: path))

        // Warten, bis Untersuchung und Hüllkurve durch sind.
        for _ in 0..<600 where state.splitSourceInfo == nil || state.isLoadingWaveform {
            try? await Task.sleep(for: .milliseconds(100))
        }
        state.analyzeSplit()
        for _ in 0..<600 where state.splitStage == .analyzing {
            try? await Task.sleep(for: .milliseconds(100))
        }

        let select = defaults.integer(forKey: "SleeveDebugSelect")
        if select > 0, select <= state.splitTracks.count {
            state.selectSplitTrack(state.splitTracks[select - 1].id)
        }

        // Ende eines Tracks anspielen — zeigt den Abspielkopf in der Lupe.
        if defaults.bool(forKey: "SleeveDebugPlayEnd") {
            state.jumpToEndBoundary()
        }
        // Eine Trackliste aus einer Datei einfügen und das Blatt zeigen.
        if let pasted = defaults.string(forKey: "SleeveDebugPaste"),
           let text = try? String(contentsOfFile: pasted, encoding: .utf8) {
            state.splitLookupMode = .pasted
            state.splitPasteText = text
            state.isShowingSplitLookup = true
            // …oder gleich übernehmen, um das Ergebnis im Fenster zu sehen.
            if defaults.bool(forKey: "SleeveDebugApply") {
                state.isShowingSplitLookup = false
                state.applyListing(TrackListing(pasted: text), alignBoundaries: true)
                let again = defaults.integer(forKey: "SleeveDebugSelect")
                if again > 0, again <= state.splitTracks.count {
                    state.selectSplitTrack(state.splitTracks[again - 1].id)
                }
            }
        }
        // „Titel nachschlagen" mit einer eigenen Suche öffnen.
        if let search = defaults.string(forKey: "SleeveDebugSearch") {
            let parts = search.components(separatedBy: "|")
            var query = DiscogsClient.SearchQuery()
            query.artist = parts.first ?? ""
            query.releaseTitle = parts.count > 1 ? parts[1] : ""
            state.splitSearch = state.makeReleaseSearch(query: query, provider: .musicBrainz)
            let pick = defaults.integer(forKey: "SleeveDebugPick")
            state.splitDebugPick = pick > 0 ? pick : nil
            state.splitLookupMode = .musicBrainz
            state.isShowingSplitLookup = true
        }
        if defaults.bool(forKey: "SleeveDebugLookup") {
            state.isShowingSplitLookup = true
        }
        // Wirklich aufteilen, in einen Ordner nach Wahl.
        if let target = defaults.string(forKey: "SleeveDebugSplitTo") {
            state.splitDestination = URL(fileURLWithPath: target)
            state.startSplit()
        }
        // Ende um einige Sekunden verschieben — zeigt die gezogene Grenze.
        let shift = defaults.double(forKey: "SleeveDebugShiftEnd")
        if shift != 0, let track = state.selectedSplitTrack {
            state.moveSelectedEnd(to: track.range.end + shift)
        }
    }
}
#endif
