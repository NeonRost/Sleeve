//
//  SleeveApp.swift
//  Sleeve
//

import SwiftUI

@main
struct SleeveApp: App {
    static let splitWindowID = "split"
    static let aboutWindowID = "about"
    static let licensesWindowID = "licenses"

    @State private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(state)
                .frame(minWidth: 900, minHeight: 500)
        }
        .commands { SleeveCommands(state: state) }

        // Eigenes Fenster statt Blatt: verschiebbar, vergrößerbar, und es
        // hängt an keiner Scheibe im Hauptfenster (Spec §7).
        Window("Split Into Tracks", id: SleeveApp.splitWindowID) {
            SplitWindow()
                .environment(state)
        }
        .defaultSize(width: 760, height: 680)
        .windowResizability(.contentMinSize)

        // Eigene Fenster statt des Standardfelds — siehe AboutWindow.swift.
        // Ohne Eintrag im Fenster-Menü: erreichbar über „Über Sleeve".
        Window("About Sleeve", id: SleeveApp.aboutWindowID) {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commandsRemoved()

        Window("Licenses", id: SleeveApp.licensesWindowID) {
            LicensesView()
        }
        .defaultSize(width: 760, height: 720)
        .commandsRemoved()

        Settings {
            SettingsView()
                .environment(state)
        }
    }
}

struct SleeveCommands: Commands {
    let state: AppState

    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Sleeve") { openWindow(id: SleeveApp.aboutWindowID) }
        }

        CommandGroup(replacing: .newItem) {
            Button("Add Files…") { openPanel() }
                .keyboardShortcut("o")
        }

        CommandGroup(replacing: .undoRedo) {
            Button("Undo Last Save") {
                Task { await state.undoLastSave() }
            }
            .keyboardShortcut("z")
            .disabled(!state.canUndo)

            Button("Discard Changes") {
                state.revertSelection()
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(state.trackList.changedCount == 0)
        }

        CommandGroup(after: .importExport) {
            // Reines Convenience-Feature, bewusst klein gehalten (Spec §4.7) —
            // in der Toolbar nimmt es nur Platz weg.
            Button("Add to Music") { state.addToMusic() }
                .disabled(state.operationTargets.isEmpty)

            Divider()

            // Gelegentliche Medienfunktionen gehören in die Ablage, nicht ins
            // Sleeve-Menü — das ist bei macOS für das Programm selbst da
            // (Über, Einstellungen, Beenden). Und nicht in den Rip-Bereich:
            // dort wählt man Spuren aus, ein Abbild ist immer die ganze
            // Scheibe (Spec §9.1).
            Button("Create Disc Image…") { state.showImageSheet() }
            Button("Burn Image to CD…") { state.showBurnSheet() }

            Divider()

            Button("Split Into Tracks…") {
                state.prepareSplit()
                openWindow(id: SleeveApp.splitWindowID)
            }
        }

        CommandGroup(after: .saveItem) {
            Button("Save Tags") {
                Task { await state.save() }
            }
            .keyboardShortcut("s")
            .disabled(state.trackList.changedCount == 0 || state.isBusy)
        }
    }

    @MainActor
    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await state.addFiles(urls) }
    }
}
