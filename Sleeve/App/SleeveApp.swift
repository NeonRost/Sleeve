//
//  SleeveApp.swift
//  Sleeve
//
//  Copyright (C) 2026 NeonRost
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <https://www.gnu.org/licenses/>.
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

        // A window of its own instead of a sheet: movable, resizable, and not
        // tied to a disc in the main window (spec §7).
        Window("Split Into Tracks", id: SleeveApp.splitWindowID) {
            SplitWindow()
                .environment(state)
        }
        .defaultSize(width: 760, height: 680)
        .windowResizability(.contentMinSize)

        // Windows of their own instead of the standard panel — see
        // AboutWindow.swift. No entry in the Window menu: reached through
        // "About Sleeve".
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
            // Pure convenience, deliberately kept small (spec §4.7) — in the
            // toolbar it would only take up room.
            Button("Add to Music") { state.addToMusic() }
                .disabled(state.operationTargets.isEmpty)

            Divider()

            // Occasional media functions belong in the File menu, not in the
            // Sleeve menu — on macOS that one is for the program itself
            // (About, Settings, Quit). And not in the Rip section: there one
            // picks tracks, an image is always the whole disc (spec §6.9).
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
