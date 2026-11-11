//
//  AppDelegate.swift
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

import AppKit

/// Asks before quitting when quitting would cost something, and lets a tag
/// write in progress finish its file first.
///
/// SwiftUI's `App` has no say in termination; this is the one thing the
/// delegate is for.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `SleeveApp` once the main window is up.
    var state: AppState?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state, let warning = warning(for: state) else { return .terminateNow }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Quit Sleeve?")
        alert.informativeText = warning
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }

        // TagLib writes in place. The file in hand is finished, the rest of
        // the batch stays unsaved — that is what the user just agreed to.
        guard state.isWritingTags else { return .terminateNow }
        state.stopsAfterCurrentFile = true
        Task { @MainActor in
            while state.isWritingTags {
                try? await Task.sleep(for: .milliseconds(50))
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// The most costly thing quitting would interrupt, or `nil` when there
    /// is nothing to lose.
    private func warning(for state: AppState) -> String? {
        if case .running(simulated: false) = state.burnStage {
            return String(localized: "A disc is being burned. Quitting now ruins the blank.")
        }
        if state.copyStage == .burning {
            return String(localized: "A disc is being burned. Quitting now ruins the blank.")
        }
        if state.isWritingTags {
            return String(localized: "Tags are still being written. Sleeve finishes the current file and then quits.")
        }
        if state.isRipping || state.imageStage == .reading || state.imageStage == .converting
            || state.copyStage == .reading {
            return String(localized: "A disc is being read. Quitting now stops that.")
        }
        if state.isBusy {
            return String(localized: "Files are still being processed. Quitting now stops that.")
        }
        if state.trackList.changedCount > 0 {
            return String(localized: "There are unsaved changes. They are lost when you quit.")
        }
        return nil
    }
}
