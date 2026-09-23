//
//  SplitWindow.swift
//  Sleeve
//
//  Track Splitter (Spec §7).
//
//  Aufbau, von oben nach unten:
//
//  1. Datei und Erkennung — je eine Zeile, weil man sie selten anfasst.
//  2. **Übersicht** über die ganze Datei. Fest, scrollt nie weg.
//  3. Links die Trackliste, rechts der **Bearbeiter** für den gewählten Track
//     mit zwei Lupen auf Anfang und Ende.
//  4. Ausgabe und Aufteilen.
//
//  Der erste Anlauf war ein langes Formular: die Hüllkurve oben, die Tracks
//  weit darunter. Sobald man zu den Tracks scrollte, war sie weg — und über
//  45 Minuten ist ein Bildpunkt rund zwei Sekunden, zu grob für einen Schnitt.
//  Die Lupen zeigen je 20 Sekunden: rund 30 Millisekunden je Bildpunkt.
//

import SwiftUI
import UniformTypeIdentifiers

struct SplitWindow: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            SourceBar()
            Divider()

            if state.splitSource == nil {
                DropPlaceholder(isTargeted: isDropTargeted)
            } else {
                DetectionBar()
                Divider()
                OverviewStrip()
                Divider()
                if state.splitTracks.isEmpty {
                    NoTracksPlaceholder()
                } else {
                    HSplitView {
                        TrackList()
                            .frame(minWidth: 320, idealWidth: 380)
                        Editor()
                            .frame(minWidth: 460)
                    }
                }
                Divider()
                OutputBar()
            }

            Divider()
            Footer()
        }
        .frame(minWidth: 940, idealWidth: 1120, maxWidth: .infinity,
               minHeight: 600, idealHeight: 780, maxHeight: .infinity)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadTransferable(type: URL.self) { result in
                guard case let .success(url) = result else { return }
                Task { @MainActor in state.loadSplitSource(url) }
            }
            return true
        }
        .onDisappear { state.splitPreview.stop() }
        .sheet(isPresented: Binding(get: { state.isShowingSplitLookup },
                                    set: { state.isShowingSplitLookup = $0 })) {
            SplitLookupSheet().environment(state)
        }
    }
}

// MARK: - Datei

private struct SourceBar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: state.splitSourceInfo?.hasVideo == true ? "film" : "waveform")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.splitSource?.lastPathComponent ?? String(localized: "No file"))
                    .fontWeight(.medium)
                    .lineLimit(1).truncationMode(.middle)
                if let info = state.splitSourceInfo {
                    Text(summary(info))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if state.isLoadingWaveform {
                ProgressView().controlSize(.small)
                Text("Reading the file…").font(.caption).foregroundStyle(.secondary)
            }
            Button("Choose…") { state.chooseSplitSource() }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func summary(_ info: AudioSplitter.SourceInfo) -> String {
        let length = Duration.seconds(info.duration).formatted(.time(pattern: .minuteSecond))
        var parts = [length, info.audioCodec.uppercased()]
        if info.hasVideo {
            parts.append(String(localized: "video — the audio track is taken out unchanged"))
        }
        if let reason = state.splitPreview.unplayableReason { parts.append(reason) }
        return parts.joined(separator: " · ")
    }
}

private struct DropPlaceholder: View {
    @Environment(AppState.self) private var state
    let isTargeted: Bool

