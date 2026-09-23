//
//  BurnSheet.swift
//  Sleeve
//
//  Zurückbrennen (Spec §6.10).
//
//  Zwei Dinge unterscheiden dieses Blatt von allen anderen:
//
//  1. Der **Probelauf** ist der hervorgehobene Knopf, nicht der echte Brand.
//     Er läuft mit abgeschaltetem Laser durch und lässt den Rohling
//     unbeschrieben.
//  2. Der echte Brand fragt nach. Er ist die einzige Funktion in Sleeve, die
//     etwas Materielles unwiderruflich verbraucht.
//
//  Dazu der Hinweis, dass dieser Teil als einziger nie an echter Hardware
//  lief — das gehört sichtbar in die Oberfläche, nicht nur in die Spec.
//

import SwiftUI

struct BurnSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var state = state

        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            Form {
                Section("Image") {
                    LabeledContent("Cue sheet") {
                        HStack {
                            Text(state.burnCueURL?.lastPathComponent
                                 ?? String(localized: "none picked"))
                                .foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                            Button("Choose…") { state.chooseBurnImage() }
                        }
                    }
                    if let cue = state.burnCue, let layout = state.burnLayout {
                        LabeledContent("Album") {
                            Text(cue.albumTitle ?? "—").foregroundStyle(.secondary)
                        }
                        LabeledContent("Tracks") {
                            Text(verbatim: "\(layout.tracks.count)").foregroundStyle(.secondary)
                        }
                        LabeledContent("Length") {
                            Text(state.burnTotalDuration.formatted(.time(pattern: .minuteSecond)))
                                .foregroundStyle(.secondary)
                        }
                        LabeledContent("Audio") {
                            Text(cue.audioFileName)
                                .foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        if state.burnNeedsDecoding {
                            Text("A FLAC image is unpacked to a temporary file first — the drive only takes raw audio.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Section("Drive") {
                    LabeledContent("Drive") {
                        Text(state.burnDevice?.displayName ?? String(localized: "none found"))
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Disc") {
                        Text(discText).foregroundStyle(.secondary)
                    }
                    Button("Check again") { state.refreshBurnMedia() }
                }

                Section {
                    Label("The burn itself has never run on real hardware — there was no blank disc to test with. Everything before it is verified. Use the test run first.",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let message = state.burnError {
                    Section {
                        Label(message, systemImage: "xmark.octagon")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            footer
        }
        .frame(width: 480, height: 580)
        .task { state.refreshBurnMedia() }
        .confirmationDialog("Burn this disc for real?",
                            isPresented: $state.isConfirmingBurn) {
            Button("Burn", role: .destructive) { state.startBurn(simulated: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The blank is written once and cannot be reused. A test run costs nothing and checks everything except the writing itself.")
        }
    }

    private var discText: String {
        switch state.burnMedia {
        case .noDrive:              String(localized: "No optical drive found.")
        case .noDisc:               String(localized: "Insert a blank CD-R.")
        case .unusable(let reason): reason
        case .blank(let sectors):
            sectors > 0
                ? String(localized: "Blank — room for \(sectors / 75 / 60) minutes")
                : String(localized: "Blank")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Burn Image to CD").font(.headline)
            Text("Writes a BIN, WAV or FLAC image back onto a blank CD-R, with the track boundaries from its cue sheet.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            switch state.burnStage {
            case .running(let simulated):
                ProgressView(value: state.burnProgress)
                    .progressViewStyle(.linear).frame(width: 130)
                Text(simulated ? "Test run…" : "Burning…").foregroundStyle(.secondary)
                Spacer()
                Button("Stop", role: .cancel) { state.cancelBurn() }

            case .done(let simulated):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(simulated
                     ? "Test run finished — nothing was written"
                     : "Disc burned")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)

            case .idle:
                if let blocker = state.burnBlocker {
                    Text(blocker).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Burn for real…") { state.isConfirmingBurn = true }
                    .disabled(state.burnBlocker != nil)
                Button("Test run") { state.startBurn(simulated: true) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.burnBlocker != nil)
            }
        }
        .padding(14)
    }
}
