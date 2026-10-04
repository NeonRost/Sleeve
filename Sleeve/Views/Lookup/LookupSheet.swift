//
//  LookupSheet.swift
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
//  "Look Up Album" when tagging (spec §4.6). Built like "Look Up Titles" in
//  the Track Splitter: search on the left, the selected album next to one's
//  own files on the right, take over at the bottom.
//

import SwiftUI

struct LookupSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State var session: LookupSession
    @FocusState private var searchFocus: LookupSearchField?

    /// Longest edge of a taken-over cover. Remembered, because it is a matter
    /// of taste that does not change from album to album.
    @AppStorage("lookup.coverSize") private var coverSize = 600
    @State private var isLoadingCover = false
    @State private var coverError: String?

    var body: some View {
        VStack(spacing: 0) {
            LookupHeader(title: "Look Up Album") {
                Picker("Source", selection: Binding(
                    get: { session.search.provider },
                    set: { provider in Task { await session.search.switchProvider(to: provider) } })) {
                    ForEach(LookupProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .help(Text(session.search.provider.note))
            }
            Divider()

            HStack(alignment: .top, spacing: 0) {
                ReleaseSearchPane(search: session.search, focus: $searchFocus)
                    .frame(width: 320)
                    .frame(maxHeight: .infinity, alignment: .top)
                Divider()
                Group {
                    if let release = session.release {
                        VStack(spacing: 0) {
                            ReleaseHeader(release: release)
                            Divider()
                            MatchTable(session: session)
                            Divider()
                            takeOver(release)
                        }
                    } else {
                        LookupPlaceholder(text: "Choose an album on the left.")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }

            Divider()
            footer
        }
        .frame(width: 940, height: 620)
        // A cover error belongs to the last attempt, not to a new choice.
        .onChange(of: session.selectedFields) { coverError = nil }
        .onChange(of: session.release?.id) { coverError = nil }
        .task {
            // Search with the guessed terms right away — as in the splitter.
            if session.search.results.isEmpty {
                await session.search.search()
                #if DEBUG
                if let pick = state.lookupDebugPick, pick > 0, pick <= session.search.results.count {
                    await session.search.select(session.search.results[pick - 1].id)
                }
                #endif
            }
        }
    }

    private func takeOver(_ release: LookupRelease) -> some View {
        TakeOverSection(fields: LookupSession.selectableFields,
                        selection: $session.selectedFields,
                        available: session.availableFields) {
            if release.provider == .discogs {
                GenreSourcePicker(selection: $session.genreSource)
            }
        } more: {
            // The size only matters for the Cover Art Archive, which offers
            // up to 1200 px; Discogs images are about 600 px anyway.
            Picker("Cover size", selection: $coverSize) {
                ForEach([600, 1000, 1200], id: \.self) { size in
                    Text(verbatim: "\(size) px").tag(size)
                }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(!session.takesCover)
            .help("Longest edge of the cover. Smaller covers keep the files small; a cover is stored in every track.")
        }
    }

    /// Applies the proposals — after fetching the cover, if it is wanted.
    /// If the cover cannot be fetched, nothing is applied: the sheet stays
    /// open, and one can untick the cover and try again.
    private func apply() async {
        var cover: Artwork?
        if session.takesCover, let release = session.release {
            isLoadingCover = true
            coverError = nil
            defer { isLoadingCover = false }
            do {
                let data = try await session.search.service.cover(of: release)
                let options = ArtworkProcessor.Options(maximumEdge: coverSize, jpegQuality: 0.85,
                                                       output: .keepSource)
                guard let prepared = ArtworkProcessor.prepare(data, pictureType: .frontCover,
                                                              options: options) else {
                    coverError = String(localized: "The cover could not be read.")
                    return
                }
                cover = prepared
            } catch {
                coverError = String(localized: "The cover could not be loaded: \(LookupService.describe(error))")
                return
            }
        }
        // Lands in the editor state, not on disk.
        state.applyLookup(session.proposals(), fields: session.selectedFields, cover: cover)
        dismiss()
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if isLoadingCover {
                ProgressView().controlSize(.small)
                Text("Loading cover…").foregroundStyle(.secondary)
            } else if let coverError {
                LookupStatus(text: Text(verbatim: coverError), isWarning: true)
            } else if session.release != nil {
                let matched = session.matchedCount, count = session.local.count
                if matched < count {
                    LookupStatus(text: Text("\(matched) of \(count) files matched"),
                                 isWarning: true)
                } else if session.deviationCount > 0 {
                    LookupStatus(text: Text("\(matched) of \(count) files matched — orange rows differ by more than 3 s"),
                                 isWarning: true)
                } else {
                    LookupStatus(text: Text("\(matched) of \(count) files matched"),
                                 isWarning: false)
                }
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Apply") { Task { await apply() } }
                .keyboardShortcut(searchFocus == nil ? .defaultAction : nil)
                .disabled(session.release == nil || session.matchedCount == 0
                          || session.selectedFields.isEmpty || isLoadingCover)
        }
        .padding(14)
    }
}

// MARK: - Matching

/// One row per file: which track of the album belongs to it, how long
/// that is and how far the file deviates from it. The proposal comes from
/// position or title; it can be corrected per row or — for the most
/// common mistake — by shifting the whole matching by one.
private struct MatchTable: View {
    @Bindable var session: LookupSession

    var body: some View {
        ScrollView {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text(verbatim: "#")
                    Text("Your file")
                    HStack(spacing: 6) {
                        Text("Title")
                        Spacer()
                        Button { session.shift(by: -1) } label: { Image(systemName: "arrow.up") }
                            .help("Shift every assignment up by one")
                        Button { session.shift(by: 1) } label: { Image(systemName: "arrow.down") }
                            .help("Shift every assignment down by one")
                    }
                    .buttonStyle(.borderless)
                    Text("Length")
                    Text("File length")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Divider().gridCellUnsizedAxes(.horizontal)

                ForEach(Array(session.local.enumerated()), id: \.element.id) { index, track in
                    GridRow {
                        Text(verbatim: String(format: "%02d", index + 1))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text(track.comparisonText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(track.filename)
                            .frame(maxWidth: 220, alignment: .leading)
                        RemoteTrackMenu(session: session, index: index)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(verbatim: session.remoteDuration(for: index).map(Timecode.short) ?? "—")
                            .monospacedDigit()
                        LookupDeltaCell(mine: track.duration,
                                        theirs: session.remoteDuration(for: index))
                    }
                }
            }
            .padding(12)
        }
    }
}

/// The assigned track as a pop-up menu — it can be swapped there.
private struct RemoteTrackMenu: View {
    @Bindable var session: LookupSession
    let index: Int

    var body: some View {
        Menu {
            Picker("", selection: Binding(
                get: { session.pairing[safe: index] ?? nil },
                set: { session.assign(remoteIndex: $0, toLocal: index) })) {
                Text("Not matched").tag(Int?.none)
                Divider()
                ForEach(Array(session.remoteTracks.enumerated()), id: \.offset) { remoteIndex, remote in
                    Text(verbatim: Self.label(remote)).tag(Int?.some(remoteIndex))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            if let assigned = session.assigned(to: index) {
                Text(verbatim: assigned.title ?? "—")
            } else {
                Text("Not matched").foregroundStyle(.orange)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
    }

    /// "3  Title  (4:12)" — position as the source writes it.
    private static func label(_ track: LookupTrack) -> String {
        var parts = [track.position, track.title].compactMap { $0 }
        if let duration = track.duration { parts.append("(\(duration))") }
        return parts.joined(separator: "  ")
    }
}
