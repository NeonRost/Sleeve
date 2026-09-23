//
//  ArtworkImportSheet.swift
//  Sleeve
//
//  Entscheidung pro Bild statt globaler Voreinstellung (Spec §4.5).
//
//  Die angezeigte Dateigröße ist keine Schätzung: das Bild wird mit den
//  aktuellen Einstellungen tatsächlich kodiert und das Ergebnis gemessen.
//  Für ein Cover in üblicher Größe dauert das wenige Millisekunden.
//

import AppKit
import SwiftUI

struct ArtworkImportSheet: View {
    @Environment(\.dismiss) private var dismiss

    let sourceData: Data
    let sourceName: String
    /// Welche Bildtypen die Auswahl schon trägt. Daraus ergibt sich, was
    /// beim Übernehmen tatsächlich passiert — und wie der Knopf heißt.
    let existingTypes: Set<PictureType>
    /// Wird mit dem fertigen Bild aufgerufen. `replacingAll == true` räumt
    /// alle bisherigen Bilder weg.
    let onApply: (Artwork, Bool) -> Void

    @State private var pictureType: PictureType = .frontCover
    /// Bewusst aus. Anhängen ist der Normalfall; alles wegzuräumen ist die
    /// Ausnahme und muss ausdrücklich gewollt sein.
    @State private var replacesAll = false
    @State private var keepsOriginalSize = true
    @State private var targetEdge = 500
    @State private var output: ArtworkProcessor.Output = .keepSource
    @State private var quality = 0.85

    @State private var result: Artwork?
    @State private var isWorking = false

    private var sourceSize: (width: Int, height: Int)? {
        ArtworkProcessor.pixelSize(of: sourceData)
    }

    private var options: ArtworkProcessor.Options {
        ArtworkProcessor.Options(
            maximumEdge: keepsOriginalSize ? 0 : targetEdge,
            jpegQuality: quality,
            output: output
        )
    }

    /// Ändert sich das, wird neu gerechnet — `task(id:)` bricht den laufenden
    /// Durchgang ab, solange am Regler gezogen wird.
    private var signature: String {
        "\(keepsOriginalSize)-\(targetEdge)-\(output.rawValue)-\(Int(quality * 100))-\(pictureType.rawValue)"
    }

    /// Sagt, was der Knopf tun wird — „Ersetzen" wäre falsch, wenn es zu
    /// diesem Bildtyp noch gar kein Bild gibt.
    private var actionLabel: LocalizedStringKey {
        if replacesAll { return "Replace All" }
        if existingTypes.contains(pictureType) { return "Replace" }
        return existingTypes.isEmpty ? "Use" : "Add"
    }

    private var outcomeHint: String {
        if replacesAll {
            return String(localized: "All existing images are removed and this one takes their place.")
        }
        if existingTypes.contains(pictureType) {
            return String(localized: "Replaces the existing image of this kind; the others stay.")
        }
        return String(localized: "Added alongside the existing images.")
    }

    private var isLossy: Bool {
        output == .jpeg || Artwork.detectMimeType(of: sourceData) == "image/jpeg"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Add artwork").font(.headline)
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
            }
            .padding(14)

            Divider()

            HStack(alignment: .top, spacing: 16) {
                preview
                controls
            }
            .padding(14)

            Divider()

            HStack {
                Text(comparison)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(actionLabel) {
                    if let result { onApply(result, replacesAll) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(result == nil)
            }
            .padding(14)
        }
        .frame(width: 560)
        .task(id: signature) {
            // Kurz warten, damit das Ziehen am Regler nicht jede Zwischenstufe
            // kodiert.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }

            isWorking = true
            let data = sourceData
            let current = options
            let type = pictureType
            result = await Task.detached(priority: .userInitiated) {
                ArtworkProcessor.prepare(data, pictureType: type, options: current)
            }.value
            isWorking = false
        }
    }

    // MARK: - Vorschau

    private var preview: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(.quaternary)
                if let result, let image = NSImage(data: result.data) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
            }
            .frame(width: 180, height: 180)

            Text(sourceName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 180)
        }
    }

    // MARK: - Bedienung

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Der Bildtyp landet wirklich im Tag. Für ein eingescanntes
            // Booklet ist „Leaflet page" gemeint, nicht „Front Cover" —
            // Abspielprogramme unterscheiden das.
            Picker("Kind", selection: $pictureType) {
                ForEach(PictureType.commonCases, id: \.self) { type in
                    Text(type.label).tag(type)
                }
            }

            if !existingTypes.isEmpty {
                Toggle("Remove all existing images", isOn: $replacesAll)
                Text(outcomeHint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Toggle("Keep original size", isOn: $keepsOriginalSize)

            if !keepsOriginalSize {
                HStack(spacing: 8) {
                    Text("Longest edge")
                    TextField("", value: $targetEdge, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Text("px").foregroundStyle(.secondary)
                    Menu {
                        ForEach([300, 500, 600, 800, 1000, 1400], id: \.self) { value in
                            Button("\(value) px") { targetEdge = value }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                .padding(.leading, 18)
            }

            Picker("Format", selection: $output) {
                ForEach(ArtworkProcessor.Output.allCases) { value in
                    Text(value.label).tag(value)
                }
            }
            .pickerStyle(.radioGroup)

            if isLossy {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Quality")
                        Slider(value: $quality, in: 0.4...1.0)
                        Text(quality, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .frame(width: 42, alignment: .trailing)
                    }
                    Text("Only applies when the image is actually re-encoded.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Vergleich

    /// Vorher und nachher nebeneinander — das ist die Angabe, auf die es
    /// ankommt.
    private var comparison: String {
        let before = describe(size: sourceSize, bytes: sourceData.count)
        guard let result else { return before }

        let after = describe(size: ArtworkProcessor.pixelSize(of: result.data),
                             bytes: result.data.count)
        if result.data == sourceData {
            return String(localized: "\(before) — embedded unchanged")
        }
        return String(localized: "\(before)  →  \(after)")
    }

    private func describe(size: (width: Int, height: Int)?, bytes: Int) -> String {
        let dimensions = size.map { "\($0.width) × \($0.height)" } ?? "?"
        let kilobytes = (Double(bytes) / 1024).rounded()
        return "\(dimensions) · \(Int(kilobytes)) KB"
    }
}
