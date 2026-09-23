//
//  AppState+DiscImage.swift
//  Sleeve
//
//  Ein Abbild der ganzen Scheibe (Spec §9.1).
//
//  Steht bewusst nicht im Rip-Bereich: dort wählt man Spuren aus, und ein
//  Abbild ist immer die ganze Scheibe — die beiden schließen sich aus. Der
//  Weg führt über die Ablage.
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

    /// Der Name ohne Endung. Leer heißt: derselbe Vorschlag wie beim
    /// Albumordner, damit Abbild und Ordner zusammenpassen.
    var suggestedImageName: String { suggestedAlbumFolderName }

    var effectiveImageName: String {
        let custom = imageBaseName.trimmingCharacters(in: .whitespaces)
        return custom.isEmpty ? suggestedImageName : PatternRenderer().sanitize(custom)
    }

    /// Was das Erzeugen gerade verhindert.
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

    /// Wie groß das Abbild wird. Bei FLAC nur zu schätzen, deshalb als Spanne.
    var estimatedImageSize: String {
        guard let toc = disc?.toc else { return "—" }
        let bytes = Int64(toc.leadOutLBA * CDGeometry.bytesPerSector)
        switch imageFormat {
        case .bin, .wav:
            return bytes.formatted(.byteCount(style: .file))
        case .flac:
            // Verlustfrei gepackte Musik landet erfahrungsgemäß bei 55–70 %.
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
        // Der Bereich wurde vielleicht nie geöffnet — dann kennen wir die
        // Scheibe noch nicht.
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