    var body: some View {
        ContentUnavailableView {
            Label("Split Into Tracks", systemImage: "scissors")
        } description: {
            Text("Drop a long recording here — an album side, a live set, a full-album video. Sleeve finds the silences between the pieces; you check and adjust the cuts before anything is written.")
        } actions: {
            Button("Choose…") { state.chooseSplitSource() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isTargeted ? Color.accentColor.opacity(0.08) : .clear)
    }
}

private struct NoTracksPlaceholder: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 8) {
            if state.splitStage == .analyzing {
                ProgressView()
                Text("Looking for silences…").foregroundStyle(.secondary)
            } else {
                Text("Press Analyse to find the tracks.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Erkennung

private struct DetectionBar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        HStack(spacing: 16) {
            compact("Threshold", value: $state.splitThresholdDB, range: -60...(-10), step: 1,
                    caption: "\(Int(state.splitThresholdDB).formatted()) dB",
                    help: "How quiet counts as silence")
            compact("Min. silence", value: $state.splitMinimumSilence, range: 0.1...5, step: 0.1,
                    // Nach Sprache formatiert: „0,5 s", nicht „0.5 s".
                    caption: "\(state.splitMinimumSilence.formatted(.number.precision(.fractionLength(1)))) s",
                    help: "How long a silence must last to become a cut")
            compact("Shortest track", value: $state.splitMinimumTrackLength, range: 0...60, step: 1,
                    caption: state.splitMinimumTrackLength < 1
                        ? String(localized: "off")
                        : "\(Int(state.splitMinimumTrackLength).formatted()) s",
                    help: "Shorter pieces go to the neighbour they are closer to: applause to the song before, an intro after a long pause to the song after")
            Spacer(minLength: 8)
            Button("Look Up Titles…") { state.isShowingSplitLookup = true }
                .disabled(state.splitTracks.isEmpty || state.splitStage != .idle)
                .help("Name the tracks from MusicBrainz or from a pasted track list")
            if state.splitStage == .analyzing { ProgressView().controlSize(.small) }
            Button(state.splitTracks.isEmpty ? "Analyse" : "Analyse again") {
                state.analyzeSplit()
            }
            .disabled(state.splitBlocker != nil || state.splitStage != .idle
                      || state.splitSourceInfo == nil || state.isLoadingWaveform)
            .help("Finds the silences again — boundaries you moved by hand are replaced")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func compact(_ label: LocalizedStringKey, value: Binding<Double>,
                         range: ClosedRange<Double>, step: Double,
                         caption: String, help: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(caption).font(.caption.monospacedDigit())
            }
            Slider(value: value, in: range, step: step)
                .controlSize(.small)
                .frame(width: 130)
        }
        .help(Text(help))
    }
}

// MARK: - Übersicht

private struct OverviewStrip: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Group {
            if let waveform = state.splitWaveform, !waveform.isEmpty {
                WaveformView(
                    waveform: waveform,
                    window: 0...max(waveform.duration, 0.1),
                    tracks: state.splitTracks,
                    selectedID: state.splitSelectionID,
                    mark: state.splitMarkPosition,
                    playhead: state.splitPreview.position,
                    onClick: { seconds in
                        // In der Übersicht wählt ein Klick den Track, der dort
                        // liegt, und setzt die Marke an die Stelle.
                        if let track = state.splitTracks.first(where: {
                            seconds >= $0.range.start && seconds <= $0.range.end
                        }) {
                            state.selectSplitTrack(track.id)
                        }
                        state.setSplitMark(seconds)
                    })
                .help("The whole file. Click to choose a track and set the mark there.")
            } else {
                HStack(spacing: 8) {
                    if state.isLoadingWaveform { ProgressView().controlSize(.small) }
                    Text(state.isLoadingWaveform ? "Reading the file…" : "No waveform")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

// MARK: - Trackliste

private struct TrackList: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(state.splitTracks.enumerated()), id: \.element.id) { index, track in
                        TrackRow(index: index, track: track)
                            .id(track.id)
                        Divider()
                    }
                }
            }
            // Wird ein Track über die Übersicht gewählt, soll seine Zeile
            // sichtbar werden — sonst wählt man etwas, das man nicht sieht.
            .onChange(of: state.splitSelectionID) { _, id in
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}

private struct TrackRow: View {
    @Environment(AppState.self) private var state
    let index: Int
    let track: SplitTrack
    @FocusState private var titleFocused: Bool

    private var isSelected: Bool { state.splitSelectionID == track.id }
    private var isPlaying: Bool { state.splitPreview.playingID == track.id }

    var body: some View {
        HStack(spacing: 8) {
            Button { state.playAcrossStart(of: track) } label: {
                Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle")
                    .imageScale(.large)
            }
            .buttonStyle(.borderless)
            .disabled(state.splitPreview.unplayableReason != nil)
            .help("Listen across the start of this track")

            Text(verbatim: String(format: "%02d", index + 1))
                .monospacedDigit().foregroundStyle(.secondary)

            TextField("", text: Binding(get: { track.title }, set: { track.title = $0 }),
                      prompt: Text("Track \(index + 1)"))
                .textFieldStyle(.plain)
                .focused($titleFocused)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary.opacity(titleFocused ? 0.9 : 0.4)))

            VStack(alignment: .trailing, spacing: 1) {
                Text(Duration.seconds(track.range.duration)
                    .formatted(.time(pattern: .minuteSecond)))
                    .monospacedDigit()
                Text(verbatim: Timecode.format(track.range.start))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            .frame(width: 58, alignment: .trailing)

            // Von Hand verändert — sichtbar, damit man nichts vergisst.
            Circle()
                .fill(track.isAdjusted ? Color.accentColor : .clear)
                .frame(width: 6, height: 6)
                .help(track.isAdjusted ? String(localized: "Boundaries moved by hand") : "")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.18) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { state.selectSplitTrack(track.id) }
        .onChange(of: titleFocused) { _, focused in
            if focused { state.selectSplitTrack(track.id) }
        }
    }
}

