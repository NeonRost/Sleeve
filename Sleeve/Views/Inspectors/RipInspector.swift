//
//  RipInspector.swift
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
//  The Rip mode (spec §6).
//
//  The start button does **not** sit here but on the left of the toolbar,
//  in the same place as "Save" — and progress is in the footer. Both
//  because the section is long: at the bottom of a form, the most
//  important button scrolls out of view.
//

import SwiftUI

struct RipInspector: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        Form {
            if state.disc == nil {
                NoDiscSection()
            } else {
                DiscSection()
                TrackSelectionSection()
                FormatSection()
                ReadingSection()
                OutputSection()
                ResultSection()
            }
        }
        .formStyle(.grouped)
        .task {
            // The observer outlives this section — it hangs off AppState,
            // not off the view. Hence the brake here: `inspect()` opens the
            // drive, reads CD-TEXT, MCN and **every** ISRC and seeks to
            // every track for it. That is seconds of work on the drive and
            // has no business in the Tag section just because someone
            // plugged in a USB stick.
            state.discWatcher.start {
                guard state.activeMode == .rip else { return }
                Task { await state.refreshDisc() }
            }
            await state.refreshDisc()
        }
    }
}

// MARK: - Shared field style
//
// `LabeledContent` right-aligns the content and gives it only as much
// width as it currently needs — and folds it below the label as soon as
// that no longer fits. For a text field the desired width grows with the
// content, so of all things the longest entry ("Malte Arkona, Dresdner
// Philharmonie") tips into a second line, while short entries get fields
// of different widths.
//
// A fixed label column makes both impossible: all fields start at the same
// position, reach the edge and stay on one line.

private struct Row<Content: View>: View {
    let label: LocalizedStringKey
    @ViewBuilder var content: Content

    /// Wide enough for the longest label in this section, in Spanish too
    /// ("Compositor"; "Nombre de la carpeta" sits on its own).
    static var labelWidth: CGFloat { 96 }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .lineLimit(1)
                .frame(width: Self.labelWidth, alignment: .leading)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct LabeledField: View {
    let label: LocalizedStringKey
    @Binding var text: String
    var prompt: LocalizedStringKey?
    /// For placeholders that only emerge at runtime and therefore cannot
    /// be a translatable key.
    var placeholderText: String?

    var body: some View {
        Row(label: label) {
            TextField(label, text: $text,
                      prompt: placeholderText.map { Text($0) } ?? prompt.map { Text($0) })
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
        }
    }
}

/// A read-only row in the same grid.
private struct ReadOnlyRow<Content: View>: View {
    let label: LocalizedStringKey
    @ViewBuilder var content: Content

    var body: some View {
        Row(label: label) {
            content.foregroundStyle(.secondary)
        }
    }
}

// MARK: - No disc

private struct NoDiscSection: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Section {
            ContentUnavailableView {
                Label("No audio CD", systemImage: "opticaldisc")
            } description: {
                Text(state.discError ?? String(localized: "Insert an audio CD to begin."))
            } actions: {
                Button("Check again") {
                    Task { await state.refreshDisc() }
                }
                .disabled(state.isInspectingDisc)
            }
        }
    }
}

// MARK: - The disc

private struct DiscSection: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        Section("Disc") {
            LabeledField(label: "Album", text: $state.discAlbum)
            LabeledField(label: "Artist", text: $state.discArtist)
            LabeledField(label: "Year", text: $state.discYear, prompt: "unknown")
            LabeledField(label: "Genre", text: $state.discGenre, prompt: "unknown")
            LabeledField(label: "Composer", text: $state.discComposer, prompt: "unknown")

            // Only useful for multi-disc albums, hence behind a switch.
            Toggle("Part of a set", isOn: Binding(
                get: { state.discTotal > 1 },
                set: { state.discTotal = $0 ? max(2, state.discTotal) : 1 }))
            if state.discTotal > 1 {
                HStack {
                    Stepper(value: $state.discNumber, in: 1...state.discTotal) {
                        LabeledContent("Disc") {
                            Text("\(state.discNumber)").monospacedDigit()
                        }
                    }
                    Stepper(value: $state.discTotal, in: 2...30) {
                        LabeledContent("of") {
                            Text("\(state.discTotal)").monospacedDigit()
                        }
                    }
                }
            }

