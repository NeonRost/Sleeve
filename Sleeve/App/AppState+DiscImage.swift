//
//  AppState+DiscImage.swift
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
//  An image of the whole disc (spec §6.9).
//
//  Deliberately not in the Rip section: there one picks tracks, and an
//  image is always the whole disc — the two exclude each other. The way in
//  is the File menu.
//

import AppKit
import Foundation
import SwiftUI

enum DiscImageStage: Sendable, Equatable {
    case idle
    case reading
    case converting
    case done
}

extension AppState {

    /// The name without extension. Empty means: the same suggestion as for
    /// the album folder, so that image and folder match.
    var suggestedImageName: String { suggestedAlbumFolderName }

    var effectiveImageName: String {
        let custom = imageBaseName.trimmingCharacters(in: .whitespaces)
        return custom.isEmpty ? suggestedImageName : PatternRenderer().sanitize(custom)
    }

    /// What currently prevents creating the image.
    var imageBlocker: String? {
        guard disc != nil else { return String(localized: "No audio CD in the drive.") }
        guard disc?.toc.hasDataTrack != true else {
            return String(localized: "This disc carries a data track. Sleeve images audio discs only.")
        }
        guard imageFormat.needsFFmpeg else { return nil }
        guard let ffmpeg else {
            return String(localized: "ffmpeg was not found — pick WAV or BIN to work without it.")
        }
        guard ffmpeg.supports(.flac) else { return AudioFormat.flac.missingEncoderHint }
        return nil
    }

    /// How large the image will be. For FLAC only an estimate, hence a range.
    var estimatedImageSize: String {
        guard let toc = disc?.toc else { return "—" }
        let bytes = Int64(toc.leadOutLBA * CDGeometry.bytesPerSector)
        switch imageFormat {
        case .bin, .wav:
            return bytes.formatted(.byteCount(style: .file))
        case .flac:
            // Losslessly compressed music typically ends up at 55–70 %.
            let low = Int64(Double(bytes) * 0.55), high = Int64(Double(bytes) * 0.70)
            return "\(low.formatted(.byteCount(style: .file)))–\(high.formatted(.byteCount(style: .file)))"
        }
    }

    func showImageSheet() {
        imageResult = nil
        imageError = nil
        imageStage = .idle
        imageProgress = 0
        isShowingImageSheet = true
        // The section may never have been opened — then we do not know the
        // disc yet.
        if disc == nil { Task { await refreshDisc() } }
    }

    func startImage() {
        guard let disc, imageBlocker == nil, imageTask == nil else { return }

        let folder = ripDestinationFolder
        let name = effectiveImageName
        let settings = ripSettings
        let format = imageFormat
        let album = discAlbum.isEmpty ? nil : discAlbum
        let artist = discArtist.isEmpty ? nil : discArtist
        let titles = discTitles
        let tool = ffmpeg

        imageStage = .reading
        imageProgress = 0
        imageResult = nil
        imageError = nil

        imageTask = Task { [ripEngine] in
            for await event in ripEngine.createImage(
                in: folder, baseName: name, format: format, settings: settings,
                albumTitle: album, albumArtist: artist,
                trackTitles: titles, ffmpeg: tool)
            {
                switch event {
                case let .reading(fraction):
                    imageProgress = fraction
                case .converting:
                    imageStage = .converting
                case let .finished(result):
                    imageResult = result
                    imageStage = .done
                case let .failed(reason):
                    imageError = reason
                    imageStage = .idle
                }
            }
            imageTask = nil
            if imageStage == .reading || imageStage == .converting { imageStage = .idle }
            _ = disc
        }
    }

    func cancelImage() {
        imageTask?.cancel()
        imageTask = nil
        imageStage = .idle
        imageProgress = 0
    }

    func revealImage() {
        guard let result = imageResult else { return }
        NSWorkspace.shared.activateFileViewerSelecting([result.audioURL, result.cueURL])
    }
}