// MARK: - Bearbeiter

private struct Editor: View {
    @Environment(AppState.self) private var state

    /// Wie weit eine Lupe nach beiden Seiten reicht. 20 Sekunden auf rund
    /// 300 Bildpunkte ergeben etwa 30 ms je Bildpunkt.
    static let lensHalfWidth: Double = 10

    var body: some View {
        if let track = state.selectedSplitTrack, let index = state.selectedSplitIndex {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(track, index: index)
                    lenses(track)
                    transport
                    actions(track, index: index)
                }
                .padding(14)
            }
        } else {
            Text("Choose a track on the left or in the waveform.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ track: SplitTrack, index: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(track.title.isEmpty ? String(localized: "Track \(index + 1)") : track.title)
                .font(.headline)
            Text(verbatim: "\(Timecode.format(track.range.start)) – \(Timecode.format(track.range.end))")
                .monospacedDigit().foregroundStyle(.secondary)
            Spacer()
            Text(Duration.seconds(track.range.duration).formatted(.time(pattern: .minuteSecond)))
                .monospacedDigit()
        }
    }

    // MARK: Lupen

    @ViewBuilder
    private func lenses(_ track: SplitTrack) -> some View {
        if let waveform = state.splitWaveform {
            HStack(alignment: .top, spacing: 12) {
                lens(title: "Start", edge: .start, center: track.range.start,
                     waveform: waveform, track: track)
                lens(title: "End", edge: .end, center: track.range.end,
                     waveform: waveform, track: track)
            }
        }
    }

    private func lens(title: LocalizedStringKey, edge: WaveformView.Edge, center: Double,
                      waveform: WaveformSampler.Waveform, track: SplitTrack) -> some View {
        let half = Self.lensHalfWidth
        let lower = max(0, center - half)
        let upper = min(waveform.duration, max(lower + 1, center + half))

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(edge == .start ? Color.green : .orange).frame(width: 8, height: 8)
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                TimeField(track: track, edge: edge)
            }
            WaveformView(
                waveform: waveform, window: lower...upper,
                tracks: state.splitTracks, selectedID: track.id,
                mark: state.splitMarkPosition, playhead: state.splitPreview.position,
                draggableEdge: edge,
                onClick: { state.setSplitMark($0) },
                onDragEdge: { seconds in
                    if edge == .start { state.moveSelectedStart(to: seconds) }
                    else { state.moveSelectedEnd(to: seconds) }
                })
            .frame(height: 110)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            Text(edge == .start
                 ? "Drag the green line · click sets the mark"
                 : "Drag the orange line · click sets the mark")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Abspielen

    private var transport: some View {
        @Bindable var preview = state.splitPreview
        return HStack(spacing: 12) {
            Button { state.toggleSplitPlayback() } label: {
                Label(state.isSplitPlaying ? "Stop" : "Play from mark",
                      systemImage: state.isSplitPlaying ? "stop.fill" : "play.fill")
            }
            .help("Play from the mark. Stopping moves the mark to where you stopped.")

            Button { state.jumpToStartBoundary() } label: {
                Image(systemName: "backward.end.fill")
            }
            .help("Play across the start")

            Button { state.jumpToEndBoundary() } label: {
                Image(systemName: "forward.end.fill")
            }
            .help("Play across the end")

            Text(verbatim: Timecode.format(state.splitCurrentPosition))
                .monospacedDigit()
                .foregroundStyle(state.isSplitPlaying ? .red : .secondary)
                .frame(width: 70, alignment: .leading)

            Spacer()

            Picker("Preview", selection: $preview.length) {
                ForEach([8.0, 14, 20, 30, 60], id: \.self) { seconds in
                    Text(verbatim: "\(Int(seconds)) s").tag(seconds)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help("How long each preview plays")
        }
        .disabled(state.splitPreview.unplayableReason != nil)
    }

    // MARK: Grenzen setzen

    private func actions(_ track: SplitTrack, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("Start here") { state.setSelectedStartHere() }
                    .disabled(state.splitCurrentPosition >= track.range.end - SplitTrack.minimumLength)
                Button("End here") { state.setSelectedEndHere() }
                    .disabled(state.splitCurrentPosition <= track.range.start + SplitTrack.minimumLength)
                Button("Split here") { state.splitHere() }
                    .disabled(!state.canSplitHere)
            }
            Text("These use what you hear: while playing the red playhead, otherwise the mark.")
                .font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("Join with previous") { state.mergeSelectedWithPrevious() }
                    .disabled(index == 0)
                    .help("Remove the boundary before this track")
                Button("Reset boundaries") { state.resetSelectedBoundaries() }
                    .disabled(!track.isAdjusted)
                    .help("Back to what the analysis found")
            }
        }
    }
}

