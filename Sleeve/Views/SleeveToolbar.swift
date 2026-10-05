//
//  SleeveToolbar.swift
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
//  Toolbar modelled on Tagr: "Save to disk" at the far left and prominent,
//  next to it the batch operations as labelled icons, each with a small
//  popover.
//

import AppKit
import SwiftUI

/// A toolbar button that opens a popover.
struct ToolbarPopoverButton<Content: View>: View {
    let titleKey: LocalizedStringKey
    let systemImage: String
    var help: LocalizedStringKey = ""
    /// Debug builds only: `-SleeveDebugPopover <id>` opens this popover at
    /// launch, for a screenshot.
    var debugID: String?
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
        #if DEBUG
        .task {
            guard let debugID,
                  UserDefaults.standard.string(forKey: "SleeveDebugPopover") == debugID else { return }
            try? await Task.sleep(for: .seconds(2))
            isPresented = true
        }
        #endif
    }
}

/// Sets the NSToolbar display mode to icon **and** label. Otherwise
/// SwiftUI shows only icons in the macOS toolbar, and then it is impossible
/// to tell what the buttons do.
struct ToolbarConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            // Only touch the display mode. `allowsUserCustomization` triggers an
            // assertion on a SwiftUI-managed toolbar and terminates the app —
            // customization belongs to SwiftUI.
            view.window?.toolbar?.displayMode = .iconAndLabel
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// The content of the toolbar.
///
/// **Mode-dependent**, as the diagram in spec §1.1 prescribes: numbering,
/// capitalization and the pattern engine belong to tagging and have no
/// place in the Convert mode. Across all modes, only Save and the switcher
/// remain.
///
/// The switcher sits to the left of the window title instead of in the
/// middle — centred, it takes up the middle and pushes the other buttons
/// into the overflow menu.
struct SleeveToolbar: ToolbarContent {
    let state: AppState

    var body: some ToolbarContent {
        // The switcher at the far left, Save right next to it. Both are
        // basic controls and present in every mode; everything
        // mode-specific gathers at the right edge.
        ToolbarItem(placement: .navigation) {
            ModeSwitcher()
        }

        // The prominent spot on the left belongs to what the mode is
        // meant to do right now: write tags — or rip.
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

    // MARK: - Rip

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

    // MARK: - Tag

    @ViewBuilder
    private var tagItems: some View {
        ToolbarPopoverButton(
            titleKey: "Numbers",
            systemImage: "list.number",
            help: "Renumber tracks in the current sort order",
            debugID: "numbers"
        ) {
            NumberingPopover().environment(state)
        }

        ToolbarPopoverButton(
            titleKey: "Rename",
            systemImage: "textformat.abc.dottedunderline",
            help: "Build file names from tags",
            debugID: "rename"
        ) {
            FilenamePopover().environment(state)
        }

        ToolbarPopoverButton(
            titleKey: "Capitalization",
            systemImage: "textformat",
            help: "Title Case, UPPERCASE or lowercase",
            debugID: "case"
        ) {
            CasePopover().environment(state)
        }

        ToolbarPopoverButton(
            titleKey: "Replace",
            systemImage: "arrow.triangle.swap",
            help: "Find and replace text in tags",
            debugID: "replace"
        ) {
            ReplacePopover().environment(state)
        }

        ToolbarPopoverButton(
            titleKey: "Fill",
            systemImage: "text.insert",
            help: "Fill a field from other tags or the file name",
            debugID: "fill"
        ) {
            FillPopover().environment(state)
        }

        ToolbarPopoverButton(
            titleKey: "All in One",
            systemImage: "wand.and.stars",
            help: "Numbering, capitalization, renaming and saving in one go",
            debugID: "allinone"
        ) {
            AllInOnePopover().environment(state)
        }

        ToolbarPopoverButton(
            titleKey: "Extract",
            systemImage: "arrow.right.doc.on.clipboard",
            help: "Read tags out of the file names",
            debugID: "extract"
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

    // MARK: - Convert

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


/// Starts and stops the rip. Sits in the same place as "Save" because it
/// plays the same role in Rip mode.
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
