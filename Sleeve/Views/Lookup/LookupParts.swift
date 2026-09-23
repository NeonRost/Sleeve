//
//  LookupParts.swift
//  Sleeve
//
//  Die Bausteine, aus denen beide Nachschlage-Blätter bestehen: „Album
//  nachschlagen" beim Taggen (Spec §4.6) und „Titel nachschlagen" im Track
//  Splitter (§7.12). Gleiche Teile, damit beide gleich aussehen, gleich heißen
//  und sich gleich bedienen — links suchen, rechts vergleichen, unten
//  übernehmen.
//

import SwiftUI

/// Wo die Tastatur gerade steht. Solange ein Suchfeld den Fokus hat, sucht
/// Return — sonst übernimmt es. Ohne diese Weiche würde Return in einem
/// Suchfeld das Blatt schließen, sobald ein Album geladen ist.
enum LookupSearchField: Hashable { case artist, album, year, catalogNumber }

/// Titel links, Quelle rechts.
struct LookupHeader<Source: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var source: Source

    var body: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            source
                .pickerStyle(.segmented)
                .fixedSize()
        }
        .padding(14)
    }
}

// MARK: - Links: suchen

struct ReleaseSearchPane: View {
    @Bindable var search: ReleaseSearch
    var focus: FocusState<LookupSearchField?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("Artist").gridColumnAlignment(.trailing)
                    TextField("", text: $search.query.artist)
                        .focused(focus, equals: .artist)
                }
                GridRow {
                    Text("Album")
                    TextField("", text: $search.query.releaseTitle)
                        .focused(focus, equals: .album)
                }
                GridRow {
                    Text("Year")
                    HStack(spacing: 8) {
                        TextField("", text: $search.query.year)
                            .focused(focus, equals: .year)
                            .frame(width: 56)
                        Text("Catalog no.")
                        TextField("", text: $search.query.catalogNumber)
                            .focused(focus, equals: .catalogNumber)
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
            .onSubmit { Task { await search.search() } }

            HStack(spacing: 8) {
                Button("Search") { Task { await search.search() } }
                    .keyboardShortcut(focus.wrappedValue != nil ? .defaultAction : nil)
                    .disabled(!search.canSearch)
                if search.isWorking { ProgressView().controlSize(.small) }
            }

            if let blocker = search.providerBlocker {
                Label(blocker, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let message = search.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            List(search.results, selection: Binding(
                get: { search.selectedID },
                set: { id in Task { await search.select(id) } })) { result in
                LookupResultRow(result: result).tag(result.id)
            }
            .listStyle(.bordered)
        }
        .padding(12)
    }
}

struct LookupResultRow: View {
    let result: LookupSearchResult

    var body: some View {
        HStack(spacing: 8) {
            LookupThumbnail(url: result.thumbnailURL, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(result.title).lineLimit(1)
                Text(result.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 1)
    }
}

struct LookupThumbnail: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            RoundedRectangle(cornerRadius: 3).fill(.quaternary)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

// MARK: - Rechts: vergleichen

/// Das gewählte Album über dem Vergleich.
struct ReleaseHeader: View {
    let release: LookupRelease

    var body: some View {
        HStack(spacing: 10) {
            LookupThumbnail(url: release.thumbnailURL, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(release.title).fontWeight(.medium).lineLimit(1)
                Text(release.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// Solange rechts nichts zu vergleichen ist.
struct LookupPlaceholder: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Eigener Wert mit Abweichung zur Liste: „3:42 +0.4 s".
struct LookupDeltaCell: View {
    let mine: Double?
    let theirs: Double?

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: mine.map(Timecode.short) ?? "—").monospacedDigit()
            if let mine, let theirs {
                Text(verbatim: String(format: "%+.1f s", mine - theirs))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(LookupComparison.deviates(mine, from: theirs)
                                     ? Color.orange : .secondary)
            }
        }
    }
}

// MARK: - Unten: übernehmen

/// Welche Felder übernommen werden. Rechts oben Platz für eine Einstellung
/// dazu (Genre oder Style bei Discogs), hinten für weitere Schalter.
struct TakeOverSection<Accessory: View, More: View>: View {
    let fields: [TagField]
    @Binding var selection: Set<TagField>
    /// Was die Quelle überhaupt hergibt — der Rest ist ausgegraut.
    var available: Set<TagField>?
    var columns = 5
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var more: More

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Take over").font(.caption).foregroundStyle(.secondary)
                Spacer()
                accessory
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading),
                                     count: columns), spacing: 4) {
                ForEach(fields, id: \.self) { field in
                    Toggle(field.takeOverLabel, isOn: Binding(
                        get: { selection.contains(field) && isAvailable(field) },
                        set: { isOn in
                            if isOn { selection.insert(field) } else { selection.remove(field) }
                        }))
                    .disabled(!isAvailable(field))
                }
                more
            }
            .font(.callout)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func isAvailable(_ field: TagField) -> Bool {
        available?.contains(field) ?? true
    }
}

/// Bei Discogs stehen Genre und Style getrennt — gilt in beiden Blättern.
struct GenreSourcePicker: View {
    @Binding var selection: GenreSource

    var body: some View {
        Picker("Genre from", selection: $selection) {
            ForEach(GenreSource.allCases) { source in
                Text(source.label).tag(source)
            }
        }
        .fixedSize()
        .font(.callout)
        .help("Discogs keeps genre and style apart — style is usually the one you want")
    }
}

/// Unten links: passt es, oder ist etwas zu prüfen?
struct LookupStatus: View {
    let text: Text
    let isWarning: Bool

    var body: some View {
        Label {
            text
        } icon: {
            Image(systemName: isWarning ? "exclamationmark.triangle" : "checkmark.circle")
        }
        .foregroundStyle(isWarning ? Color.orange : .secondary)
    }
}

extension TagField {
    var takeOverLabel: LocalizedStringKey {
        switch self {
        case .title:       "Title"
        case .artist:      "Artist"
        case .albumArtist: "Album artist"
        case .album:       "Album"
        case .year:        "Year"
        case .genre:       "Genre"
        case .trackNumber: "Track"
        case .trackTotal:  "Track total"
        case .discNumber:  "Disc"
        case .discTotal:   "Disc total"
        default:           "—"
        }
    }
}