/// Zeitfeld mit Stepper für Zehntelsekunden — der genaue Weg neben dem Ziehen.
private struct TimeField: View {
    @Environment(AppState.self) private var state
    let track: SplitTrack
    let edge: WaveformView.Edge

    var body: some View {
        HStack(spacing: 2) {
            TextField("", text: Binding(
                get: { edge == .start ? track.startText : track.endText },
                set: { if edge == .start { track.startText = $0 } else { track.endText = $0 } }))
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospacedDigit())
                .multilineTextAlignment(.trailing)
                .frame(width: 78)
                .onSubmit { apply() }
            Stepper("", onIncrement: { nudge(0.1) }, onDecrement: { nudge(-0.1) })
                .labelsHidden()
                .help("Move by a tenth of a second")
        }
    }

    /// Getippte Zeit übernehmen. Unlesbares wird verworfen: das Feld zeigt
    /// danach wieder den gültigen Wert.
    private func apply() {
        let text = edge == .start ? track.startText : track.endText
        if let seconds = Timecode.parse(text) { move(to: seconds) }
        track.startText = Timecode.format(track.range.start)
        track.endText = Timecode.format(track.range.end)
    }

    private func nudge(_ delta: Double) {
        move(to: (edge == .start ? track.range.start : track.range.end) + delta)
    }

    private func move(to seconds: Double) {
        if edge == .start { state.moveSelectedStart(to: seconds) }
        else { state.moveSelectedEnd(to: seconds) }
    }
}

// MARK: - Ausgabe

private struct OutputBar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("Folder").foregroundStyle(.secondary)
                HStack {
                    Text(state.splitDestination?.path ?? "—")
                        .lineLimit(1).truncationMode(.middle)
                    Button("Choose…") { chooseFolder() }
                }
                Text("Format").foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Picker("", selection: Binding(
                        get: { state.splitOutput }, set: { state.splitOutput = $0 })) {
                        Text(state.splitKeepSourceLabel).tag(SplitOutput.keepSource)
                        Divider()
                        ForEach(AudioFormat.allCases) { format in
                            Text(format.displayName).tag(SplitOutput.convert(format))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    if case let .convert(format) = state.splitOutput, !format.bitrates.isEmpty {
                        Picker("", selection: $state.splitBitrate) {
                            ForEach(format.bitrates, id: \.self) { rate in
                                Text("\(rate) kbit/s").tag(rate)
                            }
                        }
                        .labelsHidden().fixedSize()
                    }
                }
            }
            GridRow {
                Text("File name").foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("", text: $state.splitPattern, prompt: Text("Track number only"))
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 160)
                    Text(verbatim: "→ \(state.splitFilename(at: state.selectedSplitIndex ?? 0))")
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                .gridCellColumns(3)
            }
            if state.splitOutput.reencodes {
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    Label("Converting re-encodes. From a lossy source that means a second round of loss — keep the source format unless you need another one.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .gridCellColumns(3)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = state.splitDestination
        if panel.runModal() == .OK { state.splitDestination = panel.url }
    }
}

// MARK: - Fußzeile

private struct Footer: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 10) {
            status
            Spacer()
            if case .cutting = state.splitStage {
                Button("Stop", role: .cancel) { state.cancelSplit() }
            } else {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Split into \(state.splitTracks.count) tracks") { state.startSplit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!state.splitCanRun)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    /// Fortschritt, Ergebnis oder Fehler — immer hier, nie im scrollenden
    /// Teil. Eine Meldung, die man erst suchen muss, ist keine.
    @ViewBuilder
    private var status: some View {
        if case let .cutting(done, total) = state.splitStage {
            ProgressView(value: Double(done), total: Double(max(total, 1)))
                .progressViewStyle(.linear).frame(width: 140)
            Text("Cutting \(done + 1) of \(total)…").foregroundStyle(.secondary)
        } else if let message = state.splitError {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange).lineLimit(2)
        } else if !state.splitFailures.isEmpty {
            Label("\(state.splitFailures.count) pieces could not be written", systemImage: "xmark.octagon")
                .foregroundStyle(.red)
                .help(state.splitFailures.map { "\($0.filename): \($0.message)" }
                    .joined(separator: "\n"))
        } else if let result = state.splitCompleted {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text("\(result.count) tracks written — they are in the track list now.")
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(result.files)
            }
            .buttonStyle(.link)
        } else if let blocker = state.splitBlockerForFormat {
            Text(blocker).font(.callout).foregroundStyle(.orange).lineLimit(2)
        }
    }
}
