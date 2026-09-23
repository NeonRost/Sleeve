//
//  SleeveToolbar.swift
//  Sleeve
//
//  Toolbar nach Tagr-Vorbild: „Auf Platte speichern" ganz links und prominent,
//  daneben die Stapelverarbeitungen als beschriftete Symbole, jede mit einem
//  kleinen Popover.
//

import AppKit
import SwiftUI

/// Ein Toolbar-Knopf, der ein Popover öffnet.
struct ToolbarPopoverButton<Content: View>: View {
    let titleKey: LocalizedStringKey
    let systemImage: String
    var help: LocalizedStringKey = ""
    @ViewBuilder var content: Content

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Label(titleKey, systemImage: systemImage)
        }
        .help(help)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            content
        }
    }
}

/// Setzt den Anzeigemodus der NSToolbar auf Symbol **und** Beschriftung.
/// SwiftUI zeigt in der macOS-Toolbar sonst nur Symbole, und dann ist nicht zu
/// erkennen, was die Knöpfe tun.
struct ToolbarConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            // Nur den Anzeigemodus anfassen. `allowsUserCustomization` wirft an
            // einer SwiftUI-verwalteten Toolbar eine Assertion und beendet die
            // App — die Anpassbarkeit gehört SwiftUI.
            view.window?.toolbar?.displayMode = .iconAndLabel
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Der Inhalt der Toolbar.
///
/// **Modusabhängig**, wie es das Diagramm in Spec §1.1 vorgibt: Nummerierung,
/// Schreibweise und die Pattern-Engine gehören zum Taggen und haben im
/// Konvertieren-Modus nichts verloren. Über alle Modi hinweg bleiben nur das
/// Speichern und der Umschalter.
///
/// Der Umschalter sitzt links neben dem Fenstertitel statt mittig — zentriert
/// verbraucht er die Mitte und drängt die übrigen Knöpfe ins Überlaufmenü.
struct SleeveToolbar: ToolbarContent {
    let state: AppState

    var body: some ToolbarContent {
        // Ganz links der Umschalter, direkt daneben das Speichern. Beide
        // gehören zur Grundbedienung und sind in jedem Modus da; alles
        // Modusspezifische sammelt sich am rechten Rand.
        ToolbarItem(placement: .navigation) {
            ModeSwitcher()
        }

        // Die hervorgehobene Stelle links gehört dem, was der Modus gerade
        // tun soll: Tags schreiben — oder eben rippen.
        ToolbarItem(placement: .navigation) {
            if state.activeMode == .rip {
                RipActionButton()
            } else {
                Button {
                    Task { await state.save() }
                } label: {
                    Label("Save", systemImage: "internaldrive")
                }
                .disabled(state.trackList.changedCount == 0 || state.isBusy)
                .help("Write all pending changes to the files")
            }
        }

        ToolbarItemGroup(placement: .automatic) {
            switch state.activeMode {
            case .tag:     tagItems
            case .convert: convertItems
            case .rip:     ripItems
            }
        }
    }

    // MARK: - Rippen

    @ViewBuilder
    private var ripItems: some View {
        Button {
            Task { await state.refreshDisc() }
        } label: {
            Label("Read disc", systemImage: "arrow.clockwise")
        }
        .disabled(state.isInspectingDisc || state.isRipping)
        .help("Read the table of contents again")

        Button {
            if let name = state.disc?.drive.bsdName { state.ripEngine.eject(bsdName: name) }
        } label: {
            Label("Eject", systemImage: "eject")
        }
        .disabled(state.disc == nil || state.isRipping)
        .help("Eject the disc")
    }

    // MARK: - Taggen

    @ViewBuilder
    private var tagItems: some View {
        ToolbarPopoverButton(
            titleKey: "Numbers",
            systemImage: "list.number",
            help: "Renumber tracks in the current sort order"
        ) {
            NumberingPopover().environment(state)
        }

        ToolbarPopoverButton(
            titleKey: "Rename",
            systemImage: "textformat.abc.dottedunderline",
            help: "Build file names from tags"
        ) {
            FilenamePopover().environment(state)
        }

        ToolbarPopoverButton(
            titleKey: "Capitalization",
            systemImage: "textformat",
            help: "Title Case, UPPERCASE or lowercase"
        ) {
            CasePopover().environment(state)
        }

        ToolbarPopoverButton(
            titleKey: "All in One",
            systemImage: "wand.and.stars",
            help: "Numbering, capitalization, renaming and saving in one go"
        ) {
            AllInOnePopover().environment(state)
        }

        ToolbarPopoverButton(
            titleKey: "Extract",
            systemImage: "arrow.right.doc.on.clipboard",
            help: "Read tags out of the file names"
        ) {
            ExtractPopover().environment(state)
        }

        Button {
            state.isShowingLookup = true
        } label: {
            Label("Look Up", systemImage: "magnifyingglass.circle")
        }
        .disabled(state.operationTargets.isEmpty)
        .help("Look the selected tracks up on MusicBrainz or Discogs")
    }

    // MARK: - Konvertieren

    @ViewBuilder
    private var convertItems: some View {
        if state.isBusy {
            Button {
                state.cancelConversion()
            } label: {
                Label("Cancel", systemImage: "stop.circle")
            }
        } else {
            Button {
                Task { await state.convert() }
            } label: {
                Label("Convert", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(state.conversionBlocker != nil)
            .help(state.conversionBlocker ?? String(localized: "Convert the selected tracks"))
        }
    }
}


/// Startet und stoppt den Rip. Steht an derselben Stelle wie „Speichern",
/// weil es im Rip-Modus dieselbe Rolle hat.
private struct RipActionButton: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if state.isRipping {
            Button(role: .cancel) {
                state.cancelRip()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .help("Stop the current rip")
        } else {
            Button {
                state.startRip()
            } label: {
                Label("Rip", systemImage: "opticaldisc")
            }
            .disabled(state.ripBlocker != nil)
            .help(state.ripBlocker ?? String(localized: "Rip the selected tracks"))
        }
    }
}
