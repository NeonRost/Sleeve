//
//  ContentView.swift
//  Sleeve
//

import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var state = state

        NavigationSplitView {
            // Inspector links, je Modus eine andere View. Die Trackliste
            // rechts bleibt beim Moduswechsel unberührt (Spec §1.1).
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
        // Ohne Fenstertitel. „Sleeve" steht schon in der Menüleiste, und in
        // der Toolbar kostet es rund 90 Punkte, die den Knöpfen fehlen.
        .navigationTitle("")
        .toolbar {
            SleeveToolbar(state: state)
        }
        // Sorgt dafür, dass die Toolbar Symbole MIT Beschriftung zeigt.
        .background(ToolbarConfigurator())
        .sheet(isPresented: $state.isShowingFailureSheet) {
            FailureSheet()
        }
        // ffmpeg einmal beim Start suchen — erst danach steht fest, ob der
        // Konvertieren-Modus überhaupt wählbar ist.
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

// MARK: - Statusleiste

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

            // Fortschritt erst ab 20 Dateien (Spec §4.1) — bei fünf Dateien
            // flackert eine Leiste nur.
            if state.isRipping {
                // Der Ripper meldet sich hier und nicht im Formular: dort
                // scrollt der Fortschritt weg, sobald man die Trackliste
                // durchsieht — genau dann, wenn man ihn sehen will.
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

// MARK: - Fehlerzusammenfassung

/// Fehler brechen den Batch nicht ab, sondern werden gesammelt und am Ende
/// in einem Sheet gezeigt (Spec §4.1).
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
