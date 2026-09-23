//
//  SettingsView.swift
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

import SwiftUI

/// Cover scaling (§4.5) and the Discogs token (§4.6).
struct SettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        Form {
            DiscogsSection()
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 300)
    }
}

// MARK: - Discogs

/// Personal access token, no OAuth — needlessly complicated for a desktop app
/// without a server (spec §4.6). The token goes into the keychain.
private struct DiscogsSection: View {
    @Environment(AppState.self) private var state
    @State private var entered = ""
    @State private var didSave = false

    var body: some View {
        @Bindable var state = state

        Section {
            if state.hasDiscogsToken {
                LabeledContent("Token") {
                    HStack {
                        Label("Stored in your keychain", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.callout)
                        Spacer()
                        Button("Remove") {
                            Task { await state.updateDiscogsToken(nil) }
                            entered = ""
                        }
                    }
                }
            } else {
                LabeledContent("Token") {
                    HStack {
                        SecureField("", text: $entered, prompt: Text("Paste your token"))
                            .textFieldStyle(.roundedBorder)
                        // Its own key, or it collides with the Save button in the
                        // toolbar: the same English text, but two different German
                        // words.
                        Button("Save Token") {
                            Task {
                                await state.updateDiscogsToken(entered)
                                entered = ""
                                didSave = true
                            }
                        }
                        .disabled(entered.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }

            Picker("Genre from", selection: $state.genreSource) {
                ForEach(GenreSource.allCases) { source in
                    Text(source.label).tag(source)
                }
            }
        } header: {
            Text("Discogs")
        } footer: {
            Text("Create a personal access token in your Discogs account settings, under Developers. Sleeve stores it in your keychain, never in its preferences.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
