//
//  ModeSwitcher.swift
//  Sleeve
//

import SwiftUI

/// Der persistente Umschalter in der Toolbar (Resolve-Modell, Spec §1.1).
/// Kein Startfenster, das vorab zur Entscheidung zwingt — die Dateiliste
/// bleibt beim Wechsel stehen.
struct ModeSwitcher: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        Picker("Mode", selection: $state.activeMode) {
            ForEach(AppMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        // Keine feste Breite: die Segmente sind in jeder Sprache verschieden
        // lang, und jeder überschüssige Punkt fehlt den Knöpfen rechts.
        .fixedSize()
        // Nicht verfügbare Modi bleiben sichtbar, sind aber nicht wählbar.
        .overlay { DisabledModeOverlay() }
    }
}

/// SwiftUIs `Picker` kennt kein „einzelnes Segment deaktivieren". Die
/// Erklärung kommt deshalb per Tooltip über dem Umschalter, und die Auswahl
/// wird zurückgesetzt, falls doch ein gesperrter Modus gewählt wird.
private struct DisabledModeOverlay: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .onChange(of: state.activeMode) { previous, new in
                if case .unavailable = state.availability(of: new) {
                    state.activeMode = previous
                }
            }
            .help(tooltip)
    }

    private var tooltip: String {
        let locked = AppMode.allCases.filter { !state.availability(of: $0).isAvailable }
        guard !locked.isEmpty else { return "" }
        return String(localized: "Converting and ripping arrive in later versions.")
    }
}