            if !state.discTrackArtists.isEmpty {
                Text("\(state.discTrackArtists.count) tracks carry their own artist — Sleeve keeps those.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let source = state.discMetadataSource {
                ReadOnlyRow(label: "Source") { Text(source.label) }
            }

            // Short labels, the explanation hangs off the mouse pointer —
            // full sentences get cut off here.
            HStack {
                Button("Look Up…") { state.isShowingDiscLookup = true }
                    .help("Find the disc at MusicBrainz or Discogs — by its disc ID, or by name")

                if state.disc?.cdText != nil {
                    Button("CD-TEXT") { state.applyCDText() }
                        .help("Take album, artist and titles from the disc itself")
                }
                Spacer()
            }

            if let disc = state.disc {
                if state.sourceDrives.count > 1 {
                    Row(label: "Drive") { SourceDrivePicker().labelsHidden() }
                } else {
                    ReadOnlyRow(label: "Drive") { Text(disc.drive.displayName) }
                }
                ReadOnlyRow(label: "Disc ID") {
                    Text(disc.discID)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
    }
}

// MARK: - Which tracks

private struct TrackSelectionSection: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        Section {
            ForEach(state.disc?.toc.audioTracks ?? []) { track in
                // The row sits in the **label** slot, the duration in the
                // content slot. The reason: `Form` right-aligns the content
                // slot and gives it only its desired width — there every title
                // field gets a different width, the text slides to the right,
                // and long titles blow up the row height. The label slot is
                // left-aligned and lets the field fill the width. Found by
                // trying, not derived.
                LabeledContent {
                    HStack(spacing: 8) {
                        Text(track.duration.formatted(.time(pattern: .minuteSecond)))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        if state.isRipping {
                            RipProgressBadge(track: track.number)
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        // Checkboxes, not switches — as known from every other
                        // ripper.
                        Toggle("", isOn: Binding(
                            get: { state.selectedRipTracks.contains(track.number) },
                            set: { on in
                                if on { state.selectedRipTracks.insert(track.number) }
                                else { state.selectedRipTracks.remove(track.number) }
                            }))
                        .toggleStyle(.checkbox)
                        .labelsHidden()

                        Text("\(track.number)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 22, alignment: .trailing)

                        TrackTitleField(
                            text: Binding(
                                get: { state.discTitles[track.number] ?? "" },
                                set: { state.discTitles[track.number] = $0 }),
                            prompt: Text("Track \(track.number)"))
                    }
                }
            }
        } header: {
            HStack {
                Text("Tracks")
                Spacer()
                Button("All") {
                    state.selectedRipTracks = Set(
                        (state.disc?.toc.audioTracks ?? []).map(\.number))
                }
                .buttonStyle(.link)
                .help("Select every track")
                Button("None") { state.selectedRipTracks = [] }
                    .buttonStyle(.link)
                    .help("Deselect every track")
            }
        }
    }
}

/// Uniform title fields: same width, same height, text on the left.
///
/// `.textFieldStyle(.roundedBorder)` insists on its own content-dependent
/// width and cannot be talked out of it by `frame(maxWidth:)` — measured.
/// Hence the plain field with a self-drawn background, as in the track list.
private struct TrackTitleField: View {
    @Binding var text: String
    let prompt: Text

    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $text, prompt: prompt)
            .textFieldStyle(.plain)
            .lineLimit(1)
            .focused($isFocused)
            .padding(.horizontal, 6)
            .frame(height: 22)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(.quaternary.opacity(isFocused ? 0.9 : 0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.accentColor, lineWidth: isFocused ? 2 : 0)
            )
    }
}

private struct RipProgressBadge: View {
    @Environment(AppState.self) private var state
    let track: Int

    var body: some View {
        if let fraction = state.ripProgress[track] {
            if fraction >= 1 {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                ProgressView(value: fraction).frame(width: 54)
            }
        } else {
            Color.clear.frame(width: 54, height: 1)
        }
    }
}

// MARK: - Target format

private struct FormatSection: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        Section("Format") {
            Picker("Format", selection: $state.ripSettings.format) {
                ForEach(AudioFormat.allCases) { format in
                    Text(format.displayName).tag(format)
                }
            }
            .help("WAV is written straight from the disc and needs no ffmpeg")

            if !state.ripSettings.format.bitrates.isEmpty {
                Picker("Bitrate", selection: $state.ripSettings.bitrate) {
                    ForEach(state.ripSettings.format.bitrates, id: \.self) { value in
                        Text("\(value) kbit/s").tag(value)
                    }
                }
            }
            if state.ripSettings.format == .flac {
                Stepper(value: $state.ripSettings.compressionLevel, in: 0...12) {
                    LabeledContent("Compression") {
                        Text("\(state.ripSettings.compressionLevel)").monospacedDigit()
                    }
                }
            }

