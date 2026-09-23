//
//  TagInspector.swift
//  Sleeve
//

import SwiftUI

struct TagInspector: View {
    @Environment(AppState.self) private var state

    private var tracks: [TrackFile] {
        let selected = state.trackList.selectedTracks
        return selected.isEmpty ? [] : selected
    }

    var body: some View {
        Group {
            if tracks.isEmpty {
                ContentUnavailableView(
                    "No selection",
                    systemImage: "sidebar.left",
                    description: Text("Select one or more tracks to edit their tags.")
                )
            } else {
                Form {
                    Section {
                        field(.title, "Title")
                        field(.artist, "Artist")
                        field(.album, "Album")
                        field(.albumArtist, "Album artist")
                    }

                    Section {
                        field(.composer, "Composer")
                        field(.genre, "Genre")
                        field(.year, "Year", width: 70)
                        compilationToggle
                    }

                    Section {
                        numberPair(.trackNumber, .trackTotal, "Track")
                        numberPair(.discNumber, .discTotal, "Disc")
                    }

                    Section {
                        // Beide wachsen beim Tippen mit, statt von vornherein
                        // einen halben Bildschirm zu belegen.
                        field(.comment, "Comment", axis: .vertical)
                        field(.lyrics, "Lyrics", axis: .vertical)
                    }

                    Section("Artwork") {
                        ArtworkWell(tracks: tracks)
                    }
                }
                .formStyle(.grouped)
                .safeAreaInset(edge: .top, spacing: 0) {
                    SelectionHeader(count: tracks.count)
                }
            }
        }
    }

    // MARK: - Felder

    @ViewBuilder
    private func field(
        _ tagField: TagField,
        _ label: LocalizedStringKey,
        width: CGFloat? = nil,
        axis: Axis = .horizontal
    ) -> some View {
        LabeledContent {
            HStack(spacing: 6) {
                TextField(
                    label,
                    text: binding(for: tagField),
                    prompt: prompt(for: tagField),
                    axis: axis
                )
                .labelsHidden()
                // Ohne Rahmen ist im Formular nicht zu sehen, dass die Zeile
                // ein Eingabefeld ist.
                .textFieldStyle(.roundedBorder)
                .frame(width: width, alignment: .leading)
                .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)

                ClearButton(isEnabled: hasValue(tagField)) { clear(tagField) }
                TouchedDot(isTouched: isTouched(tagField))
            }
        } label: {
            Text(label)
        }
    }

    /// `TRACKNUMBER` und `DISCNUMBER` sind im Tag ein Wert ("3/12"), im
    /// Editor zwei Felder.
    @ViewBuilder
    private func numberPair(
        _ number: TagField,
        _ total: TagField,
        _ label: LocalizedStringKey
    ) -> some View {
        LabeledContent {
            HStack(spacing: 6) {
                TextField(label, text: binding(for: number), prompt: prompt(for: number))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 58)
                Text("of").foregroundStyle(.secondary)
                TextField(label, text: binding(for: total), prompt: prompt(for: total))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 58)
                ClearButton(isEnabled: hasValue(number) || hasValue(total)) {
                    clear(number)
                    clear(total)
                }
                TouchedDot(isTouched: isTouched(number) || isTouched(total))
                Spacer()
            }
        } label: {
            Text(label)
        }
    }

    @ViewBuilder
    private var compilationToggle: some View {
        LabeledContent {
            HStack(spacing: 6) {
                Toggle("Compilation", isOn: Binding(
                    get: { tracks.allSatisfy(\.edited.isCompilation) },
                    set: { newValue in
                        tracks.forEach { $0.set(newValue ? "1" : "0", for: .isCompilation) }
                    }
                ))
                .labelsHidden()
                TouchedDot(isTouched: isTouched(.isCompilation))
                Spacer()
            }
        } label: {
            Text("Compilation")
        }
    }

    // MARK: - Mehrfachauswahl

    /// Gemeinsamer Wert der Auswahl, oder `nil` wenn die Werte auseinandergehen.
    private func commonValue(_ field: TagField) -> String?? {
        guard let first = tracks.first else { return .some(nil) }
        let value = first.edited.stringValue(for: field)
        let allEqual = tracks.allSatisfy { $0.edited.stringValue(for: field) == value }
        return allEqual ? .some(value) : nil
    }

    private func isMixed(_ field: TagField) -> Bool {
        commonValue(field) == nil
    }

    /// Bei unterschiedlichen Werten bleibt das Feld leer und zeigt
    /// `<Multiple values>` als Platzhalter — **nicht** einfach leer, sonst
    /// sieht es aus wie „kein Wert" (Spec §4.1).
    private func prompt(for field: TagField) -> Text? {
        isMixed(field) ? Text("<Multiple values>") : nil
    }

    private func binding(for field: TagField) -> Binding<String> {
        Binding(
            get: {
                guard let common = commonValue(field) else { return "" }
                return common ?? ""
            },
            set: { newValue in
                // Schreibt auf alle ausgewählten Tracks und merkt das Feld
                // bei jedem als berührt vor.
                tracks.forEach { $0.set(newValue, for: field) }
            }
        )
    }

    private func isTouched(_ field: TagField) -> Bool {
        tracks.contains { $0.touchedFields.contains(field) }
    }

    /// Hat überhaupt einer der ausgewählten Tracks hier etwas stehen?
    private func hasValue(_ field: TagField) -> Bool {
        tracks.contains { ($0.edited.stringValue(for: field)?.isEmpty == false) }
    }

    /// Feld bei **allen** ausgewählten Tracks leeren.
    ///
    /// Das ist ausdrücklich eine Änderung, kein Nichtstun: das Feld gilt danach
    /// als berührt und wird beim Speichern geleert. Genau dafür ist der Knopf
    /// da — etwa für die Werbe-Adresse, die in heruntergeladenen MP3s im
    /// Kommentar steht.
    private func clear(_ field: TagField) {
        tracks.forEach { $0.set(nil, for: field) }
    }
}

// MARK: - Kopfzeile

private struct SelectionHeader: View {
    let count: Int

    var body: some View {
        HStack {
            Text(count == 1 ? "1 track selected" : "\(count) tracks selected")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// Leert ein Feld bei der gesamten Auswahl. Klein und zurückhaltend, aber
/// immer an derselben Stelle — bei ausgegrautem Zustand ist nichts zu leeren.
private struct ClearButton: View {
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(isHovering && isEnabled ? AnyShapeStyle(.secondary)
                                                         : AnyShapeStyle(.tertiary))
        }
        .buttonStyle(.borderless)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { isHovering = $0 }
        .help("Clear this field on all selected tracks")
    }
}

/// Macht sichtbar, was tatsächlich geschrieben wird. Ohne diesen Punkt ist
/// für den Nutzer nicht erkennbar, ob ein leeres Feld „unberührt" oder
/// „absichtlich geleert" bedeutet.
private struct TouchedDot: View {
    let isTouched: Bool

    var body: some View {
        Circle()
            .fill(isTouched ? Color.accentColor : .clear)
            .frame(width: 6, height: 6)
            .help(isTouched
                  ? "Edited — this field will be written"
                  : "Untouched — this field stays as it is on disk")
    }
}
