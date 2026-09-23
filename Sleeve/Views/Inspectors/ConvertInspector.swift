//
//  ConvertInspector.swift
//  Sleeve
//
//  Modus „Konvertieren" (Spec §5).
//

import AppKit
import SwiftUI

struct ConvertInspector: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        Form {
            // Fehlt ffmpeg, steht die Erklärung oben und allein — dann ist sie
            // das Einzige, was zählt. Ist es da, interessiert es niemanden
            // mehr und rutscht nach ganz unten.
            if state.ffmpeg == nil {
                FFmpegMissingSection()
            }

            if let ffmpeg = state.ffmpeg {
                Section("Target format") {
                    Picker("Format", selection: $state.conversionSettings.format) {
                        ForEach(AudioFormat.allCases) { format in
                            Text(format.displayName)
                                .tag(format)
                        }
                    }
                    // Formate, die dieses ffmpeg nicht kann, bleiben sichtbar
                    // und werden erklärt — verschwinden wäre verwirrend.
                    if !ffmpeg.supports(state.conversionSettings.format) {
                        Label(state.conversionSettings.format.missingEncoderHint,
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    } else if let encoder = ffmpeg.encoder(for: state.conversionSettings.format) {
                        Text("Encoder: \(encoder)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if state.conversionSettings.format.supportsBitrate {
                        Picker("Bitrate", selection: $state.conversionSettings.bitrate) {
                            ForEach(state.conversionSettings.format.bitrates, id: \.self) { rate in
                                Text("\(rate) kbit/s").tag(rate)
                            }
                        }
                    }
                    if state.conversionSettings.format.supportsCompressionLevel {
                        Picker("Compression", selection: $state.conversionSettings.compressionLevel) {
                            ForEach([0, 5, 8, 12], id: \.self) { level in
                                Text(Self.compressionLabel(level)).tag(level)
                            }
                        }
                        .help("Higher means smaller files and slower encoding — the audio is identical either way")
                    }
                }

                DestinationSection()
                RunSection()
                FFmpegSection()
            }
        }
        .formStyle(.grouped)
    }

    private static func compressionLabel(_ level: Int) -> LocalizedStringKey {
        switch level {
        case 0:  "0 — fastest"
        case 5:  "5 — default"
        case 8:  "8 — smaller"
        default: "12 — smallest"
        }
    }
}

// MARK: - ffmpeg

/// Das gefundene ffmpeg. Steht am Ende der Liste — nach der Installation
/// interessiert es nicht mehr.
private struct FFmpegSection: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if let ffmpeg = state.ffmpeg {
            Section("ffmpeg") {
                LabeledContent("Version") {
                    Text(ffmpeg.version).monospaced()
                }
                LabeledContent("Path") {
                    Text(ffmpeg.url.path(percentEncoded: false))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Text(formatSummary(ffmpeg))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Search Again") { Task { await state.locateFFmpeg() } }
                    Button("Choose Manually…") { Task { await state.chooseFFmpegManually() } }
                    if state.customFFmpegPath != nil {
                        Button("Use Automatic") { Task { await state.forgetCustomFFmpegPath() } }
                    }
                }
                .disabled(state.isLocatingFFmpeg)
            }
        }
    }

    private func formatSummary(_ ffmpeg: FFmpegTool) -> String {
        let available = ffmpeg.availableFormats.map(\.displayName)
        let missing = AudioFormat.allCases.filter { !ffmpeg.supports($0) }.map(\.displayName)
        if missing.isEmpty {
            return String(localized: "All formats available.")
        }
        return String(localized: "Available: \(available.joined(separator: ", ")). Missing: \(missing.joined(separator: ", ")).")
    }
}

/// Was zu tun ist, wenn ffmpeg fehlt. Stumm scheitern soll der Modus nie
/// (Spec §2.2) — und die Anleitung muss zum Rechner passen: ohne Homebrew
/// bringt `brew install ffmpeg` niemanden weiter.
private struct FFmpegMissingSection: View {
    @Environment(AppState.self) private var state

    private static let installFFmpeg = "brew install ffmpeg"
    private static let installHomebrew =
        #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Label("ffmpeg was not found", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)

                Text("Sleeve does not ship ffmpeg — it uses the one on your system.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if state.homebrew == nil {
                    // Erst der Paketverwalter, dann das Programm.
                    Text("Step 1 — install Homebrew, a package manager for macOS:")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    CommandRow(command: Self.installHomebrew)
                    Link("What is Homebrew?", destination: URL(string: "https://brew.sh")!)
                        .font(.caption)

                    Text("Step 2 — then install ffmpeg:")
                        .font(.callout)
                        .padding(.top, 2)
                    CommandRow(command: Self.installFFmpeg)
                } else {
                    Text("The simplest way is Homebrew, which you already have:")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    CommandRow(command: Self.installFFmpeg)
                }

                Divider()

                Text("Already have an ffmpeg somewhere else? Point Sleeve at it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("Search Again") { Task { await state.locateFFmpeg() } }
                    Button("Choose Manually…") { Task { await state.chooseFFmpegManually() } }
                    if state.isLocatingFFmpeg {
                        ProgressView().controlSize(.small)
                    }
                }
                .disabled(state.isLocatingFFmpeg)
            }
            .padding(.vertical, 4)
        }
    }
}

/// Ein Befehl zum Auswählen und Kopieren. Ausgeführt wird hier nichts —
/// das bleibt bewusst beim Nutzer im Terminal.
private struct CommandRow: View {
    let command: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(command)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .help("Copy the command")
        }
    }
}

// MARK: - Ziel

private struct DestinationSection: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        Section("Destination") {
            LabeledContent("Folder") {
                HStack {
                    Text(state.conversionSettings.destinationFolder?.lastPathComponent
                         ?? String(localized: "Next to the original"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { state.chooseDestinationFolder() }
                    if state.conversionSettings.destinationFolder != nil {
                        Button {
                            state.conversionSettings.destinationFolder = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .help("Put converted files next to their originals again")
                    }
                }
            }

            LabeledContent("File name") {
                HStack(spacing: 6) {
                    TextField("", text: $state.conversionSettings.filenamePattern,
                              prompt: Text("Keep the original name"))
                        .textFieldStyle(.roundedBorder)
                    TokenMenu(pattern: $state.conversionSettings.filenamePattern)
                }
            }

            Toggle("Keep originals", isOn: $state.conversionSettings.keepsOriginals)
            if !state.conversionSettings.keepsOriginals {
                Label("The source files are deleted once the converted file is written and tagged.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Start

private struct RunSection: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Section {
            if let blocker = state.conversionBlocker, !state.isBusy {
                Text(blocker)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button {
                    Task { await state.convert() }
                } label: {
                    Label("Convert \(state.operationTargets.count) Tracks",
                          systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(state.conversionBlocker != nil || state.isBusy)

                if state.isBusy {
                    Button("Cancel") { state.cancelConversion() }
                }
            }

            // Tags werden nach der Umwandlung selbst geschrieben — das ist der
            // Grund, warum es diesen Modus überhaupt gibt (Spec §5).
            Text("Tags and artwork are read before converting and written back afterwards, so nothing gets lost on the way.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
