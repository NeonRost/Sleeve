//
//  ContentView.swift
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

struct ContentView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var state = state

        NavigationSplitView {
            // Inspector on the left, a different view per mode. The track list
            // on the right stays untouched when the mode changes (spec §1.1).
            Group {
                switch state.activeMode {
                case .tag:     TagInspector()
                case .convert: ConvertInspector()
                case .rip:     RipInspector()
                }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 420)
        } detail: {
            VStack(spacing: 0) {
                TrackTableView()
                Divider()
                StatusBar()
            }
        }
        // No window title. "Sleeve" is already in the menu bar, and in
        // the toolbar it costs about 90 points that the buttons lack.
        .navigationTitle("")
        .toolbar {
            SleeveToolbar(state: state)
        }
        // Makes the toolbar show icons WITH labels.
        .background(ToolbarConfigurator())
        .sheet(isPresented: $state.isShowingFailureSheet) {
            FailureSheet()
        }
        // Look for ffmpeg once at launch — only then is it clear whether
        // the Convert mode can be chosen at all.
        .task {
            state.trackList.restoreColumnLayout()
            await state.locateFFmpeg()
            #if DEBUG
            await DebugHooks.run(state: state, openWindow: openWindow)
            #endif
        }
        .sheet(isPresented: $state.isShowingLookup) {
            if let session = state.makeLookupSession() {
                LookupSheet(session: session)
                    .environment(state)
            }
        }
        .sheet(isPresented: $state.isShowingImageSheet) {
            DiscImageSheet()
                .environment(state)
        }
        .sheet(isPresented: $state.isShowingBurnSheet) {
            BurnSheet()
                .environment(state)
        }
    }
}

// MARK: - Status bar

private struct StatusBar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 12) {
            Button {
                addFiles()
            } label: {
                Image(systemName: "plus")
            }
            .help("Add files or folders")

            Button {
                state.trackList.removeSelected()
            } label: {
                Image(systemName: "minus")
            }
            .disabled(state.trackList.selection.isEmpty)
            .help("Remove selected tracks from the list")

            Button {
                state.trackList.removeAll()
            } label: {
                Image(systemName: "xmark")
            }
            .disabled(state.trackList.tracks.isEmpty)
            .help("Clear the list")

            Button {
                state.revertSelection()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(state.trackList.changedCount == 0)
            .help("Discard unsaved changes")

            Spacer()

            // Progress only from 20 files on (spec §4.1) — with five files
            // a bar only flickers.
            if state.isRipping {
                // The ripper reports here and not in the form: there the
                // progress scrolls away as soon as one looks through the track
                // list — exactly when one wants to see it.
                ProgressView(value: state.ripOverallProgress)
                    .progressViewStyle(.linear)
                    .frame(width: 160)
                Text(state.ripStatusText)
                    .foregroundStyle(.secondary)
            } else if state.showsProgress {
                ProgressView(value: state.progress)
                    .progressViewStyle(.linear)
                    .frame(width: 160)
                Text(state.progressLabel)
                    .foregroundStyle(.secondary)
            } else if state.isBusy {
                ProgressView()
                    .controlSize(.small)
            }

            Text(summary)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var summary: String {
        let total = state.trackList.tracks.count
        let changed = state.trackList.changedCount
        if changed == 0 {
            return String(localized: "\(total) tracks")
        }
        return String(localized: "\(total) tracks, \(changed) changed")
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await state.addFiles(urls) }
    }
}

// MARK: - Error summary

/// Errors do not abort the batch; they are collected and shown in a
/// sheet at the end (spec §4.1).
private struct FailureSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text("\(state.failures.count) files could not be processed")
                    .font(.headline)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            Text("Everything else was written. The affected files are marked in the list.")
                .foregroundStyle(.secondary)
                .font(.callout)

            List(state.failures) { failure in
                VStack(alignment: .leading, spacing: 2) {
                    Text(failure.filename).fontWeight(.medium)
                    Text(failure.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 160)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
