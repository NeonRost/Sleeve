//
//  RipInspector.swift
//  Sleeve
//
//  Modus „Rippen" (Spec §6).
//
//  Der Startknopf sitzt **nicht** hier, sondern links in der Werkzeugleiste,
//  an derselben Stelle wie „Speichern" — und der Fortschritt steht in der
//  Fußzeile. Beides, weil der Bereich lang ist: unten in einem Formular
//  scrollt der wichtigste Knopf aus dem Bild.
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
            // Der Beobachter überlebt diesen Bereich — er hängt an AppState,
            // nicht an der Ansicht. Deshalb hier die Bremse: `inspect()`
            // öffnet das Laufwerk, liest CD-TEXT, MCN und **jede** ISRC und
            // fährt dafür jede Spur an. Das ist sekundenlange Arbeit am
            // Laufwerk und hat im Tag-Bereich nichts zu suchen, bloß weil
            // jemand einen USB-Stick angesteckt hat.
            state.discWatcher.start {
                guard state.activeMode == .rip else { return }
                Task { await state.refreshDisc() }
            }
            await state.refreshDisc()
        }
    }
}

// MARK: - Gemeinsamer Feldstil
//
// `LabeledContent` richtet den Inhalt rechts aus und gibt ihm nur so viel
// Breite, wie er gerade braucht — und klappt ihn unter die Beschriftung,
// sobald das nicht mehr passt. Beim Textfeld wächst die Wunschbreite mit dem
// Inhalt, also kippt ausgerechnet die längste Angabe („Malte Arkona, Dresdner
// Philharmonie") in eine zweite Zeile, während kurze Angaben unterschiedlich
// breite Felder bekommen.
//
// Eine feste Beschriftungsspalte macht beides unmöglich: alle Felder beginnen
// an derselben Stelle, reichen bis zum Rand und bleiben einzeilig.

private struct Row<Content: View>: View {
    let label: LocalizedStringKey
    @ViewBuilder var content: Content

    /// Breit genug für die längste Beschriftung in diesem Bereich, auch auf
    /// Spanisch („Compositor", „Nombre de la carpeta" steht einzeln).
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
    /// Für Platzhalter, die sich zur Laufzeit ergeben und deshalb kein
    /// übersetzbarer Schlüssel sein können.
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

/// Nur-lesende Zeile im selben Raster.
private struct ReadOnlyRow<Content: View>: View {
    let label: LocalizedStringKey
    @ViewBuilder var content: Content

    var body: some View {
        Row(label: label) {
            content.foregroundStyle(.secondary)
        }
    }
}

// MARK: - Keine Scheibe

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

// MARK: - Die Scheibe

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

            // Nur bei Mehrfachalben nützlich, deshalb hinter einem Schalter.
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

            // Kurze Beschriftungen, die Erklärung hängt am Mauszeiger —
            // ausgeschriebene Sätze werden hier abgeschnitten.
            HStack {
                Button("MusicBrainz") {
                    Task { await state.lookupDisc() }
                }
                .disabled(state.isLookingUpDisc)
                .help("Identify the disc through its disc ID at MusicBrainz")

                if state.isLookingUpDisc { ProgressView().controlSize(.small) }

                if state.disc?.cdText != nil {
                    Button("CD-TEXT") { state.applyCDText() }
                        .help("Take album, artist and titles from the disc itself")
                }
                Spacer()
            }

            if let message = state.discLookupMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if state.discLookupCandidates.count > 1 {
                Picker("Pressing", selection: Binding(
                    get: { state.discLookupCandidates.first?.id ?? "" },
                    set: { id in
                        if let match = state.discLookupCandidates.first(where: { $0.id == id }) {
                            state.apply(match)
                        }
                    })) {
                    ForEach(state.discLookupCandidates, id: \.id) { release in
                        Text(Self.describe(release)).tag(release.id)
                    }
                }
                .help("Several pressings share this table of contents")
            }

            if let disc = state.disc {
                ReadOnlyRow(label: "Drive") { Text(disc.drive.displayName) }
                ReadOnlyRow(label: "Disc ID") {
                    Text(disc.discID)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
    }

    static func describe(_ release: LookupRelease) -> String {
        [release.title, release.year.map(String.init), release.country]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

// MARK: - Welche Tracks

private struct TrackSelectionSection: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        Section {
            ForEach(state.disc?.toc.audioTracks ?? []) { track in
                // Die Zeile steht im **Beschriftungs**-Platz, die Dauer im
                // Inhaltsplatz. Grund: `Form` richtet den Inhaltsplatz rechts
                // aus und gibt ihm nur die Wunschbreite — dort bekommt jedes
                // Titelfeld eine andere Breite, der Text rutscht nach rechts,
                // und lange Titel sprengen die Zeilenhöhe. Der
                // Beschriftungsplatz ist linksbündig und lässt das Feld die
                // Breite füllen. Ausprobiert, nicht hergeleitet.
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
                        // Kästchen, nicht Schalter — so kennt man es aus jedem
                        // anderen Ripper.
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

/// Einheitliche Titelfelder: gleiche Breite, gleiche Höhe, Text links.
///
/// `.textFieldStyle(.roundedBorder)` setzt seine eigene, inhaltsabhängige
/// Breite durch und lässt sich von `frame(maxWidth:)` nicht davon abbringen —
/// gemessen. Deshalb das schlichte Feld mit selbst gezeichnetem Hintergrund,
/// wie in der Trackliste auch.
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

// MARK: - Zielformat

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

// MARK: - Wie gelesen wird

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
            // Die Erklärung steht unter der Auswahl — im Menü würde sie
            // abgeschnitten.
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

// MARK: - Wohin

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
            // Als Feld, nicht als Text: es *ist* änderbar, und das muss man
            // sehen. Leer lassen heißt „nimm den Vorschlag" — deshalb steht
            // der Vorschlag als Platzhalter drin, nicht als Wert.
            LabeledField(label: "Folder name", text: $state.ripFolderName,
                         prompt: nil, placeholderText: state.suggestedAlbumFolderName)

            // Muster und Ergebnis stehen über die volle Breite und brechen um.
            // Eine Zeile mit Auslassung wäre hier nutzlos: man baut das Muster
            // ja gerade zusammen und will sehen, was dabei herauskommt.
            // Das Muster steht über die volle Breite und bricht um. Eine
            // Zeile mit Auslassung wäre hier nutzlos: man baut es ja gerade
            // zusammen und will sehen, was dabei herauskommt.
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

            // Die Bausteine bekommen einen eigenen, abgesetzten Block. Ohne
            // die Abgrenzung sahen sie aus, als gehörten sie zum Eingabefeld
            // — dabei sind sie ein Vorrat, aus dem man sich bedient.
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

/// Die Platzhalter zum Anklicken — abtippen muss sie niemand.
///
/// Die Reihenfolge ist nach Nutzen sortiert, nicht alphabetisch: für einen
/// Dateinamen greift man fast immer zuerst zu Tracknummer und Titel.
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
                    // Ohne das quetscht das Layout die Beschriftung, bis sie
                    // mitten im Wort umbricht.
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

// MARK: - Ergebnis

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

                        // Ehrlich bleiben: das ist eine Aussage über
                        // Wiederholbarkeit, nicht über Richtigkeit.
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
