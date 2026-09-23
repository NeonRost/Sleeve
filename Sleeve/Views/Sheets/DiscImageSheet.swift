//
//  DiscImageSheet.swift
//  Sleeve
//
//  Ein Blatt, kein eigenes Fenster: der Vorgang hängt an der eingelegten
//  Scheibe, die das Hauptfenster ohnehin zeigt. Ein frei schwebendes Fenster
//  würde diesen Bezug verlieren.
//
//  Die Leseeinstellungen sind an dieselben Werte gebunden wie der Rip-Bereich.
//  Zwei Sätze davon wären eine sichere Fehlerquelle — dass ein Regler an zwei
//  Stellen auftaucht, ist dagegen üblich.
//

import SwiftUI

struct DiscImageSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var state = state

        VStack(alignment: .leading, spacing: 0) {
            header

            // Ergebnis und Fehler stehen **über** dem Formular, nicht darin.
            // Im Formular landen sie unter „Lesen" und damit im scrollenden
            // Teil — fertig gemeldet, aber ungesehen. Derselbe Fehler wie
            // beim Rip-Fortschritt, der deshalb in der Fußzeile steht.
            if state.imageResult != nil || state.imageError != nil {
                Divider()
                banner
            }

            Divider()

            Form {
                if let disc = state.disc {
                    DiscFacts(disc: disc)
                } else {
                    Section {
                        Label(state.discError ?? String(localized: "No audio CD in the drive."),
                              systemImage: "opticaldisc")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Image") {
                    Picker("Format", selection: $state.imageFormat) {
                        ForEach(DiscImageFormat.allCases) { format in
                            Text(format.label).tag(format)
                        }
                    }
                    Text(state.imageFormat.hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    LabeledContent("Name") {
                        TextField("", text: $state.imageBaseName,
                                  prompt: Text(state.suggestedImageName))
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("Writes") {
                        Text(verbatim: "\(state.effectiveImageName).\(state.imageFormat.fileExtension) + .cue")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    LabeledContent("Size") {
                        Text(state.estimatedImageSize).foregroundStyle(.secondary)
                    }
                    LabeledContent("Folder") {
                        HStack {
                            Text(state.ripDestinationFolder.path)
                                .lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(.secondary)
                            Button("Choose…") { chooseFolder() }
                        }
                    }
                }

                Section("Reading") {
                    Picker("Mode", selection: $state.ripSettings.mode) {
                        ForEach(RipMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    LabeledContent("Read offset") {
                        HStack(spacing: 6) {
                            TextField("", value: $state.ripSettings.readOffset, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 64)
                            Text("samples").foregroundStyle(.secondary)
                        }
                    }
                    Text("These are the same settings the Rip section uses.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            }
            .formStyle(.grouped)

            Divider()
            footer
        }
        .frame(width: 460, height: 560)
    }

    // MARK: - Kopf und Fuß

    @ViewBuilder
    private var banner: some View {
        if let message = state.imageError {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        } else if let result = state.imageResult {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: result.isClean ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(result.isClean ? .green : .orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text(result.isClean
                         ? "Image created — read without complaint"
                         : "Image created — not everything read reliably")
                        .fontWeight(.medium)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: "\(result.audioURL.lastPathComponent)  ·  CRC32 \(String(format: "%08X", result.crc))")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Button("Show in Finder") { state.revealImage() }
            }
            .padding(14)
        }
    }

    private var header: some View {
        // Mehr Luft unter der Überschrift: der Erklärsatz klebte daran.
        VStack(alignment: .leading, spacing: 7) {
            Text("Create Disc Image").font(.headline)
            // Die Frage kommt sonst sofort — also gleich beantworten.
            Text("Not an ISO: an audio CD has no file system. Sleeve writes the audio in one piece plus a cue sheet with the track boundaries.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if state.imageStage == .reading || state.imageStage == .converting {
                ProgressView(value: state.imageStage == .reading ? state.imageProgress : 1)
                    .progressViewStyle(.linear)
                    .frame(width: 130)
                Text(state.imageStage == .reading ? "Reading the disc…" : "Converting…")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Stop", role: .cancel) { state.cancelImage() }
            } else {
                if let blocker = state.imageBlocker {
                    Text(blocker)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Image") { state.startImage() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.imageBlocker != nil)
            }
        }
        .padding(14)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = state.ripDestinationFolder
        if panel.runModal() == .OK { state.ripDestination = panel.url }
    }
}

private struct DiscFacts: View {
    let disc: DiscSnapshot

    var body: some View {
        Section("Disc") {
            LabeledContent("Album") {
                Text(disc.cdText?.albumTitle ?? "—").foregroundStyle(.secondary)
            }
            LabeledContent("Tracks") {
                Text(verbatim: "\(disc.toc.audioTracks.count)").foregroundStyle(.secondary)
            }
            LabeledContent("Length") {
                Text(disc.toc.totalDuration.formatted(.time(pattern: .minuteSecond)))
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Drive") {
                Text(disc.drive.displayName).foregroundStyle(.secondary)
            }
        }
    }
}
