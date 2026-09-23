//
//  ArtworkWell.swift
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
//  Cover pictures (spec §4.5). Clicking opens the file picker, pictures can
//  be dragged in, and everything applies to the whole selection — the most
//  common case is "one cover for the whole album".
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ArtworkWell: View {
    @Environment(AppState.self) private var state

    let tracks: [TrackFile]

    @State private var index = 0
    @State private var isTargeted = false
    @State private var isHovering = false
    /// Source data and name of the picture currently being decided on.
    @State private var pending: (data: Data, name: String)?

    private var artworks: [Artwork] {
        // Only show what all of them have in common — otherwise it is unclear
        // what the picture represents at all.
        guard let first = tracks.first?.edited.artwork else { return [] }
        let allSame = tracks.allSatisfy { $0.edited.artwork == first }
        return allSame ? first : []
    }

    private var isMixed: Bool {
        guard let first = tracks.first?.edited.artwork else { return false }
        return !tracks.allSatisfy { $0.edited.artwork == first }
    }

    private var current: Artwork? {
        guard artworks.indices.contains(index) else { return artworks.first }
        return artworks[index]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            well
            caption
            controls
        }
        .onChange(of: artworks.count) { _, count in
            if index >= count { index = max(0, count - 1) }
        }
        .sheet(isPresented: Binding(get: { pending != nil },
                                    set: { if !$0 { pending = nil } })) {
            if let pending {
                ArtworkImportSheet(sourceData: pending.data,
                                   sourceName: pending.name,
                                   existingTypes: Set(artworks.map(\.pictureType))) { artwork, replacingAll in
                    state.applyArtwork(artwork, replacing: replacingAll)
                }
            }
        }
    }

    // MARK: - Picture area

    private var well: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)

            if let current, let image = NSImage(data: current.data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                VStack(spacing: 6) {
                    Image(systemName: isMixed ? "photo.on.rectangle.angled" : "photo.badge.plus")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                    Text(isMixed ? "<Multiple values>" : "Click or drop an image")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(8)
            }

            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(isHovering ? 0.6 : 0.25),
                    lineWidth: isTargeted ? 2 : 1
                )

            // With several pictures, page through them right on the picture.
            // The arrows existed in the row of buttons below, but among the
            // other icons they were hard to recognize as paging controls.
            if artworks.count > 1 {
                pager
            }
        }
        .frame(height: 150)
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture { chooseFile() }
        .onHover { isHovering = $0 }
        .dropDestination(for: Data.self) { items, _ in
            guard let data = items.first else { return false }
            pending = (data, String(localized: "Dropped image"))
            return true
        } isTargeted: { isTargeted = $0 }
        .help("Click to choose an image, or drop one here")
    }

    /// Arrows left and right over the picture, plus the page indicator.
    private var pager: some View {
        VStack(spacing: 0) {
            Spacer()
            HStack {
                pagerButton(systemImage: "chevron.left", isEnabled: index > 0) {
                    index = max(0, index - 1)
                }
                Spacer()
                pagerButton(systemImage: "chevron.right",
                            isEnabled: index < artworks.count - 1) {
                    index = min(artworks.count - 1, index + 1)
                }
            }
            Spacer()
            Text("\(index + 1) / \(artworks.count)")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(.black.opacity(0.55)))
        }
        .padding(8)
    }

    private func pagerButton(systemImage: String, isEnabled: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(.black.opacity(0.55)))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.3)
        .disabled(!isEnabled)
    }

    // MARK: - Caption

    @ViewBuilder
    private var caption: some View {
        if let current {
            VStack(alignment: .leading, spacing: 1) {
                Text(current.pictureType.label)
                    .font(.caption)
                Text("\(current.mimeType) · \(current.data.count / 1024) KB")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else if isMixed {
            Text("The selected tracks have different artwork.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("No artwork")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 6) {
            Button { chooseFile() } label: {
                Image(systemName: "plus")
            }
            .help("Choose an image for all selected tracks")

            Button {
                if artworks.count > 1 {
                    state.removeArtwork(at: index)
                    index = max(0, min(index, artworks.count - 2))
                } else {
                    state.removeArtwork()
                }
            } label: {
                Image(systemName: "minus")
            }
            .disabled(artworks.isEmpty && !isMixed)
            .help(artworks.count > 1
                  ? "Remove this image from all selected tracks"
                  : "Remove artwork from all selected tracks")

            Button { exportFile() } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .disabled(current == nil)
            .help("Export this image to a file")

            Spacer()
        }
        .buttonStyle(.borderless)
    }

    // MARK: - Panels

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose artwork for the selected tracks")
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        pending = (data, url.lastPathComponent)
    }

    private func exportFile() {
        guard let current else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = current.mimeType == "image/png" ? "cover.png" : "cover.jpg"
        panel.message = String(localized: "Export the embedded artwork")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? state.exportArtwork(to: url)
    }
}
