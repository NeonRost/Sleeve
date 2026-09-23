//
//  SplitLookupSheet.swift
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
//  "Look Up Titles" in the Track Splitter (spec §7.12) — from MusicBrainz,
//  Discogs or a pasted track list. Built like "Look Up Album" when tagging:
//  search on the left, compare on the right, take over at the bottom.
//
//  Before anything is applied, the list stands next to what Sleeve found. If
//  the count does not match, one sees it here — and not only in wrongly
//  named files.
//

import SwiftUI

struct SplitLookupSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @FocusState private var searchFocus: LookupSearchField?

    @State private var fields = Set(TrackListing.takeOverFields)
    @State private var alignBoundaries = true
    @State private var didChooseAlignment = false
    @State private var genreSource: GenreSource?

    private var mode: SplitLookupMode { state.splitLookupMode }

    private var listing: TrackListing? {
        switch mode {
        case .musicBrainz, .discogs:
            return state.splitSearch?.release.map {
                TrackListing(release: $0, genreSource: genreSource ?? state.genreSource)
            }
        case .pasted:
            let parsed = TrackListing(pasted: state.splitPasteText)
            return parsed.entries.isEmpty ? nil : parsed
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            LookupHeader(title: "Look Up Titles") {
                Picker("Source", selection: Binding(get: { mode }, set: choose)) {
                    Text(verbatim: LookupProvider.musicBrainz.displayName).tag(SplitLookupMode.musicBrainz)
                    Text(verbatim: LookupProvider.discogs.displayName).tag(SplitLookupMode.discogs)
                    Text("Track list").tag(SplitLookupMode.pasted)
                }
                .help(mode.provider.map { Text($0.note) }
                      ?? Text("A track list with start times, as it stands under album videos."))
            }
            Divider()

            HStack(alignment: .top, spacing: 0) {
                Group {
                    if mode == .pasted {
                        pastePane
                    } else if let search = state.splitSearch {
                        ReleaseSearchPane(search: search, focus: $searchFocus)
                    }
                }
                .frame(width: 320)
                .frame(maxHeight: .infinity, alignment: .top)
                Divider()
                Group {
                    if let listing {
                        VStack(spacing: 0) {
                            if mode != .pasted, let release = state.splitSearch?.release {
                                ReleaseHeader(release: release)
                                Divider()
                            }
                            comparison(listing)
                            Divider()
                            takeOver(listing)
                        }
                    } else {
                        LookupPlaceholder(text: mode == .pasted
                                          ? "Paste a track list on the left."
                                          : "Choose an album on the left.")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }

            Divider()
            footer
        }
        .frame(width: 940, height: 620)
        .task { await prepareSearch() }
    }

    // MARK: - Search

    /// On first opening, search right away with the suggestion from the file
    /// name — if the album is nowhere to be found, the hint to paste a list is
    /// there immediately instead of only after a click.
    private func prepareSearch() async {
        if state.splitSearch == nil {
            let guess = state.suggestedSplitSearch
            var query = DiscogsClient.SearchQuery()
            query.artist = guess.artist
            query.releaseTitle = guess.album
            let search = state.makeReleaseSearch(query: query)
            state.splitSearch = search
            if mode != .pasted { state.splitLookupMode = SplitLookupMode(search.provider) }
        }
        guard let search = state.splitSearch else { return }
        search.nothingFoundMessage = String(localized: "Nothing found. Try fewer words — or paste the track list from the video description.")
        guard mode != .pasted, search.results.isEmpty, search.release == nil else { return }
        await search.search()
        #if DEBUG
        if let pick = state.splitDebugPick, pick > 0, pick <= search.results.count {
            await search.select(search.results[pick - 1].id)
        }
        #endif
    }

    private func choose(_ newMode: SplitLookupMode) {
        state.splitLookupMode = newMode
        guard let provider = newMode.provider, let search = state.splitSearch else { return }
        Task { await search.switchProvider(to: provider) }
    }

    // MARK: - Pasted

    private var pastePane: some View {
        @Bindable var state = state
        return VStack(alignment: .leading, spacing: 6) {
            Text("Paste the track list from the video description — one track per line, with its start time.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $state.splitPasteText)
                .font(.callout.monospaced())
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary.opacity(0.5)))
        }
        .padding(12)
    }

    // MARK: - Comparison

    private func comparison(_ listing: TrackListing) -> some View {
        let found = state.splitTracks
        return ScrollView {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text(verbatim: "#")
                    Text("Title")
                    Text(listing.hasStarts ? "Starts" : "Length")
                    Text(listing.hasStarts ? "Found start" : "Found length")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Divider().gridCellUnsizedAxes(.horizontal)

                ForEach(Array(listing.entries.enumerated()), id: \.offset) { index, entry in
                    let theirs = entry.start ?? entry.duration
                    GridRow {
                        Text(verbatim: String(format: "%02d", index + 1))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text(entry.title)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(verbatim: theirs.map(Timecode.short) ?? "—")
                            .monospacedDigit()
                        if index < found.count {
                            let range = found[index].range
                            LookupDeltaCell(mine: listing.hasStarts ? range.start : range.duration,
                                            theirs: theirs)
                        } else {
                            Text("Not found").foregroundStyle(.orange)
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    // MARK: - Take over

    private func takeOver(_ listing: TrackListing) -> some View {
        TakeOverSection(fields: TrackListing.takeOverFields, selection: $fields,
                        available: listing.availableFields, columns: 6) {
            if mode == .discogs {
                GenreSourcePicker(selection: Binding(
                    get: { genreSource ?? state.genreSource },
                    set: { genreSource = $0 }))
            }
        } more: {
            Toggle("Boundaries", isOn: Binding(
                get: { canAlign(listing) && align(listing) },
                set: { alignBoundaries = $0; didChooseAlignment = true }))
                .disabled(!canAlign(listing))
                .help("Set the boundaries from the list's start times or lengths. They snap to a detected silence nearby; where there is none — a transition without a pause — the list decides.")
        }
    }

    private func canAlign(_ listing: TrackListing) -> Bool {
        listing.hasStarts || listing.hasDurations
    }

    /// Start times are reliable — then align. With lengths only when the count
    /// does not match: if it does, Sleeve's boundaries are usually right
    /// already, and laying a CD's measure onto a YouTube recording tends to do
    /// harm.
    private func align(_ listing: TrackListing) -> Bool {
        didChooseAlignment
            ? alignBoundaries
            : listing.hasStarts || listing.entries.count != state.splitTracks.count
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if let listing {
                let count = listing.entries.count, found = state.splitTracks.count
                // The count alone reassures too early: on the real album 13
                // matched 13, and still one boundary was 106 s off.
                if count != found {
                    LookupStatus(text: Text("\(count) titles, but \(found) tracks found"),
                                 isWarning: true)
                } else if deviations(listing) > 0 {
                    LookupStatus(text: Text("\(count) titles for \(found) tracks — orange rows differ by more than 3 s"),
                                 isWarning: true)
                } else {
                    LookupStatus(text: Text("\(count) titles for \(found) tracks"),
                                 isWarning: false)
                }
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Apply") {
                guard let listing else { return }
                state.applyListing(listing,
                                   fields: fields.intersection(listing.availableFields),
                                   alignBoundaries: canAlign(listing) && align(listing))
                dismiss()
            }
            .keyboardShortcut(searchFocus == nil ? .defaultAction : nil)
            .disabled(!canApply)
        }
        .padding(14)
    }

    private var canApply: Bool {
        guard let listing else { return false }
        return !fields.intersection(listing.availableFields).isEmpty
            || (canAlign(listing) && align(listing))
    }

    /// How many rows deviate from the list by more than the tolerance.
    private func deviations(_ listing: TrackListing) -> Int {
        zip(listing.entries, state.splitTracks).filter { entry, track in
            if let start = entry.start {
                return LookupComparison.deviates(track.range.start, from: start)
            }
            return LookupComparison.deviates(track.range.duration, from: entry.duration)
        }.count
    }
}
