//
//  DiscLookupSheet.swift
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
//  "Look Up Disc" in the Rip section (spec §6.2.2). Built like the other two
//  lookup sheets: search on the left, compare on the right, take over at the
//  bottom. The comparison holds the CD's own track lengths against the
//  release's — to the second, because they come from the table of contents.
//

import SwiftUI

struct DiscLookupSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State var session: DiscLookupSession
    @FocusState private var searchFocus: LookupSearchField?

    var body: some View {
        VStack(spacing: 0) {
            LookupHeader(title: "Look Up Disc") {
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
                            if session.media.count > 1 { mediumPicker }
                            comparison
                            Divider()
                            TakeOverSection(fields: DiscLookupSession.selectableFields,
                                            selection: $session.selectedFields,
                                            available: session.availableFields,
                                            columns: 6) {
                                EmptyView()
                            } more: {
                                EmptyView()
                            }
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
        .task {
            if session.search.results.isEmpty, session.release == nil {
                await state.presentDiscMatches(in: session)
                #if DEBUG
                if let pick = state.lookupDebugPick, pick > 0, pick <= session.search.results.count {
                    await session.search.select(session.search.results[pick - 1].id)
                }
                #endif
            }
        }
    }

    // MARK: - Which disc

    /// A multi-disc release: which of its discs is in the drive. Preselected
    /// by the lengths; changeable, because two discs of an audio drama can
    /// be almost equally long.
    private var mediumPicker: some View {
        HStack {
            Picker("Compare with", selection: Binding(
                get: { session.medium ?? session.media.first ?? 1 },
                set: { session.medium = $0 })) {
                ForEach(session.media, id: \.self) { number in
                    Text("Disc \(number) of \(session.media.count)").tag(number)
                }
            }
            .fixedSize()
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    // MARK: - Comparison

    private var comparison: some View {
        ScrollView {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text(verbatim: "#")
                    Text("On the CD")
                    Text("Title")
                    Text("Length")
                    Text("CD length")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Divider().gridCellUnsizedAxes(.horizontal)

                ForEach(Array(session.discNumbers.enumerated()), id: \.offset) { index, number in
                    let remote = session.remoteTracks[safe: index]
                    GridRow {
                        Text(verbatim: String(format: "%02d", number))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text(verbatim: state.discTitles[number] ?? "—")
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 200, alignment: .leading)
                        if let remote {
                            Text(verbatim: remote.title ?? "—")
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text("Not on this disc").foregroundStyle(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Text(verbatim: session.remoteLength(at: index).map(Timecode.short) ?? "—")
                            .monospacedDigit()
                        LookupDeltaCell(mine: session.discLengths[index],
                                        theirs: session.remoteLength(at: index))
                    }
                }
            }
            .padding(12)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if session.release != nil {
                let mine = session.discLengths.count, theirs = session.remoteTracks.count
                if mine != theirs {
                    LookupStatus(text: Text("\(mine) tracks on the CD, \(theirs) in the release"),
                                 isWarning: true)
                } else if session.deviationCount > 0 {
                    LookupStatus(text: Text("\(mine) tracks — orange rows differ by more than 3 s: probably another pressing"),
                                 isWarning: true)
                } else {
                    LookupStatus(text: Text("\(mine) tracks, lengths match"), isWarning: false)
                }
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Apply") {
                state.applyDiscLookup(session)
                dismiss()
            }
            .keyboardShortcut(searchFocus == nil ? .defaultAction : nil)
            .disabled(session.release == nil
                      || session.selectedFields.intersection(session.availableFields).isEmpty)
        }
        .padding(14)
    }
}
