//
//  BurnSheet.swift
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
//  Burning back to disc (spec §6.10).
//
//  Two things set this sheet apart from all others:
//
//  1. The **test run** is the prominent button, not the real burn. It runs
//     through with the laser switched off and leaves the blank unwritten.
//  2. The real burn asks for confirmation. It is the only function in
//     Sleeve that irrevocably uses up something physical.
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
                    BurnerRow()
                    LabeledContent("Disc") {
                        Text(discText).foregroundStyle(.secondary)
                    }
                    Button("Check again") { state.refreshBurnMedia() }
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
        if state.burnStage == .idle, let blocker = state.burnBlocker {
            Text(blocker)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 14)
                .padding(.top, 12)
        }
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
                // Three buttons leave no room for a sentence next to them —
                // it was cut off, and "Burn for real…" with it. The reason
                // sits above the buttons instead.
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
