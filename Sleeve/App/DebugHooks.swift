//
//  DebugHooks.swift
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
//  Debug builds only. Opens windows in a defined state so that the UI can
//  be checked with a screenshot — instead of assuming from the code that it
//  is right.
//
//  The reason: the waveform in the Track Splitter was "done", but only its
//  computation had been checked. Nobody had ever seen it.
//
//      Sleeve -SleeveDebugSplit /path/to/file [-SleeveDebugSelect 3]
//      Sleeve -SleeveDebugTagLookup /path/to/folder [-SleeveDebugPick 1]
//

#if DEBUG
import SwiftUI

@MainActor
enum DebugHooks {

    /// Opens "Look Up Album" with a folder full of files, optionally picking
    /// a result right away:
    ///
    ///     Sleeve -SleeveDebugTagLookup /path/to/folder [-SleeveDebugPick 1]
    private static func tagLookup(state: AppState, defaults: UserDefaults) async {
        guard let path = defaults.string(forKey: "SleeveDebugTagLookup") else { return }
        await state.addFiles([URL(fileURLWithPath: path)])
        let pick = defaults.integer(forKey: "SleeveDebugPick")
        state.lookupDebugPick = pick > 0 ? pick : nil
        state.isShowingLookup = true
    }

    static func run(state: AppState, openWindow: OpenWindowAction) async {
        let defaults = UserDefaults.standard
        // "About Sleeve", optionally with the licenses window next to it.
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

        // Wait until probing and the waveform are done.
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

        // Play the end of a track — shows the playhead in the magnifier.
        if defaults.bool(forKey: "SleeveDebugPlayEnd") {
            state.jumpToEndBoundary()
        }
        // Paste a track list from a file and show the sheet.
        if let pasted = defaults.string(forKey: "SleeveDebugPaste"),
           let text = try? String(contentsOfFile: pasted, encoding: .utf8) {
            state.splitLookupMode = .pasted
            state.splitPasteText = text
            state.isShowingSplitLookup = true
            // …or apply it right away, to see the result in the window.
            if defaults.bool(forKey: "SleeveDebugApply") {
                state.isShowingSplitLookup = false
                state.applyListing(TrackListing(pasted: text), alignBoundaries: true)
                let again = defaults.integer(forKey: "SleeveDebugSelect")
                if again > 0, again <= state.splitTracks.count {
                    state.selectSplitTrack(state.splitTracks[again - 1].id)
                }
            }
        }
        // Open "Look Up Titles" with a search of its own.
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
        // Really split, into a folder of choice.
        if let target = defaults.string(forKey: "SleeveDebugSplitTo") {
            state.splitDestination = URL(fileURLWithPath: target)
            state.startSplit()
        }
        // Move the end by a few seconds — shows the dragged boundary.
        let shift = defaults.double(forKey: "SleeveDebugShiftEnd")
        if shift != 0, let track = state.selectedSplitTrack {
            state.moveSelectedEnd(to: track.range.end + shift)
        }
    }
}
#endif
