//
//  SettingsView.swift
//  Sleeve
//

import SwiftUI

/// Coverskalierung (§4.5). Discogs-Token (§4.6) und ffmpeg-Pfad (§2.2)
/// ziehen später hier ein.
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

/// Personal Access Token, kein OAuth — für eine Desktop-App ohne Server
/// unnötig kompliziert (Spec §4.6). Der Token landet im Schlüsselbund.
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
                        // Eigener Schlüssel, sonst kollidiert er mit dem
                        // Speichern-Knopf in der Toolbar: derselbe englische
                        // Text, aber zwei verschiedene deutsche Wörter.
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
