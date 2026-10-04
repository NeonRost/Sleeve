//
//  CopyDiscSheet.swift
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
//  File → Copy CD… (spec §6.11). One button. What the other two disc sheets
//  let one set — format, name, folder, test run — is decided here: BIN in a
//  temporary folder, the Rip section's read settings, burned for real.
//
//  What is going on sits above the form, as in the image sheet: "insert a
//  blank" must not scroll away.
//

import SwiftUI

struct CopyDiscSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if let banner = bannerContent {
                Divider()
                banner
            }

            Divider()

            Form {
                Section("Original") {
                    if let toc = state.copySourceTOC {
                        SourceDriveRow()
                        if let album = albumTitle {
                            LabeledContent("Album") {
                                Text(album).foregroundStyle(.secondary)
                            }
                        }
                        facts(tracks: toc.audioTracks.count, length: toc.totalDuration)
                    } else if let image = state.copyImage {
                        // The original is out — what was read stands in for it.
                        LabeledContent("Original") {
                            Text("Read, the disc is no longer needed").foregroundStyle(.secondary)
                        }
                        facts(tracks: image.layout.tracks.count, length: image.duration)
                    } else {
                        SourceDriveRow()
                    }
                }

                // Not "Blank": that key is the state of a disc ("Leer" in German).
                Section("The copy") {
                    BurnerRow()
                    if state.copyStage == .idle || state.copyStage == .done {
                        LabeledContent("Disc") {
                            Text(blankText).foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Text(state.copyUsesOneDrive
                         ? "Sleeve reads the original, ejects it and asks for a blank. The read settings are those of the Rip section."
                         : "Sleeve reads the original and burns the copy in the other drive. The read settings are those of the Rip section.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if state.disc?.cdText != nil {
                        Text("Titles stored on the disc as CD-TEXT are not copied.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            footer
        }
        .frame(width: 460, height: 520)
        .task {
            // Drives come and go, discs too. Only while nothing runs: during
            // reading and burning the drives have other things to do.
            while !Task.isCancelled {
                if state.copyStage == .idle || state.copyStage == .done {
                    state.refreshCopyDrives()
                }
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
        .onDisappear { state.endCopy() }
    }

    @ViewBuilder
    private func facts(tracks: Int, length: Duration) -> some View {
        LabeledContent("Tracks") {
            Text(verbatim: "\(tracks)").foregroundStyle(.secondary)
        }
        LabeledContent("Length") {
            Text(length.formatted(.time(pattern: .minuteSecond))).foregroundStyle(.secondary)
        }
    }

    /// The album, if the Rip section has read the same disc.
    private var albumTitle: String? {
        guard let disc = state.disc,
              disc.drive.bsdName == state.effectiveSourceDrive?.bsdName else { return nil }
        let title = state.discAlbum.isEmpty ? disc.cdText?.albumTitle : state.discAlbum
        return title?.isEmpty == false ? title : nil
    }

    private var blankText: String {
        switch state.burnMedia {
        case .noDrive:              String(localized: "No optical drive found.")
        case .noDisc:               state.copyUsesOneDrive
                                        ? String(localized: "Asked for after reading")
                                        : String(localized: "Insert a blank CD-R.")
        case .unusable(let reason): state.copyUsesOneDrive ? String(localized: "Asked for after reading") : reason
        case .blank:                String(localized: "Blank")
        }
    }

    // MARK: - Banner

    private var bannerContent: AnyView? {
        if case .waitingForBlank(let problem) = state.copyStage {
            return AnyView(
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "opticaldisc")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Insert a blank CD-R").fontWeight(.medium)
                        Text(problem ?? String(localized: "The copy starts as soon as the blank is recognized."))
                            .font(.callout)
                            .foregroundStyle(problem == nil ? Color.secondary : Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14))
        }
        if let message = state.copyError {
            return AnyView(
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14))
        }
        if state.copyStage == .done {
            let clean = state.copyImage?.isClean ?? true
            return AnyView(
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: clean ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.title3)
                        .foregroundStyle(clean ? .green : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Copy finished").fontWeight(.medium)
                        if !clean {
                            Text("Not everything on the original read reliably — the copy carries the same gaps.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(14))
        }
        return nil
    }

    // MARK: - Header and footer

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Copy CD").font(.headline)
            Text("Copies an audio CD 1:1 onto a blank CD-R — every sample, the track boundaries and the pauses between them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            switch state.copyStage {
            case .reading:
                ProgressView(value: state.copyProgress)
                    .progressViewStyle(.linear).frame(width: 130)
                Text("Reading the original…").foregroundStyle(.secondary)
                Spacer()
                Button("Stop", role: .cancel) { state.cancelCopy() }

            case .waitingForBlank:
                ProgressView().controlSize(.small)
                Text("Waiting for a blank…").foregroundStyle(.secondary)
                Spacer()
                Button("Stop", role: .cancel) { state.cancelCopy() }

            case .burning:
                ProgressView(value: state.copyProgress)
                    .progressViewStyle(.linear).frame(width: 130)
                Text("Burning…").foregroundStyle(.secondary)
                Spacer()
                Button("Stop", role: .cancel) { state.cancelCopy() }

            case .idle, .done:
                if state.copyStage == .idle, let blocker = state.copyBlocker {
                    Text(blocker).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if state.copyImage != nil {
                    Button("Copy Again") { state.copyAgain() }
                        .help("Burns another copy from what was read — the original is not needed again")
                        .keyboardShortcut(state.copyStage == .done ? .defaultAction : nil)
                }
                if state.copyStage == .idle {
                    Button("Copy") { state.startCopy() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(state.copyBlocker != nil)
                }
            }
        }
        .padding(14)
    }
}