            if let blocker = state.ripBlocker, state.ripSettings.needsFFmpeg,
               state.ffmpeg == nil || state.ffmpeg?.supports(state.ripSettings.format) == false {
                Label(blocker, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - How reading works

private struct ReadingSection: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        Section("Reading") {
            Picker("Mode", selection: $state.ripSettings.mode) {
                ForEach(RipMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            // The explanation sits below the picker — in the menu it would be
            // cut off.
            Text(state.ripSettings.mode.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if state.ripSettings.mode == .secure {
                Stepper(value: $state.ripSettings.maxRetries, in: 1...100) {
                    LabeledContent("Maximum retries") {
                        Text("\(state.ripSettings.maxRetries)").monospacedDigit()
                    }
                }
                Toggle("Read every track twice and compare",
                       isOn: $state.ripSettings.testBeforeCopy)
                    .help("Takes twice as long and needs no external database")
            }

            Toggle("Use C2 error pointers", isOn: $state.ripSettings.usesC2)
                .disabled(state.disc?.supportsC2 == false)
                .help("Lets the drive report which bytes it could not read")
            if state.disc?.supportsC2 == false {
                Text("This drive does not deliver usable C2 pointers — Sleeve checked. Reading continues without them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LabeledContent("Read offset") {
                HStack(spacing: 6) {
                    TextField("", value: $state.ripSettings.readOffset, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                    Text("samples").foregroundStyle(.secondary)
                }
            }
            .help("Drive-specific correction, in samples")
            Text("Sleeve does not look this up — enter the value your drive is known for, or leave it at zero.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Speed", selection: $state.ripSettings.speedMultiplier) {
                Text("Automatic").tag(Int?.none)
                ForEach([1, 2, 4, 6, 8, 10, 12, 16], id: \.self) { value in
                    Text("\(value)×").tag(Int?.some(value))
                }
            }
            .help("Reading slower often helps more than retrying on scratched discs")
        }
    }
}

// MARK: - Where to

private struct OutputSection: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        Section("Output") {
            Row(label: "Location") {
                HStack {
                    Text(state.ripDestinationFolder.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button("Choose…") { chooseFolder() }
                        .help("Pick where the album folder is created")
                }
            }
            // A field, not text: it *is* editable, and one has to see that.
            // Leaving it empty means "take the suggestion" — which is why the
            // suggestion is in there as a placeholder, not as a value.
            LabeledField(label: "Folder name", text: $state.ripFolderName,
                         prompt: nil, placeholderText: state.suggestedAlbumFolderName)

            // The pattern spans the full width and wraps. A single line with
            // an ellipsis would be useless here: one is putting the pattern
            // together right now and wants to see what comes out.
            VStack(alignment: .leading, spacing: 5) {
                Text("File name")
                TextField("", text: $state.ripSettings.filenamePattern,
                          prompt: Text("Track number only"), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    Spacer()
                    Button("Reset") {
                        state.ripSettings.filenamePattern =
                            RipSettings.defaultFilenamePattern
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .disabled(state.ripSettings.filenamePattern
                        == RipSettings.defaultFilenamePattern)
                    .help("Back to track number and title")
                }
            }

            // The building blocks get a block of their own, set apart.
            // Without the separation they looked as if they belonged to the
            // input field — whereas they are a supply to help oneself from.
            TokenHints()

            if let first = state.selectedRipTracks.min() {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Example")
                    Text(state.previewFilename(forTrack: first))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Toggle("Write a rip log", isOn: $state.ripSettings.writesLog)
                .help("Records mode, offset, checksums and anything that went wrong")
            Toggle("Write a cue sheet", isOn: $state.ripSettings.writesCueSheet)
            Toggle("Eject when finished", isOn: $state.ripSettings.ejectsWhenDone)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = state.ripDestinationFolder
        if panel.runModal() == .OK { state.ripDestination = panel.url }
    }
}

/// The placeholders to click — nobody has to type them.
///
/// The order is by usefulness, not alphabetical: for a file name one
/// almost always reaches for track number and title first.
private struct TokenHints: View {
    @Environment(AppState.self) private var state

    private static let order: [PatternToken] = [
        .track, .title, .artist, .album, .albumartist, .disc, .year, .genre, .composer,
    ]

    var body: some View {
        @Bindable var state = state

        VStack(alignment: .leading, spacing: 6) {
            Text("Available tags")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            FlowLayout {
                ForEach(Self.order) { token in
                    Button(token.placeholder) {
                        state.ripSettings.filenamePattern =
                            token.appended(to: state.ripSettings.filenamePattern)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(.caption.monospaced())
                    // Without this the layout squeezes the label until it breaks
                    // in the middle of a word.
                    .fixedSize()
                }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(.quaternary.opacity(0.5))
        )
    }
}

// MARK: - Result

private struct ResultSection: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if state.ripReport != nil || !state.ripFailures.isEmpty {
            Section("Result") {
                if let report = state.ripReport {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(report.allAccurate
                              ? "All tracks read without complaint"
                              : "At least one track could not be read reliably",
                              systemImage: report.allAccurate
                              ? "checkmark.seal" : "exclamationmark.triangle")
                            .foregroundStyle(report.allAccurate ? .green : .orange)

                        // Stay honest: this is a statement about repeatability,
                        // not about correctness.
                        Text("Checked against this drive, not against other people's rips.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(state.ripFailures) { failure in
                    Label("\(failure.filename): \(failure.message)",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }
        }
    }
}
